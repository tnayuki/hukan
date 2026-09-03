import AppKit
import WebKit

/// The tab strip's clip. A trackpad already scrolls it sideways, but a wheel reports only a
/// vertical delta and would leave the strip reachable by ⌃⇥ and ⌘1…⌘9 and by nothing a hand does
/// — so a vertical scroll with no horizontal component of its own is spent horizontally here.
/// A wheel notch is a line count rather than a distance, hence the step.
private final class TabStripScrollView: NSScrollView {
  override func scrollWheel(with event: NSEvent) {
    guard event.scrollingDeltaX == 0, event.scrollingDeltaY != 0, let document = documentView
    else { return super.scrollWheel(with: event) }
    let overflow = document.frame.width - contentView.bounds.width
    guard overflow > 0 else { return }
    let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16
    var origin = contentView.bounds.origin
    origin.x = min(max(0, origin.x - step), overflow)
    contentView.setBoundsOrigin(origin)
    reflectScrolledClipView(contentView)
  }
}

/// The strip's row of tabs, and where a dragged one is dropped. The stack lays the tabs out; this
/// adds the half of a reorder that happens over the row — reading the gap the pointer is over,
/// marking it, and scrolling the strip when the pointer reaches an edge, since a strip that
/// overflows is walked and a drop past its edge has to be reachable too. What a drop *means* is
/// the desk's (`onMove`): the strip counts gaps, the desk owns the order.
final class TabStrip: NSStackView {
  /// The one type a tab drags as: its index in the strip. Nothing outside this window reads it,
  /// and the drag is refused outside the app (see `TabLabelButton`).
  static let tabType = NSPasteboard.PasteboardType("dev.tnayuki.hukan.desk-tab")

  /// The tab views in strip order — the arranged views less the rules between them and the
  /// spacer after — handed over with each rebuild.
  var tabViews: [NSView] = []
  /// A tab at `from` was dropped into the gap at `to`, counted in tabs from the leading edge.
  var onMove: ((_ from: Int, _ to: Int) -> Void)?

  /// The mark in the gap a drop would land in: a bar the accent colour, the height of a tab.
  private let indicator = LayerSurface()

