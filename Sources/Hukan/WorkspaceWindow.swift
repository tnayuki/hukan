import AppKit

extension NSToolbarItem.Identifier {
  static let sessionFilter = NSToolbarItem.Identifier("sessionFilter")
  static let status = NSToolbarItem.Identifier("status")
  static let systemUsage = NSToolbarItem.Identifier("systemUsage")
  static let usage = NSToolbarItem.Identifier("usage")
  static let toggleFiles = NSToolbarItem.Identifier("toggleFiles")
  static let filesFilter = NSToolbarItem.Identifier("filesFilter")
  static let filesScope = NSToolbarItem.Identifier("filesScope")
  static let filesSeparator = NSToolbarItem.Identifier("filesSeparator")
}

/// Hangs its content below the titlebar inside a window whose content view runs full size.
///
/// The rail is full height, which means `.fullSizeContentView`, which means every view in the
/// window's split reaches the window's top edge — including the split's own divider views, which
/// then show through the toolbar's glass. Putting the transcript/desk split inside this keeps
/// its divider out of the titlebar: what spans the toolbar here is a plain view with nothing
/// drawn in it.
private final class ToolbarInsetViewController: NSViewController {
  private let content: NSViewController

  init(content: NSViewController) {
    self.content = content
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("interface builder is not used") }

  override func loadView() { view = NSView() }

  override func viewDidLoad() {
    super.viewDidLoad()
    addChild(content)
    content.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(content.view)
    NSLayoutConstraint.activate([
      content.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }
}

final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSWindowRestoration,
  NSToolbarDelegate, NSMenuItemValidation
{
  static let windowIdentifier = NSUserInterfaceItemIdentifier("dev.tnayuki.hukan.workspace")
  static private(set) var all: [WorkspaceWindowController] = []

  /// The app-wide cascade point, threaded through successive New Windows the way
  /// NSDocumentController does its own: the first window centres and seeds this, and each
  /// window after steps down-right from the last instead of landing on top of it. `nil`
  /// means no run has started — reset there when the last window closes, so the next window
  /// centres again rather than marching off a staircase no window is standing on anymore.
  private static var cascadePoint: NSPoint?

  let workspace: Workspace

  private let rail = SessionRailViewController()
  private let running = RunningColumnViewController()
  private let files = FileColumns()

  /// The files panel, for the scripting surface — the panel is rows, which the object model does
  /// not address.
  var filesPanelForScripting: FilesPanelViewController { files.panel }
  /// The panel's own column, owned here because it is a top-level item now.
  private var filesPanelItem: NSSplitViewItem!
  /// The other three columns, held for the same reason: whichever column is being given the
  /// window, the rest are what it has to fold away.
  private var railItem: NSSplitViewItem!
  private var runningItem: NSSplitViewItem!
  private var deskItem: NSSplitViewItem!
  /// The window's split: the rail, then everything else. Two items, not three, because only the
  /// rail is meant to rise through the titlebar — see `columnsController`.
  private let splitController = NSSplitViewController()
  /// The transcript/desk split, one level down and hung below the toolbar. Its dividers are the
  /// reason it is nested: a divider view is as tall as the split view holding it, and the outer
  /// one spans the titlebar (`.fullSizeContentView`, which the full-height rail needs), so a
  /// transcript/desk divider up there drew a line straight through the toolbar's glass — cutting
  /// the worktree's name off from the load figures beside it. The rail's own boundary has no such
  /// view to leak: a sidebar item's divider is zero-width, drawn by the sidebar's edge and the
  /// toolbar's tracking separator instead.
  private let columnsController = NSSplitViewController()

  /// The rail's full-text filter, surfaced for scripting. Getting returns the current query;
  /// setting applies it and narrows the rail at once (synchronously, so a script can read the
  /// result immediately). `filteredSessionIDs` is what the filter currently shows — every
  /// session when no query is set — surfaced to scripting as the window's `session` element so an
  /// automated check can assert the filter without a screenshot.
  var sessionFilter: String {
    get { rail.searchQuery }
    set { rail.applyScriptedSearch(newValue) }
  }
  var filteredSessionIDs: [UUID] { rail.filteredSessionIDs }
  var selectedSessionIDs: [UUID] { rail.selectedSessionIDs }
  func selectSessions(_ ids: [UUID]) { rail.selectSessions(ids) }
  /// What the open transcript's search-highlight painted for the current filter: the number of
  /// occurrences and the offset of the first (which the view scrolled to), or -1 for none. Lets a
  /// script confirm the highlight landed without needing a screenshot.
  var transcriptMatchCount: Int { running.transcriptMatchCount }
  var transcriptFirstMatchOffset: Int { running.transcriptFirstMatchOffset }

  /// A session whose `/login` (or `/logout`) is running in an external terminal. Consumed the
  /// next time the window becomes key — coming back is the signal the flow is done, so a fresh
  /// `claude` is started to pick up the new credentials. Mirrors Unterm's reconnect-on-refocus.
  private var reconnectAfterLoginSessionID: UUID?

  init(workspace: Workspace) {
    self.workspace = workspace

    // .fullSizeContentView is what lets the rail rise through the titlebar (see the toolbar
    // note at the identifiers). Everything that is *not* the rail is held below the bar by
    // `ToolbarInsetViewController` rather than by each column minding the safe area itself.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1400, height: 880),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    super.init(window: window)

    window.delegate = self
    // The four columns' own minimums (rail 280, transcript and desk 640 between them, panel 260)
    // — narrower than this and the split view starts taking it out of one of them, and both edge
    // columns carry a toolbar row that stops fitting.
    window.minSize = NSSize(width: 1180, height: 520)
    window.title = "Hukan"

    // The three pieces that hand window creation to AppKit's restoration machinery — what
    // makes this a restored window rather than a new one. The Space it is restored onto is a
    // fourth thing, the default AppDelegate registers before any of this runs.
    window.isRestorable = true
    window.restorationClass = WorkspaceWindowController.self
    window.identifier = WorkspaceWindowController.windowIdentifier

    // Left: overview. Middle: what is running. Right: files.
    // Columns with a lower holdingPriority resize first, and extra width should go to
    // the file column, so that one gets the lowest.
    railItem = NSSplitViewItem(sidebarWithViewController: rail)
    // Full height — the Mail arrangement: the rail runs to the window's top edge, the traffic
    // lights and the sidebar toggle sit over it, and the toolbar proper begins at its divider.
    // The rail is the window's top-level navigation, which is the case that arrangement exists
    // for; a full-width bar over it read as tools acting on the whole window, which nothing on
    // this bar is.
    railItem.allowsFullHeightLayout = true
    // Wide enough to keep the toolbar's session filter: the traffic lights and the sidebar
    // toggle spend the section's first ~160pt, and an item that no longer fits is not shrunk but
    // moved to the overflow menu — the field vanishes and a ≫ appears at the far end of the bar.
    // Measured: the filter survives from 280pt down to 272, and drops below that.
    railItem.minimumThickness = 280
    // The rail carries session titles, which run long — cap it high enough to read one at a
    // glance without truncation, not just to hold the dot and a few characters.
    railItem.maximumThickness = 480
    railItem.canCollapse = true
    railItem.holdingPriority = .init(262)

    runningItem = NSSplitViewItem(viewController: running)
    runningItem.minimumThickness = 320
    // Collapsible only so a maximized desk can fold it away (⌃⌘M, or a double-click on a tab).
    // The side effect is that the divider can now be dragged shut by hand as well, which is the
    // same act by another route — and ⌃⌘M is the way back from either.
    runningItem.canCollapse = true
    runningItem.holdingPriority = .init(261)

    deskItem = NSSplitViewItem(viewController: files.desk)
    // The desk alone now — the panel used to be inside it, and its 420 covered the pair.
    deskItem.minimumThickness = 320
    // Collapsible for the same reason the transcript beside it is: a maximized session has to
    // fold it away. Nothing else collapses it, and there is no toggle for it — the way back is
    // the same ⌃⌘M either column's maximize is undone with.
    deskItem.canCollapse = true
    deskItem.holdingPriority = .init(260)

    columnsController.addSplitViewItem(runningItem)
    columnsController.addSplitViewItem(deskItem)

    let columnsItem = NSSplitViewItem(
      viewController: ToolbarInsetViewController(content: columnsController))
    // What the two columns inside it need between them, so the outer split will not squeeze the
    // pair below what the inner one can honour.
    columnsItem.minimumThickness = 640
    columnsItem.holdingPriority = .init(261)

    // The panel is a column of the window, not of the desk: a sidebar item on the trailing edge,
    // full height, carrying its own filter and ± the way the rail carries its own search. Being
    // a sidebar item is also what keeps the desk/panel boundary clean — that divider is
    // zero-width, so nothing of it leaks up through the toolbar's glass (measured; a plain item's
    // divider view is as tall as the window).
    filesPanelItem = NSSplitViewItem(sidebarWithViewController: files.panel)
    filesPanelItem.allowsFullHeightLayout = true
    // Wide enough to hold its own row of the toolbar — the filter, the ± and the toggle — with
    // room to spare. Narrower and the filter runs out past the panel's leading edge into the
    // content section, which reads as a field belonging to nothing. Measured: the row clears at
    // 242pt with the field at 130, so this leaves ~18pt for a wider font to grow into.
    filesPanelItem.minimumThickness = 260
    filesPanelItem.canCollapse = true
    filesPanelItem.holdingPriority = .init(270)

    splitController.addSplitViewItem(railItem)
    splitController.addSplitViewItem(columnsItem)
    splitController.addSplitViewItem(filesPanelItem)
    window.contentViewController = splitController

    // The toolbar attaches only after the split view is in the window: the files separator
    // below tracks the desk/panel divider, and a tracking item built before its split view has
    // a window asserts.

    let toolbar = NSToolbar(identifier: "dev.tnayuki.hukan.toolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    // A separate title row wastes a whole row. Collapse it into the toolbar; the status capsule
    // carrying "which worktree am I looking at" opens the content section, over the session it
    // titles. .unified, not .unifiedCompact: the compact bar silently opts the sidebar out of
    // full-height layout (measured — the rail dropped a titlebar's height the moment the style
    // switched), so the taller bar is part of the Mail arrangement's price.
    window.toolbarStyle = .unified
    window.titleVisibility = .hidden
    window.titlebarSeparatorStyle = .line
    window.toolbar = toolbar

    rail.workspace = workspace
    running.workspace = workspace
    files.workspace = workspace
    running.onForkSession = { [weak self] source, anchor, range in
      self?.forkSession(source, at: anchor, keeping: range.location)
    }
    running.onRollBackSession = { [weak self] session, anchor, range in
      self?.rollBackSession(session, to: anchor, keeping: range.location)
    }
    workspace.onSessionsChanged = { [weak self] in self?.reload() }
    rail.onSelectWorktree = { [weak self] worktreeID in
      guard let self else { return }
      self.workspace.selectedWorktreeID = worktreeID
      self.workspace.selectedSessionID = nil
      self.resumeSelectedSessionIfNeeded()
      self.reload()
    }
    rail.onCloseRepository = { [weak self] repositoryID in
      guard let self else { return }
      self.workspace.closeRepository(repositoryID)
      self.reload()
    }
    // The workspace has already been rearranged by the drop; reload redraws the rail and records
    // the new order, which rides the worktree paths it was already saving.
    rail.onReorderRepositories = { [weak self] in self?.reload() }
    rail.onNewSession = { [weak self] repositoryID in
      self?.newSession(inRepository: repositoryID)
    }
    rail.onNewSessionInWorktree = { [weak self] worktreeID in
      guard let self, let worktree = self.workspace.worktree(id: worktreeID) else { return }
      self.createSession(in: worktree)
    }
    rail.onStartSession = { [weak self] session in self?.startSessionFromRail(session) }
    // The rail has already confirmed — deleting unlinks the transcript, so there is no undo.
    rail.onDeleteSession = { [weak self] session in
      guard let self else { return }
      self.workspace.deleteSession(session)
      self.reload()
    }
    // Refining the query while a session is already open does not reload the window, so bridge
    // the new terms straight to the transcript and re-mark where it matches.
    rail.onSearchChanged = { [weak self] in
      guard let self else { return }
      self.running.highlightTerms = self.rail.searchTerms
      self.running.refreshHighlight()
    }
    rail.onSelectSession = { [weak self] session in
      guard let self else { return }
      self.workspace.selectedWorktreeID = session.worktreeID
      self.workspace.selectedSessionID = session.id
      self.resumeSelectedSessionIfNeeded()
      self.reload()
    }
    // Return or a double-click on a session row is the master-detail dive: the selection has
    // already moved via onSelectSession, so this only carries focus into the composer. Arrowing
    // through the rail deliberately does not fire it — surveying sessions should not keep yanking
    // focus out of the list.
    rail.onActivateSession = { [weak self] in self?.focusComposer() }
    // A search hit was clicked: open its session, then jump the transcript to that occurrence.
    // The jump is set after reload so it lands on the freshly-attached transcript (and waits for
    // an async history load when the session was detached).
    rail.onSelectMatch = { [weak self] session, offset, length in
      guard let self else { return }
      self.workspace.selectedWorktreeID = session.worktreeID
      self.workspace.selectedSessionID = session.id
      self.resumeSelectedSessionIfNeeded()
      self.reload()
      self.running.jumpToOffset(offset, length: length)
    }
    // Redraw once the git query comes back.
    files.onNeedsReload = { [weak self] in self?.reload() }
    files.onSetMaximized = { [weak self] maximized in
      self?.setMaximized(maximized ? .desk : nil)
    }
    running.onSetMaximized = { [weak self] maximized in
      self?.setMaximized(maximized ? .session : nil)
    }
    // The ± is drawn by the toolbar, so a refresh dropping a scope that went empty has to reach
    // the item that draws it.
    files.panel.onScopeChanged = { [weak self] in self?.updateFilesToolbarItem() }
    // A watched worktree's files moved: refresh in place, no full reload.
    workspace.onWorktreeFilesChanged = { [weak self] id, changed in
      self?.worktreeFilesChanged(id, changed: changed)
    }

    WorkspaceWindowController.all.append(self)
    reload()
    applyDefaultFrameIfCollapsed()

    // Not during launch: restoration runs between willFinishLaunching and
    // didFinishLaunching, so anything queued here fires *before* the saved widths have
    // been decoded — it would lay out the defaults and then record them over the top.
    // The app delegate arranges the restored windows; this covers ones opened later.
    DispatchQueue.main.async { [weak self] in
      guard WorkspaceWindowController.hasFinishedLaunching else { return }
      self?.arrangeColumnsIfNeeded()
    }

    for splitView in [splitController.splitView, columnsController.splitView] {
      observers.append(
        NotificationCenter.default.addObserver(
          forName: NSSplitView.didResizeSubviewsNotification,
          object: splitView, queue: .main
        ) { [weak self] _ in
          self?.recordColumnWidths()
          // The panel also collapses without the toggle — dragged shut, or squeezed out when the
          // column runs short — so the button's state follows the divider, not just the click.
          self?.updateFilesToolbarItem()
          // Both toolbar-hosted filters are sized from the column they sit over, so they are
          // re-fit wherever a divider lands.
          self?.updateRailToolbarItem()
        })
    }

    // The rail's time buckets are derived at reload time, and every reload is event-driven — a
    // file event, a streamed fragment, a selection. Nothing of the sort happens at midnight, so
    // last night's rows would keep claiming "Today" until something unrelated refreshed them.
    // The day-change notification also arrives after a wake that crossed midnight, which covers
    // the window left open overnight.
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .NSCalendarDayChanged, object: nil, queue: .main
      ) { [weak self] _ in
        self?.rail.reload()
      })

    startSystemUsageTimer()
  }

  private var observers: [NSObjectProtocol] = []

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
    systemUsageTimer?.invalidate()
  }

