import AppKit

/// The editor's text view. Deliberately not `makeTranscriptTextView`'s, though the wiring below
/// is nearly the same boilerplate: that factory also installs the transcript's own machinery —
/// a layout delegate that lays every paragraph out as a `BlockBackgroundFragment`, a click
/// delegate that owns the `NSTextViewDelegate` slot to fold tool calls, and an `NSTextView`
/// subclass that reads every double-click as a possible fold re-toggle. None of that means
/// anything to a source file, and the fragment widens every line's rendering surface to the
/// column's full width — which here, where nothing wraps, is the width of the longest line in
/// the file. Ten lines of duplicated AppKit boilerplate is the cheaper side of the trade.
///
/// It never wraps: a gutter bar or number maps to exactly one file line, and wrapping would
/// split that line across rows. Long lines scroll sideways, and wrapped reading stays the
/// transcript's, for prose — which is what `EditorScrollView` is for.
func makeEditorTextView() -> (NSScrollView, NSTextView) {
  let textView = NSTextView(usingTextLayoutManager: true)
  let scrollView = EditorScrollView()
  scrollView.documentView = textView
  textView.minSize = .zero
  textView.maxSize = NSSize(
    width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
  textView.isVerticallyResizable = true
  textView.isHorizontallyResizable = true
  textView.autoresizingMask = []
  textView.textContainer?.widthTracksTextView = false
  textView.textContainer?.size = NSSize(
    width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
  // Every paragraph is laid out as an `EmphasisFragment`, the one place a bold or an italic can
  // be drawn without touching the font (see `SyntaxHighlighting`). The layout manager holds its
  // delegate weakly, so the table lives as long as the view does, associated with it.
  let emphasis = EmphasisTable()
  objc_setAssociatedObject(textView, &emphasisTableKey, emphasis, .OBJC_ASSOCIATION_RETAIN)
  textView.textLayoutManager?.delegate = emphasis
  // Nothing is open yet; the load path turns editing on once a file's text has landed, and off
  // again while the next one is being read.
  textView.isEditable = false
  textView.isSelectable = true
  textView.drawsBackground = false
  // Narrower on the leading edge than the transcript's 14: that one is prose with nothing to
  // its left, so it needs the whole inset to keep off the window's edge, while here the gutter
  // already sits there with a padding of its own. Stacked, the two put 18pt of nothing between
  // a change bar and the line it marks.
  textView.textContainerInset = NSSize(width: 4, height: 12)
  scrollView.drawsBackground = false
  scrollView.hasVerticalScroller = true
  scrollView.hasHorizontalScroller = true
  return (scrollView, textView)
}

private nonisolated(unsafe) var emphasisTableKey = 0

// MARK: - Right: files (the editable source)

final class FileContentViewController: NSViewController {
  private let scrollView: NSScrollView
  private let textView: NSTextView
  private var gutter: EditorGutter?
  /// The open file's syntax highlighter, held for exactly as long as the file is showing —
  /// nil when no vendored grammar covers it, and the text renders plain.
  private var highlighter: SyntaxHighlighter?
  private var worktree: Worktree?
  private var path: String?
  /// What the gutter diffs the buffer against — the file at HEAD and in the index. Read when
  /// the file opens and again whenever git moves under it, so an edit re-diffs two strings in
  /// process instead of re-opening the repository on every keystroke.
  private var fileBase = Git.FileBase()
  /// Coalesces the re-diff a burst of typing would otherwise ask for.
  private var pendingDiff: DispatchWorkItem?
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

    let gutter = EditorGutter(scrollView: scrollView, textView: textView)
    gutter.backgroundColor = .windowBackgroundColor
    scrollView.verticalRulerView = gutter
    scrollView.hasVerticalRuler = true
    scrollView.rulersVisible = true
    self.gutter = gutter

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
    scheduleLineChanges()
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
    // The new file starts over: the highlighter is per-language, the gutter per-file.
    highlighter = path.flatMap { SyntaxHighlighter(textView: textView, path: $0) }
    gutter?.lineChanges = Git.LineChanges()
    fileBase = Git.FileBase()
    render()
  }

  /// The panel renamed the open file: a buffer is keyed by `(Worktree, relative path)`, so the
  /// pane follows the name rather than pointing at one that is gone. A clean buffer re-reads,
  /// since the language and the gutter's base are both per-path; a dirty one keeps its text the
  /// way it does through an agent's write, and ⌘S now writes it to the new name.
  func renamed(to newPath: String) {
    loadViewIfNeeded()
    path = newPath
    baseFileName = (newPath as NSString).lastPathComponent
    highlighter = SyntaxHighlighter(textView: textView, path: newPath)
    guard !isDirty else {
      // The text stays; what it is measured against moves with the name.
      loadFileBase()
      return
    }
    render(preservingScroll: true)
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
    let restoreOrigin = preservingScroll ? scrollView.contentView.bounds.origin : nil
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
        self.loadFileBase()
        // A refresh keeps the reader where they were, sideways included; an open starts at
        // the leading edge — which is not x = 0 once a ruler is in the way, see the helper.
        if let restoreOrigin {
          self.scrollView.contentView.scroll(to: restoreOrigin)
          self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        } else {
          self.scrollView.scrollToLeadingEdge(y: 0)
        }
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

  /// Re-read what the gutter diffs against — the file at HEAD and in the index — and re-diff
  /// once it lands. Off the main thread, like every other git question; a stale answer for a
  /// since-switched file is dropped.
  private func loadFileBase() {
    guard let worktree, let path else {
      fileBase = Git.FileBase()
      gutter?.lineChanges = Git.LineChanges()
      return
    }
    let url = worktree.url
    DispatchQueue.global(qos: .utility).async {
      let base = Git.fileBase(at: url, path: path)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.path == path else { return }
        self.fileBase = base
        self.updateLineChanges()
      }
    }
  }

  /// Re-diff after a short pause. Typing is a burst and each keystroke moves every line below
  /// it, so the bars are recomputed once the burst stops rather than per character.
  private func scheduleLineChanges() {
    pendingDiff?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.updateLineChanges() }
    pendingDiff = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
  }

  /// Diff the *buffer* against the cached base, off the main thread. The bars therefore mark an
  /// edit as it is typed, and go on marking it until it is committed — staging alone only
  /// hollows them.
  private func updateLineChanges() {
    pendingDiff?.cancel()
    pendingDiff = nil
    guard let path, !fileBase.isEmpty else {
      gutter?.lineChanges = Git.LineChanges()
      return
    }
    let base = fileBase
    let current = textView.string
    DispatchQueue.global(qos: .utility).async {
      let changes = Git.lineChanges(base: base, current: current)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.path == path else { return }
        self.gutter?.lineChanges = changes
      }
    }
  }

  private static func renderSource(_ raw: String) -> NSAttributedString {
    NSAttributedString(
      string: raw, attributes: [.font: monospace, .foregroundColor: NSColor.labelColor])
  }
}

