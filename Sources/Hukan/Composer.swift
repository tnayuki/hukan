import AppKit

/// The composer's text view. A bare Return sends; Shift+Return (or Option) puts a newline in the
/// message. Kept off the single-line field editor so instructions can span several lines.
final class ComposerTextView: NSTextView, UndoStackOwner {
  /// The message being typed has an undo stack of its own — the window's was shared with every
  /// file open on the desk, so ⌘Z here could revert a source file nobody was looking at (see
  /// `UndoStackOwner`).
  let ownUndoManager = UndoManager()
  override var undoManager: UndoManager? { ownUndoManager }

  var onSend: (() -> Void)?
  var onChange: (() -> Void)?
  /// Files/images dropped or pasted in. The wrapper turns each path into an attachment chip.
  var onAttach: (([String]) -> Void)?
  /// Esc pressed in the field. Returns true if it was consumed (a turn was running, so Esc
  /// interrupted it like the stop button); false lets the text view do its normal Esc handling.
  var onCancel: (() -> Bool)?
  /// The completion list's first refusal on the keys it needs — the arrows to walk it, Return
  /// and Tab to take a row, Esc to put it away. Returns true when it used the key. Every one of
  /// these already means something in the composer, so the list only ever borrows them while it
  /// is open, and gives each back the moment it closes — Return included, which a list with no
  /// row selected does not take at all.
  var onCompletionKey: ((CompletionKey) -> Bool)?

  /// Esc is the keyboard twin of the in-field stop button: while a turn runs it interrupts it,
  /// so you never reach for the mouse to stop an agent. With nothing running it falls through to
  /// NSTextView's own behaviour (dismiss completion, etc.). An open completion list comes first:
  /// Esc there means "put this away", and interrupting the turn as well would be two things at
  /// once from one press.
  override func cancelOperation(_ sender: Any?) {
    if onCompletionKey?(.dismiss) == true { return }
    if onCancel?() == true { return }
    super.cancelOperation(sender)
  }

  override func insertNewline(_ sender: Any?) {
    let mods = NSApp.currentEvent?.modifierFlags ?? []
    if mods.contains(.shift) || mods.contains(.option) {
      super.insertNewline(sender)
      return
    }
    // A row under the selection is what Return is answering; sending then would post a
    // half-typed command name. A list with nothing selected — a prompt list nobody asked for —
    // answers nothing and the message goes.
    if onCompletionKey?(.accept) == true { return }
    onSend?()
  }

  override func insertTab(_ sender: Any?) {
    if onCompletionKey?(.complete) == true { return }
    super.insertTab(sender)
  }

  override func moveUp(_ sender: Any?) {
    if onCompletionKey?(.up) == true { return }
    super.moveUp(sender)
  }

  override func moveDown(_ sender: Any?) {
    if onCompletionKey?(.down) == true { return }
    super.moveDown(sender)
  }

  override func didChangeText() {
    super.didChangeText()
    onChange?()
  }

  // MARK: - Files and images

  // A dropped or pasted file/image becomes an attachment chip above the field, not inline bytes
  // or a path typed into the text: the agent opens it through its Read tool from the path the
  // chip carries. A bare clipboard image (a screenshot with no file behind it) is written to a
  // temp file first, so it becomes a path too.

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    droppablePaths(from: sender.draggingPasteboard) != nil ? .copy : super.draggingEntered(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    if let paths = droppablePaths(from: sender.draggingPasteboard) {
      onAttach?(paths)
      return true
    }
    return super.performDragOperation(sender)
  }

  override func paste(_ sender: Any?) {
    if let paths = droppablePaths(from: .general) {
      onAttach?(paths)
      return
    }
    super.paste(sender)
  }