  required init?(coder: NSCoder) { fatalError("interface builder is not used") }

  /// Assigning contentViewController shrinks the window to its content's fitting size
  /// (the sum of the columns' minimum widths). This happens on both the fresh and the
  /// restored path, so only grow when the window sits exactly at that fitting size —
  /// which means there was no saved frame to restore. Never touch a restored frame.
  private func applyDefaultFrameIfCollapsed() {
    // AppKit re-fits the window later in the same run loop, so this has to wait one
    // turn to take effect.
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window,
        let screen = window.screen ?? NSScreen.main,
        let fitting = window.contentView?.fittingSize,
        window.frame.width <= fitting.width + 8
      else { return }
      let size = NSSize(
        width: min(1400, screen.visibleFrame.width - 80),
        height: min(900, screen.visibleFrame.height - 80))
      window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
      // The first fresh window centres and seeds the cascade point; each one after steps
      // off it. cascadeTopLeft *places* the window at the point it is given and *returns*
      // the next point down-right — so the return value is what threads forward. Passing a
      // window's own top-left (the old bug) just drops the newcomer exactly on top of it.
      if let point = WorkspaceWindowController.cascadePoint {
        WorkspaceWindowController.cascadePoint = window.cascadeTopLeft(from: point)
      } else if let previous = WorkspaceWindowController.all.last(where: { $0 !== self })?.window {
        // Windows are already up (restored, say) but no run has been seeded yet — start
        // the staircase from the most recent one. `from: .zero` is a no-op move that still
        // returns that window's offset next point, so it seeds without shoving it.
        let seed = previous.cascadeTopLeft(from: .zero)
        WorkspaceWindowController.cascadePoint = window.cascadeTopLeft(from: seed)
      } else {
        window.center()
        WorkspaceWindowController.cascadePoint = window.cascadeTopLeft(from: .zero)
      }
    }
  }

  /// Put the columns back where they were left, or lay them out for the first time.
  ///
  /// Recording is suppressed until this has run: the split views resize several times while
  /// the window is being built, and each of those would otherwise overwrite the widths being
  /// restored with whatever the half-built layout happened to be.
  func arrangeColumnsIfNeeded() {
    guard !hasArrangedColumns else { return }
    let splitView = splitController.splitView
    guard splitView.bounds.width > 0 else { return }
    hasArrangedColumns = true
    // Record whatever this leaves behind, so the very first arrangement is saved too —
    // otherwise nothing is written until something happens to resize a column.
    defer {
      isArrangingColumns = false
      recordColumnWidths()
    }

    // Two dividers, one per split now that the columns are nested: the rail's is the outer
    // split's, the transcript/desk one the inner split's — and the inner one is measured from
    // the columns' own leading edge, not the window's, so the rail's width is not added in.
    let widths = workspace.columnWidths
    if widths.count == 3, widths[0] > 0, widths[1] > 0 {
      splitView.setPosition(widths[0], ofDividerAt: 0)
      if widths[2] > 0 {
        splitView.setPosition(splitView.bounds.width - widths[2], ofDividerAt: 1)
      }
      columnsController.splitView.setPosition(widths[1], ofDividerAt: 0)
      return
    }

    // Give the desk — the review surface — the most width, but start the rail wide enough to
    // read a session title, not just its first few characters, and the panel wide enough that a
    // path reads without truncating at the first directory.
    let rail: CGFloat = 300
    // Both defaults give way before the desk and the transcript are squeezed below what they
    // need: ask for all three on a narrow screen and the split view honours the minimums by
    // taking it out of the rail, which lands it on 200 with its filter dropped from the toolbar.
    let available = splitView.bounds.width
    let panel = max(180, min(280, available - rail - Self.columnsMinimumWidth))
    let running = max(420, (available - rail - panel) * 0.42)
    splitView.setPosition(rail, ofDividerAt: 0)
    splitView.setPosition(available - panel, ofDividerAt: 1)
    columnsController.splitView.setPosition(running, ofDividerAt: 0)
  }

  /// The transcript and the desk together, as their own items ask for them.
  private static let columnsMinimumWidth: CGFloat = 640

  private var isArrangingColumns = true
  private var hasArrangedColumns = false

  /// Set once AppKit has finished restoring, so a window built during launch does not
  /// arrange itself before its saved widths arrive.
  static var hasFinishedLaunching = false

  private func recordColumnWidths() {
    guard !isArrangingColumns else { return }
    // Nothing measured while one column has the window is saved: those widths belong to a mode
    // that is not saved either, and the arrangement to go back to is the one it was entered
    // from. The zero guard below does not cover it — a maximized desk folds both of the columns
    // this reads, so they measure nothing and it catches them, but a maximized session leaves
    // the transcript standing at the full width of the window.
    guard maximized == nil else { return }
    // The wrapper each split view puts around an item's view, not the item's view itself: a
    // sidebar item insets its content, so recording the inner width and feeding it back to
    // setPosition loses that inset on every launch — the rail shrank 8pt each time. Reached
    // through the view rather than by indexing `splitView.subviews`, which holds the wrappers
    // and the divider views in no particular order.
    guard let railWidth = rail.view.superview?.frame.width,
      let runningWidth = running.view.superview?.frame.width,
      let panelWidth = files.panel.view.superview?.frame.width,
      railWidth > 0, runningWidth > 0
    else { return }
    // A collapsed panel measures zero, which would overwrite the width it will reopen at, so it
    // keeps whatever was last recorded.
    let panel =
      filesPanelItem.isCollapsed
      ? (workspace.columnWidths.count == 3 ? workspace.columnWidths[2] : 0) : Double(panelWidth)
    let widths = [Double(railWidth), Double(runningWidth), panel]
    guard widths.allSatisfy({ $0 > 0 }), widths != workspace.columnWidths else { return }
    workspace.columnWidths = widths
    window?.invalidateRestorableState()
  }

  // MARK: - Toolbar

  // Interrupt and New Session used to sit here; they moved to where the hands already are —
  // stop into the composer, new-session into the rail — leaving the bar to carry only the
  // worktree name and diffstat, plus the two panel toggles. The sidebar toggle is built by
  // AppKit itself — the delegate is never asked for it — and acts through the responder chain,
  // landing on the split view controller like View ▸ Hide Sidebar does.
  //
  // Two tracking separators cut the bar into sections that follow the dividers below, so each
  // collapsible edge's toggle sits over the panel it collapses: the sidebar toggle rides the
  // full-height rail's section beside the traffic lights, and the files toggle heads the
  // section over the files panel. The worktree name opens the content section — a title
  // belongs over the thing it names, not over the rail. This reverses an earlier no-separator
  // decision: in a full-width bar the separator only made collapsing drag the toggle across a
  // bar that was meant to be left-aligned, but with the rail full height the sections are the
  // arrangement, and a toggle sliding home when its panel closes is the system's own motion.
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    // Usage rides the content section's trailing edge (after a flexible space): an account-wide
    // figure, not tied to the worktree the status names, so it sits at the content's far end —
    // the app's own CPU/memory footprint after it, the plan's consumption first, the machine
    // cost second. The files section is the panel's one row of chrome: its filter spanning the
    // panel, then the ± scope and the toggle keeping the window's corner — three separate items,
    // so each draws in its own capsule instead of the neighbours reading as though they were
    // inside the field's bezel.
    // Each section carries its own column's chrome: the rail's session filter beside the sidebar
    // toggle, the worktree's name and the machine's load over the session it names, the panel's
    // filter and scope over the panel. The rail's toggle sits at its section's trailing edge —
    // against the divider it moves, mirroring the files toggle at the window's far corner — and
    // it takes a flexible space to keep it there: the section is packed from the leading edge,
    // and its leading edge is not fixed. The traffic lights spend the first ~70pt of it in a
    // window and none of it in full screen, where they are gone, so without the space the row
    // slid left by that much and the toggle stood in the middle of the rail.
    [
      .sessionFilter, .flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, .status,
      .flexibleSpace, .usage, .systemUsage, .filesSeparator, .filesFilter, .flexibleSpace,
      .filesScope, .toggleFiles,
    ]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch identifier {
    case .status:
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.view = statusView
      // The toolbar builds its items on its own schedule (lazily, before the window is
      // visible), so the item may be born after visibility was last decided — apply the
      // current answer rather than assuming the default.
      item.isHidden = !isStatusToolbarItemVisible
      statusToolbarItem = item
      return item
    case .systemUsage:
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.view = systemUsageLabel
      return item
    case .sessionFilter:
      // A plain view item, unlike the files filter's `NSSearchToolbarItem`: a search item placed
      // in the sidebar section renders as its collapsed magnifier button no matter how much room
      // it is given (measured — the field stayed 31pt wide at every preferred width). Hosting the
      // field directly keeps it a field. The capsule that swallowed the files panel's controls is
      // not a risk here: nothing else shares this item.
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.label = "Filter Sessions"
      // The width constraint is made once and kept (`sessionFilterWidth`): the toolbar asks for
      // its items more than once over a window's life, and a second constraint on the same field
      // fights the first — the field froze at whatever width was current when it was built.
      _ = sessionFilterWidth
      item.view = rail.filterSearchField
      sessionFilterToolbarItem = item
      updateRailToolbarItem()
      return item
    case .filesFilter:
      // The field hosted directly, as the rail's is: `NSSearchToolbarItem` renders as its
      // collapsed magnifier button here whatever width it is offered. Its own item, never packed
      // with the ± — two controls in one item and the toolbar draws them inside one capsule, so
      // the ± and the toggle read as though they were inside the field's bezel.
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.label = "Filter Files"
      _ = filesFilterWidth
      item.view = files.panel.filterSearchField
      filesFilterToolbarItem = item
      updateFilesToolbarItem()
      return item
    case .filesScope:
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.label = "Changed Files Only"
      // Left to the toolbar's own sizing, like the toggle it sits beside — the glyph carried a
      // 10pt symbol configuration when it lived in the panel, which read visibly smaller than
      // its neighbours up here. Unbordered, like the sidebar toggle across the window: the bar
      // carries glyphs, not a row of capsules, so the ± says it is on by taking the accent
      // colour (`scopeImage`) rather than by filling a pill.
      item.image = Self.scopeImage(on: false)
      item.isBordered = false
      item.target = self
      item.action = #selector(toggleFilesScope(_:))
      filesScopeToolbarItem = item
      updateFilesToolbarItem()
      return item
    case .filesSeparator:
      // Divider 1 of the window's own split: the desk/panel boundary, now that the panel is a
      // column of the window rather than of the desk.
      return NSTrackingSeparatorToolbarItem(
        identifier: identifier, splitView: splitController.splitView, dividerIndex: 1)
    case .toggleFiles:
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.label = "Files"
      item.image = Self.barGlyph("sidebar.trailing", description: "Files", accented: false)
      item.isBordered = false
      item.target = self
      item.action = #selector(toggleFilesPanel(_:))
      filesToolbarItem = item
      updateFilesToolbarItem()
      return item
    case .usage:
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.view = usageLabel
      // Born hidden and revealed only once `ClaudeUsage` returns a reading (see `refreshUsage`),
      // so an API-key/signed-out user — where `/usage` prints no plan limits — shows nothing.
      item.isHidden = usageLabel.stringValue.isEmpty
      usageToolbarItem = item
      return item
    default:
      return nil
    }
  }

  private weak var sessionFilterToolbarItem: NSToolbarItem?
  /// A constant, not sized from the rail it filters. Sizing a toolbar field from the column
  /// under it is a loop: the wider field widens the section, the section's tracking separator
  /// moves the divider it tracks, the column narrows, and the next pass asks for less again
  /// (measured on the files side before its filter moved into the panel: 279 → 258 → 180pt).
  /// It also has to finish inside the rail — the traffic lights and the toggle spend the
  /// section's first ~160pt, and an item asking for more than its section holds is dropped
  /// outright rather than shrunk, which is how this one vanished the first time it was tried.
  private lazy var sessionFilterWidth: NSLayoutConstraint = {
    let constraint = rail.filterSearchField.widthAnchor.constraint(equalToConstant: 130)
    constraint.isActive = true
    return constraint
  }()

  /// The rail's filter belongs to the rail, so it goes with it — hidden while the rail is
  /// collapsed.
  func updateRailToolbarItem() {
    guard let sessionFilterToolbarItem else { return }
    _ = sessionFilterWidth
    sessionFilterToolbarItem.isHidden = splitController.splitViewItems.first?.isCollapsed == true
  }

  private weak var filesToolbarItem: NSToolbarItem?
  private weak var filesFilterToolbarItem: NSToolbarItem?
  private weak var filesScopeToolbarItem: NSToolbarItem?
  /// A constant, for the reason the rail's filter is one — see `sessionFilterWidth`. Sized to
  /// leave the ± and the toggle their room inside the panel's own section.
  private lazy var filesFilterWidth: NSLayoutConstraint = {
    let constraint = files.panel.filterSearchField.widthAnchor.constraint(equalToConstant: 130)
    constraint.isActive = true
    return constraint
  }()

  /// The toggle reads as pressed while the panel is open, the way a trailing-inspector button
  /// does, so the bar says which state the window is in rather than only what the click will do.
  /// The filter and the ± beside it belong to the panel, so they go with it when it collapses.
  func updateFilesToolbarItem() {
    // Not simply `isCollapsed`: that flips the moment the toggle is clicked — and so does the
    // column's frame, with only the presentation animated — so the field and the ± appeared over
    // an empty strip and waited for the column to slide in under them. While a reveal is in
    // flight the row stays away and `setFilesPanelCollapsed` brings it back at the end. Closing
    // needs no such care: the row leaves as the column starts going.
    let shown = isFilesPanelVisible && !isRevealingFilesPanel
    filesFilterToolbarItem?.isHidden = !shown
    if let filesScopeToolbarItem {
      filesScopeToolbarItem.isHidden = !shown
      filesScopeToolbarItem.isEnabled = files.panel.canScopeToChanged
      filesScopeToolbarItem.toolTip = files.panel.scopeToolTip
      // The image, not the button's state: an image item's view is AppKit's own and is not
      // handed back through `view`, so the scope says it is on by wearing the accent colour.
      filesScopeToolbarItem.image = Self.scopeImage(on: files.panel.isChangedOnlyScope)
    }
    guard let filesToolbarItem else { return }
    filesToolbarItem.toolTip = shown ? "Hide Files" : "Show Files"
  }

  /// A glyph for the panel's row, sized to sit beside the sidebar toggle AppKit draws at the
  /// other end of the bar. Left unconfigured a symbol comes out a size larger than that one, and
  /// a bar whose two ends disagree about how big a glyph is reads as an accident.
  private static func barGlyph(_ name: String, description: String, accented: Bool) -> NSImage? {
    var configuration = NSImage.SymbolConfiguration(scale: .small)
    if accented {
      configuration = configuration.applying(
        NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor]))
    }
    return NSImage(systemSymbolName: name, accessibilityDescription: description)?
      .withSymbolConfiguration(configuration)
  }

  /// The ± glyph, accented while the scope is on. Plain otherwise, so it reads as one of the
  /// bar's glyphs rather than a pressed control.
  private static func scopeImage(on: Bool) -> NSImage? {
    barGlyph("plus.forwardslash.minus", description: "Changed files only", accented: on)
  }

  private weak var statusToolbarItem: NSToolbarItem?
  private var isStatusToolbarItemVisible = true
  private weak var usageToolbarItem: NSToolbarItem?

  /// Account-wide Claude plan usage (`session NN% · week NN%`) at the toolbar's trailing edge.
  /// This is the whole account's consumption of its rolling session window and weekly limits —
  /// not any one session's — so it sits apart from the per-session conversation cost in the
  /// running column's header. The full breakdown (reset times, per-model bars) is the tooltip.
  private lazy var usageLabel: NSTextField = {
    let field = NSTextField(labelWithString: "")
    field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    field.textColor = .secondaryLabelColor
    field.lineBreakMode = .byTruncatingTail
    return field
  }()

  /// One reading at a time, and not more often than this. `reload()` is driven by every session
  /// state change, so a single turn calls `refreshUsage` dozens of times — while the figures only
  /// move when the API answers. The interval collapses that burst; it is no longer paying for a
  /// process, which is what the old `/usage` probe's 45 seconds were for.
  private var usageInFlight = false
  private var lastUsageRead: Date?
  private static let usageInterval: TimeInterval = 5

  /// Pull the latest account usage and show it at the toolbar's trailing edge. Safe to call on
  /// every reload and on window focus.
  ///
  /// The figures are account-wide, so whichever session is running answers for all of them; with
  /// none running there is nobody to ask and the last reading stands. It is never cleared on a
  /// failed read either — a window whose only session just exited has not stopped having a plan.
  /// The item starts hidden and is revealed by the first reading, so an account with no plan
  /// limits at all (an API key, Bedrock, Vertex) simply never shows one.
  func refreshUsage(force: Bool = false) {
    guard !usageInFlight else { return }
    if !force, let last = lastUsageRead, Date().timeIntervalSince(last) < Self.usageInterval {
      return
    }
    guard let session = workspace.sessions.first(where: { $0.isRunning }) else { return }
    usageInFlight = true
    lastUsageRead = Date()
    session.requestUsage { [weak self] snapshot in
      guard let self else { return }
      self.usageInFlight = false
      guard let snapshot else { return }
      self.applyUsage(snapshot)
    }
  }

  private func applyUsage(_ snapshot: ClaudeUsage.Snapshot) {
    // Headline: the session window, the "all models" week, then any per-model weekly bars. The
    // first two are SF Symbols (hourglass = the rolling session window, calendar = the week)
    // rather than spelled-out "session"/"week" words; a per-model bar keeps its model name (that
    // name is real information, not a generic label), e.g. "Fable 22%". Words live in the tooltip.
    let line = NSMutableAttributedString()
    func spacer() {
      if line.length > 0 { line.append(NSAttributedString(string: "   ")) }
    }
    func percent(_ value: Int, leadingSpace: Bool) -> NSAttributedString {
      NSAttributedString(
        string: "\(leadingSpace ? " " : "")\(value)%",
        attributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
          .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }
    func iconSegment(symbol: String, percent value: Int) {
      spacer()
      if let icon = Self.usageIcon(symbol) {
        let attachment = NSTextAttachment()
        attachment.image = icon
        // Nudge the glyph down so it centres against the digits rather than riding the baseline.
        let font = usageLabel.font ?? .systemFont(ofSize: 11)
        attachment.bounds = CGRect(
          x: 0, y: (font.capHeight - icon.size.height) / 2,
          width: icon.size.width, height: icon.size.height)
        line.append(NSAttributedString(attachment: attachment))
      }
      line.append(percent(value, leadingSpace: true))
    }
    func labelSegment(label: String, percent value: Int) {
      spacer()
      line.append(
        NSAttributedString(
          string: label,
          attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
          ]))
      line.append(percent(value, leadingSpace: true))
    }
    if let session = snapshot.session { iconSegment(symbol: "hourglass", percent: session.percent) }
    for (index, bar) in snapshot.weekly.enumerated() {
      if index == 0 {
        iconSegment(symbol: "calendar", percent: bar.percent)
      } else {
        labelSegment(label: bar.label, percent: bar.percent)
      }
    }
    usageLabel.attributedStringValue = line

    // Tooltip spells out what the icons mean, with reset times and any per-model bars.
    var lines: [String] = []
    if let session = snapshot.session {
      lines.append("Session: \(session.percent)%\(Self.resetSuffix(session.resetsAt))")
    }
    for bar in snapshot.weekly {
      lines.append("Week (\(bar.label)): \(bar.percent)%\(Self.resetSuffix(bar.resetsAt))")
    }
    usageLabel.toolTip = lines.joined(separator: "\n")
    usageToolbarItem?.isHidden = line.length == 0
  }

  /// " · resets Aug 28 at 9:29 AM", in the reader's own locale and time zone — or nothing at all
  /// for a window the engine tracks without a reset time. The engine sends a UTC instant, so the
  /// wording is hukan's; the old `/usage` text had already been through the CLI's formatter.
  private static func resetSuffix(_ date: Date?) -> String {
    guard let date else { return "" }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return " · resets \(formatter.string(from: date))"
  }

  /// A toolbar-sized, secondary-tinted SF Symbol for the usage cluster.
  private static func usageIcon(_ name: String) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
      .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(configuration)
  }

  /// Hukan's footprint (`cpu NN% · memorychip N.N GB`) — the app and its subprocess tree — at the
  /// toolbar's far end, after the plan usage. Unlike plan usage this is always shown (every process
  /// has a memory figure) and it is driven by a local timer (`systemUsageTimer`) rather than the
  /// `/usage` probe's slow, throttled cadence.
  private lazy var systemUsageLabel: NSTextField = {
    let field = NSTextField(labelWithString: "")
    field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    field.textColor = .secondaryLabelColor
    field.lineBreakMode = .byTruncatingTail
    field.alignment = .left
    // A fixed width, so the plan-usage item to its left holds still instead of being shoved
    // sideways every tick as this reading gains or loses a digit (a 3-digit percent, MB↔GB).
    // It is the toolbar's last item, so its right edge is pinned anyway; fixing the width pins the
    // left edge too. Wide enough for the worst realistic reading; content is leading-aligned, so a
    // short one simply leaves the slack at the trailing edge.
    field.translatesAutoresizingMaskIntoConstraints = false
    field.widthAnchor.constraint(equalToConstant: 140).isActive = true
    return field
  }()

  private var systemUsageSampler = SystemUsageSampler()
  private var systemUsageTimer: Timer?
  /// A footprint gauge wants to feel live without churning: often enough to catch a busy agent,
  /// calm enough not to flicker. CPU is a delta over this interval, so it also sets the smoothing.
  private static let systemUsageInterval: TimeInterval = 3

  /// Start (or restart) the footprint timer and take an immediate reading so the toolbar is not
  /// blank until the first tick. Sampling is light enough to stay on the main thread.
  private func startSystemUsageTimer() {
    systemUsageTimer?.invalidate()
    refreshSystemUsage()
    let timer = Timer(timeInterval: Self.systemUsageInterval, repeats: true) { [weak self] _ in
      self?.refreshSystemUsage()
    }
    // Common modes so the reading keeps ticking through a live resize or a menu tracking loop,
    // rather than freezing whenever the run loop leaves the default mode.
    RunLoop.main.add(timer, forMode: .common)
    systemUsageTimer = timer
  }

  private func refreshSystemUsage() {
    applySystemUsage(
      systemUsageSampler.sample(engines: Set(workspace.sessions.compactMap(\.enginePID))))
  }

  private func applySystemUsage(_ snapshot: SystemUsageSampler.Snapshot) {
    let line = NSMutableAttributedString()
    func text(_ string: String) -> NSAttributedString {
      NSAttributedString(
        string: string,
        attributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
          .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }
    func segment(symbol: String, value: String) {
      if line.length > 0 { line.append(NSAttributedString(string: "   ")) }
      if let icon = Self.usageIcon(symbol) {
        let attachment = NSTextAttachment()
        attachment.image = icon
        let font = systemUsageLabel.font ?? .systemFont(ofSize: 11)
        attachment.bounds = CGRect(
          x: 0, y: (font.capHeight - icon.size.height) / 2,
          width: icon.size.width, height: icon.size.height)
        line.append(NSAttributedString(attachment: attachment))
      }
      line.append(text(" \(value)"))
    }
    // Figure spaces (U+2007 — a digit's width in this monospaced-digit font) left-pad the percent
    // to a three-digit field, so the memory segment after it does not shuffle sideways as the
    // number crosses 10% or 100%.
    let cpuNumber = Int(snapshot.cpuPercent.rounded())
    let cpu =
      String(repeating: "\u{2007}", count: max(0, 3 - String(cpuNumber).count)) + "\(cpuNumber)%"
    let memory = Self.memoryFormatter.string(fromByteCount: Int64(snapshot.memoryBytes))
    segment(symbol: "cpu", value: cpu)
    segment(symbol: "memorychip", value: memory)
    systemUsageLabel.attributedStringValue = line
    // The label carries the whole-tree total, so the tooltip is the split behind it: our own pid
    // (Hukan), the engines, what the engines spawned, and the terminals — the last only while
    // there is one, since a line saying none is noise on a desk with no terminal. Each share but
    // Hukan's says how many processes it is. No total line — it is already on screen above.
    func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
    func bytes(_ value: UInt64) -> String {
      Self.memoryFormatter.string(fromByteCount: Int64(value))
    }
    func share(_ name: String, _ bucket: SystemUsageSampler.Bucket, counted: Bool = true) -> String
    {
      let title = counted ? "\(name) (\(bucket.processes))" : name
      return "\(title) — CPU \(percent(bucket.cpuPercent)), Mem \(bytes(bucket.memoryBytes))"
    }
    var lines = [
      share("Hukan", snapshot[.hukan], counted: false),
      share("Claude Code", snapshot[.engine]),
      share("Spawned by Claude Code", snapshot[.spawned]),
    ]
    if snapshot[.terminal].processes > 0 { lines.append(share("Terminals", snapshot[.terminal])) }
    systemUsageLabel.toolTip = lines.joined(separator: "\n")
  }

  private static let memoryFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .memory
    formatter.allowedUnits = [.useMB, .useGB]
    return formatter
  }()

  private lazy var worktreeLabel: NSTextField = {
    let field = NSTextField(labelWithString: "")
    field.font = .systemFont(ofSize: 13, weight: .semibold)
    field.lineBreakMode = .byTruncatingMiddle
    return field
  }()

  /// Match the diff view's colors. Monochrome digits are far harder to read at a glance.
  private lazy var diffLabel: NSTextField = {
    let field = NSTextField(labelWithString: "")
    field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    return field
  }()

  private lazy var statusView: NSStackView = {
    // State (thinking / needs you / done) lives in the rail dot and the composer's stop
    // cluster ("Thinking" beside the stop glyph), so it is not duplicated up here — this bar
    // carries the worktree name and diffstat.
    let stack = NSStackView(views: [worktreeLabel, diffLabel])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 8
    // A right inset too: without it the diffstat sits flush against the trailing edge and,
    // inside Tahoe's toolbar-item capsule, its last digits are clipped by the rounded end.
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
    stack.setCustomSpacing(12, after: worktreeLabel)
    return stack
  }()

  private func setDiffStat(added: Int?, removed: Int?) {
    guard let added, let removed, added + removed > 0 else {
      diffLabel.stringValue = ""
      return
    }
    let text = NSMutableAttributedString()
    text.append(
      NSAttributedString(string: "+\(added)", attributes: [.foregroundColor: NSColor.systemGreen]))
    text.append(
      NSAttributedString(string: "  −\(removed)", attributes: [.foregroundColor: NSColor.systemRed])
    )
    text.addAttribute(
      .font, value: diffLabel.font as Any, range: NSRange(location: 0, length: text.length))
    diffLabel.attributedStringValue = text
  }

  // MARK: - Restoration

  static func restoreWindow(
    withIdentifier identifier: NSUserInterfaceItemIdentifier,
    state: NSCoder,
    completionHandler: @escaping (NSWindow?, Error?) -> Void
  ) {
    // Return a window carrying an empty Workspace here; the contents are filled in by
    // window(_:didDecodeRestorableState:).
    let controller = WorkspaceWindowController(workspace: Workspace())
    completionHandler(controller.window, nil)
  }

  func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
    workspace.encodeState(to: state)
  }

  func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
    workspace.decodeState(from: state)
    reload()
    // The column widths only exist now. Arranging from init instead would run before this
    // and lay out the defaults — and then record them, destroying what was saved.
    DispatchQueue.main.async { [weak self] in
      self?.arrangeColumnsIfNeeded()
      // Reattach the restored session's engine explicitly. It used to ride on the rail's
      // selection restore firing onSelectSession, but that path is deliberately suppressed
      // as programmatic (and fires a runloop late besides), so whether it reached `--resume`
      // was a race — the "process didn't start after restore, sometimes" symptom. Restore is
      // a selection; resume it like one.
      self?.resumeSelectedSessionIfNeeded()
    }
  }

  func windowWillClose(_ notification: Notification) {
    WorkspaceWindowController.all.removeAll { $0 === self }
    // Nothing left to march off — start the next window centred, not partway down a staircase.
    if WorkspaceWindowController.all.isEmpty { WorkspaceWindowController.cascadePoint = nil }
  }

  /// Coming back to the window is the moment to notice git moves made elsewhere — a branch
  /// switched or a commit made in a terminal while the app sat in the background. Only redraw
  /// if something actually changed, so an ordinary focus-in costs one cheap query and no reload.
  func windowDidBecomeKey(_ notification: Notification) {
    reconnectAfterLogin()
    // Coming back is the cue to re-read account usage too (throttled inside ClaudeUsage), so the
    // toolbar figure reflects usage spent elsewhere — other machines, claude.ai — while away.
    refreshUsage()
    workspace.refreshGitState { [weak self] changed in
      if changed { self?.reload() }
    }
  }

  /// A worktree's files moved while the app watched it — from an agent editing in it, a
  /// terminal command, an external editor. Every worktree is watched so a parallel agent's
  /// work keeps that worktree's rail badge live even off-screen (the whole point of the
  /// bird's-eye view). The rail always refreshes; the file column and the top-bar diffstat
  /// only when it is the worktree on screen, and then in place so an active edit does not yank
  /// the selection or scroll.
  private func worktreeFilesChanged(_ worktreeID: UUID, changed: Set<String>?) {
    rail.reload()
    guard worktreeID == workspace.selectedWorktreeID,
      let worktree = workspace.worktree(id: worktreeID)
    else { return }
    let stat = worktree.diffstat
    setDiffStat(added: stat.added, removed: stat.removed)
    files.refreshInPlace(changed: changed)
  }

  /// Coming back after a `/login` terminal is the cue to restart that session, so a fresh
  /// `claude` initializes with the new credentials. One-shot: only fires when a login was
  /// actually launched, and only restarts a session that is idle (not one already re-running).
  private func reconnectAfterLogin() {
    guard let id = reconnectAfterLoginSessionID else { return }
    reconnectAfterLoginSessionID = nil
    guard let session = workspace.sessions.first(where: { $0.id == id }),
      let worktree = workspace.worktree(id: session.worktreeID)
    else { return }
    session.stop()
    // stop() is graceful now (stdin EOF, escalating up to ~3s), so the engine goes down on
    // its own clock. Start the replacement only once it is actually gone: `start` no-ops
    // while `runner` is still set, and two engines on one session id would write one
    // transcript. Poll rather than guess a delay; give up past the escalation window.
    var attempts = 40
    func startWhenGone() {
      guard self.workspace.sessions.contains(where: { $0.id == id }) else { return }
      if session.isRunning, attempts > 0 {
        attempts -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { startWhenGone() }
        return
      }
      self.attach(session)
      session.start(at: worktree.url)
      self.reload()
    }
    startWhenGone()
  }

  // MARK: - Refresh

  func reload() {
    rail.reload()
    // Opening a session under an active filter should land on the first match — hand the running
    // column the terms before it attaches so its own highlight pass has them.
    running.highlightTerms = rail.searchTerms
    running.reload()
    files.reload()
    // Account usage is global, not tied to the session tree; refresh here (throttled inside
    // ClaudeUsage) so a turn ending — which lands as a reload — keeps the toolbar figure current.
    refreshUsage()

    if let worktreeID = workspace.selectedWorktreeID,
      let worktree = workspace.worktree(id: worktreeID)
    {
      window?.title = "\(worktree.repositoryName)/\(worktree.displayName)"
      worktreeLabel.stringValue = "\(worktree.repositoryName)/\(worktree.displayName)"
      let stat = worktree.diffstat
      setDiffStat(added: stat.added, removed: stat.removed)
      setStatusToolbarItemVisible(true)
    } else {
      window?.title = "Hukan"
      setDiffStat(added: nil, removed: nil)
      setStatusToolbarItemVisible(false)
    }

    // The transcript's counterpart to the desk's last tab closing (`WorktreeDesk.closeTabs`):
    // the session deleted, or its worktree gone with the repository, leaves the column with
    // nothing it was given the window for.
    if isSessionMaximized, workspace.selectedSession == nil { setMaximized(nil) }

    invalidateRestorableState()
  }

  /// The status cluster's toolbar capsule suits a live worktree name and diffstat, but it is the
  /// wrong dress for a bare app name — with nothing open the capsule frames nothing. So the
  /// empty state hides the item and the bar carries only the sidebar toggle: the rail's own
  /// "No repositories yet" placeholder already says what this window is. (Showing the window
  /// title instead was tried and looked worse — a leading title shoves the sidebar toggle off
  /// the traffic lights into the middle of the bar.) Hidden via `isHidden`, not removed:
  /// removal indexes into `toolbar.items`, which is empty until the toolbar lazily builds —
  /// an early reload() missed and left an empty capsule behind.
  private func setStatusToolbarItemVisible(_ visible: Bool) {
    isStatusToolbarItemVisible = visible
    statusToolbarItem?.isHidden = !visible
  }

  // MARK: - Actions

  @objc func newSession(_ sender: Any?) {
    guard let worktreeID = workspace.selectedWorktreeID,
      let worktree = workspace.worktree(id: worktreeID)
    else {
      openRepository(sender)
      return
    }
    createSession(in: worktree)
  }

  /// The heading's `+`: a new session in that repository. Prefer the selected worktree when it
  /// belongs to the repository (land where the work already is), otherwise its first worktree —
  /// the main checkout, which is added before any feature worktree.
  private func newSession(inRepository repositoryID: String) {
    // The repository heading *is* main, so its `+` means main — never "wherever you happen to be
    // standing". It used to prefer the selected worktree, which was right when the heading
    // carried the only `+` in the group; now every linked worktree has one of its own, and
    // preferring the selection made the two buttons do the same thing whenever a linked
    // worktree's session was selected.
    let worktrees = workspace.worktrees.filter { $0.repositoryID == repositoryID }
    if let target = worktrees.first(where: \.isMain) ?? worktrees.first {
      createSession(in: target)
    }
  }

  @discardableResult
  private func createSession(in worktree: Worktree) -> AgentSession {
    let session = AgentSession(worktreeID: worktree.id)
    // Creating a session is an explicit act, not merely looking at one, so seed its sort key to
    // now — otherwise it sorts as never-instructed (`.distantPast`) and the freshest row sinks
    // to the bottom until its first send.
    session.lastInstructedAt = Date()
    attach(session)
    workspace.sessions.append(session)
    workspace.selectedWorktreeID = worktree.id
    workspace.selectedSessionID = session.id
    // Unlike a merely-restored session, a New Session spawns `claude` now rather than on the first
    // send: this is the one path that eager-starts, so the model picker fills from the engine's own
    // roster before you type — a fresh session has none remembered to seed, it learns its own.
    // `holdIdle` keeps the row idle (no turn exists) instead of the optimistic "thinking" a send-
    // driven start shows. The cost is that an abandoned New Session now holds one message-less
    // process (it exits with the window; a pre-send effort change respawns it clean).
    session.start(at: worktree.url, holdIdle: true)
    reload()
    // So you can start typing the moment you press it.
    window?.makeFirstResponder(running.inputField)
    return session
  }

  /// Branch a conversation: a new session in the same worktree holding everything the source
  /// said up to `anchor`, with the message that followed — and everything after it — left behind.
  ///
  /// A sibling of the source, not a child of it: the model says a Session belongs to a Worktree,
  /// and a branch is another process working in the same worktree, so it takes an ordinary rail
  /// row rather than nesting under the conversation it came from. The source is untouched — it
  /// keeps running, keeps its transcript, and can be returned to by selecting it — which is the
  /// whole point over rewinding in place: the road not taken stays on the rail.
  ///
  /// The composer's choices come along because the engine does not remember them for a session it
  /// has never seen (the charter's one session-side exception); the conversation comes from the
  /// engine itself at launch (`ForkPoint`), and `keeping` is only how much of the source's
  /// already-rendered transcript to show in the meantime.
  @discardableResult
  func forkSession(_ source: AgentSession, at anchor: String, keeping prefixLength: Int)
    -> AgentSession?
  {
    guard let worktree = workspace.worktree(id: source.worktreeID) else { return nil }
    let inherited = source.transcript.attributedSubstring(
      from: NSRange(location: 0, length: min(max(prefixLength, 0), source.transcript.length)))
    let session = AgentSession(worktreeID: worktree.id)
    session.lastInstructedAt = Date()
    session.model = source.model
    session.permissionMode = source.permissionMode
    session.effort = source.effort
    session.forkOrigin = ClaudeSession.ForkPoint(source: source.id, anchor: anchor)
    attach(session)
    workspace.sessions.append(session)
    workspace.selectedWorktreeID = worktree.id
    workspace.selectedSessionID = session.id
    session.seedForkedConversation(inherited, anchor: anchor)
    session.inheritPendingPrefix(from: source)
    // Eager, like the `+` button and for the same reason plus one: the branch's transcript does
    // not exist until the engine writes it, so nothing is on disk to resume until this runs.
    session.start(at: worktree.url, holdIdle: true)
    reload()
    window?.makeFirstResponder(running.inputField)
    return session
  }

  /// Cut a conversation back to before one of its messages, in place.
  ///
  /// The sibling of `forkSession`, for when the attempt being undone is worth nothing: a branch
  /// would leave it on the rail as a row to ignore, and the transcript is the thing being kept
  /// readable. It asks first, because from inside hukan there is no way back — though on disk
  /// there is: the abandoned messages stay in the jsonl, unreachable rather than deleted, so a
  /// rollback destroys nothing that a transcript reader could not still find.
  func rollBackSession(_ session: AgentSession, to anchor: String, keeping prefixLength: Int) {
    let dropped = session.transcript.length - min(max(prefixLength, 0), session.transcript.length)
    guard dropped > 0 else { return }
    // The menu greys this out for a held session; a scripted caller reaches the verb's own
    // refusal. Both funnel here, so say it plainly rather than failing silently.
    guard session.canRollBack else {
      let held = NSAlert()
      held.messageText = "Cannot roll this conversation back"
      held.informativeText =
        "Another live process has this session open (pid \(session.heldByPID.map(Int.init) ?? 0)), "
        + "so hukan cannot reload its engine at an earlier point. Close it there and try again, "
        + "or fork instead — a fork only reads this conversation."
      held.addButton(withTitle: "OK")
      held.runModal()
      return
    }
    let alert = NSAlert()
    alert.messageText = "Roll back this conversation?"
    alert.informativeText =
      "This message and everything after it leave the conversation, and the agent forgets them. "
      + "They stay in the transcript file on disk. Fork instead to keep them as their own session."
    alert.addButton(withTitle: "Roll Back")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    session.rollBack(to: anchor, keeping: prefixLength)
    reload()
    window?.makeFirstResponder(running.inputField)
  }

  /// Scripting seam: create a session in an explicit worktree and hand it back, so the
  /// `new session` command can return the real object rather than reaching for the last-appended
  /// one. Goes through the same path as the `+` button, selection and start included.
  func makeSession(in worktree: Worktree) -> AgentSession {
    createSession(in: worktree)
  }

  /// Wire a merely-restored session to the window the first time it is selected — but do NOT
  /// spawn `claude`. Attaching everything at launch would wire N sessions nobody is looking at;
  /// starting one just for being selected would spawn a process nobody is talking to. Viewing
  /// needs only the transcript (loaded from disk); the process comes up on the first send.
  func resumeSelectedSessionIfNeeded() {
    guard let session = workspace.selectedSession else { return }
    reattachIfNeeded(session)
  }

  /// Wire a specific detached session to the window (callbacks only, no process). Scripting can
  /// `send` to a session that is not the selected one, so this has to be addressable rather than
  /// tied to the selection — and the send it precedes is what actually starts the process.
  func reattachIfNeeded(_ session: AgentSession) {
    guard session.isDetached, !session.isRunning else { return }
    attach(session)
  }

  /// Subscribe to a session's notifications in one place.
  private func attach(_ session: AgentSession) {
    session.onStateChange = { [weak self] in
      guard let self else { return }
      self.reload()
      // A session can move worktrees mid-run, so resolve the name at fire time, not here.
      let name = self.workspace.worktree(id: session.worktreeID)?.displayName
      SessionNotifier.shared.observe(session, worktreeName: name)
      // Hold the machine awake while any agent is mid-turn (dropped when none are).
      SleepGuard.shared.refresh()
    }
    // Held changes must reach the rail even for a session created before any discovery pass wires
    // it (`discoverSessions` wires the rest). Reload is enough — the row's grey rides on `heldByPID`.
    session.onHeldChange = { [weak self] in self?.reload() }
    session.onEnterWorktree = { [weak self] url in self?.moveSession(session, to: url) }
    session.onExitWorktree = { [weak self] url in self?.returnSession(session, to: url) }
    session.onRecencyChange = { [weak self] in self?.scheduleRailReload() }
    session.onLoginRequested = { [weak self] verb in self?.runLogin(verb, for: session) }
    session.onNeedsStart = { [weak self] in self?.startSession(session) }
  }

  /// Spawn `claude` for a session that has none yet — the deferred start, reached from the first
  /// send (`onNeedsStart`). Resolves the worktree and starts; `start` itself refuses if another
  /// process already owns the session, and passes `--resume` for a restored one.
  private func startSession(_ session: AgentSession) {
    guard !session.isRunning, let worktree = workspace.worktree(id: session.worktreeID) else {
      return
    }
    session.start(at: worktree.url)
  }

  /// Start Session from the rail — the one place besides New Session that spawns without a send.
  /// Selects it so the composer and the model roster the eager start fills are usable, wires its
  /// callbacks (`reattachIfNeeded`), then spawns — resuming from the transcript when there is one.
  func startSessionFromRail(_ session: AgentSession) {
    guard !session.isRunning else { return }
    workspace.selectedWorktreeID = session.worktreeID
    workspace.selectedSessionID = session.id
    reattachIfNeeded(session)
    startSession(session)
    reload()
    window?.makeFirstResponder(running.inputField)
  }

  /// Run `claude auth login` / `claude auth logout` in a real terminal. The stream-json session
  /// can't do the OAuth/browser flow (it needs a TTY), so shell out to Terminal.app and reconnect
  /// the session when the window comes back. `verb` is the bare word ("login").
  ///
  /// It is `claude auth <verb>`, not `claude <verb>`: current Claude Code keeps auth under the
  /// `auth` subcommand, and a bare `claude login` treats "login" as a *prompt* — it opens an
  /// ordinary chat instead of signing in, so the sign-in silently never happens.
  private func runLogin(_ verb: String, for session: AgentSession) {
    // Terminal.app runs a login shell that sources the user's profile, so `claude` is on PATH
    // there the same way it is for the agent. The verb is a fixed literal, never user input.
    let script =
      "tell application \"Terminal\"\nactivate\ndo script \"claude auth \(verb)\"\nend tell"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    do {
      try task.run()
      reconnectAfterLoginSessionID = session.id
      session.note("Opening a terminal to \(verb). Come back once it finishes to reconnect.")
    } catch {
      session.note("Could not open a terminal to \(verb): \(error.localizedDescription)")
    }
  }

  /// Recency moves per streamed fragment, so mid-turn the rail's order goes stale — a session
  /// speaking now can sit below one quiet for minutes, and nothing reorders until a state
  /// change. Coalesce the storm into one rail-only reload: cheap enough to run mid-turn, and
  /// the rail's cross-fade makes the rise read as motion.
  private var railReloadPending = false
  private func scheduleRailReload() {
    guard !railReloadPending else { return }
    railReloadPending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      guard let self else { return }
      self.railReloadPending = false
      self.rail.reload()
    }
  }

  /// The agent created a worktree, so make it a Worktree and move the session there.
  /// Being a git worktree, its repositoryName matches the parent, which groups the two
  /// rows under one heading in the rail.
  private func moveSession(_ session: AgentSession, to url: URL) {
    let worktree = workspace.addWorktree(url)
    session.worktreeID = worktree.id
    workspace.selectedWorktreeID = worktree.id
    workspace.selectedSessionID = session.id
    reload()
  }

  /// The agent left its worktree, so the session goes back to the one it was started from and
  /// the window follows it there, the way it followed it in. The model decides whether there is
  /// anywhere to go (`Workspace.returnSession`); a result naming no open worktree changes nothing.
  private func returnSession(_ session: AgentSession, to url: URL) {
    guard workspace.returnSession(session, to: url) else { return }
    workspace.selectedWorktreeID = session.worktreeID
    workspace.selectedSessionID = session.id
    reload()
  }

  /// Closing is per repository, never per worktree. Worktrees are enumerated from git, so
  /// hiding one individually would leave a state git disagrees with; they come and go with
  /// the repository, or with landing the work.
  @objc func closeRepository(_ sender: Any?) {
    guard let worktreeID = workspace.selectedWorktreeID,
      let worktree = workspace.worktree(id: worktreeID)
    else { return }
    let repository = worktree.repositoryID
    let name = worktree.repositoryName

    let running = workspace.worktrees
      .filter { $0.repositoryID == repository }
      .flatMap { workspace.sessions(inWorktree: $0.id) }
      .filter(\.isRunning)
    if !running.isEmpty {
      let alert = NSAlert()
      alert.messageText = "Close \(name)?"
      alert.informativeText =
        running.count == 1
        ? "One agent is still running and will be stopped. Nothing on disk is removed."
        : "\(running.count) agents are still running and will be stopped. Nothing on disk is removed."
      alert.addButton(withTitle: "Close")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }

    workspace.closeRepository(repository)
    reload()
  }

  @objc func interruptSession(_ sender: Any?) {
    guard let session = workspace.selectedSession else { return }
    // With an approval on screen the thing to escape from is the approval, not the turn.
    // A second Escape then stops the turn as usual.
    if session.pendingApproval != nil {
      session.resolveApproval(allow: false)
      return
    }
    session.interrupt()
  }

  /// The approval card's two buttons, as commands. The card is the visible surface, but the
  /// clear-the-queue flow is keyboard-first — ⌘⏎ lands on the session that is waiting, so the
  /// decision itself needs shortcuts too (Session ▸ Allow ⇧⌘⏎ / Deny ⌘.).
  @objc func allowPendingApproval(_ sender: Any?) {
    workspace.selectedSession?.resolveApproval(allow: true)
  }

  @objc func denyPendingApproval(_ sender: Any?) {
    workspace.selectedSession?.resolveApproval(allow: false)
  }

  /// View ▸ Show/Hide Sidebar. Routed through NSSplitViewController's own toggle so the
  /// collapse animates and the divider state stays consistent.
  @objc func toggleRail(_ sender: Any?) {
    // Arranging a column by hand ends the maximized mode: the memento would otherwise put this
    // column back the next time the layout is restored, undoing what was just asked for. The
    // rail is left to the toggle below — it is the thing being asked for, and the menu item
    // reads "Show Sidebar" while the mode has it folded. Maximizing again re-reads whatever is
    // showing then.
    forgetMaximizedLayout()
    splitController.toggleSidebar(sender)
    // The collapse animates, so the item's fate is read once it has landed rather than from the
    // state the click started in.
    DispatchQueue.main.async { [weak self] in self?.updateRailToolbarItem() }
  }

  @objc func openRepository(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open Repository"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    workspace.selectedWorktreeID = workspace.openRepository(url).id
    reload()
  }

  /// File ▸ Save (Cmd+S). Writes the open source file back to disk; a no-op with nothing edited.
  @objc func saveFile(_ sender: Any?) {
    files.saveCurrent()
  }

  /// File ▸ Close Tab (⌘W). Closes the active tab — an open file (after the unsaved-edit prompt)
  /// — and is validated off when the desk is empty.
  @objc func closeTab(_ sender: Any?) {
    files.closeActiveTab()
  }

  /// Window ▸ Select Next/Previous Tab (⌃⇥ / ⌃⇧⇥). Cycles the desk's file tabs.
  @objc func selectNextTab(_ sender: Any?) {
    files.selectNextTab()
  }

  @objc func selectPreviousTab(_ sender: Any?) {
    files.selectPreviousTab()
  }

  /// Window ▸ Select Tab ▸ Tab N (⌘1…⌘9). The item's tag is N; the strip counts from zero.
  @objc func selectTabAtIndex(_ sender: NSMenuItem) {
    files.selectTab(at: sender.tag - 1)
  }

  /// Edit ▸ Find (⌘F). Finds within the active tab — the file's own find bar — scoped to the
  /// desk so it does not fight the rail's session search.
  @objc func find(_ sender: Any?) {
    files.findInActiveSurface(sender)
  }

  /// Edit ▸ Go to File… (⌘P). The files panel, shown if hidden, its filter focused.
  @objc func goToFile(_ sender: Any?) {
    revealFilesPanel()
    files.focusFilter()
  }

  /// Edit ▸ Find in Files… (⌘⇧F). The same field, running its content search instead.
  @objc func findInFiles(_ sender: Any?) {
    revealFilesPanel()
    files.searchInFiles()
  }

  /// View ▸ Files (⌘⇧E), and the toolbar's trailing toggle. Show or hide the files panel on the
  /// desk's trailing edge.
  @objc func toggleFilesPanel(_ sender: Any?) {
    forgetMaximizedLayout()
    setFilesPanelCollapsed(!filesPanelItem.isCollapsed)
  }

  /// Collapse or reveal the panel, repainting its toolbar row as the column settles rather than
  /// as the click lands (see `updateFilesToolbarItem`). The completion handler is the backstop:
  /// the divider notifications that drive the row stop arriving once the slide ends, and the
  /// last one can land a fraction short of the final width.
  private func setFilesPanelCollapsed(_ collapsed: Bool) {
    isRevealingFilesPanel = !collapsed
    NSAnimationContext.runAnimationGroup { _ in
      filesPanelItem.animator().isCollapsed = collapsed
    } completionHandler: { [weak self] in
      guard let self else { return }
      self.isRevealingFilesPanel = false
      self.updateFilesToolbarItem()
    }
    updateFilesToolbarItem()
  }

  /// Set while the panel is sliding open, so its toolbar row waits for the column. See
  /// `updateFilesToolbarItem`.
  private var isRevealingFilesPanel = false

  /// Which column the window has given itself to. The desk's tab and the rail's conversation are
  /// the same act — one column takes the window, everything that can fold does — so they share
  /// the memento, the menu item and the rules that end the mode.
  enum MaximizedColumn { case session, desk }

  /// The column being shown alone and what was collapsed when it took the window, so leaving the
  /// mode puts back exactly what was showing — a rail already hidden stays hidden. Nil means not
  /// maximized. Deliberately not saved with the window: a restored window opening with no rail
  /// and no transcript reads as a broken one, and the mode is a thing you are doing, not a thing
  /// the workspace is.
  private var maximized:
    (column: MaximizedColumn, rail: Bool, running: Bool, desk: Bool, panel: Bool)?

  /// Which columns are on screen, read off the split items rather than off the screen: a fold
  /// is what this mode is made of, and asserting one otherwise means measuring pixels.
  var showingColumns: (rail: Bool, session: Bool, desk: Bool, panel: Bool) {
    (
      !railItem.isCollapsed, !runningItem.isCollapsed, !deskItem.isCollapsed,
      !filesPanelItem.isCollapsed
    )
  }

  var maximizedColumn: MaximizedColumn? { maximized?.column }
  var isDeskMaximized: Bool { maximized?.column == .desk }
  var isSessionMaximized: Bool { maximized?.column == .session }

  /// Put the keyboard in the conversation — the dive a session's rail row makes on Return or a
  /// double-click, and what says "the focus is in this column" to anything that reads it
  /// (⌃⌘M does).
  func focusComposer() {
    window?.makeFirstResponder(running.inputField)
  }

  /// View ▸ Maximize Tab / Maximize Session (⌃⌘M), the tab menu's item, and the double-click
  /// each column carries on the strip that names what it is showing: give that column the whole
  /// window, or put the others back.
  @objc func toggleMaximize(_ sender: Any?) {
    setMaximized(maximized == nil ? maximizeTargetForFocus : nil)
  }

  /// Which column ⌃⌘M means, read off where the focus is: an edge column maximizes the column
  /// it feeds — the rail's detail is the conversation, the files panel's is a tab — and the two
  /// middle columns maximize themselves. Focus nowhere in the columns (the toolbar's fields, or
  /// a window nobody has clicked in yet) falls to the desk, which is where the key started.
  private var maximizeTargetForFocus: MaximizedColumn {
    var view = window?.firstResponder as? NSView
    while let current = view {
      if current === running.view || current === rail.view { return .session }
      if current === files.desk.view || current === files.panel.view { return .desk }
      view = current.superview
    }
    return .desk
  }

  /// Fold everything but one column away, or unfold it. Everything that can collapse does —
  /// because what is being asked for is the one tab, or the one conversation, and nothing else;
  /// what stays is that column's own header strip, since it is the way back. Asking for the other
  /// column while one is already showing alone keeps the layout the first one was entered from,
  /// which is the arrangement the way back has to lead to.
  private func setMaximized(_ column: MaximizedColumn?) {
    guard maximized?.column != column else { return }
    let before =
      maximized.map { ($0.rail, $0.running, $0.desk, $0.panel) }
      ?? (
        railItem.isCollapsed, runningItem.isCollapsed, deskItem.isCollapsed,
        filesPanelItem.isCollapsed
      )
    if let column {
      maximized = (column, before.0, before.1, before.2, before.3)
      setColumnsCollapsed(
        rail: true, running: column != .session, desk: column != .desk, panel: true)
    } else {
      maximized = nil
      setColumnsCollapsed(rail: before.0, running: before.1, desk: before.2, panel: before.3)
    }
    files.isDeskMaximized = isDeskMaximized
    running.isMaximized = isSessionMaximized
  }

  /// End the mode because a column is being arranged by hand. The column the act is about to
  /// move is the caller's and is left alone — putting it back is exactly what the memento must
  /// not do here. What is put back is the pair the mode folded that nothing else can unfold: the
  /// transcript and the desk have no toggle of their own, so a mode dropped in place would leave
  /// whichever of them it had folded with no way back. Each returns to what it was before the
  /// mode, so a divider somebody had dragged shut stays shut.
  private func forgetMaximizedLayout() {
    guard let before = maximized else { return }
    maximized = nil
    files.isDeskMaximized = false
    running.isMaximized = false
    guard runningItem.isCollapsed != before.running || deskItem.isCollapsed != before.desk
    else { return }
    NSAnimationContext.runAnimationGroup { _ in
      runningItem.animator().isCollapsed = before.running
      deskItem.animator().isCollapsed = before.desk
    }
  }

  /// The four columns in one animation, so the maximized one grows and shrinks as a single move
  /// rather than as several that happen to overlap. The toolbar rows are repainted as the columns
  /// settle, for the reason `setFilesPanelCollapsed` gives.
  private func setColumnsCollapsed(rail: Bool, running: Bool, desk: Bool, panel: Bool) {
    isRevealingFilesPanel = !panel
    NSAnimationContext.runAnimationGroup { _ in
      railItem.animator().isCollapsed = rail
      runningItem.animator().isCollapsed = running
      deskItem.animator().isCollapsed = desk
      filesPanelItem.animator().isCollapsed = panel
    } completionHandler: { [weak self] in
      guard let self else { return }
      self.isRevealingFilesPanel = false
      self.updateRailToolbarItem()
      self.updateFilesToolbarItem()
    }
    updateRailToolbarItem()
    updateFilesToolbarItem()
  }

  /// The toolbar's ± — scope the panel's tree and its content search to the worktree's changed
  /// files. The panel keeps the state; this only asks it to flip and repaints the item.
  @objc func toggleFilesScope(_ sender: Any?) {
    files.panel.toggleChangedOnlyScope()
    updateFilesToolbarItem()
  }

  /// Whether the panel's column is showing — the toggle's state, and what ⌘P has to fix before
  /// it can put the focus in a field nobody can see.
  var isFilesPanelVisible: Bool { !filesPanelItem.isCollapsed }

  private func revealFilesPanel() {
    // Asking for a column by name is arranging one by hand, the same as the toggle — so the mode
    // ends here too, or restoring would close the panel ⌘P had just opened.
    forgetMaximizedLayout()
    if filesPanelItem.isCollapsed { setFilesPanelCollapsed(false) }
  }

  /// Bring a session into view across every open window — the target of a tapped notification.
  /// Like `focusNextPending`, it selects the session's worktree; unlike it, the session is
  /// named, so it also fronts the window that holds it. Activation is the caller's job.
  static func focusSession(id: UUID) {
    for controller in all where controller.workspace.sessions.contains(where: { $0.id == id }) {
      // A maximized column has the rail folded away whichever one it is, and being sent to a
      // session is being sent to the rail as much as to the transcript. The mode ends where the
      // reason for it does.
      controller.setMaximized(nil)
      controller.workspace.selectedWorktreeID =
        controller.workspace.sessions.first { $0.id == id }?.worktreeID
      controller.workspace.selectedSessionID = id
      controller.reload()
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
  }

  /// With N running in parallel, the human's job reduces to clearing whatever is blocked,
  /// one after another. This is that, bound to a single key.
  @objc func focusNextPending(_ sender: Any?) {
    // Same as `focusSession`: what is waiting on you is on the rail and in the transcript, so
    // going to it puts the columns back.
    setMaximized(nil)
    // A signed-out or failed session is blocked on you too — it needs /login, or a look at what
    // went wrong — so both rank with the things waiting, above the merely-done idle ones.
    let order: [RunState] = [.needsAttention, .signedOut, .failed, .idle]
    for state in order {
      if let session = workspace.sessions.first(where: { $0.state == state }) {
        workspace.selectedWorktreeID = session.worktreeID
        reload()
        return
      }
    }
  }

  // MARK: - Menu validation

  /// Enablement, plus the state-reflecting titles: a toggle's menu item names the action it
  /// would perform ("Hide Sidebar" while it shows), not both states at once.
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(allowPendingApproval(_:)), #selector(denyPendingApproval(_:)):
      return workspace.selectedSession?.pendingApproval != nil
    case #selector(interruptSession(_:)):
      return workspace.selectedSession?.isRunning == true
    case #selector(focusNextPending(_:)):
      return !workspace.sessions.isEmpty
    case #selector(closeRepository(_:)):
      return workspace.selectedWorktreeID != nil
    case #selector(saveFile(_:)):
      return files.hasUnsavedEdit
    case #selector(closeTab(_:)):
      return files.hasClosableTab
    case #selector(find(_:)):
      return files.canFind
    case #selector(goToFile(_:)), #selector(findInFiles(_:)):
      return workspace.selectedWorktreeID != nil
    case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
      return files.hasMultipleTabs
    case #selector(selectTabAtIndex(_:)):
      return files.tabCount >= menuItem.tag
    case #selector(toggleMaximize(_:)):
      // Restoring stays available whatever the columns hold, so the way back never disappears.
      // Maximizing names the column the focus says it would take, and an empty one is refused:
      // giving the window to no tab, or to no conversation, shows nothing.
      guard maximized == nil else {
        menuItem.title = "Restore Layout"
        return true
      }
      switch maximizeTargetForFocus {
      case .session:
        menuItem.title = "Maximize Session"
        return workspace.selectedSession != nil
      case .desk:
        menuItem.title = "Maximize Tab"
        return files.hasClosableTab
      }
    case #selector(toggleRail(_:)):
      let collapsed = splitController.splitViewItems.first?.isCollapsed == true
      menuItem.title = collapsed ? "Show Sidebar" : "Hide Sidebar"
      return true
    case #selector(toggleFilesPanel(_:)):
      menuItem.title = isFilesPanelVisible ? "Hide Files" : "Show Files"
      return true
    default:
      return true
    }
  }
}