/// The worktree's desk (the tabs: files, web, terminals) and the files panel that indexes it.
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
  /// A directory with it is the files panel's Open in Terminal; nil is the worktree's root.
  var onNewTerminal: ((URL?) -> Void)?
  /// A double-click on a tab, or its menu, asking for the whole window. The columns are the
  /// window controller's, so this bubbles up the same way.
  var onSetMaximized: ((Bool) -> Void)?

  let desk = WorktreeDeskViewController()
  let panel = FilesPanelViewController()

  init() {
    desk.onNewTerminal = { [weak self] in self?.onNewTerminal?(nil) }
    desk.onNewBrowser = { [weak self] in self?.openBrowser() }
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
    // The History section is the panel's other half and opens tabs the same way — the index is
    // here, the reading is on the desk.
    panel.history.onSelect = { [weak self] oid in self?.openCommitFromPanel(oid, pin: false) }
    panel.history.onActivate = { [weak self] oid in self?.openCommitFromPanel(oid, pin: true) }
    panel.history.onLoadMore = { [weak self] in self?.loadMoreHistory() }
    // The panel's context menu: a shell where the row is, and the writes it makes to the
    // worktree.
    panel.onNewTerminal = { [weak self] url in self?.onNewTerminal?(url) }
    panel.onFileEdit = { [weak self] edit in self?.applyFileEdit(edit) }
  }

  /// The files panel wrote to the worktree. FSEvents is asked to ignore hukan's own writes, so
  /// nothing here happens on its own: the desk is told what moved under its tabs, and git is
  /// asked again — with an empty moved set, since no open file's *contents* changed.
  private func applyFileEdit(_ edit: FilesPanelViewController.FileEdit) {
    // The panel's worktree, not the selection's: they agree, but the panel is where the edit was
    // made, and the path it reports is relative to that.
    guard let workspace, let worktree = panel.worktree else { return }
    switch edit {
    case .createdFolder:
      // Nothing to open: a folder has no tab, and git has nothing to re-read for an empty one —
      // the panel rebuilds its own tree, since it is the only party that can see it.
      return
    case .created(let path):
      // A file made from the menu is one you are about to write in, so it opens as a lasting tab
      // rather than in the preview slot the next click would take back.
      desk.openFile(worktree: worktree, path: path, preview: false)
    case .renamed(let from, let to):
      desk.fileRenamed(worktreeID: worktree.id, from: from, to: to)
    case .deleted(let path):
      desk.fileDeleted(worktreeID: worktree.id, path: path)
    }
    workspace.refreshFiles(worktreeID: worktree.id, moved: [])
  }

  private func openFromPanel(_ path: String, line: Int?, pin: Bool) {
    guard let workspace,
      let worktree = workspace.selectedWorktreeID.flatMap({ workspace.worktree(id: $0) })
    else { return }
    desk.openFile(
      worktree: worktree, path: path, preview: !pin, reveal: line.map { ($0, panel.query) })
  }

  /// The History section reached the end of what has been read. The limit lives on the worktree,
  /// so every other reason to re-read git — a commit landing, a branch moving — hands back what
  /// has been paged in rather than the first page again.
  private func loadMoreHistory() {
    guard let workspace, let worktreeID = workspace.selectedWorktreeID else { return }
    // Not `needsFileReload`: that asks for the whole worktree again — the tracked list and the
    // working-tree diff along with the log — and the section asks for a page every time it is
    // scrolled to the end.
    workspace.loadMoreHistory(worktreeID: worktreeID) { [weak self] in
      self?.onNeedsReload?()
    }
  }

  private func openCommitFromPanel(_ oid: String, pin: Bool) {
    guard let workspace,
      let worktree = workspace.selectedWorktreeID.flatMap({ workspace.worktree(id: $0) })
    else { return }
    desk.openCommit(worktree: worktree, oid: oid, preview: !pin)
  }

  /// ⌘P: the panel's filter, focused and ready to type. The window has already made sure the
  /// panel is showing.
  func focusFilter() {
    panel.focusFilter()
  }

  /// The toolbar's History glyph and ⌘⇧L: fold the History section away, or bring it back.
  func toggleHistorySection() {
    panel.toggleHistory()
  }

  /// Unfold it without folding it — what revealing the panel from the toolbar's glyph does.
  func expandHistorySection() {
    panel.expandHistory()
  }

  /// Whether the section has commits to show — nothing to fold on a checkout that has committed
  /// nothing of its own, so the menu item goes grey rather than toggling an invisible thing.
  var hasHistory: Bool { panel.history.hasAnythingToShow }
  var isHistoryVisible: Bool { panel.isHistoryVisible }

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

  /// Open a new web tab in the selected worktree.
  func openBrowser() {
    guard let workspace,
      let worktree = workspace.selectedWorktreeID.flatMap({ workspace.worktree(id: $0) })
    else { return }
    desk.openBrowser(worktree: worktree)
  }

  /// Open an address in the selected worktree's desk — a link followed from the transcript.
  func openBrowser(url: URL) {
    guard let workspace,
      let worktree = workspace.selectedWorktreeID.flatMap({ workspace.worktree(id: $0) })
    else { return }
    desk.openBrowser(worktree: worktree, url: url)
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

  /// Back / forward for the web tab showing on the desk — the browser menu items and their
  /// validation. Guarded on the view being loaded, like the rest here.
  var canBrowserGoBack: Bool { desk.isViewLoaded && desk.canBrowserGoBack }
  var canBrowserGoForward: Bool { desk.isViewLoaded && desk.canBrowserGoForward }
  func browserGoBack() { desk.browserGoBack() }
  func browserGoForward() { desk.browserGoForward() }

  /// A terminal renamed itself (OSC title); repaint the strip's labels.
  func refreshTerminalTabs() {
    guard desk.isViewLoaded else { return }
    desk.reload(worktreeID: workspace?.selectedWorktreeID)
  }

  /// Redraw the panel's tree from what it already holds. For the one change git cannot report —
  /// a directory it has no path for — where nothing else on screen is measured against anything
  /// that moved.
  func rebuildTree() {
    panel.rebuildTree()
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