  /// Enable the Paste command for a file or image on the clipboard. Without this, a plain-text
  /// view validates Paste against its readable types (text only) and disables it — so ⌘V never
  /// reaches `paste(_:)`, it just beeps. This re-enables it exactly when `droppablePaths` can turn
  /// the clipboard into a path.
  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(paste(_:)), canDrop(from: .general) { return true }
    return super.validateUserInterfaceItem(item)
  }

  /// A cheap "would `droppablePaths` return something?" for menu validation — no temp file written.
  private func canDrop(from pasteboard: NSPasteboard) -> Bool {
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      urls.contains(where: { !Self.isDirectory($0) })
    {
      return true
    }
    if pasteboard.canReadItem(withDataConformingToTypes: [
      NSPasteboard.PasteboardType.png.rawValue,
      NSPasteboard.PasteboardType.tiff.rawValue,
    ]) {
      return true
    }
    return NSImage(pasteboard: pasteboard) != nil
  }

  /// File URLs on the pasteboard become their paths; a bare image becomes one temp-file path.
  /// nil means "nothing to hand off as a path" — let the text view do its normal thing.
  ///
  /// A directory is not one of them: a chip stands for a file the agent will open with its Read
  /// tool, and a folder behind one would be a document icon in front of something that is not a
  /// document. The refusal belongs here rather than at the files panel's rows, which is where it
  /// used to live — the panel is one of several places a drag comes from, and a folder dragged
  /// out of the Finder walked straight past it.
  func droppablePaths(from pasteboard: NSPasteboard) -> [String]? {
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
    {
      let files = urls.filter { !Self.isDirectory($0) }
      return files.isEmpty ? nil : files.map(\.path)
    }
    if let image = NSImage(pasteboard: pasteboard), let path = Self.writeTempImage(image) {
      return [path]
    }
    return nil
  }

  static func isDirectory(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
      && directory.boolValue
  }

  private static func writeTempImage(_ image: NSImage) -> String? {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else { return nil }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("hukan-paste-\(UUID().uuidString).png")
    do {
      try png.write(to: url)
      return url.path
    } catch { return nil }
  }
}

/// A view that shows the arrow cursor instead of inheriting the I-beam from the text it floats
/// over — a pill floating over the transcript. A `LayerSurface` because it is one: its layer
/// carries catalog colours, which have to be re-resolved where they are drawn.
final class ArrowCursorView: LayerSurface {
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .arrow)
  }
}

/// A one- to few-line compose box. Reads as the old rounded field but grows with the text up to a
/// ceiling, then scrolls, so a long paragraph never swallows the transcript above it.
final class ComposerInput: LayerSurface {
  var onSend: ((String, [Attachment]) -> Void)?
  /// Return on an empty field, nothing attached. There is no message to send, so the press
  /// means the one thing left for it to mean — a second Return after the one that queued a line
  /// is that line asked for now (see `AgentSession.sendLastQueuedNow`).
  var onSendEmpty: (() -> Void)?
  /// Pressing the in-field stop button. Wired to interrupt the attached session's turn.
  var onStop: (() -> Void)?
  /// The field's text changed — by a keystroke or by `commit` clearing it. The controller
  /// mirrors this into the attached session so each session keeps its own unsent draft.
  var onChange: (() -> Void)?

  private let textView = ComposerTextView()
  private let scroll = NSScrollView()
  private let stopButton = NSButton()
  private var scrollTrailingFull: NSLayoutConstraint!
  private var scrollTrailingWithStop: NSLayoutConstraint!
  private var heightConstraint: NSLayoutConstraint!
  // Roomy from the start: the field is the most-clicked target in the pane, so it opens at about
  // three lines rather than one and only grows past that. `recomputeHeight` clamps to this floor.
  private let minHeight: CGFloat = 64
  private let maxHeight: CGFloat = 150

  /// A pasted or dropped file/image rides here as a chip until the message is sent, rather than
  /// as a path typed into the field. On send an image goes as a native image block and a file as
  /// its path (see `ClaudeSession.send`).
  private let attachmentsStack = NSStackView()
  private var attachmentsHeightConstraint: NSLayoutConstraint!
  private let attachmentRowHeight: CGFloat = 52
  private(set) var attachments: [Attachment] = []

  /// AppKit focuses the text view itself, not this wrapper.
  var focusTarget: NSView { textView }

  /// What a `/` in this field completes against. Set from the session on screen; empty until
  /// some engine in the window has reported its list, and a field with an empty list simply
  /// never opens one.
  var commands: [ClaudeCommand] = [] {
    didSet { updateCompletion() }
  }

  /// Where the past prompts come from when the field is completing one. A source rather than a
  /// list, because it is read at the keystroke: the repository's history lands in the background
  /// (see `Workspace.promptHistory(forWorktree:)`) and a stored copy here would be whatever it
  /// was at the last refresh.
  var promptSource: (() -> [PromptCompletion.Indexed])?

  private let completionPanel = CommandCompletionPanel()

  /// While a turn is in flight the stop button rides in the field's right edge; otherwise it is
  /// hidden and the field reads as a plain compose box. The thinking indicator is not here — it
  /// floats at the foot of the transcript (see `RunningColumnViewController`), where it reads as
  /// part of the conversation rather than getting lost in the input box.
  ///
  /// The button takes real width: the text area ends where the button begins, so a long draft
  /// wraps short of it rather than running underneath.
  var isRunning = false {
    didSet {
      stopButton.isHidden = !isRunning
      if isRunning {
        scrollTrailingFull.isActive = false
        scrollTrailingWithStop.isActive = true
      } else {
        scrollTrailingWithStop.isActive = false
        scrollTrailingFull.isActive = true
      }
      recomputeHeight()
    }
  }

