import AppKit
import QuickLookUI

/// The panel's outline, subclassed for the two keys a row answers to. ⏎ names the row — the
/// Finder's key, and Xcode's navigator's — and ⌘↓ opens it as a lasting tab, which is where that
/// went. ⏎ was the open once, matching the rail's dive; naming took it because naming is the one
/// act on a row with no other way to it from the keyboard, while opening keeps the double-click
/// it always had and gains a key of its own.
private final class FilesOutlineView: NSOutlineView {
  var onActivate: (() -> Void)?
  var onRename: (() -> Void)?
  var onQuickLook: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    let command = event.modifierFlags.contains(.command)
    let isReturn = event.keyCode == 36 || event.keyCode == 76
    if isReturn, !command {
      onRename?()
      return
    }
    // ⌘↓, the Finder's open.
    if event.keyCode == 125, command {
      onActivate?()
      return
    }
    // Space, the Finder's Quick Look. It takes the key off type-select, which a tree read by
    // eye and narrowed by a field of its own has no use for.
    if event.keyCode == 49, !command {
      onQuickLook?()
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
/// The tree is the worktree as it is on disk (`DiskTree`), listed a directory at a time as its
/// rows open, with git's answer laid over it: the diffstats, and which of it git ignores — shown
/// dimmed rather than left out, since it is in the worktree whether git wants it or not. What
/// narrows the tree — the filter, the ± scope — narrows a list of the paths git produced instead,
/// because a filter has to see every path and walking the checkout for that is the cost the disk
/// tree exists to avoid.
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
  NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuDelegate, QLPreviewPanelDataSource,
  QLPreviewPanelDelegate
{
  /// A single click / arrow-key move: preview the file (at `line` for a content hit).
  var onSelect: ((String, Int?) -> Void)?
  /// A double-click / Return on a row: open it as a lasting tab.
  var onActivate: ((String, Int?) -> Void)?
  /// The context menu's Open in Terminal: a shell in this directory. Terminals are the window
  /// controller's to make, so the panel only says where one belongs.
  var onNewTerminal: ((URL) -> Void)?
  /// The panel wrote to the worktree. FSEvents is asked to ignore hukan's own writes, so this is
  /// the only notice anything gets: the desk has to follow a file it may have open, and git has
  /// to be re-read, because the panel says so and nothing else will.
  var onFileEdit: ((FileEdit) -> Void)?

  /// What the menu did to the worktree. A rename carries both halves because a buffer is keyed
  /// by `(Worktree, relative path)` and an open tab has to follow the name.
  enum FileEdit {
    case created(String)
    case createdFolder(String)
    case renamed(from: String, to: String)
    case deleted(String)
    /// Files a drop landed here, contents and all — a copy, or one either act replaced. Not
    /// `created`: that one opens the file as a tab, which is right for a file you just made in
    /// order to write in it and wrong for twenty arriving at once. What these do owe is a
    /// re-read, since a tab may be showing a file whose contents have just been written over.
    case copiedIn([String])
  }

  private let filterField = GestureSearchField()
  /// Says what ⏎ escalates to, while the field is focused. See `showSearchHint`.
  private let splitController = NSSplitViewController()
  private var historyItem: NSSplitViewItem!
  /// A restored height that arrived before the panel had a size to place the divider in.
  private var pendingHistoryHeight: CGFloat?
  /// Whether the section was folded away *by hand*, kept apart from whether it is showing: a
  /// worktree with nothing committed collapses the section too, and coming to one that has
  /// commits must bring back the section a person never folded.
  private var isHistoryFoldedByHand = false
  /// True while the panel folds the section itself, so its own collapse does not read as a
  /// person having closed it.
  private var isAdjustingHistory = false
  private let hintLabel = NSTextField(labelWithString: "")
  private lazy var hintHeight = hintLabel.heightAnchor.constraint(equalToConstant: 0)
  private let outline = FilesOutlineView()
  /// Rebuilt per click — what it offers depends on the row under the cursor. See
  /// `menuNeedsUpdate`.
  private let contextMenu = NSMenu()
  /// The row the open menu was raised on, kept only for as long as the menu is up: `clickedRow`
  /// is meaningful during the click and the acts fire after it.
  private var menuTarget: MenuTarget?
  /// The row view the name is being typed in. Held rather than looked up again: the lookup goes
  /// through the tree, and taking a row out of edit has to work even when the tree no longer
  /// answers for it — which is exactly the Escape case, where nothing on disk moved.
  private weak var namingRowView: PanelRowView?
  /// The path whose row is being typed in, while it is. Naming happens on the row itself rather
  /// than in a dialog, so this is also what makes the tree hold still: see `refresh`.
  private var editingPath: String?
  /// A file just made, waiting for the row it will appear on so the naming can start. The make
  /// is announced and git is re-read off the main thread, so the row is a turn or two away.
  private var pendingEdit: String?
  /// A row to select once the tree can name it — an outside hand-off (`hukan src/foo`) landing
  /// before git has answered about a just-opened worktree. Applied and cleared by `refresh`.
  private var pendingRevealPath: String?
  private let listScroll = NSScrollView()
  /// The panel's second half: what this worktree has committed. Its own controller, since the
  /// tree and the history answer different questions and only share a column.
  let history = HistoryPanelViewController()
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
    (
      paths: [String], changed: [ChangedFile], query: String, changedOnly: Bool,
      indexGeneration: Int
    )?

  /// The scoped path set, and the same paths folded ready to be matched against. Typing is what
  /// this cache is for: the filter runs over every path in the worktree on each keystroke, and on
  /// a large one deriving that list — and folding it — costs more per keystroke than the matching
  /// does. Its key deliberately holds the changed files' *paths* and not their diffstats, since
  /// the numbers move while an agent works and the set of paths does not.
  private struct ScopeKey: Equatable {
    let tracked: [String]
    let changed: [String]
    let changedOnly: Bool
    /// The index's generation, so a directory relisted moves the filter's universe with it.
    let indexGeneration: Int
  }
  private var scoped: (key: ScopeKey, paths: [String], folded: [FoldedText]?)?
  /// Every path git would take, for the disk tree to tell an ignored file from one git simply
  /// has not been asked about — nil where there is no git. Keyed like `scoped`, on git's answer.
  private var known: (tracked: [String], changed: [String], paths: Set<String>?)?

  /// The worktree as it is on disk, which is what the panel shows when nothing narrows it — no
  /// filter, no ± scope. Kept across rebuilds, node objects and all: the disclosure state is keyed
  /// on those objects, and what git's answer moves is the numbers on them, not the rows.
  private var diskTree: DiskTree?
  /// Browsing the disk, as opposed to a list of paths git produced (a filter, the changed scope)
  /// or the hits of a content search.
  private var isDiskMode: Bool {
    filterField.stringValue.isEmpty && !isChangedOnly && !isShowingResults
  }

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
    // A click on the toolbar is a click elsewhere: the name is committed, as one on the list would.
    endNaming(commit: true, handingBackFocus: true)
    isChangedOnly.toggle()
    onScopeChanged?()
    if isShowingResults { runSearch() } else { refresh() }
  }

  override func loadView() {
    // The verb typing runs, and what it runs over — see the rail's field, which names itself the
    // same way. What ⏎ adds is said by `hintLabel` while the field is focused: spelling all three
    // out in a placeholder did not survive the field being narrow.
    filterField.placeholderString = "Filter Files"
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
    outline.onRename = { [weak self] in self?.renameSelected() }
    outline.onQuickLook = { [weak self] in self?.toggleQuickLook() }
    contextMenu.delegate = self
    outline.menu = contextMenu
    // Out of the window it is a copy and only a copy: an index must never be able to *move* the
    // file it points at somewhere hukan cannot see, since the row is a reference to the file and
    // not the file's home. Inside the window a move is exactly what a drag means — the tree is
    // the worktree, so landing a row in another directory is the rename that carries directories,
    // read as a gesture rather than typed. ⌥ turns it back into a copy without a word here:
    // AppKit intersects the modifier keys into the mask the destination is handed.
    outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
    outline.setDraggingSourceOperationMask(.copy, forLocal: false)
    outline.registerForDraggedTypes([.fileURL])
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

    let tree = NSViewController()
    let container = NSView()
    tree.view = container
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

    // The two halves are a split, so the line between them can be dragged: the tree gave the
    // section a fixed seven rows before, and seven rows is not a reading of a log. The divider
    // is the controller's, never hand-built — adding constraints to an NSSplitView by hand
    // collides with its autoresizing-derived ones and sends Auto Layout into infinite recursion
    // (see the note on FileColumns).
    splitController.splitView.isVertical = false
    splitController.splitView.dividerStyle = .thin
    let treeItem = NSSplitViewItem(viewController: tree)
    treeItem.minimumThickness = 80
    // The tree gives way: dragging the divider is a request for more history, and the panel's
    // own width is what the tree is really short of.
    treeItem.holdingPriority = .init(250)
    splitController.addSplitViewItem(treeItem)

    historyItem = NSSplitViewItem(viewController: history)
    historyItem.minimumThickness = HistoryPanelViewController.minimumHeight
    historyItem.canCollapse = true
    historyItem.holdingPriority = .init(251)
    splitController.addSplitViewItem(historyItem)

    addChild(splitController)
    view = splitController.view
    onScopeChanged?()
  }

  /// Put the section back where it was left. Called once the panel has a height to place a
  /// divider in — before that, `setPosition` lands on nothing.
  override func viewDidLayout() {
    super.viewDidLayout()
    guard let pending = pendingHistoryHeight, view.bounds.height > 0 else { return }
    pendingHistoryHeight = nil
    splitController.splitView.setPosition(view.bounds.height - pending, ofDividerAt: 0)
  }

  /// The toolbar's History glyph and ⌘⇧L. Folding is the split item's, which is how the panel's
  /// own collapse works one level up — the section no longer measures itself.
  func toggleHistory() {
    loadViewIfNeeded()
    isHistoryFoldedByHand = !historyItem.isCollapsed
    isAdjustingHistory = true
    historyItem.animator().isCollapsed = isHistoryFoldedByHand
    isAdjustingHistory = false
  }

  /// Unfold without folding — what revealing the panel from the toolbar does, so the glyph never
  /// opens a column onto a section that is still shut.
  func expandHistory() {
    loadViewIfNeeded()
    isHistoryFoldedByHand = false
    updateHistoryVisibility()
  }

  var isHistoryVisible: Bool { isViewLoaded && !historyItem.isCollapsed }

  /// The section's height, recorded with the column widths so it survives a relaunch. Collapsed
  /// reads as zero, which the recorder skips, so a folded section does not overwrite the height
  /// it will reopen at.
  var historyHeight: CGFloat {
    get {
      guard isViewLoaded, !historyItem.isCollapsed else { return 0 }
      let height = history.view.frame.height
      return height < HistoryPanelViewController.minimumHeight ? 0 : height
    }
    set {
      guard newValue > 0 else { return }
      loadViewIfNeeded()
      // Place it now when the panel already has a height, and wait for one when it does not: a
      // restored height arrives before the window has laid out, where `setPosition` lands on
      // nothing.
      guard view.bounds.height > 0 else {
        pendingHistoryHeight = newValue
        view.needsLayout = true
        return
      }
      splitController.splitView.setPosition(view.bounds.height - newValue, ofDividerAt: 0)
    }
  }

  /// A section with nothing in it is not a stub — it is gone, and the panel is all tree. Which is
  /// also what the toolbar's glyph promises: it is showing the section or it is not.
  private func updateHistoryVisibility() {
    guard isViewLoaded else { return }
    isAdjustingHistory = true
    defer { isAdjustingHistory = false }
    if !history.hasAnythingToShow {
      historyItem.isCollapsed = true
    } else if !isHistoryFoldedByHand {
      historyItem.isCollapsed = false
    }
  }

  /// The section's divider, so the window can record where it is left. Dragging it shut is the
  /// same act as the toolbar's glyph, so it is remembered the same way — otherwise the next
  /// worktree with commits would push a section back open that was deliberately closed.
  var splitView: NSSplitView {
    loadViewIfNeeded()
    return splitController.splitView
  }

  func dividerMoved() {
    guard isViewLoaded, !isAdjustingHistory else { return }
    isHistoryFoldedByHand = historyItem.isCollapsed
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

  // MARK: Worktree

  /// Point the panel at `worktree` (nil with none selected). A different worktree drops the
  /// query and the results; the same one just refreshes.
  func show(worktree: Worktree?) {
    loadViewIfNeeded()
    // Leaving a worktree mid-name drops the name: a rename landing on a checkout that is no longer
    // on screen would be an act nobody watched.
    if worktree !== self.worktree { endNaming(commit: false, handingBackFocus: true) }
    history.show(history: worktree?.history ?? Git.History())
    updateHistoryVisibility()
    if worktree !== self.worktree {
      self.worktree = worktree
      pendingRevealPath = nil
      filterField.stringValue = ""
      isShowingResults = false
      results = []
      roots = []
      builtFrom = nil
      scoped = nil
      known = nil
      diskTree = nil
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

  /// The index read these directories again (it walked, or FSEvents named something in them),
  /// so the rows built from them are drawn again — the ones already built, since a directory
  /// nobody has opened has nothing to go stale. Nothing waits on git here: this is how a file
  /// written by a build, an agent or a `mkdir` reaches the panel, whether git will ever see it or
  /// not. nil is all of them — the walk landing, or a batch that could not be placed.
  func pathsMoved(_ directories: Set<String>?) {
    guard isViewLoaded, let tree = diskTree else { return }
    var rootTouched = false
    var touched: [FileNode] = []
    if let directories {
      for directory in directories {
        if directory.isEmpty {
          rootTouched = true
        } else if let node = tree.listedNode(at: directory) {
          node.markStale()
          touched.append(node)
        }
      }
    } else {
      tree.markAllStale()
      rootTouched = true
    }
    // The filter's universe moved with the index; a filter on screen is rebuilt from it.
    guard isDiskMode else {
      if !isShowingResults, editingPath == nil { refresh() }
      return
    }
    // A name being typed holds the outline still (see `refresh`); the listings are stale all the
    // same, and the redraw that ends the naming reads them.
    guard editingPath == nil else { return }
    if rootTouched {
      redrawDisk()
    } else {
      for node in touched where outline.isItemExpanded(node) {
        outline.reloadItem(node, reloadChildren: true)
      }
    }
  }

  /// List the top level again and redraw, keeping what is open and selected. The nodes are
  /// reused, so the redraw is what puts a fresh listing under every open row that went stale.
  private func redrawDisk() {
    guard let tree = diskTree else { return }
    let openDirs = expandedDirectories()
    let selectedPath = selectedRowPath()
    roots = tree.relistRoots()
    redraw(openDirs: openDirs, selectedPath: selectedPath, query: "")
    updateEmptyLabel()
  }

  /// The worktree's files changed on disk: the tree if its inputs moved, the results always (a
  /// line just fixed must leave the list).
  func filesChangedOnDisk() {
    guard isViewLoaded else { return }
    // The same tick carries both halves: the commit that empties the tree's changed scope is the
    // one that adds a row down here.
    history.show(history: worktree?.history ?? Git.History())
    updateHistoryVisibility()
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
      changedOnly: isChangedOnly, indexGeneration: worktree.index?.generation ?? -1)
    if let scoped, scoped.key == key { return scoped.paths }

    var paths: [String]
    if isChangedOnly {
      paths = key.changed.sorted(by: FileTree.precedesBytewise)
    } else if let index = worktree.index {
      // The disk, as the walk found it: the same files the tree shows, less the directories git
      // ignores, which the walk does not go into.
      paths = index.filePaths
    } else {
      // No walk yet — the worktree has not been selected through the workspace, which is the
      // tests' case — so git's list stands in.
      paths = worktree.trackedFiles
      let known = Set(paths)
      let extra = key.changed.filter { !known.contains($0) }
      if !extra.isEmpty {
        paths.append(contentsOf: extra)
        paths.sort(by: FileTree.precedesBytewise)
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
    // A rebuild reloads the outline, which takes the field editor down mid-word — and an agent
    // writing files in this worktree makes that happen every second. The tree holds still until
    // the name is finished, then catches up in one go.
    guard editingPath == nil else { return }
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
    let inputs = (
      worktree.trackedFiles, worktree.changedFiles, query, isChangedOnly,
      worktree.index?.generation ?? -1
    )
    if let builtFrom, builtFrom == inputs, !isShowingResults {
      // Same inputs, same tree — but the button is repainted anyway, since this is also the path
      // a first load lands on once git answers.
      onScopeChanged?()
      // A file made a moment ago may already be a row by the time this refresh runs, and a
      // refresh with nothing to rebuild is still the one that has to start naming it. Left out,
      // the row is made and never handed the field, which reads as New File having done nothing.
      startPendingNaming()
      applyPendingReveal()
      return
    }
    builtFrom = inputs

    // What is open and what is selected are read off the outline view, and reading a row asks
    // the data source for it — so both have to be taken while `roots` is still the tree those
    // rows were built from. Assigning the new tree first left the view asking for children the
    // new one does not have, which is an out-of-range crash on any refresh that shrinks it.
    let openDirs = expandedDirectories()
    let selectedPath = selectedRowPath()

    var changed: [String: ChangedFile] = [:]
    for file in worktree.changedFiles { changed[file.path] = file }
    if query.isEmpty, !isChangedOnly {
      // Browsing: the worktree as it is on disk, git's answer laid over it. The tree outlives
      // the answer, so what a new answer does is renumber the rows already listed.
      let tree =
        diskTree
        ?? DiskTree(root: worktree.url) { [url = worktree.url] directories, files in
          Git.ignored(at: url, directories: directories, files: files)
        }
      diskTree = tree
      tree.index = worktree.index
      tree.update(changed: changed, known: knownPaths())
      // Listed once; after that git's answer renumbers what is listed and the disk is read only
      // when FSEvents names something (`pathsMoved`).
      roots = tree.roots.isEmpty ? tree.relistRoots() : tree.roots
    } else {
      // Narrowed: a list of the paths git produced — the ± scope's changed set, or everything
      // matching what was typed — built into a tree. An ignored file is not in git's list and
      // cannot be filtered to, which is the price of a filter that does not walk the checkout.
      var paths = scopedPaths()
      if !query.isEmpty {
        let needle = FoldedText(query)
        paths = zip(paths, foldedPaths()).compactMap { needle.occurs(in: $1) ? $0 : nil }
      }
      roots = FileTree(paths: paths, changed: changed).rootChildren
    }
    isShowingResults = false
    redraw(openDirs: openDirs, selectedPath: selectedPath, query: query)
    updateEmptyLabel()
    onScopeChanged?()
    startPendingNaming()
    applyPendingReveal()
  }

  /// Put `roots` on screen. A narrowed tree is small and its point is to be read at a glance, so
  /// it opens itself; unfiltered, the reader's own disclosure state is what comes back. Either
  /// way the opening is batched: `expandItem` reloads the view around every row it inserts,
  /// which on a filtered tree of a few hundred rows was most of what a keystroke cost.
  private func redraw(openDirs: Set<String>, selectedPath: String?, query: String) {
    outline.reloadData()
    outline.beginUpdates()
    if query.isEmpty {
      reopen(roots, openDirs)
    } else {
      var budget = Self.openRowBudget
      expandAll(roots, budget: &budget)
    }
    outline.endUpdates()
    if let selectedPath { select(path: selectedPath) }
  }

  /// Every path git would take, or nil where there is no git — read off the same answer the
  /// scope is, and kept until that answer moves.
  private func knownPaths() -> Set<String>? {
    guard let worktree else { return nil }
    let changed = worktree.changedFiles.map(\.path)
    if let known, known.tracked == worktree.trackedFiles, known.changed == changed {
      return known.paths
    }
    let paths: Set<String>? =
      Git.repository(at: worktree.url) == nil ? nil : Set(worktree.trackedFiles).union(changed)
    known = (worktree.trackedFiles, changed, paths)
    return paths
  }

  /// Hand a just-made file's row to the naming, once it has one. Called from every way out of
  /// `refresh`, since which of them the row arrives on depends on which git read lands first.
  private func startPendingNaming() {
    guard let pending = pendingEdit, node(at: pending) != nil else { return }
    pendingEdit = nil
    beginNaming(path: pending)
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
    guard let node = node(at: path) else { return }
    selectItem(node, announce: false)
  }

  /// Select `path`'s row, opening the directories above it — the outside hand-offs' landing
  /// (a directory dropped on the app, `hukan src/foo`). Deferred when the tree cannot name it
  /// yet: a worktree opened for the hand-off answers its file list a beat later.
  func reveal(path: String) {
    loadViewIfNeeded()
    if let node = node(at: path) {
      selectItem(node, announce: false)
    } else {
      pendingRevealPath = path
    }
  }

  /// The reveal `reveal(path:)` had to hold until the tree could name the row.
  private func applyPendingReveal() {
    guard let pending = pendingRevealPath, let node = node(at: pending) else { return }
    pendingRevealPath = nil
    selectItem(node, announce: false)
  }

  /// The row for `path`, opening the directories above it on the way — which is what makes a
  /// file just made three levels down actually reachable.
  private func node(at path: String) -> FileNode? {
    var nodes = roots
    let components = path.split(separator: "/").map(String.init)
    for depth in 0..<components.count {
      let prefix = components[0...depth].joined(separator: "/")
      guard let node = nodes.first(where: { $0.relativePath == prefix }) else { return nil }
      guard node.isDirectory, depth < components.count - 1 else { return node }
      outline.expandItem(node)
      nodes = node.children
    }
    return nil
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
    if control !== filterField {
      return nameFieldCommand(selector, typed: textView.string)
    }
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

  /// Escape and Return on a row being named. Handled here rather than left to the field editor
  /// because inside a table Escape reaches `abortEditing()`, which takes the editor down without
  /// posting `controlTextDidEndEditing` — so a row left to AppKit keeps its box and the panel goes
  /// on believing a name is being typed. Focus is handed back to the list either way, which is
  /// also what stops the editor lingering on a field that is no longer editable.
  private func nameFieldCommand(_ selector: Selector, typed: String) -> Bool {
    guard editingPath != nil else { return false }
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)):
      endNaming(commit: false, handingBackFocus: true)
      return true
    case #selector(NSResponder.insertNewline(_:)):
      endNaming(commit: true, typed: typed, handingBackFocus: true)
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
    if let shownWait, shownWait == .scan || roots.isEmpty {
      // The disk is listed at once, so a tree is usually on screen while git is still being
      // read; the note is for the case where there is nothing yet, not a banner over the rows.
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
    let preview = isQuickLookShowing ? (selectedRowPath() ?? "—") : "—"
    if isShowingResults {
      let lines = results.reduce(0) { $0 + $1.lines.count }
      return "results files:\(results.count) lines:\(lines)\(truncated ? "+" : "") "
        + "query:\(filterField.stringValue) scope:\(scope) waiting:\(waiting) preview:\(preview)"
    }
    let index = worktree?.index.map { $0.isBuilt ? "built" : "walking" } ?? "—"
    return "tree rows:\(outline.numberOfRows) query:\(filterField.stringValue) "
      + "scope:\(scope) waiting:\(waiting) naming:\(editingPath ?? "—") field:\(hasFieldEditor) "
      + "index:\(index) preview:\(preview)"
  }

  /// Whether the row being named really has the field editor — which is the half `editingPath`
  /// cannot answer for, since a name typed on a row that never took focus goes nowhere.
  private var hasFieldEditor: Bool {
    guard let editor = namingRowView?.nameFieldForNaming.currentEditor() else { return false }
    return view.window?.firstResponder === editor
  }

  /// Type into the field, the way a keystroke reaches it.
  func filterForScripting(_ query: String) {
    loadViewIfNeeded()
    // A keystroke in the field would already have taken the focus off a name being typed; this
    // path moves no focus, so it ends the name itself or the rebuild would be held.
    endNaming(commit: true, handingBackFocus: true)
    filterField.stringValue = query
    refresh()
  }

  /// Space on this row, without a click at coordinates to put the selection there first: the row
  /// is selected and the panel toggled, which is what the key does. Keyed to the row rather than
  /// a plain toggle, so previewing one file and then another reads as it does on screen — the
  /// same path twice closes the panel, a different one moves the preview onto it. What it did is
  /// read back through `report`'s `preview:`, the panel being the system's own and having nothing
  /// else to say for itself.
  func previewForScripting(path: String) -> String {
    loadViewIfNeeded()
    guard let url = url(for: path), FileManager.default.fileExists(atPath: url.path) else {
      return "no such path"
    }
    if isQuickLookShowing, selectedRowPath() == path {
      QLPreviewPanel.shared().orderOut(nil)
      // The panel zooms out rather than vanishing, so an answer taken straight away would name a
      // preview already on its way off the screen. Bounded, since what is waited for is an
      // animation and a wait that never ends is worse than a line one beat stale.
      let deadline = Date().addingTimeInterval(1)
      while isQuickLookShowing, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
      }
      return report
    }
    select(path: path)
    guard selectedRowPath() == path else { return "no row" }
    showQuickLook()
    refreshQuickLook()
    return report
  }

  /// What the right-click menu offers on `path` (empty for the panel's own background), a line
  /// each, `--` for a separator. Reported and not run: what is checkable without a click is which
  /// items a row carries at all, and the acts themselves are the guarded verbs below.
  func menuForScripting(path: String) -> String {
    loadViewIfNeeded()
    guard let worktree else { return "no worktree" }
    var isDirectory: ObjCBool = false
    let url = path.isEmpty ? worktree.url : worktree.url.appendingPathComponent(path)
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return "no such path"
    }
    let menu = NSMenu()
    build(menu, for: MenuTarget(path: path, isDirectory: isDirectory.boolValue, line: nil))
    return
      menu.items
      .map { $0.isSeparatorItem ? "--" : $0.title }
      .joined(separator: "\n")
  }

  // The writes the menu makes, run without the row's naming or the alert that normally stands
  // in front of them — which is exactly why they are guarded (`HUKAN_SCRIPTING_GUARDED=1`, the
  // same gate `approve` sits behind): each stands in for a human's answer, and a session's own
  // agent can reach osascript. What they buy is a check of the half that has no text to read
  // back — that a row goes into naming, that an open tab follows a rename and leaves on a delete,
  // and that git is re-read at all, since FSEvents drops hukan's own writes.

  /// New File in this directory (empty text for the worktree root) — the menu's whole act, which
  /// does not stop at the write: the row it makes goes straight into naming.
  func writeForScripting(create directory: String) -> String {
    loadViewIfNeeded()
    return newFile(inDirectory: directory) ?? "ok"
  }

  /// New Folder in this directory — the other half of the same act, and the one with no git read
  /// behind it at all, which is exactly what makes it worth a check of its own.
  func writeForScripting(createFolder directory: String) -> String {
    loadViewIfNeeded()
    return newFolder(inDirectory: directory) ?? "ok"
  }

  func writeForScripting(rename path: String, to name: String) -> String {
    loadViewIfNeeded()
    let problem = rename(path, to: name)
    // The menu's rename is followed by a redraw a turn later (see `catchUpAfterNaming`); this
    // one is followed by nothing, so the redraw is run here.
    if isDiskMode { redrawDisk() }
    return problem ?? "ok"
  }

  func writeForScripting(delete path: String) -> String {
    loadViewIfNeeded()
    return delete(path) ?? "ok"
  }

  /// A drop, with the drag session taken out: `paths` land in `directory` — copied, or moved when
  /// they are this worktree's own — and a name already taken is answered with `answer` instead of
  /// by the alert. Guarded like the rest, since that alert is a human's decision; what it buys is
  /// a check of the two halves a screenshot cannot see, which of the two acts ran and where the
  /// file ended up.
  func writeForScripting(
    drop paths: [String], into directory: String, moving: Bool, answering answer: DropAnswer
  ) -> String {
    loadViewIfNeeded()
    let outcome = take(
      paths.map { URL(fileURLWithPath: $0) }, into: directory, moving: moving,
      answering: { _ in answer })
    if let problem = outcome.problem { return problem }
    return outcome.landed.isEmpty ? "stopped" : "ok \(outcome.landed.joined(separator: " "))"
  }

  /// Type into the field and press Return.
  func searchForScripting(_ query: String) {
    loadViewIfNeeded()
    endNaming(commit: true, handingBackFocus: true)
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

  /// ⏎ on a row: name it. A result list is hits rather than the tree, and there is nothing to
  /// rename in it, so ⏎ there keeps the meaning it always had — open what it found.
  @objc private func renameSelected() {
    guard !isShowingResults else {
      activateSelected()
      return
    }
    guard let path = selectedRowPath() else { return }
    beginNaming(path: path)
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    refreshQuickLook()
    guard !isSelectingQuietly, let pick = picked(outline.item(atRow: outline.selectedRow)) else {
      return
    }
    onSelect?(pick.path, pick.line)
  }

  // MARK: Quick Look

  /// Space previews the selected row in the Finder's own panel (`QLPreviewPanel`), which is the
  /// whole of why this is affordable: the previews are the system's, so a `.pdf`, a `.mov`, a
  /// font and an archive are all answered without hukan learning anything about them — where the
  /// file pane, which is the editor, reads text and draws the handful of bitmap formats it has a
  /// table for and says so about everything else. It is a look and never a way in: the panel
  /// closes on the same key, and opening a file to work on it stays the double-click's and ⌘↓'s.
  /// So it is offered on a directory too, which has no tab to open at all.
  ///
  /// It follows the selection while it is up, so ↑/↓ walks the tree with the preview keeping up —
  /// which is what the panel is actually for, a run of files being read one after another rather
  /// than a row guessed right the first time. The arrows have to be handed back to the outline
  /// (`previewPanel(_:handle:)`) because the panel is key while it is showing.
  @objc private func toggleQuickLook() {
    guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible else {
      showQuickLook()
      return
    }
    QLPreviewPanel.shared().orderOut(nil)
  }

  /// The panel finds who feeds it by walking the key window's responder chain, so the tree has to
  /// hold the focus before it opens — which the key press already implies and the menu item does
  /// not, that one being reachable with the focus still in the composer. Without it the preview
  /// comes up fed by nobody and empty.
  private func showQuickLook() {
    guard quickLookURL != nil else { return }
    outline.window?.makeFirstResponder(outline)
    QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
  }

  /// True while the panel is up and it is this panel feeding it — a window next door may be the
  /// one holding it.
  private var isQuickLookShowing: Bool {
    guard QLPreviewPanel.sharedPreviewPanelExists() else { return false }
    let panel = QLPreviewPanel.shared()
    return panel?.isVisible == true && panel?.dataSource === self
  }

  /// What the panel previews: the selected row, whatever kind of row it is — a tree node, a
  /// result's file, one of its lines — since all three name one path in the worktree. A row
  /// naming a file that is no longer there previews nothing rather than an empty panel.
  private var quickLookURL: URL? {
    guard let path = selectedRowPath(), !path.isEmpty, let url = url(for: path) else { return nil }
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// The selection moved under an open panel. Cheap enough to run on every selection change:
  /// it asks whether the panel exists at all before anything else, and it exists only once
  /// something has pressed Space.
  private func refreshQuickLook() {
    guard isQuickLookShowing else { return }
    QLPreviewPanel.shared().reloadData()
  }

  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = self
    panel.delegate = self
  }

  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = nil
    panel.delegate = nil
  }

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURL == nil ? 0 : 1 }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
    quickLookURL as NSURL?
  }

  /// The zoom the panel opens and closes with, aimed at the row it came from: without it the
  /// preview grows out of the middle of the screen, which says nothing about which row is being
  /// looked at — and while the panel follows the arrows, that is the one thing worth saying.
  func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!)
    -> NSRect
  {
    let row = outline.selectedRow
    guard row >= 0, let window = outline.window else { return .zero }
    return window.convertToScreen(outline.convert(outline.rect(ofRow: row), to: nil))
  }

