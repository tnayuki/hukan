import AppKit

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
  private let indicator = NSView()

  init() {
    super.init(frame: .zero)
    registerForDraggedTypes([Self.tabType])
    indicator.wantsLayer = true
    indicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
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

/// The right column's content area: this worktree's open files, side by side as tabs. Each tab
/// navigates inside itself — a file by its find bar; getting *to* a file is the files panel beside
/// this, and getting to another worktree is the rail. The strip shows only when there is something
/// to switch between — a lone open file is the plain file pane it replaced.
///
/// Open files are the desk's own state, kept per worktree so switching worktrees swaps the whole
/// set. The strip's order is the desk's too, whatever kind
/// a tab is: a new tab takes the end, a drag puts it wherever it was dropped, and closing the
/// active one lands on the neighbour to its right.
final class WorktreeDeskViewController: NSViewController {
  var workspace: Workspace?
  /// A file tab wrote itself back to disk — the column reloads so the change shows in the diffstat.
  var onFileSaved: (() -> Void)?
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
    let content = FileContentViewController()
    init(path: String, isPreview: Bool) {
      self.path = path
      self.isPreview = isPreview
    }
  }

  private let tabBar = TabStrip()
  /// The strip's clip. Tabs keep their natural width and run off the edge rather than being
  /// squeezed into slivers, so a desk with a dozen of them is walked rather than read at a
  /// glance — which is what the strip was before: past a handful of tabs every label was
  /// truncated to nothing at once, and the whole row said the same thing about none of them.
  private let tabScroll = TabStripScrollView()
  private let hairline = NSView()
  private let container = NSView()
  private let placeholder = NSView()
  private lazy var tabBarHeight = tabScroll.heightAnchor.constraint(equalToConstant: 0)
  private var worktreeID: UUID?
  private var fileTabsByWorktree: [UUID: [FileTab]] = [:]
  /// The strip's order per worktree: the order the tabs were opened in, then whatever dragging
  /// has made of it. Written back on every rebuild, so a tab it has not met — one just opened —
  /// takes the end of the strip, which is where a browser puts a new tab, and one that has since
  /// closed drops out.
  private var tabOrderByWorktree: [UUID: [Surface]] = [:]

  private enum Surface: Equatable {
    case none
    case file(UUID)
  }
  private var surface: Surface = .none
  /// The selected tab's view in the strip, so it can be scrolled back into sight after a rebuild.
  private weak var selectedTabView: NSView?

  private var fileTabs: [FileTab] { worktreeID.flatMap { fileTabsByWorktree[$0] } ?? [] }

  /// The file content of the active tab, or nil when nothing is showing. The column drives save /
  /// diff-toggle / refresh through this.
  var activeFileContent: FileContentViewController? {
    guard case .file(let id) = surface, let tab = fileTabs.first(where: { $0.id == id }) else {
      return nil
    }
    return tab.content
  }

  /// Whether ⌘W has a tab to close — a file is the active surface.
  var hasClosableTab: Bool { surface != .none }

  /// Whether ⌘F has a surface to search in — a file, not an empty desk.
  var canFind: Bool {
    switch surface {
    case .file: return true
    case .none: return false
    }
  }

  /// ⌘F: find within the active surface — the file's own find bar, which reads its action tag
  /// off the menu item passed through as `sender`.
  func performFind(_ sender: Any?) {
    guard case .file(let id) = surface else { return }
    fileTabs.first { $0.id == id }?.content.performFind(sender)
  }

  /// How many tabs the desk holds — ⌃⇥ tab-cycling validates on more than one.
  var tabCount: Int { fileTabs.count }

  /// The tabs in strip order, so ⌃⇥ / ⌃⇧⇥ walk them the way they read: the order kept in
  /// `tabOrderByWorktree`, then any tab it does not know yet.
  private var orderedSurfaces: [Surface] {
    worktreeID.map { orderedSurfaces(in: $0) } ?? []
  }

  /// The same for any worktree.
  private func orderedSurfaces(in worktreeID: UUID) -> [Surface] {
    let present = (fileTabsByWorktree[worktreeID] ?? []).map { Surface.file($0.id) }
    let known = (tabOrderByWorktree[worktreeID] ?? []).filter(present.contains)
    return known + present.filter { !known.contains($0) }
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
    case .file, .none:
      break
    }
  }

  override func loadView() {
    view = NSView()

    tabBar.orientation = .horizontal
    tabBar.alignment = .centerY
    tabBar.spacing = 4
    tabBar.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
    tabBar.translatesAutoresizingMaskIntoConstraints = false
    tabBar.onMove = { [weak self] from, to in self?.moveTab(at: from, to: to) }
    tabScroll.documentView = tabBar
    tabScroll.drawsBackground = false
    tabScroll.hasHorizontalScroller = false
    tabScroll.hasVerticalScroller = false
    tabScroll.verticalScrollElasticity = .none
    tabScroll.automaticallyAdjustsContentInsets = false
    tabScroll.translatesAutoresizingMaskIntoConstraints = false
    // The stack is the document: as tall as the clip, as wide as its tabs, and pinned to the
    // leading edge — so a strip that fits sits where it always did and one that does not scrolls
    // instead of compressing.
    let clip = tabScroll.contentView
    NSLayoutConstraint.activate([
      tabBar.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
      tabBar.topAnchor.constraint(equalTo: clip.topAnchor),
      tabBar.heightAnchor.constraint(equalTo: clip.heightAnchor),
    ])
    // A hairline under the strip, so the tab row reads as a header the way the other columns' do.
    hairline.wantsLayer = true
    hairline.layer?.backgroundColor = NSColor.separatorColor.cgColor
    hairline.translatesAutoresizingMaskIntoConstraints = false
    container.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(tabScroll)
    view.addSubview(hairline)
    view.addSubview(container)
    NSLayoutConstraint.activate([
      // The desk already hangs below the toolbar (`ToolbarInsetViewController`), so this is the
      // same as the top — kept as the safe area for the cases AppKit adds one anyway.
      tabScroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      tabScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tabScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tabBarHeight,
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

  /// Re-render for the given worktree: show its open files, dropping any surface whose tab is gone
  /// (the worktree switched out from under it).
  func reload(worktreeID: UUID?) {
    loadViewIfNeeded()
    self.worktreeID = worktreeID
    pruneClosedWorktrees()
    reconcileSurface()
    rebuildTabBar()
    applySurface()
  }

  /// Open the file at `path` in a tab, or focus the tab already showing it. `preview` (a single
  /// click) opens it in the reused preview slot; a non-preview open (a double-click) makes a
  /// lasting tab — and pins the preview one if that is what was already showing this file.
  /// `reveal` lands the view on a line, selecting `term` there — the files panel's hand-off for
  /// a content hit.
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
      fresh.content.onSaved = { [weak self] in self?.onFileSaved?() }
      // The first edit pins the tab: you must not lose what you just started typing to the next
      // single click reusing the slot.
      let id = fresh.id
      fresh.content.onEdited = { [weak self] in
        _ = self?.pinIfPreview(.file(id))
      }
      // The dot goes up and comes down on the tab; the pin above rides the same first edit, so
      // one rebuild here covers both.
      fresh.content.onDirtyChanged = { [weak self] in self?.rebuildTabBar() }
      addChild(fresh.content)
      fresh.content.show(worktree: worktree, path: path)
      tabs.append(fresh)
      fileTabsByWorktree[worktree.id] = tabs
      tab = fresh
    }
    surface = .file(tab.id)
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
    case .none:
      return false
    }
  }

  /// ⌘W: close the active tab — a file, after the unsaved-edit prompt. Returns whether there was
  /// one to close, so the menu action is a no-op on an empty desk.
  @discardableResult
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

  /// Remove one tab, leaving the selection to the caller. Returns false only when a file's
  /// unsaved edit was kept by Cancel — the one thing that can refuse.
  private func close(_ target: Surface) -> Bool {
    switch target {
    case .none:
      return true
    case .file(let id):
      guard let worktreeID, var tabs = fileTabsByWorktree[worktreeID],
        let index = tabs.firstIndex(where: { $0.id == id })
      else { return true }
      // A pending edit gets Save / Don't Save / Cancel before the tab goes.
      guard tabs[index].content.confirmLeavingCurrentFile() else { return false }
      tabs[index].content.removeFromParent()
      tabs.remove(at: index)
      fileTabsByWorktree[worktreeID] = tabs
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
    for tab in fileTabs where changed == nil || changed?.contains(tab.path) == true {
      tab.content.refreshCurrent()
    }
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
    for key in tabOrderByWorktree.keys where !live.contains(key) { tabOrderByWorktree[key] = nil }
  }

  // MARK: Tab strip

  private func rebuildTabBar() {
    for arranged in tabBar.arrangedSubviews {
      tabBar.removeArrangedSubview(arranged)
      arranged.removeFromSuperview()
    }
    selectedTabView = nil
    let files = fileTabs
    // Nothing to switch between — a lone open file is the plain file pane — so collapse the strip.
    let total = files.count
    guard total > 1 else {
      tabScroll.isHidden = true
      hairline.isHidden = true
      tabBarHeight.constant = 0
      return
    }
    tabScroll.isHidden = false
    hairline.isHidden = false
    tabBarHeight.constant = 30

    var tabs: [NSView] = []
    // A tab's identity in the strip is its position in
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
    index: Int, title: String, image: NSImage?, selected: Bool, preview: Bool = false
  ) -> NSView {
    let button = TabLabelButton()
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

    let tab = NSView()
    tab.wantsLayer = true
    if selected {
      tab.layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
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
    let line = NSView()
    line.wantsLayer = true
    line.layer?.backgroundColor = NSColor.separatorColor.cgColor
    line.translatesAutoresizingMaskIntoConstraints = false
    line.widthAnchor.constraint(equalToConstant: 1).isActive = true
    line.heightAnchor.constraint(equalToConstant: 14).isActive = true
    return line
  }

  /// A click on a tab's label: show it. A double-click promotes the tab as far as it will go —
  /// a preview becomes a lasting tab, and a tab that is already lasting takes the whole window.
  /// So the gesture that pins keeps pinning wherever pinning is what is left to do (the files
  /// panel's rule and the rail's, unchanged), and past that the same gesture maximizes.
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

  // MARK: Surface swap

  private var currentSurfaceView: NSView?

  private func applySurface() {
    switch surface {
    case .none:
      setSurfaceView(placeholder)
    case .file(let id):
      if let tab = fileTabs.first(where: { $0.id == id }) {
        setSurfaceView(tab.content.view)
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
