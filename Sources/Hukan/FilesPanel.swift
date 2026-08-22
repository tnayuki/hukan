import AppKit

/// The panel's outline, subclassed only so Return opens the selected row as a lasting file tab —
/// the same dive the rail makes on Return.
private final class FilesOutlineView: NSOutlineView {
  var onActivate: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76 {
      onActivate?()
      return
    }
    super.keyDown(with: event)
  }
}

/// A running background read's kill switch, shared between the main thread that starts it and
/// the queue that runs it — one flag, so the lock is a formality the compiler's concurrency
/// checking needs rather than contention.
final class Cancellation {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

/// One file the content search hit, and the lines it hit on.
private final class ResultFile: NSObject {
  let path: String
  var lines: [ResultLine] = []
  init(path: String) { self.path = path }
}

private final class ResultLine: NSObject {
  let path: String
  let line: Int
  let text: String
  init(_ hit: FileSearch.Hit) {
    path = hit.path
    line = hit.line
    text = hit.text
  }
}

/// The files panel on the desk's trailing edge: the selected worktree's tree, docked. Navigation
/// only — a pick opens a tab on the desk, nothing is edited here, which is what lets it stay
/// narrow (the panel is the index, the tab is the text).
///
/// One field, but two operations kept apart by the gesture that runs them, because they are not
/// the same kind of thing: **typing** narrows the tree by path, live and in memory, and the tree
/// stays a tree — directories with no surviving child simply drop out. **Return** runs a content
/// search over the same file set, off the main thread, and the panel becomes a result list
/// (file → matching lines) until Escape brings the tree back. Merging the two into one live
/// keystroke was tried and is wrong: it greps the whole worktree on every character, and it has
/// to flatten the tree to show what it found, so the filter stops being a filter.
///
/// The ± toggle at the field's trailing edge scopes both operations to the worktree's changed
/// files — the review set, the thing an agent just wrote. It carries no number: the size of the
/// change is the toolbar's, and repeating it here would say the same thing twice.
final class FilesPanelViewController: NSViewController, NSOutlineViewDataSource,
  NSOutlineViewDelegate, NSSearchFieldDelegate
{
  /// A single click / arrow-key move: preview the file (at `line` for a content hit).
  var onSelect: ((String, Int?) -> Void)?
  /// A double-click / Return on a row: open it as a lasting tab.
  var onActivate: ((String, Int?) -> Void)?

  private let filterField = GestureSearchField()
  /// Says what ⏎ escalates to, while the field is focused. See `showSearchHint`.
  private let hintLabel = NSTextField(labelWithString: "")
  private lazy var hintHeight = hintLabel.heightAnchor.constraint(equalToConstant: 0)
  private let outline = FilesOutlineView()
  private let listScroll = NSScrollView()
  private let emptyLabel = NSTextField(labelWithString: "")
  private(set) var worktree: Worktree?

  /// Only the worktree's changed files, rather than everything tracked.
  private var isChangedOnly = false
  /// The panel is showing content-search results rather than the tree.
  private var isShowingResults = false

  /// What the panel is waiting on, and what it has admitted to waiting on. Neither of the two
  /// waits is instant — a content scan reads every file, and a worktree's first draw waits on
  /// git — so the panel says which it is rather than sitting there looking empty. It says so only
  /// once the wait has lasted long enough to be worth saying, since one that answers in
  /// milliseconds would otherwise just flash a word and take it away again.
  private enum Wait {
    case scan
    case read
    var note: String {
      switch self {
      case .scan: return "Searching…"
      case .read: return "Reading…"
      }
    }
  }
  private var wait: Wait?
  private var shownWait: Wait?
  private var waitNote: DispatchWorkItem?
  private static let waitNoteDelay: TimeInterval = 0.15

  /// The tree's roots, and the inputs they were built from — rebuilt only when one of those
  /// actually changed, so a routine reload does not fold every open directory.
  private var roots: [FileNode] = []
  private var builtFrom:
    (paths: [String], changed: [ChangedFile], query: String, changedOnly: Bool)?

  /// The scoped path set, and the same paths folded ready to be matched against. Typing is what
  /// this cache is for: the filter runs over every path in the worktree on each keystroke, and on
  /// a large one deriving that list — and folding it — costs more per keystroke than the matching
  /// does. Its key deliberately holds the changed files' *paths* and not their diffstats, since
  /// the numbers move while an agent works and the set of paths does not.
  private struct ScopeKey: Equatable {
    let tracked: [String]
    let changed: [String]
    let changedOnly: Bool
  }
  private var scoped: (key: ScopeKey, paths: [String], folded: [FoldedText]?)?

  private var results: [ResultFile] = []
  private var truncated = false
  private var generation = 0
  /// The scan now out, so a query that is no longer wanted can be dropped mid-read rather than
  /// run to the end while the next one waits behind it on this serial queue.
  private var runningScan: Cancellation?
  private let queue = DispatchQueue(label: "dev.tnayuki.hukan.files-search")

  var query: String { filterField.stringValue }

  /// The field and the ± live in the toolbar, over this panel's own column and on the same row
  /// as the toggle that hides it — the panel runs the window's full height, so its first rows
  /// belong to the bar. Inside the panel they sat a row lower than everything else up there.
  /// The panel still owns the field (delegate, focus, the query the searches read) and the
  /// scope's state; the window only places them.
  var filterSearchField: NSSearchField {
    loadViewIfNeeded()
    return filterField
  }
  var isChangedOnlyScope: Bool { isChangedOnly }
  var canScopeToChanged: Bool { !(worktree?.changedFiles.isEmpty ?? true) }
  /// Nothing changed in this worktree means nothing to scope to. Dropping a scope that has gone
  /// empty is `refresh`'s job, not the button's — doing it while painting would re-enter the
  /// rebuild that asked.
  var scopeToolTip: String {
    guard canScopeToChanged else { return "Nothing changed in this worktree" }
    return isChangedOnly ? "Showing changed files only" : "Show changed files only"
  }
  /// The scope moved, or a refresh dropped it: repaint the toolbar item that draws it.
  var onScopeChanged: (() -> Void)?

  func toggleChangedOnlyScope() {
    isChangedOnly.toggle()
    onScopeChanged?()
    if isShowingResults { runSearch() } else { refresh() }
  }

  override func loadView() {
    // The verb typing runs. What ⏎ adds is said by `hintLabel` while the field is focused —
    // spelling both out in a placeholder did not survive the field being narrow.
    filterField.placeholderString = "Filter"
    filterField.onFocusChange = { [weak self] focused in self?.showSearchHint(focused) }
    filterField.delegate = self
    filterField.sendsWholeSearchString = false
    filterField.sendsSearchStringImmediately = false

    let column = NSTableColumn(identifier: .init("row"))
    column.resizingMask = .autoresizingMask
    outline.addTableColumn(column)
    outline.outlineTableColumn = column
    outline.headerView = nil
    outline.rowHeight = 20
    outline.intercellSpacing = NSSize(width: 0, height: 2)
    outline.style = .plain
    outline.indentationPerLevel = 12
    outline.selectionHighlightStyle = .regular
    outline.dataSource = self
    outline.delegate = self
    outline.target = self
    outline.doubleAction = #selector(activateSelected)
    outline.onActivate = { [weak self] in self?.activateSelected() }
    outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
    listScroll.documentView = outline
    listScroll.hasVerticalScroller = true
    listScroll.drawsBackground = false
    listScroll.translatesAutoresizingMaskIntoConstraints = false

    emptyLabel.font = .systemFont(ofSize: 11)
    emptyLabel.textColor = .tertiaryLabelColor
    emptyLabel.alignment = .center
    emptyLabel.isHidden = true
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false

    // Sits directly under the field, which is in the toolbar over this column, and only while
    // that field is being typed in.
    hintLabel.stringValue = "⏎ to search contents"
    hintLabel.font = .systemFont(ofSize: 11)
    hintLabel.textColor = .tertiaryLabelColor
    hintLabel.alignment = .center
    hintLabel.isHidden = true
    hintLabel.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(hintLabel)
    container.addSubview(listScroll)
    container.addSubview(emptyLabel)
    NSLayoutConstraint.activate([
      // The panel runs the window's full height; the safe area is what holds the tree clear of
      // the toolbar, where its filter and ± now sit.
      hintLabel.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
      hintLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      hintLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      hintHeight,
      listScroll.topAnchor.constraint(equalTo: hintLabel.bottomAnchor),
      listScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      listScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      listScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      emptyLabel.topAnchor.constraint(equalTo: listScroll.topAnchor, constant: 16),
      emptyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
      emptyLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
    ])
    view = container
    onScopeChanged?()
  }

  func focusFilter() {
    loadViewIfNeeded()
    // The field rides a toolbar item that unhides with the panel, so when ⌘P is also the thing
    // opening the panel, the field may not be back in the window on this turn of the run loop —
    // chase it briefly rather than dropping the focus.
    var attempts = 20
    func land() {
      if let window = filterField.window {
        window.makeFirstResponder(filterField)
        filterField.selectText(nil)
        return
      }
      guard attempts > 0 else { return }
      attempts -= 1
      DispatchQueue.main.async(execute: land)
    }
    land()
  }

  /// ⌘⇧F: the field, with whatever is typed already searched — the difference between "go to a
  /// file" and "find in files" is which of the two the caller wants run, not a second field.
  func focusSearch() {
    loadViewIfNeeded()
    if !filterField.stringValue.isEmpty { runSearch() }
    focusFilter()
  }

  // MARK: Worktree

  /// Point the panel at `worktree` (nil with none selected). A different worktree drops the
  /// query and the results; the same one just refreshes.
  func show(worktree: Worktree?) {
    loadViewIfNeeded()
    if worktree !== self.worktree {
      self.worktree = worktree
      filterField.stringValue = ""
      isShowingResults = false
      results = []
      roots = []
      builtFrom = nil
      scoped = nil
      generation += 1
      cancelScan()
      // Emptied here rather than left for the rebuild below: the rows on screen belong to the
      // worktree being left, and `refresh()` reads them back (what was open, what was selected)
      // through the data source, which now answers for the worktree being arrived at. Nothing
      // of the old worktree's disclosure state is worth carrying over anyway.
      outline.reloadData()
    }
    refresh()
  }

  /// The worktree's files changed on disk: the tree if its inputs moved, the results always (a
  /// line just fixed must leave the list).
  func filesChangedOnDisk() {
    guard isViewLoaded else { return }
    if isShowingResults { runSearch() } else { refresh() }
    onScopeChanged?()
  }

  // MARK: Tree

  /// The file set both the tree and the search work over: everything tracked, or — scoped — only
  /// what has changed. Sorted, since `FileTree`'s prefix search relies on byte order, and a
  /// changed-file list arrives in git's diff order rather than the index's. Held in `scoped`
  /// until git says something that moves it, because both callers ask per keystroke.
  private func scopedPaths() -> [String] {
    guard let worktree else { return [] }
    let key = ScopeKey(
      tracked: worktree.trackedFiles, changed: worktree.changedFiles.map(\.path),
      changedOnly: isChangedOnly)
    if let scoped, scoped.key == key { return scoped.paths }

    var paths: [String]
    if isChangedOnly {
      paths = key.changed.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    } else {
      paths = worktree.trackedFiles
      // An agent's brand-new file is not in the index yet but is certainly part of the work.
      let known = Set(paths)
      let extra = key.changed.filter { !known.contains($0) }
      if !extra.isEmpty {
        paths.append(contentsOf: extra)
        paths.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
      }
    }
    scoped = (key, paths, nil)
    return paths
  }

  /// The same paths, folded ready to match against — prepared on the first keystroke that needs
  /// them rather than with the list itself, since the list is rebuilt whenever an agent adds or
  /// removes a file and most of those redraws have nothing typed in the field at all.
  private func foldedPaths() -> [FoldedText] {
    guard let scoped else { return [] }
    if let folded = scoped.folded { return folded }
    let folded = scoped.paths.map(FoldedText.init)
    self.scoped = (scoped.key, scoped.paths, folded)
    return folded
  }

  /// Rebuild the tree if anything it is derived from moved, keeping the open directories and the
  /// selection. Typing narrows the path set first, so the tree stays a tree — a directory with no
  /// surviving child is simply not built.
  private func refresh() {
    cancelScan()
    guard let worktree else {
      roots = []
      builtFrom = nil
      endWait()
      outline.reloadData()
      updateEmptyLabel()
      onScopeChanged?()
      return
    }
    // git has not answered about this worktree yet. The tree below is built from whatever is
    // known so far — nothing, on a first draw — so what stops it from reading as "this worktree
    // has no files" is the note, not an early return: the panel still draws, and fills in.
    if worktree.hasLoadedFiles { endWait() } else { beginWait(.read) }
    // Nothing changed any more (the work was committed, or git has only just been asked): the
    // scope has nothing to scope to, so it lets go rather than showing an empty panel.
    if isChangedOnly, worktree.changedFiles.isEmpty { isChangedOnly = false }
    let query = filterField.stringValue
    let inputs = (worktree.trackedFiles, worktree.changedFiles, query, isChangedOnly)
    if let builtFrom, builtFrom == inputs, !isShowingResults {
      // Same inputs, same tree — but the button is repainted anyway, since this is also the path
      // a first load lands on once git answers.
      onScopeChanged?()
      return
    }
    builtFrom = inputs

    // What is open and what is selected are read off the outline view, and reading a row asks
    // the data source for it — so both have to be taken while `roots` is still the tree those
    // rows were built from. Assigning the new tree first left the view asking for children the
    // new one does not have, which is an out-of-range crash on any refresh that shrinks it.
    let openDirs = expandedDirectories()
    let selectedPath = selectedRowPath()

    var paths = scopedPaths()
    if !query.isEmpty {
      let needle = FoldedText(query)
      paths = zip(paths, foldedPaths()).compactMap { needle.occurs(in: $1) ? $0 : nil }
    }
    var changed: [String: ChangedFile] = [:]
    for file in worktree.changedFiles { changed[file.path] = file }
    roots = FileTree(paths: paths, changed: changed).rootChildren
    isShowingResults = false
    outline.reloadData()
    // A narrowed tree is small and its point is to be read at a glance, so it opens itself;
    // unfiltered, the reader's own disclosure state is what comes back. Either way the opening is
    // batched: `expandItem` reloads the view around every row it inserts, which on a filtered
    // tree of a few hundred rows was most of what a keystroke cost.
    outline.beginUpdates()
    if query.isEmpty {
      reopen(roots, openDirs)
    } else {
      var budget = Self.openRowBudget
      expandAll(roots, budget: &budget)
    }
    outline.endUpdates()
    if let selectedPath { select(path: selectedPath) }
    updateEmptyLabel()
    onScopeChanged?()
  }

  private func expandedDirectories() -> Set<String> {
    guard !isShowingResults else { return [] }
    var open: Set<String> = []
    for row in 0..<outline.numberOfRows {
      if let node = outline.item(atRow: row) as? FileNode, node.isDirectory,
        outline.isItemExpanded(node)
      {
        open.insert(node.relativePath)
      }
    }
    return open
  }

  private func reopen(_ nodes: [FileNode], _ openDirs: Set<String>) {
    for node in nodes where node.isDirectory && openDirs.contains(node.relativePath) {
      outline.expandItem(node)
      reopen(node.children, openDirs)
    }
  }

  /// Open a filtered tree down to `budget` rows, and no further. A narrowed tree opens itself
  /// because its point is to be read at a glance — but one character typed against a large
  /// worktree narrows almost nothing, and opening all of it was a quarter of a second of the main
  /// thread per keystroke (measured on a 25,000-file checkout). So the opening is a budget spent
  /// in tree order, the way the commit tab spends its own on the cards it can afford; what does
  /// not fit stays folded, which is the state a tree row is readable in anyway.
  @discardableResult
  private func expandAll(_ nodes: [FileNode], budget: inout Int) -> Bool {
    for node in nodes where node.isDirectory {
      guard budget > 0 else { return false }
      outline.expandItem(node)
      budget -= node.children.count
      guard expandAll(node.children, budget: &budget) else { return false }
    }
    return true
  }

  /// How many rows a filtered tree opens itself to. Large enough that a real query — one that
  /// names something — is open to its leaves, small enough that a mistyped one costs nothing.
  private static let openRowBudget = 500

  /// Re-select the row for `path` without announcing it — whatever is open stays open. `path` can
  /// name a directory, which is a row like any other.
  private func select(path: String) {
    var nodes = roots
    let components = path.split(separator: "/").map(String.init)
    for depth in 0..<components.count {
      let prefix = components[0...depth].joined(separator: "/")
      guard let node = nodes.first(where: { $0.relativePath == prefix }) else { return }
      guard node.isDirectory, depth < components.count - 1 else {
        selectItem(node, announce: false)
        return
      }
      outline.expandItem(node)
      nodes = node.children
    }
  }

  // MARK: Field

  /// The field took or lost focus: show or hide the line that names the second gesture.
  private func showSearchHint(_ shown: Bool) {
    guard isViewLoaded else { return }
    hintLabel.isHidden = !shown
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      hintHeight.animator().constant = shown ? 18 : 0
    }
  }