  var isEnabled = true {
    didSet {
      textView.isEditable = isEnabled
      textView.isSelectable = isEnabled
    }
  }

  var stringValue: String {
    get { textView.string }
    set {
      textView.string = newValue
      recomputeHeight()
      // Set from outside — a session switched, a queued line reopened — so whatever the list was
      // showing belonged to the text that just left.
      completionPanel.dismiss()
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.borderWidth = 1
    paintLayer = {
      $0.borderColor = NSColor.separatorColor.cgColor
      $0.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    textView.font = .systemFont(ofSize: 14)
    textView.isRichText = false
    // NSTextView records no undo by default, so ⌘Z did nothing in the composer.
    textView.allowsUndo = true
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 6, height: 7)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.onSend = { [weak self] in self?.commit() }
    textView.onChange = { [weak self] in
      self?.recomputeHeight()
      self?.updateCompletion()
      self?.onChange?()
    }
    textView.onCompletionKey = { [weak self] key in
      guard let self, self.completionPanel.isVisible else { return false }
      switch key {
      case .up:
        self.completionPanel.move(-1)
      case .down:
        self.completionPanel.move(1)
      case .dismiss:
        self.completionPanel.dismiss()
      case .accept:
        guard let item = self.completionPanel.selected else { return false }
        self.take(item)
      case .complete:
        guard let item = self.completionPanel.selected ?? self.completionPanel.best else {
          return false
        }
        self.take(item)
      }
      return true
    }
    completionPanel.onPick = { [weak self] item in self?.take(item) }
    textView.onAttach = { [weak self] paths in self?.attach(paths) }
    // Esc mirrors the stop button, but only while a turn is in flight — otherwise let the text
    // view keep Esc for its own use (and never swallow it into a silent no-op).
    textView.onCancel = { [weak self] in
      guard let self, self.isRunning else { return false }
      self.onStop?()
      return true
    }
    // Accept file and image drops on top of whatever the text view already takes, so a dropped
    // file — or a bare image dragged from a browser — reaches performDragOperation rather than
    // being refused. A pasted image needs no registration; paste() reads the pasteboard direct.
    textView.registerForDraggedTypes(textView.registeredDraggedTypes + [.fileURL, .png, .tiff])

    // The attachment chips sit in a row above the field; the field fills the rest. The row
    // collapses to zero height when empty (constraint below), so an ordinary compose box is
    // unchanged until something is attached.
    attachmentsStack.orientation = .horizontal
    attachmentsStack.spacing = 6
    attachmentsStack.alignment = .centerY
    attachmentsStack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 0, right: 8)
    attachmentsStack.translatesAutoresizingMaskIntoConstraints = false
    attachmentsStack.clipsToBounds = true
    addSubview(attachmentsStack)

    scroll.drawsBackground = false
    scroll.hasVerticalScroller = false
    scroll.autohidesScrollers = true
    scroll.documentView = textView
    scroll.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scroll)

    attachmentsHeightConstraint = attachmentsStack.heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      attachmentsStack.topAnchor.constraint(equalTo: topAnchor),
      attachmentsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
      attachmentsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
      attachmentsHeightConstraint,
      scroll.topAnchor.constraint(equalTo: attachmentsStack.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    // A borderless stop glyph in the field's right edge, vertically centred on the text
    // area (not pinned to a corner, so a field that has grown several lines tall keeps the
    // button in its middle). It owns its column — the text area's trailing edge swaps to the
    // button's leading edge while a turn runs (see `isRunning`) — so it never sits over text.
    stopButton.translatesAutoresizingMaskIntoConstraints = false
    stopButton.isBordered = false
    stopButton.bezelStyle = .regularSquare
    stopButton.imagePosition = .imageOnly
    stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
    stopButton.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
    stopButton.contentTintColor = .secondaryLabelColor
    stopButton.toolTip = "Interrupt the running agent"
    stopButton.isHidden = true
    stopButton.target = self
    stopButton.action = #selector(stopClicked)
    addSubview(stopButton)

    NSLayoutConstraint.activate([
      stopButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
      stopButton.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
      stopButton.widthAnchor.constraint(equalToConstant: 20),
      stopButton.heightAnchor.constraint(equalToConstant: 20),
    ])

    // The two homes for the text area's trailing edge: the field's edge when idle, the stop
    // button's leading edge while a turn runs. Swapped in `isRunning`.
    scrollTrailingFull = scroll.trailingAnchor.constraint(equalTo: trailingAnchor)
    scrollTrailingWithStop = scroll.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor)
    scrollTrailingFull.isActive = true

