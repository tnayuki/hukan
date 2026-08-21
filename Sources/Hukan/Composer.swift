import AppKit

/// The composer's text view. A bare Return sends; Shift+Return (or Option) puts a newline in the
/// message. Kept off the single-line field editor so instructions can span several lines.
final class ComposerTextView: NSTextView {
  var onSend: (() -> Void)?
  var onChange: (() -> Void)?
  /// Files/images dropped or pasted in. The wrapper turns each path into an attachment chip.
  var onAttach: (([String]) -> Void)?
  /// Esc pressed in the field. Returns true if it was consumed (a turn was running, so Esc
  /// interrupted it like the stop button); false lets the text view do its normal Esc handling.
  var onCancel: (() -> Bool)?

  /// Esc is the keyboard twin of the in-field stop button: while a turn runs it interrupts it,
  /// so you never reach for the mouse to stop an agent. With nothing running it falls through to
  /// NSTextView's own behaviour (dismiss completion, etc.).
  override func cancelOperation(_ sender: Any?) {
    if onCancel?() == true { return }
    super.cancelOperation(sender)
  }

  override func insertNewline(_ sender: Any?) {
    let mods = NSApp.currentEvent?.modifierFlags ?? []
    if mods.contains(.shift) || mods.contains(.option) {
      super.insertNewline(sender)
    } else {
      onSend?()
    }
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
    if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
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
  private func droppablePaths(from pasteboard: NSPasteboard) -> [String]? {
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
    {
      return urls.map(\.path)
    }
    if let image = NSImage(pasteboard: pasteboard), let path = Self.writeTempImage(image) {
      return [path]
    }
    return nil
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
/// over — a pill floating over the transcript.
final class ArrowCursorView: NSView {
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .arrow)
  }
}

/// A one- to few-line compose box. Reads as the old rounded field but grows with the text up to a
/// ceiling, then scrolls, so a long paragraph never swallows the transcript above it.
final class ComposerInput: NSView {
  var onSend: ((String, [Attachment]) -> Void)?
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
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.separatorColor.cgColor
    layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

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
      self?.onChange?()
    }
    textView.onAttach = { [weak self] paths in self?.addAttachments(paths) }
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

  private func commit() {
    let text = textView.string
    // A message may be attachments alone (a screenshot with no words), so empty text is not a
    // bar to sending when something is attached.
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    else { return }
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

  private func addAttachments(_ paths: [String]) {
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

  /// One attachment: a small thumbnail (the image itself, so you see what you attached) or a
  /// document icon for a non-image file, with an × to drop it. The path is the tooltip.
  private func makeChip(path: String, image: NSImage?) -> NSView {
    let chip = NSView()
    chip.wantsLayer = true
    chip.layer?.cornerRadius = 5
    chip.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
    chip.layer?.borderWidth = 1
    chip.layer?.borderColor = NSColor.separatorColor.cgColor
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
      thumb.symbolConfiguration = .init(pointSize: 18, weight: .regular)
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

    NSLayoutConstraint.activate([
      chip.widthAnchor.constraint(equalToConstant: 40),
      chip.heightAnchor.constraint(equalToConstant: 40),
      thumb.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 3),
      thumb.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -3),
      thumb.topAnchor.constraint(equalTo: chip.topAnchor, constant: 3),
      thumb.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -3),
      remove.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 3),
      remove.topAnchor.constraint(equalTo: chip.topAnchor, constant: -3),
    ])
    return chip
  }
}