  /// The panel takes the keyboard while it is up, so the two keys that move the selection under
  /// it are handed back to the tree. Nothing else is: the panel's own keys — Space to close,
  /// ⌘Return for full screen — are the system's, and a key nobody claims must go on meaning what
  /// the panel says it means.
  func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
    guard event.type == .keyDown, event.keyCode == 125 || event.keyCode == 126 else { return false }
    outline.keyDown(with: event)
    return true
  }

  // MARK: Context menu

  /// What a right-click landed on. Every act the menu offers is about one path in the worktree,
  /// so the three kinds of row — a tree node, a result's file, one of its lines — reduce to the
  /// same target, and so does the background: a click below the last row is the worktree root,
  /// which is the directory a file made there belongs in.
  private struct MenuTarget {
    let path: String
    let isDirectory: Bool
    /// A content hit's line, so Open in New Tab lands where the row said it would.
    let line: Int?
    var isRoot: Bool { path.isEmpty }
    var name: String { (path as NSString).lastPathComponent }
    /// The directory an act performed at this row works in: the row itself when it is one,
    /// otherwise the directory holding it.
    var directory: String { isDirectory ? path : (path as NSString).deletingLastPathComponent }
  }

  private func clickedTarget() -> MenuTarget? {
    guard worktree != nil else { return nil }
    let row = outline.clickedRow
    switch row >= 0 ? outline.item(atRow: row) : nil {
    case let node as FileNode:
      return MenuTarget(path: node.relativePath, isDirectory: node.isDirectory, line: nil)
    case let file as ResultFile:
      return MenuTarget(path: file.path, isDirectory: false, line: file.lines.first?.line)
    case let line as ResultLine:
      return MenuTarget(path: line.path, isDirectory: false, line: line.line)
    default:
      return MenuTarget(path: "", isDirectory: true, line: nil)
    }
  }

  private func url(for path: String) -> URL? {
    guard let worktree else { return nil }
    return path.isEmpty ? worktree.url : worktree.url.appendingPathComponent(path)
  }

  /// Built per click rather than kept around: `clickedRow` is only meaningful while the click
  /// that raised the menu is being handled, and what the menu offers is read off the row it
  /// landed on.
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    // A right-click is a click elsewhere: a name being typed is committed before the menu can act
    // on the tree — and before `clickedRow` is read, since committing may move the rows.
    endNaming(commit: true, handingBackFocus: true)
    menuTarget = clickedTarget()
    guard let target = menuTarget else { return }
    build(menu, for: target)
  }

  /// The menu's contents for `target`, separated from the delegate so the scripting surface can
  /// read back what a row would offer without a click to read `clickedRow` from.
  private func build(_ menu: NSMenu, for target: MenuTarget) {
    @discardableResult
    func add(_ title: String, _ action: Selector) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      menu.addItem(item)
      return item
    }

    if !target.isRoot, !target.isDirectory {
      add("Open in New Tab", #selector(openTargetInNewTab))
    }
    // Space's other end. Every key this panel has is in this menu — ⏎ as Rename, ⌘↓ as Open in
    // New Tab — because the menu is where a key is found by someone who does not already know it
    // is there. Not on the background, which is not a row and has no file to preview.
    if !target.isRoot { add("Quick Look", #selector(quickLookTarget)) }
    add("Reveal in Finder", #selector(revealTargetInFinder))
    add("Open in Terminal", #selector(openTerminalAtTarget))

    if !target.isRoot {
      menu.addItem(.separator())
      // Two items rather than one and an ⌥ alternate. The relative path is what is wanted nearly
      // every time — it is the unit a buffer is keyed by and the form a path is written in to an
      // agent — but an alternate is only reachable by someone who already knows it is there, and
      // a menu is where you look precisely when you do not.
      add("Copy Path", #selector(copyRelativePath))
      add("Copy Absolute Path", #selector(copyAbsolutePath))
    }

    menu.addItem(.separator())
    add("New File…", #selector(newFileAtTarget))
    add("New Folder…", #selector(newFolderAtTarget))
    if !target.isRoot {
      menu.addItem(.separator())
      // A result row names a file and the file can be renamed — but naming happens on the file's
      // row in the tree, and what is on screen is hits. Delete needs no row, so it stays.
      if !isShowingResults { add("Rename…", #selector(renameTarget)) }
      add("Delete…", #selector(deleteTarget))
    }
  }

  @objc private func openTargetInNewTab() {
    guard let target = menuTarget, !target.isDirectory else { return }
    onActivate?(target.path, target.line)
  }

  /// The menu opens the preview rather than toggling it: a menu item is a thing chosen, where
  /// Space is a key pressed twice.
  @objc private func quickLookTarget() {
    guard let target = menuTarget else { return }
    select(path: target.path)
    showQuickLook()
    refreshQuickLook()
  }

  @objc private func revealTargetInFinder() {
    guard let target = menuTarget, let url = url(for: target.path) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  @objc private func openTerminalAtTarget() {
    guard let target = menuTarget, let url = url(for: target.directory) else { return }
    onNewTerminal?(url)
  }

  @objc private func copyRelativePath() {
    guard let target = menuTarget else { return }
    put(target.path, onPasteboard: .general)
  }

  @objc private func copyAbsolutePath() {
    guard let target = menuTarget, let url = url(for: target.path) else { return }
    put(url.path, onPasteboard: .general)
  }

  private func put(_ text: String, onPasteboard pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  /// The file is made first, under a name nobody chose, and then named on its own row — which is
  /// the Finder's order and the one that leaves a single naming mechanism instead of two. A row
  /// for a file that does not exist would have to be conjured into a tree built from git's path
  /// list and then defended against every refresh an agent's writing triggers; a file that is
  /// really there needs none of that, and it arrives on the row through the ordinary path.
  ///
  /// A name typed on its row may carry directories — `Sources/Hukan/Model.swift` — and they are
  /// made on the way; New Folder beside it is for the directory wanted on its own.
  @objc private func newFileAtTarget() {
    guard let target = menuTarget else { return }
    if let problem = newFile(inDirectory: target.directory) { report(problem) }
  }

  /// Make the file and ask for its row. Returns what refused, or nil.
  private func newFile(inDirectory directory: String) -> String? {
    guard worktree != nil else { return "no worktree" }
    let name = untitledName(in: directory)
    let path = directory.isEmpty ? name : "\(directory)/\(name)"
    if let problem = createFile(at: path) { return problem }
    // Browsing the disk, the row is there as soon as the directory is listed again; narrowed,
    // it arrives when git's answer does, and `refresh` starts the naming then.
    pendingEdit = path
    relist(directory)
    startPendingNaming()
    return nil
  }

  /// A directory the panel just wrote into: the index reads it again now, on this thread, so
  /// the row is there to be named; then the tree redraws. FSEvents is asked to ignore hukan's
  /// own writes, so nothing else will say so — and the index is also told the slow way, for
  /// the subtree bookkeeping a directory that moved needs.
  private func relist(_ directory: String) {
    guard let tree = diskTree else { return }
    worktree?.index?.refreshNow(directory)
    if !directory.isEmpty { tree.listedNode(at: directory)?.markStale() }
    guard isDiskMode, editingPath == nil else { return }
    redrawDisk()
  }

  /// A folder is a row here for the same reason an untracked file is one: it is in this worktree.
  /// git records no empty directory, so nothing about it will survive a commit until something
  /// lands in it — which is exactly what the row is for.
  @objc private func newFolderAtTarget() {
    guard let target = menuTarget else { return }
    if let problem = newFolder(inDirectory: target.directory) { report(problem) }
  }

  private func newFolder(inDirectory directory: String) -> String? {
    guard let worktree else { return "no worktree" }
    let name = untitledName(in: directory, base: "untitled folder")
    let path = directory.isEmpty ? name : "\(directory)/\(name)"
    do {
      try FileManager.default.createDirectory(
        at: worktree.url.appendingPathComponent(path), withIntermediateDirectories: true)
    } catch {
      return error.localizedDescription
    }
    onFileEdit?(.createdFolder(path))
    pendingEdit = path
    relist(directory)
    startPendingNaming()
    return nil
  }

  /// `untitled`, then `untitled 2` and so on — the Finder's rule, and it has to be a real answer
  /// because the file is made before it is named. No extension: what it is called is the next
  /// thing that happens.
  private func untitledName(in directory: String, base name: String = "untitled") -> String {
    guard let worktree else { return name }
    let root = directory.isEmpty ? worktree.url : worktree.url.appendingPathComponent(directory)
    var candidate = name
    var counter = 2
    while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
      candidate = "\(name) \(counter)"
      counter += 1
    }
    return candidate
  }

  /// The write itself, without the prompt in front of it — shared with the guarded scripting
  /// verb, which stands in for the answer the prompt collects. Returns what refused, or nil.
  private func createFile(at path: String) -> String? {
    guard let worktree else { return "no worktree" }
    let url = worktree.url.appendingPathComponent(path)
    guard !FileManager.default.fileExists(atPath: url.path) else {
      return "“\(path)” already exists."
    }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
      return error.localizedDescription
    }
    guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
      return "Could not create “\(path)”."
    }
    onFileEdit?(.created(path))
    return nil
  }

  @objc private func renameTarget() {
    guard let target = menuTarget, !target.isRoot else { return }
    beginNaming(path: target.path)
  }

  /// The typed name, read against the directory the row is in. It may carry directories —
  /// `deep/Model.swift` — and they are made on the way, which turns a rename into a move as the
  /// same rule read from the other side; the trade is worth taking, since a name box that quietly
  /// cannot reach a new directory is a worse surprise than one that can.
  ///
  /// It cannot leave the worktree, though. `..` is refused outright rather than resolved, since
  /// the one thing a name typed on a row must not be able to mean is a file somewhere else.
  private func rename(_ path: String, to name: String) -> String? {
    guard let worktree else { return "no worktree" }
    let components = name.split(separator: "/").map(String.init)
    guard !components.isEmpty, !name.hasPrefix("/"),
      !components.contains(where: { $0 == ".." || $0 == "." })
    else {
      return "“\(name)” is not a name this worktree has room for."
    }
    let parent = (path as NSString).deletingLastPathComponent
    let renamed = ([parent] + components).filter { !$0.isEmpty }.joined(separator: "/")
    guard renamed != path else { return nil }
    let from = worktree.url.appendingPathComponent(path)
    let to = worktree.url.appendingPathComponent(renamed)
    // Skipped when only the case moved: this filesystem answers "exists" for the file being
    // renamed, and `Model.swift` → `model.swift` is a rename git very much sees.
    if to.path.compare(from.path, options: .caseInsensitive) != .orderedSame,
      FileManager.default.fileExists(atPath: to.path)
    {
      return "“\(renamed)” already exists."
    }
    do {
      try FileManager.default.createDirectory(
        at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: from, to: to)
    } catch {
      return error.localizedDescription
    }
    onFileEdit?(.renamed(from: path, to: renamed))
    // Both directories, since a name that carried one is a move. Marked and not redrawn: a
    // rename typed on a row ends inside the field editor's own callback, and the redraw waits
    // for the turn after (see `catchUpAfterNaming`); the scripting verb redraws itself.
    let newParent = (renamed as NSString).deletingLastPathComponent
    worktree.index?.refreshNow(parent)
    if newParent != parent { worktree.index?.refreshNow(newParent) }
    worktree.index?.update(moved: [path, renamed]) { [weak self] in self?.pathsMoved($0) }
    diskTree?.listedNode(at: parent)?.markStale()
    diskTree?.listedNode(at: newParent)?.markStale()
    return nil
  }

  /// Deleted outright rather than moved to the Trash, and confirmed before it happens. A
  /// worktree is a checkout: what was committed git still has, and what was not was never
  /// anywhere else — so the Trash's copy would answer to a path this worktree no longer has,
  /// for the one case it could actually help with. The confirmation is what stands in for it.
  @objc private func deleteTarget() {
    guard let target = menuTarget, !target.isRoot else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Delete “\(target.name)”?"
    alert.informativeText =
      target.isDirectory
      ? "The folder and everything in it will be deleted. This cannot be undone."
      : "The file will be deleted. This cannot be undone."
    alert.addButton(withTitle: "Delete").hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    if let problem = delete(target.path) { report(problem) }
  }

  private func delete(_ path: String) -> String? {
    guard let url = url(for: path), !path.isEmpty else { return "no such path" }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      return error.localizedDescription
    }
    onFileEdit?(.deleted(path))
    relist((path as NSString).deletingLastPathComponent)
    worktree?.index?.update(moved: [path]) { [weak self] in self?.pathsMoved($0) }
    return nil
  }

  /// What went wrong, said once. These are the ordinary refusals — a name already taken, a
  /// permission — and none of them has a next step hukan could offer.
  private func report(_ problem: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = problem
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  // MARK: Naming a row

  /// Put `path`'s row into edit. A name is typed where the name is, not in a dialog over the
  /// window: the row already says what is being renamed, so a dialog would say it a second time
  /// and take the whole window to do it — and New File's name is decided against the rows around
  /// it, which a sheet stands in front of.
  func beginNaming(path: String) {
    loadViewIfNeeded()
    // Tree rows only: a result list still holds the tree's nodes behind it, but none of them is
    // on screen to be typed in.
    guard !isShowingResults else { return }
    // A name already being typed is committed first, the way any click elsewhere commits it —
    // and before `editingPath` moves, or the old field's end of editing, which the new field
    // taking focus is about to cause, would be read as the new row's and rename the wrong file.
    endNaming(commit: true, handingBackFocus: false)
    guard let node = node(at: path), let window = view.window else { return }
    let row = outline.row(forItem: node)
    guard row >= 0 else { return }
    outline.scrollRowToVisible(row)
    selectItem(node, announce: false)
    guard
      let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? PanelRowView
    else { return }
    editingPath = path
    namingRowView = cell
    // The field may be refused the focus — something else declining to give it up — and a
    // naming nobody can type into must not hold the tree still.
    guard cell.beginNaming(node.name, delegate: self, in: window) else {
      editingPath = nil
      namingRowView = nil
      return
    }
  }

  /// Return, Tab or a click elsewhere commits; Escape leaves the name alone. Either way the tree
  /// starts moving again, and catches up on whatever it held back while the name was being typed.
  func controlTextDidEndEditing(_ obj: Notification) {
    // The naming field's, and no other: the filter is a text field with this same delegate, and
    // a row's field that has already been taken out of edit may still end its editing later.
    guard let field = obj.object as? NSTextField, field === namingRowView?.nameFieldForNaming
    else { return }
    let cancelled =
      (obj.userInfo?["NSTextMovement"] as? Int).map { $0 == NSTextMovement.cancel.rawValue }
      ?? false
    endNaming(commit: !cancelled, typed: field.stringValue, handingBackFocus: false)
  }

  /// Take the row out of edit, keeping the typed name or leaving it. What was typed is read off
  /// the field editor while it is still up — a field's own `stringValue` does not catch up until
  /// editing has ended — unless the caller has it already.
  ///
  /// `handingBackFocus` is for the ends the panel starts itself: Escape, Return, the toolbar, the
  /// menu. The editor is still first responder then and the list should be again, or the editor
  /// lingers on a field that is no longer editable. It must stay false on the focus-loss path,
  /// where AppKit is midway through moving first responder to what was clicked and a
  /// `makeFirstResponder` from inside that would take the click's target away from it.
  private func endNaming(commit: Bool, typed: String? = nil, handingBackFocus: Bool) {
    guard let path = editingPath else { return }
    editingPath = nil
    let cell = namingRowView
    namingRowView = nil
    let field = cell?.nameFieldForNaming
    let editor = field?.currentEditor()
    let name = (typed ?? editor?.string ?? field?.stringValue ?? "")
      .trimmingCharacters(in: .whitespaces)
    cell?.endNaming()
    if handingBackFocus, let window = view.window, let editor, window.firstResponder === editor {
      window.makeFirstResponder(outline)
    }
    var problem: String?
    var renamed = false
    // An empty name is not a name: it leaves the file alone, the way Escape does, rather than
    // refusing out loud — there is nothing to tell someone who has just cleared a field.
    if commit, !name.isEmpty, name != (path as NSString).lastPathComponent {
      problem = rename(path, to: name)
      renamed = problem == nil
    }
    catchUpAfterNaming(restoring: renamed ? nil : path, reporting: problem)
  }

  /// The tree moves again. Deferred a turn: this is called out of the field editor's own
  /// notification, and reloading the outline under it is what AppKit spends that turn undoing.
  /// The refresh always runs — one may have been held back (see `refresh`), and the one that was
  /// not is the cheap early return — and so does the alert, for the same reason: a modal run from
  /// inside the editor's notification is run from inside the thing it interrupts.
  private func catchUpAfterNaming(restoring path: String?, reporting problem: String?) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if self.isShowingResults {
        self.runSearch()
      } else if self.isDiskMode {
        // The disk is the tree, so the redraw is the whole of it: a renamed row is listed under
        // its new name, and one that kept its name is drawn again with it.
        self.refresh()
        if self.editingPath == nil { self.redrawDisk() }
      } else {
        self.refresh()
        // A row whose name did not take is still showing the plain string it was handed to be
        // typed in — the half-typed one, or nothing at all — and the refresh that found nothing
        // to rebuild did not touch it, so it is reloaded on its own account. A renamed row is
        // left alone: the typed name is the right label until git's answer rebuilds the tree.
        // Never the row being typed in now, since a reload is what takes a field editor down.
        if let path, path != self.editingPath, let node = self.node(at: path) {
          self.outline.reloadItem(node)
        }
      }
      if let problem { self.report(problem) }
    }
  }

  // MARK: Dragging out

  /// A row drags as its own file URL, absolute — the path is what goes to the engine, and it must
  /// not depend on where the engine is standing. That is the whole of "add this to the context":
  /// the composer already takes a file dropped from the Finder and turns it into an attachment
  /// chip, so a row that writes the same thing needs nothing at the other end.
  ///
  /// Directories drag too, now that a drag back into the tree is a move: a folder that could not
  /// be picked up would be a move that worked on half the rows. The rule it used to carry — no
  /// attachment chip for a directory — did not survive being kept here anyway, since a folder
  /// dragged out of the Finder walked straight past it; it lives at the composer, which is the
  /// side that has the reason. Unlike the rail's rows, which stand for a checkout and so refuse
  /// `.fileURL` outright, these rows *are* files: the drag is good anywhere a file is, the Finder
  /// included, and outside this window it is offered as a copy so nothing can take the file out
  /// of the worktree.
  func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any)
    -> NSPasteboardWriting?
  {
    let path: String
    switch item {
    case let node as FileNode: path = node.relativePath
    case let file as ResultFile: path = file.path
    case let line as ResultLine: path = line.path
    default: return nil
    }
    guard !path.isEmpty, let url = url(for: path) else { return nil }
    let entry = NSPasteboardItem()
    entry.setString(url.absoluteString, forType: .fileURL)
    return entry
  }

  // MARK: Dropping in

  /// What a name the destination already has is answered with — the Finder's three, since a drop
  /// is the Finder's gesture and this panel is where hukan runs it. `stop` answers the whole drop
  /// rather than the one file, which is what the word means there too.
  enum DropAnswer {
    case keepBoth
    case replace
    case stop
  }

  /// Where a proposed drop lands, and the row that should light up for it: a directory row is the
  /// destination, a file row means the directory it is in, the background is the worktree root.
  /// The parent is read off the outline rather than looked up by path, because the lookup opens
  /// the directories it walks through and a drag merely passing over a row must not unfold it.
  private func dropDestination(for item: Any?) -> (directory: String, row: FileNode?)? {
    switch item {
    case nil: return ("", nil)
    case let node as FileNode where node.isDirectory: return (node.relativePath, node)
    case let node as FileNode:
      return (
        (node.relativePath as NSString).deletingLastPathComponent,
        outlineParent(of: node)
      )
    default: return nil
    }
  }

  private func outlineParent(of node: FileNode) -> FileNode? {
    outline.parent(forItem: node) as? FileNode
  }

  /// The way back in: a row drags out as its file URL, and the same URL dropped on a row is that
  /// file arriving. Two acts told apart by where the drag came from — a row of this panel moves,
  /// anything else copies — which is the Finder's own reading, and the modifier keys arrive
  /// already applied in `draggingSourceOperationMask`, so ⌥ over an internal drag is a copy and ⌘
  /// over one from outside is refused rather than silently doing the other thing.
  ///
  /// Never onto a result list: those rows are hits rather than places, and a hit is not a
  /// directory anything can land in.
  func outlineView(
    _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
    proposedChildIndex index: Int
  ) -> NSDragOperation {
    guard let operation = proposedOperation(info, item: item) else { return [] }
    // Retarget rather than refuse, the way the rail's reorder does: a drop *between* two rows is
    // not a position in an order — the tree's order is the disk's, not anyone's — so it is read as
    // a drop into the directory those rows are in.
    outlineView.setDropItem(operation.row, dropChildIndex: NSOutlineViewDropOnItemIndex)
    return operation.operation
  }

  func outlineView(
    _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int
  ) -> Bool {
    guard let proposed = proposedOperation(info, item: item) else { return false }
    let outcome = take(
      proposed.sources, into: proposed.directory, moving: proposed.operation.contains(.move),
      answering: askingAboutNames())
    if let problem = outcome.problem { report(problem) }
    return !outcome.landed.isEmpty
  }

  /// What this drag would do if it were dropped where it is: the sources, the directory they would
  /// land in, the row to light up, and which of the two acts it is. nil is "nothing here" — the
  /// one answer both delegate methods share.
  private func proposedOperation(_ info: NSDraggingInfo, item: Any?)
    -> (sources: [URL], directory: String, row: FileNode?, operation: NSDragOperation)?
  {
    guard !isShowingResults, let worktree, let destination = dropDestination(for: item),
      let sources = droppedFiles(from: info.draggingPasteboard)
    else { return nil }
    let root =
      destination.directory.isEmpty
      ? worktree.url : worktree.url.appendingPathComponent(destination.directory)
    // Ours only when the rows came from this panel *and* every one of them is this worktree's:
    // another window's panel is another checkout, and moving a file between two of them is a
    // change to two worktrees at once with nothing to say which one it was.
    let ours =
      (info.draggingSource as? NSOutlineView) === outline
      && sources.allSatisfy { relativePath(of: $0) != nil }
    let operation = Self.dropOperation(
      sources: sources, into: root, allowed: info.draggingSourceOperationMask, fromThisPanel: ours)
    guard !operation.isEmpty else { return nil }
    return (sources, destination.directory, destination.row, operation)
  }

  /// Which act a drag over `directory` is, as a rule with no drag session behind it — the shape
  /// the rail's `dropBoundary` already takes, and for the same reason: the rule is the part worth
  /// checking, and an `NSDraggingInfo` is not something a test can make.
  ///
  /// `allowed` is what the source offered narrowed by the modifier keys, so this only has to
  /// choose within it. What it refuses outright is the pair of things a drop can never mean: a
  /// directory landing inside itself, which a copy would follow for as long as the disk lasted,
  /// and a move onto the directory the file is already in.
  static func dropOperation(
    sources: [URL], into directory: URL, allowed: NSDragOperation, fromThisPanel: Bool
  ) -> NSDragOperation {
    guard !sources.isEmpty else { return [] }
    let root = resolved(directory)
    guard !sources.contains(where: { root == resolved($0) || root.hasPrefix(resolved($0) + "/") })
    else { return [] }
    if fromThisPanel, allowed.contains(.move) {
      guard !sources.contains(where: { resolved($0.deletingLastPathComponent()) == root }) else {
        return []
      }
      return .move
    }
    return allowed.contains(.copy) ? .copy : []
  }

  /// A path with the symlinks taken out, which is what any two of them have to be compared as:
  /// a worktree under `/tmp` is reached through one on this system, so the same directory arrives
  /// spelt two ways depending on who wrote the URL.
  private static func resolved(_ url: URL) -> String {
    url.resolvingSymlinksInPath().path
  }

  /// `url` as a path relative to this worktree, or nil when it is somewhere else — which is also
  /// what says a drag is this panel's own rather than another checkout's.
  private func relativePath(of url: URL) -> String? {
    guard let worktree else { return nil }
    let root = Self.resolved(worktree.url)
    let path = Self.resolved(url)
    guard path.hasPrefix(root + "/") else { return nil }
    return String(path.dropFirst(root.count + 1))
  }

  private func droppedFiles(from pasteboard: NSPasteboard) -> [URL]? {
    guard
      let urls = pasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      !urls.isEmpty
    else { return nil }
    return urls
  }

  /// The alert a name already taken raises: the Finder's three answers, and its Apply to All,
  /// which is what makes dropping twenty files onto a directory holding some of them survivable.
  /// Handed to the write as a closure so the write itself has no window in it — which is what
  /// lets the guarded verb answer with a fixed word, the same seam the menu's writes use.
  private func askingAboutNames() -> (String) -> DropAnswer {
    var toAll: DropAnswer?
    return { name in
      if let toAll { return toAll }
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "An item named “\(name)” already exists in this location."
      alert.informativeText =
        "Keep Both lands it under a name of its own. Replacing cannot be undone."
      alert.addButton(withTitle: "Keep Both")
      alert.addButton(withTitle: "Replace").hasDestructiveAction = true
      alert.addButton(withTitle: "Stop").keyEquivalent = "\u{1b}"
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title = "Apply to All"
      let answer: DropAnswer
      switch alert.runModal() {
      case .alertFirstButtonReturn: answer = .keepBoth
      case .alertSecondButtonReturn: answer = .replace
      default: answer = .stop
      }
      if alert.suppressionButton?.state == .on { toAll = answer }
      return answer
    }
  }

  /// The write behind a drop. Each source lands in `directory` under its own name; a name already
  /// taken is `answer`'s to settle, and `stop` ends the drop rather than that one file, which is
  /// what the word means in the Finder's version of this alert.
  ///
  /// A move reports itself as a rename, because that is what it is — the same act the name box
  /// performs when what is typed carries a directory — and that is what makes an open tab follow
  /// the file, subtree and all. A collision with a directory on either side is refused outright
  /// rather than offered Replace: replacing a folder is deleting everything in it, and the one
  /// place this panel destroys a directory is behind Delete's own alert.
  private func take(
    _ sources: [URL], into directory: String, moving: Bool, answering answer: (String) -> DropAnswer
  ) -> (landed: [String], problem: String?) {
    guard let worktree else { return ([], "no worktree") }
    let root = directory.isEmpty ? worktree.url : worktree.url.appendingPathComponent(directory)
    var landed: [String] = []
    var moved: [(from: String, to: String)] = []
    /// Every destination whose *contents* are new — a copy, or a file replaced by either act. A
    /// tab may be showing one of them, so unlike a move these have to be re-read.
    var written: [String] = []
    var touched: Set<String> = [directory]
    var problem: String?
    func refuse(_ text: String) { problem = problem ?? text }

    drop: for source in sources {
      var sourceIsDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory)
      else {
        refuse("“\(source.lastPathComponent)” is no longer there.")
        continue
      }
      let from = relativePath(of: source)
      guard
        Self.dropOperation(
          sources: [source], into: root, allowed: moving ? .move : .copy,
          fromThisPanel: moving && from != nil) == (moving ? .move : .copy)
      else {
        refuse("“\(source.lastPathComponent)” cannot land there.")
        continue
      }
      var name = source.lastPathComponent
      var destination = root.appendingPathComponent(name)
      var replacing = false
      var destinationIsDirectory: ObjCBool = false
      if FileManager.default.fileExists(
        atPath: destination.path, isDirectory: &destinationIsDirectory)
      {
        guard !sourceIsDirectory.boolValue, !destinationIsDirectory.boolValue else {
          refuse("“\(name)” already exists.")
          continue
        }
        switch answer(name) {
        case .stop: break drop
        case .keepBoth:
          name = Self.freeName(name, in: root)
          destination = root.appendingPathComponent(name)
        case .replace:
          replacing = true
        }
      }
      do {
        if replacing { try FileManager.default.removeItem(at: destination) }
        if moving {
          try FileManager.default.moveItem(at: source, to: destination)
        } else {
          try FileManager.default.copyItem(at: source, to: destination)
        }
      } catch {
        refuse(error.localizedDescription)
        continue
      }
      let arrived = directory.isEmpty ? name : "\(directory)/\(name)"
      landed.append(arrived)
      if moving, let from {
        moved.append((from: from, to: arrived))
        touched.insert((from as NSString).deletingLastPathComponent)
        if replacing { written.append(arrived) }
      } else {
        written.append(arrived)
      }
    }

    // FSEvents drops hukan's own writes, so this is the only notice anything gets — the same
    // hand-off the menu's writes take. A move names both ends, which on a directory is every
    // file that went with it.
    for move in moved { onFileEdit?(.renamed(from: move.from, to: move.to)) }
    if !written.isEmpty { onFileEdit?(.copiedIn(written)) }
    for touchedDirectory in touched {
      worktree.index?.refreshNow(touchedDirectory)
      if !touchedDirectory.isEmpty { diskTree?.listedNode(at: touchedDirectory)?.markStale() }
    }
    if !moved.isEmpty {
      worktree.index?.update(moved: Set(moved.flatMap { [$0.from, $0.to] })) { [weak self] in
        self?.pathsMoved($0)
      }
    }
    if isDiskMode, editingPath == nil { redrawDisk() }
    // The row is the whole of the report: no tab, since a drop is not a file you are about to
    // write in and there may be twenty of them.
    if let arrived = landed.last { reveal(path: arrived) }
    return (landed, problem)
  }

  /// The Finder's Keep Both: `Model 2.swift`, the number before the extension — the same " 2"
  /// `untitledName` already spells, said of a name that arrived with the file rather than one
  /// hukan chose.
  private static func freeName(_ name: String, in directory: URL) -> String {
    let base = (name as NSString).deletingPathExtension
    let extended = (name as NSString).pathExtension
    var candidate = name
    var counter = 2
    while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
      candidate = extended.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(extended)"
      counter += 1
    }
    return candidate
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
      // An ignored file is in the worktree and so on the tree, but it is not the work; the
      // dimming is what keeps a build directory from reading as it.
      cell.show(
        icon: node.isDirectory ? "folder" : "doc",
        lead: nil,
        name: NSAttributedString(
          string: node.name,
          attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: node.isIgnored ? NSColor.tertiaryLabelColor : NSColor.labelColor,
          ]),
        trailing: node.added.flatMap { added in
          node.removed.flatMap { removed in
            added + removed > 0 ? diffstatText(added: added, removed: removed) : nil
          }
        },
        dimmed: node.isIgnored)
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
    // The rows set their text attributed, font included; this is the font a name is typed in,
    // which is plain text, so it has to say the same size.
    nameField.font = .systemFont(ofSize: 12)
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

  /// Put this row's name into edit. The field is a label the rest of the time — an editable one
  /// would take a plain click, and a click on a row here previews the file — so what makes it a
  /// field is this call, and `endNaming` takes it back.
  /// False if the field could not take the focus, in which case the row is a label again.
  func beginNaming(_ name: String, delegate: NSTextFieldDelegate, in window: NSWindow) -> Bool {
    nameField.stringValue = name
    nameField.isEditable = true
    nameField.isSelectable = true
    nameField.isBezeled = true
    nameField.bezelStyle = .roundedBezel
    nameField.drawsBackground = true
    nameField.delegate = delegate
    guard window.makeFirstResponder(nameField) else {
      endNaming()
      return false
    }
    // The extension is rarely what is being changed, so the selection is the stem — the Finder's
    // rule. A name that is all extension (`.gitignore`) has no stem, and takes the lot.
    let stem = (name as NSString).deletingPathExtension
    if !stem.isEmpty, stem != name {
      nameField.currentEditor()?.selectedRange = NSRange(
        location: 0, length: (stem as NSString).length)
    }
    return true
  }

  /// The field a name is typed in, for the panel to read a value back off when something other
  /// than the field editor itself ends the edit.
  var nameFieldForNaming: NSTextField { nameField }

  func endNaming() {
    nameField.isEditable = false
    nameField.isSelectable = false
    nameField.isBezeled = false
    nameField.drawsBackground = false
    nameField.delegate = nil
  }

  /// Fill the row. A nil part is hidden rather than left empty, so the stack closes the gap and
  /// a row with no icon starts where its text does.
  func show(
    icon symbol: String?, lead: NSAttributedString?, name: NSAttributedString,
    trailing: NSAttributedString?, dimmed: Bool = false
  ) {
    // This cell may be the one a name was being typed in, handed back for another row. Ending
    // the edit is the safe failure; a bezel left on a row nobody is naming is the other one.
    if nameField.isEditable { endNaming() }
    icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    icon.isHidden = symbol == nil
    icon.contentTintColor = dimmed ? .quaternaryLabelColor : .tertiaryLabelColor
    leadField.attributedStringValue = lead ?? NSAttributedString()
    leadField.isHidden = lead == nil
    nameField.attributedStringValue = name
    trailingField.attributedStringValue = trailing ?? NSAttributedString()
    trailingField.isHidden = trailing == nil
  }
}