    heightConstraint = heightAnchor.constraint(equalToConstant: minHeight)
    heightConstraint.isActive = true
  }

  @objc private func stopClicked() { onStop?() }

  required init?(coder: NSCoder) { fatalError() }

  // A width change rewraps the text, which can change its height; recompute after the pass.
  // The threshold in `recomputeHeight` stops the constraint edit from looping back here.
  override func layout() {
    super.layout()
    recomputeHeight()
  }

  // MARK: - Completion

  /// Open, refilter or close the list to match what is in the field. Driven by every keystroke,
  /// which is affordable because the list is in memory and the match is a substring — the same
  /// reasoning as the files panel's filter.
  ///
  /// The two lists are asked in the order they can be told apart: a leading `/` is a command and
  /// nothing else, so the command list answers first and the prompts are what is left. Never
  /// both at once — one message is being completed, and mixing the engine's commands into a list
  /// of things this person has said would make the row taken by Return depend on which kind
  /// happened to sort first.
  private func updateCompletion() {
    guard isEnabled else {
      completionPanel.dismiss()
      return
    }
    if !commands.isEmpty, let query = CommandCompletion.query(in: textView.string) {
      completionPanel.present(
        CommandCompletion.matches(query, in: commands).map(CompletionItem.command), below: self)
      return
    }
    let prompts = promptSource?() ?? []
    if !prompts.isEmpty,
      let query = PromptCompletion.query(
        in: textView.string, isComposing: textView.hasMarkedText())
    {
      completionPanel.present(
        PromptCompletion.matches(query, in: prompts).map(CompletionItem.prompt), below: self)
      return
    }
    completionPanel.dismiss()
  }

  /// Put a picked row in the field, caret at the end. Written through the text view's own edit
  /// path rather than by assigning `string`, so ⌘Z takes it back the way it takes back anything
  /// else typed here — which is the whole of the way back from a prompt taken by mistake.
  private func take(_ item: CompletionItem) {
    let all = NSRange(location: 0, length: (textView.string as NSString).length)
    let replacement: String
    switch item {
    case .command(let command): replacement = CommandCompletion.completion(for: command)
    case .prompt(let prompt): replacement = prompt
    }
    if textView.shouldChangeText(in: all, replacementString: replacement) {
      textView.replaceCharacters(in: all, with: replacement)
      textView.didChangeText()
    }
    textView.setSelectedRange(NSRange(location: (replacement as NSString).length, length: 0))
    // After the edit, not before: `didChangeText` re-runs the filter, and a name with no argument
    // still matches itself — the list would reopen on the row just taken.
    completionPanel.dismiss()
  }

  /// Scripting seam: put text in the field the way a keystroke does — through the text view's
  /// own change path, so the list opens, filters and closes exactly as it would for a person
  /// rather than through a shortcut only a script can take.
  func typeForScripting(_ text: String) {
    let all = NSRange(location: 0, length: (textView.string as NSString).length)
    guard textView.shouldChangeText(in: all, replacementString: text) else { return }
    textView.replaceCharacters(in: all, with: text)
    textView.didChangeText()
    textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
  }

  /// Drive the open list from a script, the way the arrow keys and Return do.
  @discardableResult
  func completionKeyForScripting(_ key: CompletionKey) -> Bool {
    textView.onCompletionKey?(key) ?? false
  }

  /// What the list is showing, one row a line, with `▸` on the selected one.
  var completionReportForScripting: String { completionPanel.report }

  /// The list must not outlive the field it belongs to: it is a panel over the window, so a
  /// column that goes away, a session switched, or the window losing key would otherwise leave
  /// it floating with nothing behind it.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { completionPanel.dismiss() }
  }

  private func commit() {
    completionPanel.dismiss()
    let text = textView.string
    // A message may be attachments alone (a screenshot with no words), so empty text is not a
    // bar to sending when something is attached.
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    else {
      onSendEmpty?()
      return
    }
    onSend?(text, attachments)
    textView.string = ""
    clearAttachments()
    recomputeHeight()
    onChange?()
  }

  private func recomputeHeight() {
    guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
    lm.ensureLayout(for: tc)
    let content = lm.usedRect(for: tc).height + textView.textContainerInset.height * 2
    let text = min(max(content, minHeight), maxHeight)
    let attach = attachments.isEmpty ? 0 : attachmentRowHeight
    let target = text + attach
    if abs(heightConstraint.constant - target) > 0.5 { heightConstraint.constant = target }
    if abs(attachmentsHeightConstraint.constant - attach) > 0.5 {
      attachmentsHeightConstraint.constant = attach
    }
    scroll.hasVerticalScroller = content > maxHeight
  }

  // MARK: - Attachments

  /// Take files on as chips — from a drop or a paste, and from a queued line reopened for
  /// editing, which brings back what was attached to it rather than losing it.
  func attach(_ paths: [String]) {
    for path in paths where !attachments.contains(where: { $0.path == path }) {
      let image = NSImage(contentsOfFile: path)
      attachments.append(Attachment(path: path, isImage: image != nil))
      attachmentsStack.addArrangedSubview(makeChip(path: path, image: image))
    }
    recomputeHeight()
  }

  private func clearAttachments() {
    attachments.removeAll()
    for view in attachmentsStack.arrangedSubviews { view.removeFromSuperview() }
  }

  @objc private func removeAttachmentClicked(_ sender: NSButton) {
    guard let path = sender.identifier?.rawValue, let chip = sender.superview else { return }
    attachments.removeAll { $0.path == path }
    chip.removeFromSuperview()
    recomputeHeight()
  }

  /// One attachment. An image is its own thumbnail — you see what you attached, which is the
  /// whole of what identifies it — and anything else is named, because a document glyph is the
  /// same glyph for every file and says only that there is one. That was survivable while an
  /// attachment came from the Finder now and then; a row dragged off the files panel makes it
  /// the ordinary case, and three anonymous squares above the composer are three files you have
  /// to remember the order of. The name is the last component, truncated in the middle so the
  /// extension survives — it is half of what tells two of these apart — and the full path stays
  /// the tooltip.
  private func makeChip(path: String, image: NSImage?) -> NSView {
    let chip = LayerSurface()
    chip.wantsLayer = true
    chip.layer?.cornerRadius = 5
    chip.layer?.borderWidth = 1
    chip.paintLayer = {
      $0.backgroundColor = NSColor.quaternarySystemFill.cgColor
      $0.borderColor = NSColor.separatorColor.cgColor
    }
    chip.translatesAutoresizingMaskIntoConstraints = false
    chip.toolTip = path

    let thumb = NSImageView()
    thumb.imageScaling = .scaleProportionallyUpOrDown
    thumb.translatesAutoresizingMaskIntoConstraints = false
    if let image {
      thumb.image = image
    } else {
      thumb.image = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: "file")
      thumb.contentTintColor = .secondaryLabelColor
      thumb.symbolConfiguration = .init(pointSize: 13, weight: .regular)
      thumb.setContentHuggingPriority(.required, for: .horizontal)
      thumb.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    chip.addSubview(thumb)

    let remove = NSButton(
      title: "",
      image: NSImage(
        systemSymbolName: "xmark.circle.fill",
        accessibilityDescription: "Remove")!,
      target: self, action: #selector(removeAttachmentClicked(_:)))
    remove.isBordered = false
    remove.imagePosition = .imageOnly
    remove.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
    remove.contentTintColor = .secondaryLabelColor
    remove.translatesAutoresizingMaskIntoConstraints = false
    // The × carries its own path; its chip is its superview, so one handler serves every chip.
    remove.identifier = NSUserInterfaceItemIdentifier(path)
    chip.addSubview(remove)

    var constraints: [NSLayoutConstraint] = [
      chip.heightAnchor.constraint(equalToConstant: 40),
      remove.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 3),
      remove.topAnchor.constraint(equalTo: chip.topAnchor, constant: -3),
    ]
    if image != nil {
      constraints += [
        chip.widthAnchor.constraint(equalToConstant: 40),
        thumb.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 3),
        thumb.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -3),
        thumb.topAnchor.constraint(equalTo: chip.topAnchor, constant: 3),
        thumb.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -3),
      ]
    } else {
      let name = NSTextField(labelWithString: (path as NSString).lastPathComponent)
      name.font = .systemFont(ofSize: 11)
      name.textColor = .labelColor
      name.lineBreakMode = .byTruncatingMiddle
      name.maximumNumberOfLines = 1
      name.cell?.truncatesLastVisibleLine = true
      name.translatesAutoresizingMaskIntoConstraints = false
      chip.addSubview(name)
      // Wide enough for a name of ordinary length, capped so a handful of them still fit the row
      // — the field truncates rather than the chip growing off the end of the composer.
      let width = chip.widthAnchor.constraint(lessThanOrEqualToConstant: 160)
      width.priority = .required
      constraints += [
        width,
        thumb.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 8),
        thumb.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        name.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 6),
        name.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
        name.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
      ]
    }
    NSLayoutConstraint.activate(constraints)
    return chip
  }
}