  func controlTextDidChange(_ obj: Notification) {
    guard (obj.object as? NSSearchField) === filterField else { return }
    // Editing the query leaves any result list behind: what is on screen must never be the
    // answer to a query that is no longer in the field.
    refresh()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard control === filterField else { return false }
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      runSearch()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      // Escape backs out one step: the results first, then the query itself.
      if isShowingResults {
        refresh()
      } else if !filterField.stringValue.isEmpty {
        filterField.stringValue = ""
        refresh()
      }
      return true
    case #selector(NSResponder.moveDown(_:)):
      // Straight from the field into the list, the way a search field should hand off.
      guard outline.numberOfRows > 0 else { return true }
      view.window?.makeFirstResponder(outline)
      if outline.selectedRow < 0 {
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      }
      return true
    default:
      return false
    }
  }

  // MARK: Content search

  /// Run the content search over the scoped file set. Off the main thread and
  /// generation-guarded; an empty query just returns to the tree.
  private func runSearch() {
    guard let worktree else { return }
    let query = filterField.stringValue
    generation += 1
    let current = generation
    guard !query.isEmpty else {
      refresh()
      return
    }
    let paths = scopedPaths()
    let root = worktree.url
    let selectedPath = selectedRowPath()
    let selectedLine = (outline.item(atRow: outline.selectedRow) as? ResultLine)?.line
    // Switch to the result list at the moment the search is asked for, not when it answers: the
    // gesture has to visibly take, and the reading below happens on `queue` either way.
    cancelScan()
    beginWait(.scan)
    let cancellation = Cancellation()
    runningScan = cancellation
    isShowingResults = true
    results = []
    truncated = false
    builtFrom = nil
    outline.reloadData()
    updateEmptyLabel()
    queue.async { [weak self] in
      let scanned = FileSearch.scan(
        query: query, paths: paths, root: root, isCancelled: { cancellation.isCancelled })
      guard !cancellation.isCancelled else { return }
      var byPath: [String: ResultFile] = [:]
      var ordered: [ResultFile] = []
      for hit in scanned.hits {
        let file: ResultFile
        if let existing = byPath[hit.path] {
          file = existing
        } else {
          file = ResultFile(path: hit.path)
          byPath[hit.path] = file
          ordered.append(file)
        }
        file.lines.append(ResultLine(hit))
      }
      DispatchQueue.main.async {
        guard let self, current == self.generation else { return }
        self.results = ordered
        self.truncated = scanned.truncated
        self.endWait()
        self.isShowingResults = true
        self.builtFrom = nil
        self.outline.reloadData()
        for file in ordered { self.outline.expandItem(file) }
        self.updateEmptyLabel()
        self.restoreSelection(path: selectedPath, line: selectedLine)
      }
    }
  }

  private func restoreSelection(path: String?, line: Int?) {
    guard let path, let file = results.first(where: { $0.path == path }) else { return }
    // The same line stays quietly; a line that is gone (just fixed) steps to the next, and that
    // move previews it — the worklist advances on its own.
    if let line, let same = file.lines.first(where: { $0.line == line }) {
      selectItem(same, announce: false)
    } else if let line, let next = file.lines.first(where: { $0.line > line }) {
      selectItem(next, announce: true)
    } else {
      selectItem(file, announce: false)
    }
  }

  // MARK: Scope

  private func updateEmptyLabel() {
    guard isViewLoaded else { return }
    if let shownWait {
      emptyLabel.isHidden = false
      emptyLabel.stringValue = shownWait.note
      filterField.toolTip = nil
    } else if isShowingResults {
      let hits = results.reduce(0) { $0 + $1.lines.count }
      emptyLabel.isHidden = !results.isEmpty
      emptyLabel.stringValue = "No matches"
      // The count belongs on screen while a search is showing, so the list reads as a worklist.
      filterField.toolTip =
        truncated ? "\(FileSearch.limit)+ matching lines" : "\(hits) matching lines"
    } else {
      emptyLabel.isHidden = !roots.isEmpty
      emptyLabel.stringValue = filterField.stringValue.isEmpty ? "No files" : "No matching files"
      filterField.toolTip = nil
    }
  }

  // MARK: Scripting

  /// One line of what the panel is showing: which gesture, how much of it, and what it is waiting
  /// on. See `FilesPanelCommand`.
  var report: String {
    loadViewIfNeeded()
    let waiting = shownWait.map(\.note) ?? "—"
    let scope = isChangedOnly ? "changed" : "all"
    if isShowingResults {
      let lines = results.reduce(0) { $0 + $1.lines.count }
      return "results files:\(results.count) lines:\(lines)\(truncated ? "+" : "") "
        + "query:\(filterField.stringValue) scope:\(scope) waiting:\(waiting)"
    }
    return "tree rows:\(outline.numberOfRows) query:\(filterField.stringValue) "
      + "scope:\(scope) waiting:\(waiting)"
  }

  /// Type into the field, the way a keystroke reaches it.
  func filterForScripting(_ query: String) {
    loadViewIfNeeded()
    filterField.stringValue = query
    refresh()
  }

  /// Type into the field and press Return.
  func searchForScripting(_ query: String) {
    loadViewIfNeeded()
    filterField.stringValue = query
    runSearch()
  }

  // MARK: Waiting

  /// Start waiting on `kind`, showing the note only if the wait outlives `waitNoteDelay`.
  private func beginWait(_ kind: Wait) {
    guard wait != kind else { return }
    waitNote?.cancel()
    wait = kind
    shownWait = nil
    let note = DispatchWorkItem { [weak self] in
      guard let self, self.wait == kind else { return }
      self.shownWait = kind
      self.updateEmptyLabel()
    }
    waitNote = note
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.waitNoteDelay, execute: note)
  }

  private func endWait() {
    waitNote?.cancel()
    waitNote = nil
    wait = nil
    guard shownWait != nil else { return }
    // The note is on screen, and the caller may be on a path that draws nothing else — a refresh
    // whose inputs have not moved returns without touching the list. Take it away here.
    shownWait = nil
    updateEmptyLabel()
  }

  /// Drop the scan that is out, if any: the reader has moved on, and it must neither land on
  /// screen nor hold the next one behind it.
  private func cancelScan() {
    runningScan?.cancel()
    runningScan = nil
    if wait == .scan { endWait() }
  }

  // MARK: Selection

  private func selectedRowPath() -> String? {
    switch outline.item(atRow: outline.selectedRow) {
    case let node as FileNode: return node.relativePath
    case let file as ResultFile: return file.path
    case let line as ResultLine: return line.path
    default: return nil
    }
  }

  /// True while the panel moves its own selection, so the delegate does not re-open the file.
  private var isSelectingQuietly = false

  private func selectItem(_ item: Any, announce: Bool) {
    let row = outline.row(forItem: item)
    guard row >= 0 else { return }
    isSelectingQuietly = !announce
    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    isSelectingQuietly = false
    outline.scrollRowToVisible(row)
  }

  private func picked(_ item: Any?) -> (path: String, line: Int?)? {
    switch item {
    case let node as FileNode where !node.isDirectory: return (node.relativePath, nil)
    case let file as ResultFile: return (file.path, file.lines.first?.line)
    case let line as ResultLine: return (line.path, line.line)
    default: return nil
    }
  }

  /// Return / double-click. A file opens as a lasting tab; a directory, having no tab to open,
  /// folds or unfolds instead — the same key doing the only useful thing that row has.
  @objc private func activateSelected() {
    let item = outline.item(atRow: outline.selectedRow)
    if let node = item as? FileNode, node.isDirectory {
      if outline.isItemExpanded(node) {
        outline.collapseItem(node)
      } else {
        outline.expandItem(node)
      }
      return
    }
    guard let pick = picked(item) else { return }
    onActivate?(pick.path, pick.line)
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    guard !isSelectingQuietly, let pick = picked(outline.item(atRow: outline.selectedRow)) else {
      return
    }
    onSelect?(pick.path, pick.line)
  }

  // MARK: Outline

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    switch item {
    case nil: return isShowingResults ? results.count : roots.count
    case let node as FileNode: return node.children.count
    case let file as ResultFile: return file.lines.count
    default: return 0
    }
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    switch item {
    case nil: return isShowingResults ? results[index] : roots[index]
    case let node as FileNode: return node.children[index]
    case let file as ResultFile: return file.lines[index]
    default: fatalError("no children")
    }
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    switch item {
    case let node as FileNode: return node.isDirectory
    case let file as ResultFile: return !file.lines.isEmpty
    default: return false
    }
  }

  // Every row selects, directories included — selecting is not opening. A directory has nothing
  // to show in a tab, so picking one just moves the highlight (and Return/double-click folds it);
  // refusing the selection outright only made the row look broken under the cursor.
  func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
    true
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
    -> NSView?
  {
    let identifier = NSUserInterfaceItemIdentifier("rowCell")
    let cell =
      outlineView.makeView(withIdentifier: identifier, owner: nil) as? PanelRowView
      ?? PanelRowView(identifier: identifier)
    switch item {
    case let node as FileNode:
      cell.show(
        icon: node.isDirectory ? "folder" : "doc",
        lead: nil,
        name: NSAttributedString(
          string: node.name,
          attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
          ]),
        trailing: node.added.flatMap { added in
          node.removed.flatMap { removed in
            added + removed > 0 ? diffstatText(added: added, removed: removed) : nil
          }
        })
      cell.toolTip = node.relativePath
    case let file as ResultFile:
      cell.show(
        icon: "doc", lead: nil,
        name: NSAttributedString(
          string: file.path,
          attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
          ]),
        trailing: nil)
      cell.toolTip = file.path
    case let line as ResultLine:
      cell.show(
        icon: nil,
        lead: NSAttributedString(
          string: "\(line.line)",
          attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
          ]),
        name: NSAttributedString(
          string: line.text.trimmingCharacters(in: .whitespaces),
          attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
          ]),
        trailing: nil)
      cell.toolTip = "\(line.path):\(line.line)"
    default:
      break
    }
    return cell
  }
}

