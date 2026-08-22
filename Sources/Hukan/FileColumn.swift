import AppKit

/// The editor's text view. Deliberately not `makeTranscriptTextView`'s, though the wiring below
/// is nearly the same boilerplate: that factory also installs the transcript's own machinery —
/// a layout delegate that lays every paragraph out as a `BlockBackgroundFragment`, a click
/// delegate that owns the `NSTextViewDelegate` slot to fold tool calls, and an `NSTextView`
/// subclass that reads every double-click as a possible fold re-toggle. None of that means
/// anything to a source file. Ten lines of duplicated AppKit boilerplate is the cheaper side
/// of the trade.
func makeEditorTextView() -> (NSScrollView, NSTextView) {
  let textView = NSTextView(usingTextLayoutManager: true)
  let scrollView = NSScrollView()
  scrollView.documentView = textView
  textView.minSize = .zero
  textView.maxSize = NSSize(
    width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
  textView.isVerticallyResizable = true
  textView.isHorizontallyResizable = false
  textView.autoresizingMask = [.width]
  textView.textContainer?.widthTracksTextView = true
  // Nothing is open yet; the load path turns editing on once a file's text has landed, and off
  // again while the next one is being read.
  textView.isEditable = false
  textView.isSelectable = true
  textView.drawsBackground = false
  textView.textContainerInset = NSSize(width: 14, height: 12)
  scrollView.drawsBackground = false
  scrollView.hasVerticalScroller = true
  return (scrollView, textView)
}

// MARK: - Right: files (the editable source)

final class FileContentViewController: NSViewController {
  private let scrollView: NSScrollView
  private let textView: NSTextView
  private var worktree: Worktree?
  private var path: String?
  /// The open file's bare name, for the one place it is still spoken aloud: the alert that asks
  /// about an unsaved edit. The pane itself never names the file — the tab does (see `loadView`).
  private var baseFileName = ""
  /// True once the reader has typed into the source without it being written back yet. Guards
  /// the on-disk refresh (an agent editing the same worktree must not clobber an unsaved edit)
  /// and gates the save. The tab wears the dot for it, so every transition — not just the first
  /// edit — has to reach the strip.
  private var isDirty = false {
    didSet {
      guard isDirty != oldValue else { return }
      onDirtyChanged?()
    }
  }
  /// Set once the current path's text has landed, so a reveal asked for mid-load can wait.
  private var isLoaded = false
  private var pendingReveal: (line: Int, term: String?)?
  /// Fired after a save lands, so the column can re-ask git and the file's changed state catches
  /// up (an FSEvents IgnoreSelf drops our own write, so nothing else would notice it).
  var onSaved: (() -> Void)?
  /// Fired the moment an untouched file is first edited, so a preview tab can pin itself — you do
  /// not want the tab you just started typing in to be discarded by the next single click.
  var onEdited: (() -> Void)?
  /// Fired on every crossing into and out of unsaved, so the tab can put its dot up and take it
  /// down. Separate from `onEdited` because that one is the pin and fires once; this one has to
  /// catch the save, and the Don't Save that throws the edit away.
  var onDirtyChanged: (() -> Void)?

  init() {
    (scrollView, textView) = makeEditorTextView()
    super.init(nibName: nil, bundle: nil)
    textView.allowsUndo = true
    // ⌘F in a file is the text view's own find bar, the way ⌘F in a terminal is SwiftTerm's.
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
  }

  required init?(coder: NSCoder) { fatalError() }

  /// The pane is the text and nothing else — no header naming the file. The tab above it already
  /// carries that name (and the full path in its tooltip), so a strip of chrome under the strip
  /// was saying it twice, costing 36pt of the file to do so. The one thing the header held that
  /// the tab did not — the unsaved-edit dot — moved onto the tab, where it is beside the ✕ that
  /// would discard it.
  override func loadView() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: container.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    view = container
    render()
  }

  /// The open file, so the column can fall back to it when a switch is cancelled.
  var currentPath: String? { path }

  /// Before an unsaved edit is lost, ask. Save writes it, Don't Save drops it, Cancel keeps it
  /// and returns false so the caller aborts the move; a no-op returning true when nothing is
  /// dirty. The one modal in the file pane, and only over an otherwise unrecoverable loss.
  func confirmLeavingCurrentFile() -> Bool {
    guard isDirty else { return true }
    let alert = NSAlert()
    alert.messageText = "Save the changes to “\(baseFileName)”?"
    alert.informativeText = "Your edits will be lost if you don’t save them."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
    alert.addButton(withTitle: "Don’t Save")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      save()
      return true
    case .alertThirdButtonReturn:
      isDirty = false
      return true
    default:
      return false
    }
  }

  @objc private func textChanged() {
    guard textView.isEditable else { return }
    // Fire the pin hook only on the transition into dirty, not on every keystroke — and before
    // the flag flips, because the flag's own hook rebuilds the tab strip and the pin has to be
    // in place by then or the tab redraws as a preview it no longer is.
    let firstEdit = !isDirty
    if firstEdit { onEdited?() }
    isDirty = true
  }

  /// Whether the open file has an unsaved edit, so the Save menu item can enable itself.
  var hasUnsavedEdit: Bool { isDirty }

  /// Write the edited source back to disk, atomically, and let the column re-ask git so the
  /// file's changed state updates. Driven by Cmd+S, or by leaving the file. A no-op unless there
  /// is an unsaved edit to a real file.
  func save() {
    guard isDirty, textView.isEditable, let worktree, let path else { return }
    let url = worktree.url.appendingPathComponent(path)
    do {
      try textView.string.write(to: url, atomically: true, encoding: .utf8)
      isDirty = false
      onSaved?()
    } catch {
      NSSound.beep()
    }
  }

  /// Open a file's source. There is no second mode to pick — the pane is the source, always.
  func show(worktree: Worktree?, path: String?) {
    loadViewIfNeeded()
    // The caller confirms any unsaved edit before switching (see the column); the new file
    // starts clean.
    isDirty = false
    isLoaded = false
    pendingReveal = nil
    self.worktree = worktree
    self.path = path
    baseFileName = path.map { ($0 as NSString).lastPathComponent } ?? ""
    render()
  }

  /// Re-read the open file after it changed on disk, keeping the reader where they were
  /// scrolled. Unlike `show` it does not jump to the top — an agent saving mid-read should
  /// refresh the text under the eye, not yank the view around.
  func refreshCurrent() {
    loadViewIfNeeded()
    // An unsaved edit outweighs the on-disk copy — never overwrite it from a refresh.
    guard !isDirty else { return }
    guard worktree != nil, path != nil else { return }
    render(preservingScroll: true)
  }

  func render(preservingScroll: Bool = false) {
    loadViewIfNeeded()
    guard let worktree, let path else {
      textView.isEditable = false
      textView.textStorage?.setAttributedString(
        NSAttributedString(
          string: "",
          attributes: [.font: monospace]))
      return
    }
    let url = worktree.url
    let restoreY = preservingScroll ? scrollView.contentView.bounds.origin.y : nil
    DispatchQueue.global(qos: .userInitiated).async {
      let rendered = Self.renderSource(Git.fileContents(at: url, path: path) ?? "")
      DispatchQueue.main.async { [weak self] in
        guard let self, self.path == path else { return }
        self.textView.textStorage?.setAttributedString(rendered)
        // Always the source, so always editable. Typed text inherits its monospace.
        self.textView.isEditable = true
        self.textView.typingAttributes = [.font: monospace, .foregroundColor: NSColor.labelColor]
        self.isDirty = false
        self.isLoaded = true
        self.textView.scroll(restoreY.map { NSPoint(x: 0, y: $0) } ?? .zero)
        if let pending = self.pendingReveal {
          self.pendingReveal = nil
          self.reveal(line: pending.line, term: pending.term)
        }
      }
    }
  }

  /// Scroll to `line` (1-based) and select `term` on it — or the whole line when the term is
  /// absent, as it is once the line was edited. The files panel's hand-off for a content hit.
  /// Deferred until the file's text has landed.
  func reveal(line: Int, term: String?) {
    guard isLoaded, let storage = textView.textStorage else {
      pendingReveal = (line, term)
      return
    }
    let text = storage.string as NSString
    // Walk line ranges from the top; a line past the end lands on the last one.
    var lineRange = text.lineRange(for: NSRange(location: 0, length: 0))
    var current = 1
    while current < line, NSMaxRange(lineRange) < text.length {
      lineRange = text.lineRange(for: NSRange(location: NSMaxRange(lineRange), length: 0))
      current += 1
    }
    var target = lineRange
    if let term, !term.isEmpty {
      let found = text.range(of: term, options: [.caseInsensitive], range: lineRange)
      if found.location != NSNotFound { target = found }
    }
    // Trailing newline off the selection, so a whole-line select does not spill onto the next.
    if target.length > 0, text.character(at: target.location + target.length - 1) == 0x0A {
      target.length -= 1
    }
    textView.setSelectedRange(target)
    textView.scrollRangeToVisible(target)
    textView.showFindIndicator(for: target)
  }

  /// ⌘F: the text view's find bar.
  func performFind(_ sender: Any?) {
    view.window?.makeFirstResponder(textView)
    textView.performFindPanelAction(sender)
  }

  private static func renderSource(_ raw: String) -> NSAttributedString {
    NSAttributedString(
      string: raw, attributes: [.font: monospace, .foregroundColor: NSColor.labelColor])
  }
}