  init() {
    super.init(frame: .zero)
    registerForDraggedTypes([Self.tabType])
    indicator.wantsLayer = true
    indicator.paintLayer = { $0.backgroundColor = NSColor.controlAccentColor.cgColor }
    indicator.layer?.cornerRadius = 1
    // Over the tabs, which are re-added above it on every rebuild.
    indicator.layer?.zPosition = 1
    indicator.isHidden = true
    addSubview(indicator)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The gap a drop at `point` (in the strip's coordinates) lands in: after every tab whose
  /// middle the pointer has passed, so a tab is displaced once the pointer is over its far half.
  func dropIndex(at point: NSPoint) -> Int {
    tabViews.filter { $0.frame.midX < point.x }.count
  }

  private func sourceIndex(_ info: NSDraggingInfo) -> Int? {
    info.draggingPasteboard.string(forType: Self.tabType).flatMap(Int.init)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingUpdated(sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard let from = sourceIndex(sender) else { return [] }
    let point = convert(sender.draggingLocation, from: nil)
    scrollTowardEdge(point)
    let to = dropIndex(at: point)
    // A tab held over its own gap moves nothing, and the strip says so by marking nothing.
    guard to != from, to != from + 1, !tabViews.isEmpty else {
      indicator.isHidden = true
      return .move
    }
    let x =
      to < tabViews.count
      ? tabViews[to].frame.minX - 3 : tabViews[tabViews.count - 1].frame.maxX + 1
    let reference = tabViews[min(to, tabViews.count - 1)].frame
    indicator.frame = NSRect(x: x, y: reference.minY, width: 2, height: reference.height)
    indicator.isHidden = false
    return .move
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    indicator.isHidden = true
  }

  override func draggingEnded(_ sender: NSDraggingInfo) {
    indicator.isHidden = true
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    indicator.isHidden = true
    guard let from = sourceIndex(sender) else { return false }
    let to = dropIndex(at: convert(sender.draggingLocation, from: nil))
    if to != from, to != from + 1 { onMove?(from, to) }
    return true
  }

  /// Nudge the strip along when the pointer is held near either end of the clip — AppKit sends
  /// `draggingUpdated` periodically while the pointer rests, so holding a tab at the edge walks
  /// the strip rather than needing the pointer to keep moving.
  private func scrollTowardEdge(_ point: NSPoint) {
    guard let scroll = enclosingScrollView else { return }
    let clip = scroll.contentView
    let visible = clip.bounds
    var origin = visible.origin
    if point.x < visible.minX + 24 {
      origin.x = max(0, origin.x - 8)
    } else if point.x > visible.maxX - 24 {
      origin.x = min(max(0, frame.width - visible.width), origin.x + 8)
    }
    guard origin != visible.origin else { return }
    clip.setBoundsOrigin(origin)
    scroll.reflectScrolledClipView(clip)
  }
}

/// A tab's label, and the handle a tab is dragged by. An `NSButton` tracks its own click from
/// the press to the release, so to be dragged as well it has to be handed the mouse first: a
/// press that moves is a drag of the tab, and one that does not is the click it always was —
/// delivered on the release, where `NSApp.currentEvent` still carries the click count the
/// double-click rule reads. The ✕ beside it keeps its own click and is not a handle.
private final class TabLabelButton: NSButton, NSDraggingSource {
  /// The whole tab, which is what the drag image shows — the label alone, lifted off, would
  /// leave the ✕ and the background behind.
  weak var tabView: NSView?

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    var dragged = false
    window.trackEvents(
      matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
      mode: .eventTracking
    ) { next, stop in
      guard let next else {
        stop.pointee = true
        return
      }
      switch next.type {
      case .leftMouseUp:
        stop.pointee = true
      case .leftMouseDragged:
        let travel =
          abs(next.locationInWindow.x - event.locationInWindow.x)
          + abs(next.locationInWindow.y - event.locationInWindow.y)
        if travel > 4 {
          dragged = true
          stop.pointee = true
        }
      default:
        break
      }
    }
    if dragged {
      beginDrag(with: event)
    } else {
      performClick(nil)
    }
  }

  private func beginDrag(with event: NSEvent) {
    guard let tabView else { return }
    let item = NSPasteboardItem()
    item.setString(String(tag), forType: TabStrip.tabType)
    let dragging = NSDraggingItem(pasteboardWriter: item)
    dragging.setDraggingFrame(
      convert(tabView.bounds, from: tabView), contents: snapshot(of: tabView))
    let session = beginDraggingSession(with: [dragging], event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = true
  }

  private func snapshot(of view: NSView) -> NSImage? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    let image = NSImage(size: view.bounds.size)
    image.addRepresentation(rep)
    return image
  }

  /// A move, and only inside the app: a tab dropped on the desktop is not a file, so outside
  /// the window the drag has nothing to be and snaps back.
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    context == .withinApplication ? .move : []
  }

  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

/// What a file tab keeps across a relaunch: its worktree, and the path relative to it. That pair
/// *is* a buffer's identity, so it is the whole of the tab. Nothing of the text rides along — an
/// unsaved edit is answered for before the window goes (see `confirmClosingWindow`), so the tab
/// comes back on the file as it stands on disk.
struct FileTabState: Equatable {
  var worktreeID: UUID
  var path: String
}

/// What a commit tab keeps: the oid, and the worktree it was opened from. The oid is the tab's
/// identity — a commit belongs to the repository, not the worktree — and the worktree is which
/// desk it stands on.
struct CommitTabState: Equatable {
  var worktreeID: UUID
  var oid: String
}

/// The right column's content area: this worktree's open files, web tabs and terminals, side by
/// side as tabs. Each navigates inside itself — a file by its find bar, a browser by its address
/// bar, a terminal by its prompt; getting *to* a file is the files panel beside this, and getting
/// to another worktree is the rail. Browsers and terminals arrive by ⌘T / ⌃⌘T or the strip's `+`.
/// The strip shows only when there is something to switch between.
///
/// Open files and browsers are the desk's own state (kept per worktree so switching worktrees
/// swaps the whole set); terminals it only renders — the window controller owns their creation
/// and removal over `Workspace.terminals`. The strip's order is the desk's too, whatever kind
/// a tab is: a new tab takes the end, a drag puts it wherever it was dropped, and closing the
/// active one lands on the neighbour to its right.

final class WorktreeDeskViewController: NSViewController {
  var workspace: Workspace?
  /// ⌃⌘T or the strip's `+` asks the controller to make a terminal in the selected worktree; it
  /// appends the model, then calls `open(terminalID:)` back.
  var onNewTerminal: (() -> Void)?
  /// ⌘T or the strip's `+` asked for a web tab in the selected worktree.
  var onNewBrowser: (() -> Void)?
  /// A file tab wrote itself back to disk, naming its worktree and the path in it — the column
  /// re-asks git about that file so the change shows in the diffstat.
  var onFileSaved: ((UUID, String) -> Void)?
  /// A file tab left the desk — closed, or its file deleted under it. What the `edit … waiting`
  /// verb listens for: the path is the tab's identity, so a waiter keyed on it can resume.
  var onFileTabClosed: ((UUID, String) -> Void)?
  /// A file tab's identity moved with a rename, so a waiter keyed on the old path follows it.
  var onFileTabRenamed: ((_ worktreeID: UUID, _ from: String, _ to: String) -> Void)?
  /// Ask the window for the whole width, or to put the other columns back. The desk is a column
  /// and the columns are the window's, so maximizing is asked for here, never done here.
  var onSetMaximized: ((Bool) -> Void)?

  /// Whether the window is showing the desk alone right now. The window controller sets it once
  /// the columns have moved, and the strip reads it back: the tab menu says Maximize or Restore,
  /// and a double-click knows which way it is toggling.
  var isMaximized = false {
    didSet {
      guard isMaximized != oldValue, isViewLoaded else { return }
      rebuildTabBar()
    }
  }

  /// One open file: its own content view controller, so each tab keeps its scroll, mode and
  /// unsaved edit. Identity is the relative path — the worktree half is the tab's bucket.
  private final class FileTab {
    let id = UUID()
    /// Mutable so a preview tab can be repointed at another file in place, reusing the one slot
    /// rather than spawning a tab per click.
    var path: String
    /// A preview tab — opened by a single click, shown in italic, and replaced by the next
    /// single-clicked file. Cleared (pinned) by a double-click or the first edit, after which it
    /// stays like any other tab. Mirrors VS Code's preview tab.
    var isPreview: Bool
    /// A restored tab nobody has looked at yet: the path is known, but the file is unread and the
    /// pane unbuilt until the tab is shown. See `realize`.
    var isPending = false
    let content = FileContentViewController()
    init(path: String, isPreview: Bool) {
      self.path = path
      self.isPreview = isPreview
    }
  }

  /// One web tab: its own pane (web view + chrome). Like files, browsers are the desk's state,
  /// kept per worktree — the task's browser travels with its worktree.
  private final class BrowserTab {
    let id = UUID()
    let pane: BrowserPaneViewController
    init(pane: BrowserPaneViewController) { self.pane = pane }
  }

  /// One open commit: its own read-only pane, kept per worktree like the rest of the desk. The
  /// oid is the identity — a commit is an object of the repository, not of the worktree, so the
  /// same one opened from two worktrees is the same text; what is per-worktree is which commits
  /// this task has been reading.
  private final class CommitTab {
    let id = UUID()
    var oid: String
    /// The preview slot, single-clicked from the History section — the file tabs' rule, kept.
    var isPreview: Bool
    /// Unread until looked at, like a restored file tab's — and the tab is where a commit git no
    /// longer has says so, since nothing cheap answers that without reading it.
    var isPending = false
    let content = CommitContentViewController()
    init(oid: String, isPreview: Bool) {
      self.oid = oid
      self.isPreview = isPreview
    }
  }

  private let tabBar = TabStrip()
  /// The strip's clip. Tabs keep their natural width and run off the edge rather than being
  /// squeezed into slivers, so a desk with a dozen of them is walked rather than read at a
  /// glance — which is what the strip was before: past a handful of tabs every label was
  /// truncated to nothing at once, and the whole row said the same thing about none of them.
  private let tabScroll = TabStripScrollView()
  private let hairline = LayerSurface()
  private let plusButton = NSButton()
  private let container = NSView()
  private let placeholder = NSView()
  private lazy var tabBarHeight = tabScroll.heightAnchor.constraint(equalToConstant: 0)
  private var worktreeID: UUID?
  private var fileTabsByWorktree: [UUID: [FileTab]] = [:]
  private var browserTabsByWorktree: [UUID: [BrowserTab]] = [:]
  private var commitTabsByWorktree: [UUID: [CommitTab]] = [:]
  private var terminals: [TerminalSession] = []
  /// The strip's order per worktree: the order the tabs were opened in, then whatever dragging
  /// has made of it. Written back on every rebuild, so a tab it has not met — one just opened —
  /// takes the end of the strip, which is where a browser puts a new tab, and one that has since
  /// closed drops out. Only the web tabs outlive the window, so only their part of it is saved,
  /// and as their relative order (see `restorableBrowserTabs`).
  private var tabOrderByWorktree: [UUID: [Surface]] = [:]

  private enum Surface: Hashable {
    case none
    case file(UUID)
    case browser(UUID)
    case terminal(UUID)
    case commit(UUID)
  }
  private var surface: Surface = .none
  /// The strip's label per surface, so a title that changes on its own — a page loading — can be
  /// relabelled without rebuilding the strip.
  private var tabButtons: [Surface: NSButton] = [:]
  /// The selected tab's view in the strip, so it can be scrolled back into sight after a rebuild.
  private weak var selectedTabView: NSView?

  private var fileTabs: [FileTab] { worktreeID.flatMap { fileTabsByWorktree[$0] } ?? [] }
  /// The showing worktree's file tabs by path, in strip order — what a test reads to check that a
  /// tab followed a rename or left with a delete. The strip itself is views, and a tab's identity
  /// is its path, so this is the whole of what there is to assert.
  var openFilePaths: [String] { fileTabs.map(\.path) }
  private var browserTabs: [BrowserTab] { worktreeID.flatMap { browserTabsByWorktree[$0] } ?? [] }
  private var commitTabs: [CommitTab] { worktreeID.flatMap { commitTabsByWorktree[$0] } ?? [] }

  /// The commit tab showing right now, when the desk is on one. The scripting surface's handle on
  /// it: a commit tab has no specifier of its own, and checking one by clicking at coordinates is
  /// exactly what the dictionary exists to avoid.
  var selectedCommitTab: CommitContentViewController? {
    guard case .commit(let id) = surface else { return nil }
    return commitTabs.first { $0.id == id }?.content
  }

  /// The file content of the active tab, or nil when a terminal (or nothing) is showing. The
  /// column drives save / diff-toggle / refresh through this.
  var activeFileContent: FileContentViewController? {
    guard case .file(let id) = surface, let tab = fileTabs.first(where: { $0.id == id }) else {
      return nil
    }
    return tab.content
  }

  /// Whether ⌘W has a tab to close — any file or terminal is the active surface.
  var hasClosableTab: Bool { surface != .none }

  /// The terminal showing right now, if the active tab is one — what ⌘K clears.
  var activeTerminal: TerminalSession? {
    guard case .terminal(let id) = surface else { return nil }
    return terminals.first { $0.id == id }
  }

  /// Whether ⌘F has a surface to search in — anything but an empty desk, and anything but an
  /// image, which is the one surface here with no text in it for a find bar to reach.
  var canFind: Bool {
    guard surface != .none else { return false }
    return activeFileContent?.isShowingImage != true
  }

  /// The web tab showing right now, for the browser's own menu items (back / forward). Nil when
  /// the active surface is anything else, which is what disables them.
  private var activeBrowserPane: BrowserPaneViewController? {
    guard case .browser(let id) = surface else { return nil }
    return browserTabs.first { $0.id == id }?.pane
  }

  var canBrowserGoBack: Bool { activeBrowserPane?.webView.canGoBack ?? false }
  var canBrowserGoForward: Bool { activeBrowserPane?.webView.canGoForward ?? false }
  func browserGoBack() { activeBrowserPane?.webView.goBack() }
  func browserGoForward() { activeBrowserPane?.webView.goForward() }

  /// Reload and Open Location ask only that a web tab is showing, where back and forward also
  /// want somewhere to go: the page worth reloading most is the one that failed to load, and the
  /// tab worth typing an address into is the blank one.
  var isShowingWebTab: Bool { activeBrowserPane != nil }
  func browserReload() { activeBrowserPane?.reloadPage() }
  func browserFocusAddress() { activeBrowserPane?.focusAddress() }

  /// The image showing right now, if the active tab is a file and that file is one.
  private var activeImageContent: FileContentViewController? {
    guard let content = activeFileContent, content.isShowingImage else { return nil }
    return content
  }

  /// Zoom is aimed by the focus, the way the find is. A web tab's page zoom and an image's
  /// magnification are one key meaning one thing about two surfaces — closer — so the menu
  /// carries one item each and the desk says which surface is under them. Nothing else on the
  /// desk has a size to change: source is the size it is set at, and a terminal's is the
  /// terminal's.
  var canZoom: Bool { isShowingWebTab || activeImageContent != nil }

  func zoom(by delta: Int) {
    if let image = activeImageContent {
      image.zoomImage(by: delta)
    } else {
      activeBrowserPane?.zoomPage(by: delta)
    }
  }

  func resetZoom() {
    if let image = activeImageContent {
      image.resetImageZoom()
    } else {
      activeBrowserPane?.resetZoom()
    }
  }

  /// ⌘F: find within the active surface. A terminal's bar is SwiftTerm's, a file's the text
  /// view's; both read their action tag off the menu item passed through as `sender`.
  func performFind(_ sender: Any?) {
    switch surface {
    case .terminal(let id):
      guard let terminal = terminals.first(where: { $0.id == id }) else { return }
      view.window?.makeFirstResponder(terminal.view)
      terminal.view.performFindPanelAction(sender)
    case .file(let id):
      fileTabs.first { $0.id == id }?.content.performFind(sender)
    case .commit(let id):
      commitTabs.first { $0.id == id }?.content.performFind(sender)
    case .browser(let id):
      browserTabs.first { $0.id == id }?.pane.performFind(sender)
    case .none:
      break
    }
  }

  /// How many tabs the desk holds — ⌃⇥ tab-cycling validates on more than one.
  var tabCount: Int {
    fileTabs.count + browserTabs.count + commitTabs.count + terminals.count
  }

  /// The tabs in strip order, so ⌃⇥ / ⌃⇧⇥ walk them the way they read: the order kept in
  /// `tabOrderByWorktree`, then any tab it does not know yet.
  private var orderedSurfaces: [Surface] {
    worktreeID.map { orderedSurfaces(in: $0, terminals: terminals) } ?? []
  }

  /// The same for any worktree, given its terminals — the desk caches only the on-screen
  /// worktree's, and the window's state is saved for every worktree at once.
  private func orderedSurfaces(in worktreeID: UUID, terminals: [TerminalSession]) -> [Surface] {
    let present =
      (fileTabsByWorktree[worktreeID] ?? []).map { Surface.file($0.id) }
      + (commitTabsByWorktree[worktreeID] ?? []).map { .commit($0.id) }
      + (browserTabsByWorktree[worktreeID] ?? []).map { .browser($0.id) }
      + terminals.map { .terminal($0.id) }
    let known = (tabOrderByWorktree[worktreeID] ?? []).filter(present.contains)
    return known + present.filter { !known.contains($0) }
  }

  /// The strip order of the tabs that come back after a relaunch, as one row per tab across every
  /// worktree, in strip order. The desk's contribution to the window's restorable state beside the
  /// tabs themselves: the four saved lists are written in this order too (see
  /// `restorableBrowserTabs`, `restorableFileTabs`, `restorableCommitTabs`, and the window for the
  /// terminals), so a row need only say which kind it is for `restoreTabOrder` to know which tab
  /// it names.
  var restorableTabOrder: [Workspace.RestoredTabOrder] {
    guard let workspace else { return [] }
    return workspace.worktrees.flatMap { worktree in
      orderedSurfaces(in: worktree.id, terminals: workspace.terminals(inWorktree: worktree.id))
        .compactMap { surface -> Workspace.RestoredTabOrder? in
          switch surface {
          case .browser: return .init(worktreeID: worktree.id, kind: .browser)
          case .terminal: return .init(worktreeID: worktree.id, kind: .terminal)
          case .file: return .init(worktreeID: worktree.id, kind: .file)
          case .commit: return .init(worktreeID: worktree.id, kind: .commit)
          case .none: return nil
          }
        }
    }
  }

  /// Where the strip was standing: the showing tab's place in the showing worktree's strip, or a
  /// negative when the desk is empty. Only the one worktree's — the desk does not remember a tab
  /// per worktree, so there is nothing else to save.
  var restorableSelectedTabIndex: Int {
    guard surface != .none else { return -1 }
    return orderedSurfaces.firstIndex(of: surface) ?? -1
  }

  /// Every file tab, across every worktree, in strip order — the order `restoreFileTabs` puts
  /// them back in. A preview tab is here like any other: it is on the strip, and it is very often
  /// the one being read.
  var restorableFileTabs: [FileTabState] {
    fileTabsByWorktree.flatMap { worktreeID, tabs in
      inStripOrder(tabs, in: worktreeID, surface: { .file($0.id) })
        .map { FileTabState(worktreeID: worktreeID, path: $0.path) }
    }
  }

  /// Every commit tab, across every worktree, in strip order.
  var restorableCommitTabs: [CommitTabState] {
    commitTabsByWorktree.flatMap { worktreeID, tabs in
      inStripOrder(tabs, in: worktreeID, surface: { .commit($0.id) })
        .map { CommitTabState(worktreeID: worktreeID, oid: $0.oid) }
    }
  }

  /// One worktree's tabs of a kind, in strip order rather than the order they were opened — a
  /// dragged tab must not spring back on relaunch. A tab the order has not met (there is always
  /// one, briefly) keeps its opened position, at the end.
  private func inStripOrder<Tab: AnyObject>(
    _ tabs: [Tab], in worktreeID: UUID, surface: (Tab) -> Surface
  ) -> [Tab] {
    let order = tabOrderByWorktree[worktreeID] ?? []
    return tabs.enumerated().sorted { a, b in
      (order.firstIndex(of: surface(a.element)) ?? .max, a.offset)
        < (order.firstIndex(of: surface(b.element)) ?? .max, b.offset)
    }.map(\.element)
  }

  /// Put last run's file tabs back on their worktrees. Like the web tabs, none is read until its
  /// tab is looked at (see `realize`): a restored desk costs the one file on screen, not every
  /// file that was open. A tab whose worktree is gone stays gone, and so does one whose file is —
  /// an agent's `git worktree remove`, or a rebase, and the tab would have nothing to show.
  /// Restored tabs are lasting, never previews: a preview is what the last click made of a tab,
  /// and a relaunch is not a click.
  func restoreFileTabs(_ states: [FileTabState]) {
    loadViewIfNeeded()
    for state in states {
      guard let worktree = workspace?.worktree(id: state.worktreeID) else { continue }
      let url = worktree.url.appendingPathComponent(state.path)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      let tab = FileTab(path: state.path, isPreview: false)
      tab.isPending = true
      wire(tab)
      fileTabsByWorktree[state.worktreeID, default: []].append(tab)
    }
  }

  /// Put last run's commit tabs back. Unread until looked at, like the files — and unchecked:
  /// nothing answers "is this oid still here" more cheaply than reading the commit, so a commit a
  /// rebase has dropped says so in the tab when it is opened.
  func restoreCommitTabs(_ states: [CommitTabState]) {
    loadViewIfNeeded()
    for state in states {
      guard workspace?.worktree(id: state.worktreeID) != nil else { continue }
      let tab = CommitTab(oid: state.oid, isPreview: false)
      tab.isPending = true
      addChild(tab.content)
      commitTabsByWorktree[state.worktreeID, default: []].append(tab)
    }
  }

  /// Land on the tab the window was left on. Called once every kind is back and in order, and
  /// before the desk is reloaded onto its worktree: it names the tab by its place in that
  /// worktree's strip, and the reload's own reconcile then finds the surface already on the strip
  /// and leaves it alone. Doing it the other way round — letting the reload pick — is what put a
  /// restored window on the end of its strip, and taking the index inside the reload was worse
  /// still: the terminals arrive on a reload of their own, so the index was spent against a strip
  /// that was still half of one.
  func restoreSelectedTab(worktreeID: UUID, index: Int) {
    guard let workspace, workspace.worktree(id: worktreeID) != nil else { return }
    let order = orderedSurfaces(
      in: worktreeID, terminals: workspace.terminals(inWorktree: worktreeID))
    guard order.indices.contains(index) else { return }
    surface = order[index]
  }

  /// How many restored tabs are still unread. The laziness a restored desk rests on is the one
  /// thing about it the strip does not show — a tab that has not been opened looks exactly like
  /// one that has — so this is what a test asserts it on.
  var unreadRestoredTabCount: Int {
    fileTabsByWorktree.values.flatMap { $0 }.count { $0.isPending }
      + commitTabsByWorktree.values.flatMap { $0 }.count { $0.isPending }
  }

  /// Read a restored tab, the first time it is shown. Everything a fresh open does except
  /// choosing the tab — which the caller has already done by landing on it.
  private func realize(_ tab: FileTab) {
    guard tab.isPending, let worktreeID, let worktree = workspace?.worktree(id: worktreeID) else {
      return
    }
    tab.isPending = false
    tab.content.show(worktree: worktree, path: tab.path)
  }

  private func realize(_ tab: CommitTab) {
    guard tab.isPending, let worktreeID, let worktree = workspace?.worktree(id: worktreeID) else {
      return
    }
    tab.isPending = false
    tab.content.show(worktree: worktree, oid: tab.oid)
  }

  /// The terminals in strip order, for saving — so that they come back in it.
  func restorableTerminals(_ terminals: [TerminalSession]) -> [TerminalSession] {
    var rank: [UUID: Int] = [:]
    for worktreeID in Set(terminals.map(\.worktreeID)) {
      let order = orderedSurfaces(
        in: worktreeID, terminals: terminals.filter { $0.worktreeID == worktreeID })
      for (index, surface) in order.enumerated() {
        if case .terminal(let id) = surface { rank[id] = index }
      }
    }
    return terminals.enumerated().sorted { a, b in
      (rank[a.element.id] ?? .max, a.offset) < (rank[b.element.id] ?? .max, b.offset)
    }.map(\.element)
  }

  /// Lay last run's tabs out in the order they were saved in. Called once every kind is back on
  /// its worktree, each list in the order it was saved — which is the strip's — so walking the
  /// rows and taking the next tab of each row's kind rebuilds the strip. A row past the end of its
  /// list is skipped: that is a tab that did not come back (a terminal whose worktree is gone, a
  /// file that is), and the tabs after it on the strip close up over the gap.
  func restoreTabOrder(_ rows: [Workspace.RestoredTabOrder]) {
    guard let workspace else { return }
    var next: [Workspace.RestoredTabOrder: Int] = [:]
    var order: [UUID: [Surface]] = [:]
    for row in rows {
      let index = next[row, default: 0]
      next[row] = index + 1
      switch row.kind {
      case .browser:
        let tabs = browserTabsByWorktree[row.worktreeID] ?? []
        guard index < tabs.count else { continue }
        order[row.worktreeID, default: []].append(.browser(tabs[index].id))
      case .terminal:
        let tabs = workspace.terminals(inWorktree: row.worktreeID)
        guard index < tabs.count else { continue }
        order[row.worktreeID, default: []].append(.terminal(tabs[index].id))
      case .file:
        let tabs = fileTabsByWorktree[row.worktreeID] ?? []
        guard index < tabs.count else { continue }
        order[row.worktreeID, default: []].append(.file(tabs[index].id))
      case .commit:
        let tabs = commitTabsByWorktree[row.worktreeID] ?? []
        guard index < tabs.count else { continue }
        order[row.worktreeID, default: []].append(.commit(tabs[index].id))
      }
    }
    for (worktreeID, surfaces) in order { tabOrderByWorktree[worktreeID] = surfaces }
    if isViewLoaded { rebuildTabBar() }
  }

  /// The hooks every file tab carries, wherever it came from: what a save tells the window, what
  /// the first edit does to a preview slot, and the dot the strip puts up for an unsaved edit.
  private func wire(_ tab: FileTab) {
    tab.content.onSaved = { [weak self] worktreeID, path in
      self?.onFileSaved?(worktreeID, path)
    }
    // The first edit pins the tab: you must not lose what you just started typing to the next
    // single click reusing the slot.
    let id = tab.id
    tab.content.onEdited = { [weak self] in
      _ = self?.pinIfPreview(.file(id))
    }
    // The dot goes up and comes down on the tab; the pin above rides the same first edit, so
    // one rebuild here covers both.
    tab.content.onDirtyChanged = { [weak self] in self?.rebuildTabBar() }
    addChild(tab.content)
  }

  /// A tab dragged from `from` into the gap at `to` — gaps counted in tabs from the strip's
  /// leading edge, so the gap after the last tab is `tabCount`. The strip's own gesture, and the
  /// scripting surface's way of doing it without a pointer.
  func moveTab(at from: Int, to: Int) {
    guard let worktreeID else { return }
    var order = orderedSurfaces
    guard order.indices.contains(from), (0...order.count).contains(to) else { return }
    let moved = order.remove(at: from)
    order.insert(moved, at: to > from ? to - 1 : to)
    tabOrderByWorktree[worktreeID] = order
    rebuildTabBar()
  }

  /// ⌃⇥ (+1) / ⌃⇧⇥ (−1): move to the next or previous tab, wrapping, and hand it focus.
  func cycleTab(by delta: Int) {
    let order = orderedSurfaces
    guard order.count > 1 else { return }
    let current = order.firstIndex(of: surface) ?? 0
    let count = order.count
    surface = order[((current + delta) % count + count) % count]
    rebuildTabBar()
    applySurface()
    focusActiveSurface()
  }

  private func focusActiveSurface() {
    switch surface {
    case .terminal(let id):
      view.window?.makeFirstResponder(terminals.first { $0.id == id }?.view)
    case .browser(let id):
      view.window?.makeFirstResponder(browserTabs.first { $0.id == id }?.pane.webView)
    case .file, .commit, .none:
      break
    }
  }

  override func loadView() {
    view = NSView()

    tabBar.orientation = .horizontal
    tabBar.alignment = .centerY
    tabBar.spacing = 4
    tabBar.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
    // Fill the width deterministically: the tabs keep their natural size, and a trailing spacer
    // (added last in rebuildTabBar) soaks up the slack. Left to its default the stack has
    // to park leftover width on some arranged view and chooses inconsistently, which is what made
    // a tab's width jump on a resize or a tab open/close.
    tabBar.distribution = .fill
    tabBar.translatesAutoresizingMaskIntoConstraints = false
    tabBar.onMove = { [weak self] from, to in self?.moveTab(at: from, to: to) }
    tabScroll.documentView = tabBar
    tabScroll.drawsBackground = false
    tabScroll.hasHorizontalScroller = false
    tabScroll.hasVerticalScroller = false
    tabScroll.verticalScrollElasticity = .none
    tabScroll.automaticallyAdjustsContentInsets = false
    tabScroll.translatesAutoresizingMaskIntoConstraints = false
    // The stack is the document: as tall as the clip, and at least as wide — so a strip that fits
    // still stretches into its spacer, and one that does not scrolls instead of compressing.
    let clip = tabScroll.contentView
    NSLayoutConstraint.activate([
      tabBar.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
      tabBar.topAnchor.constraint(equalTo: clip.topAnchor),
      tabBar.heightAnchor.constraint(equalTo: clip.heightAnchor),
      tabBar.widthAnchor.constraint(greaterThanOrEqualTo: clip.widthAnchor),
    ])

    // `+` offers what can be added to a desk — a web tab or a terminal — as a menu, in the File
    // menu's order (⌘T / ⌃⌘T). It sits outside the scrolling strip, at the trailing edge: inside
    // it, the one control that makes a tab would be the first thing to scroll away exactly when
    // there are enough tabs to have to scroll.
    plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Tab")
    plusButton.imagePosition = .imageOnly
    plusButton.isBordered = false
    plusButton.bezelStyle = .accessoryBarAction
    plusButton.contentTintColor = .secondaryLabelColor
    plusButton.toolTip = "New Browser or Terminal"
    plusButton.target = self
    plusButton.action = #selector(showAddMenu(_:))
    plusButton.translatesAutoresizingMaskIntoConstraints = false
    // A hairline under the strip, so the tab row reads as a header the way the other columns' do.
    hairline.wantsLayer = true
    hairline.paintLayer = { $0.backgroundColor = NSColor.separatorColor.cgColor }
    hairline.translatesAutoresizingMaskIntoConstraints = false
    container.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(tabScroll)
    view.addSubview(plusButton)
    view.addSubview(hairline)
    view.addSubview(container)
    NSLayoutConstraint.activate([
      // The desk already hangs below the toolbar (`ToolbarInsetViewController`), so this is the
      // same as the top — kept as the safe area for the cases AppKit adds one anyway.
      tabScroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      tabScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tabScroll.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor),
      tabBarHeight,
      plusButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
      plusButton.centerYAnchor.constraint(equalTo: tabScroll.centerYAnchor),
      hairline.topAnchor.constraint(equalTo: tabScroll.bottomAnchor),
      hairline.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hairline.heightAnchor.constraint(equalToConstant: 1),
      container.topAnchor.constraint(equalTo: hairline.bottomAnchor),
      container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    setSurfaceView(placeholder)
  }

  /// Re-render for the given worktree: show its open files and terminals, dropping any surface
  /// whose tab is gone (a terminal closed, or the worktree switched out from under it).
  func reload(worktreeID: UUID?) {
    loadViewIfNeeded()
    self.worktreeID = worktreeID
    terminals = worktreeID.flatMap { workspace?.terminals(inWorktree: $0) } ?? []
    pruneClosedWorktrees()
    reconcileSurface()
    rebuildTabBar()
    applySurface()
  }

  /// Open the file at `path` in a tab, or focus the tab already showing it. `preview` (a single
  /// click) opens it in the reused preview slot; a non-preview open (a double-click) makes a
  /// lasting tab — and pins the preview one if that is what was already showing this file.
  /// `reveal` lands the view on a line, selecting `term` there — the files panel's hand-off for
  /// a content hit, so stepping down its lines steps the preview tab through the occurrences.
  func openFile(
    worktree: Worktree, path: String, preview: Bool, reveal: (line: Int, term: String?)? = nil
  ) {
    loadViewIfNeeded()
    self.worktreeID = worktree.id
    var tabs = fileTabsByWorktree[worktree.id] ?? []
    let tab: FileTab
    if let existing = tabs.first(where: { $0.path == path }) {
      // Already open: focus it, and a deliberate (non-preview) open pins a tab that was a preview.
      tab = existing
      if !preview { tab.isPreview = false }
    } else if preview, let slot = tabs.first(where: { $0.isPreview }) {
      // Reuse the single preview slot rather than piling up tabs: repoint it at the new file.
      tab = slot
      tab.path = path
      tab.content.show(worktree: worktree, path: path)
    } else {
      let fresh = FileTab(path: path, isPreview: preview)
      wire(fresh)
      fresh.content.show(worktree: worktree, path: path)
      tabs.append(fresh)
      fileTabsByWorktree[worktree.id] = tabs
      tab = fresh
    }
    surface = .file(tab.id)
    terminals = workspace?.terminals(inWorktree: worktree.id) ?? []
    rebuildTabBar()
    applySurface()
    if let reveal { tab.content.reveal(line: reveal.line, term: reveal.term) }
  }

  /// Pin a preview tab so it stops behaving like one — what a double-click's first step does,
  /// and what the first edit does to the file it lands in. Returns whether there was a preview
  /// to pin, which is what tells a double-click to maximize instead; repainting is the caller's,
  /// since both callers redraw the strip for their own reasons anyway.
  @discardableResult
  private func pinIfPreview(_ target: Surface) -> Bool {
    switch target {
    case .file(let id):
      guard let tab = fileTabs.first(where: { $0.id == id }), tab.isPreview else { return false }
      tab.isPreview = false
      return true
    case .commit(let id):
      guard let tab = commitTabs.first(where: { $0.id == id }), tab.isPreview else { return false }
      tab.isPreview = false
      return true
    case .browser, .terminal, .none:
      return false
    }
  }

  /// Open `oid` in a tab, or focus the tab already showing it. Single-clicking the History
  /// section previews (one reused slot); a double-click or Return pins — the files panel's
  /// gesture, since it is the same kind of move: an index picking what the desk shows.
  func openCommit(worktree: Worktree, oid: String, preview: Bool) {
    loadViewIfNeeded()
    self.worktreeID = worktree.id
    var tabs = commitTabsByWorktree[worktree.id] ?? []
    let tab: CommitTab
    if let existing = tabs.first(where: { $0.oid == oid }) {
      tab = existing
      if !preview { tab.isPreview = false }
    } else if preview, let slot = tabs.first(where: { $0.isPreview }) {
      tab = slot
      tab.oid = oid
      tab.content.show(worktree: worktree, oid: oid)
    } else {
      let fresh = CommitTab(oid: oid, isPreview: preview)
      addChild(fresh.content)
      fresh.content.show(worktree: worktree, oid: oid)
      tabs.append(fresh)
      commitTabsByWorktree[worktree.id] = tabs
      tab = fresh
    }
    surface = .commit(tab.id)
    terminals = workspace?.terminals(inWorktree: worktree.id) ?? []
    rebuildTabBar()
    applySurface()
  }

  /// Open a new web tab in this worktree, address field focused and ready to type. A popup opens
  /// the same way but arrives with its web view already built (see `wire`); `url` opens a known
  /// address instead — a link followed from the transcript — and lands on the tab already showing
  /// it rather than stacking a second copy, which is the rule a file tab follows.
  ///
  /// A web tab has no preview slot, unlike a file or a commit: the two or three pages an agent
  /// hands you are context you want side by side, so they are lasting from the first click, and
  /// the reuse above is what keeps that from piling up.
  func openBrowser(worktree: Worktree, webView: WKWebView? = nil, url: URL? = nil) {
    loadViewIfNeeded()
    // A popup belongs to the worktree of the page that opened it, which is not necessarily the
    // one on screen: a sign-in finishing in a background worktree's tab must not swap the desk
    // out from under the rail's selection. It joins that worktree's tabs and waits there.
    let popupInBackground = webView != nil && worktreeID != nil && worktreeID != worktree.id
    if !popupInBackground { self.worktreeID = worktree.id }
    if let url,
      let existing = (browserTabsByWorktree[worktree.id] ?? []).first(
        where: { $0.pane.currentURL == url })
    {
      surface = .browser(existing.id)
      terminals = workspace?.terminals(inWorktree: worktree.id) ?? []
      rebuildTabBar()
      applySurface()
      return
    }
    let tab = BrowserTab(pane: BrowserPaneViewController(webView: webView))
    wire(tab, in: worktree.id)
    var tabs = browserTabsByWorktree[worktree.id] ?? []
    tabs.append(tab)
    browserTabsByWorktree[worktree.id] = tabs
    view.window?.invalidateRestorableState()
    guard !popupInBackground else { return }
    surface = .browser(tab.id)
    terminals = workspace?.terminals(inWorktree: worktree.id) ?? []
    rebuildTabBar()
    applySurface()
    if let url {
      tab.pane.load(url)
    } else if webView == nil {
      tab.pane.focusAddress()
    }
  }

  /// Every web tab worth saving, across every worktree — a blank one is one keystroke to make
  /// again, so it has no slot.
  var restorableBrowserTabs: [BrowserTabState] {
    browserTabsByWorktree.flatMap { worktreeID, tabs in
      inStripOrder(tabs, in: worktreeID, surface: { .browser($0.id) })
        .compactMap { tab -> BrowserTabState? in
          guard var state = tab.pane.restorableState else { return nil }
          state.worktreeID = worktreeID
          return state
        }
    }
  }

  /// Put last run's web tabs back on their worktrees. None loads until its tab is shown — see the
  /// pane — so a window with a dozen of them comes back as fast as one with none. A tab whose
  /// worktree is gone stays gone, the way a terminal's does.
  func restoreBrowserTabs(_ states: [BrowserTabState]) {
    loadViewIfNeeded()
    for state in states {
      guard workspace?.worktree(id: state.worktreeID) != nil else { continue }
      let tab = BrowserTab(pane: BrowserPaneViewController(restoring: state))
      wire(tab, in: state.worktreeID)
      browserTabsByWorktree[state.worktreeID, default: []].append(tab)
    }
  }

  /// The showing worktree's strip, one line per tab: its place, `●` for the one showing, its kind,
  /// and what it is of — with a restored tab nobody has opened yet marked unread. The scripting
  /// surface's handle on the desk as a whole, added for the same reason the commit tab and the
  /// files panel have theirs: the strip is buttons, so what a relaunch put back on it, in what
  /// order and open at which tab, is otherwise only checkable by clicking at coordinates.
  var tabStripReport: String {
    let order = orderedSurfaces
    guard !order.isEmpty else { return "(no tabs)" }
    return order.enumerated().map { index, item in
      let marker = item == surface ? "●" : " "
      return "\(index + 1) \(marker) \(describe(item))"
    }.joined(separator: "\n")
  }

  private func describe(_ item: Surface) -> String {
    switch item {
    case .file(let id):
      guard let tab = fileTabs.first(where: { $0.id == id }) else { return "file" }
      // An image pane has no text to read back at all, so whether the file is one — and whether
      // it decoded — is said here or nowhere. Every built tab answers, not only the one showing:
      // a tab that has not been read yet says `(unread)` instead, which is the honest answer for
      // it, and a restored strip is exactly what this is read to check.
      let kind = tab.content.isShowingImage ? "  (image)" : ""
      return "file      \(tab.path)\(tab.isPending ? "  (unread)" : "")\(kind)"
    case .commit(let id):
      guard let tab = commitTabs.first(where: { $0.id == id }) else { return "commit" }
      return "commit    \(tab.oid.prefix(7))\(tab.isPending ? "  (unread)" : "")"
    case .browser(let id):
      guard let tab = browserTabs.first(where: { $0.id == id }) else { return "browser" }
      return "browser   \(tab.pane.pageTitle)"
    case .terminal(let id):
      guard let terminal = terminals.first(where: { $0.id == id }) else { return "terminal" }
      return "terminal  \(terminal.title)"
    case .none:
      return "none"
    }
  }

  /// The web tabs of the worktree on screen, as text — one line each, `●` marking the one
  /// showing. The scripting surface's handle on the browser: a web tab has no text of its own to
  /// read back, and its whole job is to end up at a URL, so what the dictionary needs is the
  /// title and that URL. Without it the only way to check where a click landed is to click at
  /// coordinates, which is what the dictionary exists to avoid.
  var browserTabsReport: String {
    let tabs = browserTabs
    guard !tabs.isEmpty else { return "(no web tabs)" }
    return tabs.enumerated().map { index, tab in
      let marker = surface == .browser(tab.id) ? "●" : " "
      return
        "\(index + 1) \(marker) \(tab.pane.pageTitle)  \(tab.pane.currentURL?.absoluteString ?? "")"
    }.joined(separator: "\n")
  }

  /// The web tab showing right now — what a script loads an address into.
  var selectedBrowserPane: BrowserPaneViewController? {
    guard case .browser(let id) = surface else { return nil }
    return browserTabs.first { $0.id == id }?.pane
  }

  private func wire(_ tab: BrowserTab, in worktreeID: UUID) {
    addChild(tab.pane)
    let id = tab.id
    // A page retitles itself several times while it loads. That relabels one tab in place
    // rather than rebuilding the strip — the commit tab's stance, that what is on screen is
    // what gets built — and marks the window's state stale, since the address moved too.
    tab.pane.onTitleChange = { [weak self] in
      guard let self else { return }
      if let button = self.tabButtons[.browser(id)] {
        button.title = tab.pane.pageTitle
        button.toolTip = tab.pane.currentURL?.absoluteString
      }
      self.view.window?.invalidateRestorableState()
    }
    tab.pane.onOpenPopup = { [weak self] popup in
      guard let self, let worktree = self.workspace?.worktree(id: worktreeID) else { return false }
      self.openBrowser(worktree: worktree, webView: popup)
      return true
    }
    tab.pane.onClose = { [weak self] in
      guard let self else { return }
      // The tab may be in a worktree not on screen (a background popup closing itself), so it is
      // removed from its own bucket rather than through the strip's close.
      var tabs = self.browserTabsByWorktree[worktreeID] ?? []
      guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
      let previous = self.orderedSurfaces
      tabs[index].pane.removeFromParent()
      tabs.remove(at: index)
      self.browserTabsByWorktree[worktreeID] = tabs
      self.view.window?.invalidateRestorableState()
      guard worktreeID == self.worktreeID else { return }
      self.reconcileSurface(previous: previous)
      self.rebuildTabBar()
      self.applySurface()
    }
  }

  /// Show a just-created terminal and hand it the keyboard.
  func open(terminalID: UUID) {
    surface = .terminal(terminalID)
    reload(worktreeID: worktreeID)
    if let terminal = terminals.first(where: { $0.id == terminalID }) {
      view.window?.makeFirstResponder(terminal.view)
    }
  }

  /// ⌘W: close the active tab — a file (after the unsaved-edit prompt) or a terminal. Returns
  /// whether there was one to close, so the menu action is a no-op on an empty desk.
  @discardableResult
  /// Every unsaved edit on the desk, asked about before the window goes — the same Save / Don't
  /// Save / Cancel a closing tab gets, since closing the window closes every tab. False when one
  /// of them was cancelled, which the window and the app both read as "do not close after all".
  ///
  /// It is what makes restoring file tabs honest: hukan keeps no copy of an unsaved buffer, so
  /// without this a quit dropped the edit and put the tab back on the file as it had been left on
  /// disk. Across every worktree, not only the one showing — the alert names the file, and the tab
  /// is selected first when it is on the desk in front of you, so a Cancel lands on it.
  func confirmClosingWindow() -> Bool {
    let previous = surface
    for (worktreeID, tabs) in fileTabsByWorktree {
      for tab in tabs where tab.content.hasUnsavedEdit {
        if worktreeID == self.worktreeID {
          surface = .file(tab.id)
          rebuildTabBar()
          applySurface()
        }
        guard tab.content.confirmLeavingCurrentFile() else { return false }
      }
    }
    guard surface != previous else { return true }
    surface = previous
    rebuildTabBar()
    applySurface()
    return true
  }

  func closeActiveTab() -> Bool {
    guard surface != .none else { return false }
    closeTabs([surface])
    return true
  }

  /// Close every tab in `targets`, in strip order — one tab for ⌘W and the ✕, a sweep for the
  /// tab menu's Close Others / to the Right / All. A cancelled unsaved-edit prompt stops the
  /// sweep where it stands rather than rolling on: the Cancel answered for the gesture, not for
  /// that one file.
  private func closeTabs(_ targets: [Surface]) {
    let previous = orderedSurfaces
    for target in targets {
      if !close(target) { break }
    }
    reconcileSurface(previous: previous)
    rebuildTabBar()
    applySurface()
    // The last tab gone, the desk has nothing left to be given the window for.
    if isMaximized, surface == .none { onSetMaximized?(false) }
  }

  /// Remove one tab, whichever kind, leaving the selection to the caller. Returns false only
  /// when a file's unsaved edit was kept by Cancel — the one thing that can refuse.
  private func close(_ target: Surface) -> Bool {
    switch target {
    case .none:
      return true
    case .terminal(let id):
      workspace?.removeTerminal(id: id)
      terminals = worktreeID.flatMap { workspace?.terminals(inWorktree: $0) } ?? []
      return true
    case .file(let id):
      guard let worktreeID, var tabs = fileTabsByWorktree[worktreeID],
        let index = tabs.firstIndex(where: { $0.id == id })
      else { return true }
      // A pending edit gets Save / Don't Save / Cancel before the tab goes.
      guard tabs[index].content.confirmLeavingCurrentFile() else { return false }
      let closed = tabs[index].path
      tabs[index].content.removeFromParent()
      tabs.remove(at: index)
      fileTabsByWorktree[worktreeID] = tabs
      onFileTabClosed?(worktreeID, closed)
      return true
    case .commit(let id):
      guard let worktreeID, var tabs = commitTabsByWorktree[worktreeID],
        let index = tabs.firstIndex(where: { $0.id == id })
      else { return true }
      // Nothing to save: a commit is finished, so it just goes.
      tabs[index].content.removeFromParent()
      tabs.remove(at: index)
      commitTabsByWorktree[worktreeID] = tabs
      return true
    case .browser(let id):
      guard let worktreeID, var tabs = browserTabsByWorktree[worktreeID],
        let index = tabs.firstIndex(where: { $0.id == id })
      else { return true }
      tabs[index].pane.removeFromParent()
      tabs.remove(at: index)
      browserTabsByWorktree[worktreeID] = tabs
      view.window?.invalidateRestorableState()
      return true
    }
  }

  /// An agent edited the worktree on disk: refresh the open files that moved, in place, keeping
  /// each where it was scrolled (a dirty buffer is left alone — see the content pane).
  ///
  /// `changed` is nil when what moved could not be placed — a commit, a staging — and every tab
  /// has to be re-read. Otherwise only the tabs named: re-reading a file is a whole-file parse
  /// and a highlight, and it drops the selection with it, so a tab nobody wrote to must not pay
  /// for a tab somebody did.
  func refreshOpenFiles(changed: Set<String>? = nil) {
    // A restored tab nobody has opened has nothing read to refresh; it reads the file when it is
    // looked at, which is later than this and so newer.
    for tab in fileTabs
    where !tab.isPending && (changed == nil || changed?.contains(tab.path) == true) {
      tab.content.refreshCurrent()
    }
  }

  /// The files panel renamed something. A tab is keyed by its path, so every tab on the renamed
  /// file — or under the renamed directory — follows it; nothing is closed, since the text is
  /// exactly where it was, one name along.
  func fileRenamed(worktreeID: UUID, from: String, to: String) {
    var moved = false
    for tab in fileTabsByWorktree[worktreeID] ?? [] {
      guard let path = Self.repath(tab.path, from: from, to: to) else { continue }
      let previous = tab.path
      tab.path = path
      // A restored tab that has not been read yet only needs the new name: it opens on it.
      if !tab.isPending { tab.content.renamed(to: path) }
      onFileTabRenamed?(worktreeID, previous, path)
      moved = true
    }
    guard moved else { return }
    rebuildTabBar()
  }

  /// The files panel deleted something. A tab showing a file that no longer exists has nothing
  /// left to show, so it goes — without the unsaved-edit prompt `close` would put in front of
  /// it, which would be offering to save an edit back to a path the person has just removed.
  func fileDeleted(worktreeID: UUID, path: String) {
    let previous = orderedSurfaces
    var tabs = fileTabsByWorktree[worktreeID] ?? []
    let doomed = tabs.filter { Self.repath($0.path, from: path, to: path) != nil }
    guard !doomed.isEmpty else { return }
    for tab in doomed { tab.content.removeFromParent() }
    let gone = Set(doomed.map(\.id))
    tabs.removeAll { gone.contains($0.id) }
    fileTabsByWorktree[worktreeID] = tabs
    for tab in doomed { onFileTabClosed?(worktreeID, tab.path) }
    reconcileSurface(previous: previous)
    rebuildTabBar()
    applySurface()
    if isMaximized, surface == .none { onSetMaximized?(false) }
  }

  /// `path` rewritten if it is `from` or sits under it, nil if the rename does not reach it.
  /// The directory test is on the separator, so renaming `Sources` does not claim `Sources.md`.
  private static func repath(_ path: String, from: String, to: String) -> String? {
    if path == from { return to }
    guard path.hasPrefix(from + "/") else { return nil }
    return to + path.dropFirst(from.count)
  }

  // MARK: Surface bookkeeping

  /// Drop the current surface if its tab no longer exists, then land on its neighbour: the tab
  /// that stood to its right in the strip as it was — a browser's rule, and the one that reads
  /// right whatever order dragging has made — else the one to its left. `previous` is the strip
  /// before the change; without it (the worktree switched out from under the desk) the landing
  /// is the last tab, and with nothing left it is nothing.
  private func reconcileSurface(previous: [Surface] = []) {
    let order = orderedSurfaces
    guard !order.contains(surface) else { return }
    if let index = previous.firstIndex(of: surface),
      let neighbour = previous[index...].first(where: order.contains)
        ?? previous[..<index].last(where: order.contains)
    {
      surface = neighbour
    } else {
      surface = order.last ?? .none
    }
  }

  private func pruneClosedWorktrees() {
    guard let workspace else { return }
    let live = Set(workspace.worktrees.map(\.id))
    for key in fileTabsByWorktree.keys where !live.contains(key) {
      for tab in fileTabsByWorktree[key] ?? [] { tab.content.removeFromParent() }
      fileTabsByWorktree[key] = nil
    }
    for key in browserTabsByWorktree.keys where !live.contains(key) {
      for tab in browserTabsByWorktree[key] ?? [] { tab.pane.removeFromParent() }
      browserTabsByWorktree[key] = nil
    }
    for key in commitTabsByWorktree.keys where !live.contains(key) {
      for tab in commitTabsByWorktree[key] ?? [] { tab.content.removeFromParent() }
      commitTabsByWorktree[key] = nil
    }
    for key in tabOrderByWorktree.keys where !live.contains(key) { tabOrderByWorktree[key] = nil }
  }

  // MARK: Tab strip

  private func rebuildTabBar() {
    // What is on the strip, and which of it is showing, is what comes back after a relaunch — and
    // every act that moves either rebuilds the strip, so one call here covers the lot. A tab
    // renaming itself as its page loads does not, which is why the browser marks it too.
    view.window?.invalidateRestorableState()
    for arranged in tabBar.arrangedSubviews {
      tabBar.removeArrangedSubview(arranged)
      arranged.removeFromSuperview()
    }
    tabButtons = [:]
    selectedTabView = nil
    let files = fileTabs
    let commits = commitTabs
    let browsers = browserTabs
    // Show the strip whenever anything is open, a lone file included — making a single tab the one
    // case that hides its own tab (and the `+` with it) was the odd exception. Only nothing open
    // collapses it.
    let total = files.count + commits.count + browsers.count + terminals.count
    guard total > 0 else {
      tabScroll.isHidden = true
      plusButton.isHidden = true
      hairline.isHidden = true
      tabBarHeight.constant = 0
      return
    }
    tabScroll.isHidden = false
    plusButton.isHidden = false
    hairline.isHidden = false
    tabBarHeight.constant = 30

    var tabs: [NSView] = []
    // One running index across the four kinds. A tab's identity in the strip is its position in
    // `orderedSurfaces`, which is what ⌃⇥, ⌘1…⌘9, a drag and the tab menu's "Close to the Right"
    // all count in — so every control on a tab carries that number and nothing else.
    let order = orderedSurfaces
    if let worktreeID { tabOrderByWorktree[worktreeID] = order }
    for (index, item) in order.enumerated() {
      switch item {
      case .file(let id):
        guard let file = files.first(where: { $0.id == id }) else { continue }
        // The dot for an unsaved edit rides in front of the name. It is the whole of what the
        // editor's own header used to say that the tab did not, and it belongs here, next to the
        // ✕ that would discard it.
        let name = (file.path as NSString).lastPathComponent
        let tab = makeTab(
          index: index, title: (file.content.hasUnsavedEdit ? "• " : "") + name, image: nil,
          selected: surface == item, preview: file.isPreview)
        tab.toolTip = file.path
        tabs.append(tab)
      case .commit(let id):
        guard let commit = commits.first(where: { $0.id == id }) else { continue }
        let tab = makeTab(
          index: index, title: commit.content.tabTitle,
          image: NSImage(
            systemSymbolName: "point.3.filled.connected.trianglepath.dotted",
            accessibilityDescription: nil),
          selected: surface == item, preview: commit.isPreview)
        tab.toolTip = commit.oid
        tabs.append(tab)
      case .browser(let id):
        guard let browser = browsers.first(where: { $0.id == id }) else { continue }
        // Every web tab wears the same globe, so the address is what tells three GitHub tabs
        // apart — on the tooltip, where a file tab keeps its path.
        let tab = makeTab(
          index: index, title: browser.pane.pageTitle,
          image: NSImage(systemSymbolName: "globe", accessibilityDescription: nil),
          selected: surface == item, surface: item)
        tab.toolTip = browser.pane.currentURL?.absoluteString
        tabs.append(tab)
      case .terminal(let id):
        guard let terminal = terminals.first(where: { $0.id == id }) else { continue }
        tabs.append(
          makeTab(
            index: index, title: terminal.title,
            image: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil),
            selected: surface == item))
      case .none:
        continue
      }
    }
    // A thin rule between adjacent tabs so the boundaries read even when none is selected.
    for (i, tab) in tabs.enumerated() {
      if i > 0 { tabBar.addArrangedSubview(tabSeparator()) }
      tabBar.addArrangedSubview(tab)
    }
    tabBar.tabViews = tabs

    // The flexible tail the `.fill` distribution stretches into, so leftover width lands here
    // rather than on a tab. It hugs and resists compression at the floor priority, so it is both
    // the first thing to grow when there is room and the first to collapse when there is not —
    // past which the strip scrolls rather than the labels giving way.
    let spacer = NSView()
    spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    tabBar.addArrangedSubview(spacer)
    revealSelectedTab()
  }

  /// Scroll the selected tab back into sight. The strip scrolls now, so the tab ⌃⇥ or ⌘1…⌘9 just
  /// moved to can be off the end of the column — and a selection that cannot be seen is the same
  /// as no selection at all. Only the strip is laid out, not the desk under it: the surface being
  /// swapped in is far more expensive than the row naming it.
  private func revealSelectedTab() {
    guard let tab = selectedTabView, !tabScroll.isHidden else { return }
    tabScroll.layoutSubtreeIfNeeded()
    // A tab's own bounds stop at its edge; widened, the scroll leaves a hair of the neighbour
    // showing, which is what says there is more of the strip in that direction.
    tab.scrollToVisible(tab.bounds.insetBy(dx: -12, dy: 0))
  }

  /// One tab: a clickable label (icon + title) and a close ✕, wrapped so the selected one can wear
  /// a rounded background — the boundary and the selection both read at a glance. `index` is the
  /// tab's place in the strip, and every control built here carries it: what a click, a ✕ or a
  /// menu item acts on is read back out of `orderedSurfaces`, which is rebuilt with the strip.
  private func makeTab(
    index: Int, title: String, image: NSImage?, selected: Bool, preview: Bool = false,
    surface: Surface? = nil
  ) -> NSView {
    let button = TabLabelButton()
    if let surface { tabButtons[surface] = button }
    button.title = title
    button.image = image
    button.imagePosition = image == nil ? .noImage : .imageLeading
    button.isBordered = false
    button.bezelStyle = .accessoryBarAction
    // A preview tab reads in italic, the way an editor marks the not-yet-committed one.
    let base = NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
    button.font =
      preview ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
    button.contentTintColor = selected ? .labelColor : .secondaryLabelColor
    button.lineBreakMode = .byTruncatingMiddle
    button.tag = index
    button.target = self
    button.action = #selector(selectTab(_:))
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    // Cap the title so one long filename cannot eat the strip while others are pushed to a sliver;
    // `.byTruncatingMiddle` keeps the extension visible past the cap.
    button.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true

    let closeButton = NSButton()
    closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
    closeButton.imagePosition = .imageOnly
    closeButton.isBordered = false
    closeButton.bezelStyle = .accessoryBarAction
    closeButton.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
    closeButton.contentTintColor = .tertiaryLabelColor
    closeButton.toolTip = "Close"
    closeButton.tag = index
    closeButton.target = self
    closeButton.action = #selector(closeTabFromStrip(_:))
    closeButton.setContentHuggingPriority(.required, for: .horizontal)

    let row = NSStackView(views: [button, closeButton])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 3
    row.translatesAutoresizingMaskIntoConstraints = false

    let tab = LayerSurface()
    tab.wantsLayer = true
    if selected {
      tab.paintLayer = {
        $0.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
      }
      tab.layer?.cornerRadius = 5
    }
    tab.addSubview(row)
    button.tabView = tab
    tab.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 7),
      row.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -6),
      row.topAnchor.constraint(equalTo: tab.topAnchor, constant: 2),
      row.bottomAnchor.constraint(equalTo: tab.bottomAnchor, constant: -2),
    ])
    // The same menu on all three: AppKit pops the menu of the view the right-click landed on,
    // and that is as often the label or the ✕ as the tab's own padding around them.
    let menu = tabMenu(index: index, preview: preview)
    tab.menu = menu
    button.menu = menu
    closeButton.menu = menu
    if selected { selectedTabView = tab }
    return tab
  }

  /// A tab's right-click menu: the four ways to close from here, "Keep Open" while the tab is
  /// still a preview, and the maximize toggle a double-click also reaches. Built with the strip
  /// — which is rebuilt whenever anything moves, the maximized state included — so an item can
  /// state plainly whether it applies rather than being greyed from a validator somewhere else.
  private func tabMenu(index: Int, preview: Bool) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let count = tabCount
    func add(_ title: String, _ action: Selector, enabled: Bool = true) {
      let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
      item.target = self
      item.tag = index
      item.isEnabled = enabled
    }
    add("Close", #selector(closeTabFromMenu(_:)))
    add("Close Others", #selector(closeOtherTabs(_:)), enabled: count > 1)
    add("Close to the Right", #selector(closeTabsToTheRight(_:)), enabled: index < count - 1)
    add("Close All", #selector(closeAllTabs(_:)))
    menu.addItem(.separator())
    // Only a preview tab has anything to keep open; the rest already are.
    if preview { add("Keep Open", #selector(keepTabOpen(_:))) }
    add(isMaximized ? "Restore Layout" : "Maximize Tab", #selector(toggleMaximized(_:)))
    return menu
  }

  private func tabSeparator() -> NSView {
    let line = LayerSurface()
    line.wantsLayer = true
    line.paintLayer = { $0.backgroundColor = NSColor.separatorColor.cgColor }
    line.translatesAutoresizingMaskIntoConstraints = false
    line.widthAnchor.constraint(equalToConstant: 1).isActive = true
    line.heightAnchor.constraint(equalToConstant: 14).isActive = true
    return line
  }

  /// A click on a tab's label: show it. A double-click promotes the tab as far as it will go —
  /// a preview becomes a lasting tab, and a tab that is already lasting takes the whole window.
  /// So the gesture that pins keeps pinning wherever pinning is what is left to do (the files
  /// panel's rule and the rail's, unchanged), and on a browser or a terminal — which have no
  /// preview state to leave — the first double-click is already the maximize.
  @objc private func selectTab(_ sender: NSButton) {
    let order = orderedSurfaces
    guard order.indices.contains(sender.tag) else { return }
    let target = order[sender.tag]
    surface = target
    if NSApp.currentEvent?.clickCount == 2, !pinIfPreview(target) {
      onSetMaximized?(!isMaximized)
    }
    rebuildTabBar()
    applySurface()
    // A terminal wants the keyboard as soon as it is showing; the rest are picked to be read.
    if case .terminal = target { focusActiveSurface() }
  }

  /// ⌘1…⌘9: the Nth tab of the strip, if the strip is that long.
  func selectTab(at index: Int) {
    let order = orderedSurfaces
    guard order.indices.contains(index) else { return }
    surface = order[index]
    rebuildTabBar()
    applySurface()
    focusActiveSurface()
  }

  // A tab's ✕ and the menu's Close are the same act on the same tab.
  @objc private func closeTabFromStrip(_ sender: NSButton) {
    closeTab(at: sender.tag)
  }

  @objc private func closeTabFromMenu(_ sender: NSMenuItem) {
    closeTab(at: sender.tag)
  }

  private func closeTab(at index: Int) {
    let order = orderedSurfaces
    guard order.indices.contains(index) else { return }
    closeTabs([order[index]])
  }

  @objc private func closeOtherTabs(_ sender: NSMenuItem) {
    let order = orderedSurfaces
    guard order.indices.contains(sender.tag) else { return }
    // Clearing everything around a tab is a way of saying this is the one being worked in, so it
    // becomes the active one — it is also the tab that has to survive the sweep.
    surface = order[sender.tag]
    closeTabs(order.enumerated().filter { $0.offset != sender.tag }.map(\.element))
  }

  @objc private func closeTabsToTheRight(_ sender: NSMenuItem) {
    let order = orderedSurfaces
    guard order.indices.contains(sender.tag) else { return }
    closeTabs(Array(order[(sender.tag + 1)...]))
  }

  @objc private func closeAllTabs(_ sender: NSMenuItem) {
    closeTabs(orderedSurfaces)
  }

  @objc private func keepTabOpen(_ sender: NSMenuItem) {
    let order = orderedSurfaces
    guard order.indices.contains(sender.tag) else { return }
    pinIfPreview(order[sender.tag])
    rebuildTabBar()
  }

  @objc private func toggleMaximized(_ sender: Any?) {
    onSetMaximized?(!isMaximized)
  }

  @objc private func showAddMenu(_ sender: NSButton) {
    let menu = NSMenu()
    menu.addItem(withTitle: "New Browser", action: #selector(addBrowserTab), keyEquivalent: "")
      .target = self
    menu.addItem(withTitle: "New Terminal", action: #selector(addTerminalTab), keyEquivalent: "")
      .target = self
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
  }

  @objc private func addTerminalTab() {
    onNewTerminal?()
  }

  @objc private func addBrowserTab() {
    onNewBrowser?()
  }

  // MARK: Surface swap

  private var currentSurfaceView: NSView?

  private func applySurface() {
    switch surface {
    case .none:
      setSurfaceView(placeholder)
    case .file(let id):
      if let tab = fileTabs.first(where: { $0.id == id }) {
        realize(tab)
        setSurfaceView(tab.content.view)
      } else {
        setSurfaceView(placeholder)
      }
    case .browser(let id):
      if let tab = browserTabs.first(where: { $0.id == id }) {
        setSurfaceView(tab.pane.view)
      } else {
        setSurfaceView(placeholder)
      }
    case .commit(let id):
      if let tab = commitTabs.first(where: { $0.id == id }) {
        realize(tab)
        setSurfaceView(tab.content.view)
      } else {
        setSurfaceView(placeholder)
      }
    case .terminal(let id):
      if let terminal = terminals.first(where: { $0.id == id }) {
        setSurfaceView(terminal.view)
      } else {
        setSurfaceView(placeholder)
      }
    }
  }

  private func setSurfaceView(_ surfaceView: NSView) {
    guard currentSurfaceView !== surfaceView else { return }
    currentSurfaceView?.removeFromSuperview()
    container.addSubview(surfaceView)
    surfaceView.pin(to: container)
    currentSurfaceView = surfaceView
  }
}