/// One panel row, laid out so that a narrow panel degrades in the one order that keeps it
/// readable: the name gives way first (truncating), while the icon, the line number and the
/// diffstat hold their size. Built from separate fields rather than one concatenated string —
/// a single field can only truncate its tail, which is exactly where the diffstat sits, and an
/// attributed string carrying no paragraph style ignores the field's line-break mode and wraps.
private final class PanelRowView: NSTableCellView {
  private let icon = NSImageView()
  private let leadField = NSTextField(labelWithString: "")
  private let nameField = NSTextField(labelWithString: "")
  private let trailingField = NSTextField(labelWithString: "")
  private let iconWidth: CGFloat = 14

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    icon.symbolConfiguration = .init(pointSize: 10, weight: .regular)
    icon.contentTintColor = .tertiaryLabelColor
    icon.setContentHuggingPriority(.required, for: .horizontal)
    // Without this the stack squeezes the image view to nothing before it truncates any text,
    // which read as the icon vanishing at narrow widths.
    icon.setContentCompressionResistancePriority(.required, for: .horizontal)
    icon.translatesAutoresizingMaskIntoConstraints = false

    for field in [leadField, nameField, trailingField] {
      field.maximumNumberOfLines = 1
      field.lineBreakMode = .byTruncatingTail
      field.cell?.truncatesLastVisibleLine = true
      field.translatesAutoresizingMaskIntoConstraints = false
    }
    // The name is the only thing allowed to give: a truncated name still identifies the row,
    // while a truncated diffstat or line number says nothing at all.
    nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    for field in [leadField, trailingField] {
      field.setContentCompressionResistancePriority(.required, for: .horizontal)
      field.setContentHuggingPriority(.required, for: .horizontal)
    }

    let row = NSStackView(views: [icon, leadField, nameField, trailingField])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 5
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    imageView = icon
    textField = nameField
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: iconWidth),
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Fill the row. A nil part is hidden rather than left empty, so the stack closes the gap and
  /// a row with no icon starts where its text does.
  func show(
    icon symbol: String?, lead: NSAttributedString?, name: NSAttributedString,
    trailing: NSAttributedString?
  ) {
    icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    icon.isHidden = symbol == nil
    leadField.attributedStringValue = lead ?? NSAttributedString()
    leadField.isHidden = lead == nil
    nameField.attributedStringValue = name
    trailingField.attributedStringValue = trailing ?? NSAttributedString()
    trailingField.isHidden = trailing == nil
  }
}