/// The worktree's desk (the tabs: files and terminals) and the files panel that indexes it.
///
/// Not a view controller, and not a split: the two sit in different places in the window now —
/// the desk beside the transcript, under the toolbar, and the panel as a column of its own on
/// the trailing edge, running the window's full height the way the rail does on the leading
/// edge. A split view holding both would put a divider view in the titlebar, which shows
/// through the toolbar's glass; two full-height items have no divider between them to leak (a
/// sidebar item's is zero-width). So what is left here is the seam that keeps the pair talking
/// — a pick in the panel opens a tab on the desk — with no view of its own. The window owns
/// where they sit and how wide they are.
final class FileColumns {
  var workspace: Workspace? {
    didSet { desk.workspace = workspace }
  }
  var onNeedsReload: (() -> Void)?
  /// ⌃⌘T / the desk's `+` bubbles up to the window controller, which owns terminal creation.
  var onNewTerminal: (() -> Void)?
  /// A double-click on a tab, or its menu, asking for the whole window. The columns are the
  /// window controller's, so this bubbles up the same way.
  var onSetMaximized: ((Bool) -> Void)?

  let desk = WorktreeDeskViewController()
  let panel = FilesPanelViewController()

  init() {
    desk.onNewTerminal = { [weak self] in self?.onNewTerminal?() }
    desk.onSetMaximized = { [weak self] maximized in self?.onSetMaximized?(maximized) }
    // A save is the panel's cue too: an FSEvents IgnoreSelf drops our own write, so the content
    // hits would otherwise keep listing the line just fixed.
    desk.onFileSaved = { [weak self] in
      self?.panel.filesChangedOnDisk()
      self?.onNeedsReload?()
    }
    // A single click previews, a double-click (or Return) pins — the rail's gesture, kept.
    panel.onSelect = { [weak self] path, line in self?.openFromPanel(path, line: line, pin: false) }
    panel.onActivate = { [weak self] path, line in self?.openFromPanel(path, line: line, pin: true)
    }
  }

  private func openFromPanel(_ path: String, line: Int?, pin: Bool) {
    guard let workspace,
      let worktree = workspace.selectedWorktreeID.flatMap({ workspace.worktree(id: $0) })
    else { return }
    desk.openFile(
      worktree: worktree, path: path, preview: !pin, reveal: line.map { ($0, panel.query) })
  }

  /// ⌘P: the panel's filter, focused and ready to type. The window has already made sure the
  /// panel is showing.
  func focusFilter() {
    panel.focusFilter()
  }

  /// ⌘⇧F: the same field, with what is already typed searched for in the files rather than
  /// filtered by — the two keys differ in which operation they run, not in where they land.
  func searchInFiles() {
    panel.focusSearch()
  }

  func reload() {
    guard let workspace else { return }
    let worktree = workspace.selectedWorktreeID.flatMap { workspace.worktree(id: $0) }

    // Query git for a worktree that has not been loaded yet, then redraw — this is what fills in
    // the panel's tree for the selected worktree.
    if let worktree, !worktree.hasLoadedFiles || worktree.needsFileReload {
      workspace.loadFiles(worktreeID: worktree.id) { [weak self] in
        self?.onNeedsReload?()
      }
    }

    panel.show(worktree: worktree)
    desk.reload(worktreeID: workspace.selectedWorktreeID)
  }

  /// Show a just-created terminal in the desk. The controller has already appended it to
  /// `Workspace.terminals`.
  func openTerminal(id: UUID) {
    desk.open(terminalID: id)
  }

  /// ⌘W: close the active tab (file or terminal). Returns whether one was showing to close.
  @discardableResult
  func closeActiveTab() -> Bool {
    desk.closeActiveTab()
  }

  /// Whether any tab is the active surface — the Close Tab menu item validates on this.
  var hasClosableTab: Bool { desk.isViewLoaded && desk.hasClosableTab }

  /// Whether a terminal is the active tab — the Clear Terminal menu item validates on this.
  var hasActiveTerminal: Bool { desk.isViewLoaded && desk.activeTerminal != nil }

  /// Whether the desk holds more than one tab — the tab-cycling items validate on this.
  var hasMultipleTabs: Bool { desk.isViewLoaded && desk.tabCount > 1 }

  /// How many tabs the strip holds — ⌘1…⌘9 validate on it, so ⌘7 with four tabs is disabled
  /// rather than a beep.
  var tabCount: Int { desk.isViewLoaded ? desk.tabCount : 0 }

  /// Whether the window is showing the desk alone. The window controller owns the columns and
  /// so owns the answer; the desk is told, and reads it back for its tab menu.
  var isDeskMaximized: Bool {
    get { desk.isMaximized }
    set { desk.isMaximized = newValue }
  }

  /// ⌘1…⌘9: show the Nth tab.
  func selectTab(at index: Int) {
    desk.selectTab(at: index)
  }

  /// ⌃⇥ / ⌃⇧⇥: step through the desk's tabs.
  func selectNextTab() {
    desk.cycleTab(by: 1)
  }

  func selectPreviousTab() {
    desk.cycleTab(by: -1)
  }

  /// ⌘K: clear the active terminal's scrollback.
  func clearActiveTerminal() {
    desk.activeTerminal?.clearBuffer()
  }

  /// ⌘F: find within the active surface — a terminal's find bar (SwiftTerm's) or a file's (the
  /// text view's). The menu item is the sender both bars read their action tag from
  /// (`showFindPanel`), so it is passed straight through.
  func findInActiveSurface(_ sender: Any?) {
    desk.performFind(sender)
  }

  /// Whether the active surface has something ⌘F can search — the Find item validates on this.
  var canFind: Bool { desk.isViewLoaded && desk.canFind }

  /// A terminal renamed itself (OSC title); repaint the strip's labels.
  func refreshTerminalTabs() {
    guard desk.isViewLoaded else { return }
    desk.reload(worktreeID: workspace?.selectedWorktreeID)
  }

  /// The selected worktree's files changed on disk: refresh every open file and the panel (its
  /// tree if the list moved, its content hits so the worklist reflects the disk), then reload so
  /// the rail's Changed section picks up the new diffstat.
  func refreshInPlace(changed: Set<String>? = nil) {
    desk.refreshOpenFiles(changed: changed)
    panel.filesChangedOnDisk()
    onNeedsReload?()
  }

  /// Cmd+S from the menu: write the open source file back to disk.
  func saveCurrent() {
    desk.activeFileContent?.save()
  }

  /// Whether the open file has an unsaved edit, so the Save menu item can validate itself.
  var hasUnsavedEdit: Bool { desk.activeFileContent?.hasUnsavedEdit ?? false }
}
