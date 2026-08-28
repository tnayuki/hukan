import AppKit

extension NSToolbarItem.Identifier {
  static let sessionFilter = NSToolbarItem.Identifier("sessionFilter")
  static let status = NSToolbarItem.Identifier("status")
  static let systemUsage = NSToolbarItem.Identifier("systemUsage")
  static let usage = NSToolbarItem.Identifier("usage")
  static let toggleFiles = NSToolbarItem.Identifier("toggleFiles")
  static let toggleHistory = NSToolbarItem.Identifier("toggleHistory")
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

  /// Whether AppKit built this window to restore into. Set by `restoreWindow` on the controller
  /// it has just constructed, which is early enough for `applyDefaultFrame` to read — see there
  /// for why the geometry cannot answer the question itself.
  private var isRestored = false

  let workspace: Workspace

  private let rail = SessionRailViewController()
  private let running = RunningColumnViewController()
  private let files = FileColumns()

  /// The files panel, for the scripting surface — the panel is rows, which the object model does
  /// not address.
  var filesPanelForScripting: FilesPanelViewController { files.panel }
  /// The desk, for the scripting surface — `browser` and `commit` both drive a tab the object
  /// model does not address.
  var deskForScripting: WorktreeDeskViewController { files.desk }
  /// The composer, for the scripting surface — the completion list is rows over a floating
  /// panel, so `completions` is the only way to read one back without clicking at coordinates.
  var composerForScripting: ComposerInput { running.composerForScripting }
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

    // Installed on the first window and shared by the rest: the monitor picks its controller out
    // of the event, so one is enough however many windows are open.
    _ = Self.tabCyclingMonitor

    window.delegate = self
    // The columns' own minimums added up — narrower than this and the split view starts taking
    // it out of one of them, and both edge columns carry a toolbar row that stops fitting. Two
    // of the three terms are the display mode's, so this is re-read whenever it moves
    // (`applyToolbarDisplayMode`) rather than being a number written down once.
    window.minSize = NSSize(
      width: Self.railMinimumWidth(labelled: false) + Self.columnsMinimumWidth
        + Self.filesPanelMinimumWidth(labelled: false),
      height: Self.windowMinimumHeight)
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
    // Measured: the filter survives from 280pt down to 272, and drops below that. The number
    // is the display mode's — see `railMinimumWidth`.
    railItem.minimumThickness = Self.railMinimumWidth(labelled: false)
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
    deskItem.minimumThickness = Self.deskMinimumWidth
    // Collapsible for the same reason the transcript beside it is: a maximized session has to
    // fold it away. Nothing else collapses it, and there is no toggle for it — the way back is
    // the same ⌃⌘M either column's maximize is undone with.
    deskItem.canCollapse = true
    deskItem.holdingPriority = Self.deskHoldingPriority

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
    // Wide enough to hold its own row of the toolbar — the filter, the ±, the History fold and the
    // toggle. Narrower and the filter runs out past the panel's leading edge into the content
    // section, which reads as a field belonging to nothing. Measured with the field at 130: the
    // row clears at 280pt and spills by 7 at 271, where the three-item row cleared at 242. So the
    // number moves whenever an item joins the row, and `ToolbarRowFitsTests` is what says so —
    // the next button to arrive fails there rather than quietly pushing the field out.
    filesPanelItem.minimumThickness = Self.filesPanelMinimumWidth(labelled: false)
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
    // `.iconOnly` above is where the bar starts, not where it stays: the toolbar's own
    // right-click menu offers `Icon and Text`, there is no supported way to decline it, and the
    // captions it adds are wider than the columns the sections were measured against. So the
    // mode is followed rather than fought — the property is documented key-value observable,
    // and every floor the row sets is re-read from it.
    displayModeObservation = toolbar.observe(\.displayMode, options: [.initial]) {
      [weak self] _, _ in
      MainActor.assumeIsolated { self?.applyToolbarDisplayMode() }
    }

    rail.workspace = workspace
    running.workspace = workspace
    files.workspace = workspace
    running.onForkSession = { [weak self] source, anchor, range in
      self?.forkSession(source, at: anchor, keeping: range.location)
    }
    running.onRollBackSession = { [weak self] session, anchor, range in
      self?.rollBackSession(session, to: anchor, keeping: range.location)
    }
    running.onOpenURL = { [weak self] url in self?.openFromTranscript(url) ?? false }
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
    // The desk's + button opens a terminal in the selected worktree, same as ⌃⌘T.
    files.onNewTerminal = { [weak self] in self?.newTerminal(nil) }
    // A watched worktree's files moved: refresh in place, no full reload.
    workspace.onWorktreeFilesChanged = { [weak self] id, changed in
      self?.worktreeFilesChanged(id, changed: changed)
    }

    WorkspaceWindowController.all.append(self)
    reload()
    applyDefaultFrame()

    // Not during launch: restoration runs between willFinishLaunching and
    // didFinishLaunching, so anything queued here fires *before* the saved widths have
    // been decoded — it would lay out the defaults and then record them over the top.
    // The app delegate arranges the restored windows; this covers ones opened later.
    DispatchQueue.main.async { [weak self] in
      guard WorkspaceWindowController.hasFinishedLaunching else { return }
      self?.arrangeColumnsIfNeeded()
    }

    for splitView in [
      splitController.splitView, columnsController.splitView, files.panel.splitView,
    ] {
      observers.append(
        NotificationCenter.default.addObserver(
          forName: NSSplitView.didResizeSubviewsNotification,
          object: splitView, queue: .main
        ) { [weak self] _ in
          self?.files.panel.dividerMoved()
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
    terminalTitleTimer?.invalidate()
  }

  required init?(coder: NSCoder) { fatalError("interface builder is not used") }

  /// Size and place a *fresh* window. Assigning contentViewController shrinks the window to its
  /// content's fitting size — the sum of the columns' minimum widths — so without this a new
  /// window opens at its own floor, in whatever corner the last one left.
  ///
  /// A restored window is exempt, and it has to be *told* it is one: the geometry cannot answer
  /// the question. This used to run only when `frame.width <= contentView.fittingSize.width + 8`,
  /// on the reading that a window still at its fitting size is a window with no saved frame to
  /// restore — but the split view's fitting width *is* the window's current width (measured:
  /// 1650 inside a 1650pt window), so the test was true of every window, and every restored
  /// frame was overwritten with the default size and re-centred. AppKit applies the saved frame
  /// once more after this runs, which is why the window usually still came back where it was
  /// left; which of the two landed last was a race, and a lost one is saved by the next quit, so
  /// the window kept the default frame from then on.
  private func applyDefaultFrame() {
    // AppKit re-fits the window later in the same run loop, so this has to wait one
    // turn to take effect. That turn is also what makes `isRestored` readable here: the
    // restoration path sets it on the controller as soon as init returns.
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window,
        let screen = window.screen ?? NSScreen.main
      else { return }
      // A restored window has its saved frame by this turn — AppKit applies it while
      // `restoreWindow` is still returning. One still standing at its floor is one restoration
      // had no frame to give (state discarded because the machine's "close windows when
      // quitting" was on, state written before there was a window to save), and it takes the
      // default like a fresh window rather than opening at the columns' minimums.
      let atFloor =
        window.frame.width <= window.minSize.width && window.frame.height <= window.minSize.height
      guard !self.isRestored || atFloor else { return }
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
    if workspace.historyHeight > 0 {
      files.panel.historyHeight = CGFloat(workspace.historyHeight)
    }
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
    // read a session title, not just its first few characters.
    let rail: CGFloat = 300
    // Both defaults give way before the desk and the transcript are squeezed below what they
    // need: ask for all three on a narrow screen and the split view honours the minimums by
    // taking it out of the rail, which lands it on 200 with its filter dropped from the toolbar.
    let available = splitView.bounds.width
    let panel = filesPanelItem.minimumThickness
    let running = max(420, (available - rail - panel) * 0.42)
    splitView.setPosition(rail, ofDividerAt: 0)
    splitView.setPosition(available - panel, ofDividerAt: 1)
    columnsController.splitView.setPosition(running, ofDividerAt: 0)
  }

  /// The transcript and the desk together, as their own items ask for them.
  private static let columnsMinimumWidth: CGFloat = 640

  /// Two rows of the transcript, a composer and a tab strip — the height below which the window
  /// is no longer a window anyone works in. Unlike the widths, nothing in the toolbar moves it.
  private static let windowMinimumHeight: CGFloat = 520

  /// What the panel's row of the toolbar needs — see where it is set for the measurement. The
  /// panel opens at this too: the row defines both, so there is one number rather than a default
  /// that can drift below the floor it is clamped to.
  ///
  /// Two numbers, because the row's width is the display mode's. `Icon and Text` — which the
  /// bar's own right-click menu offers, and which nothing here can refuse — writes a caption
  /// under every glyph, and the ± alone goes from 44pt to the width of "Changed Files Only".
  /// The floor follows the row rather than the row being forbidden its captions: the panel is
  /// pushed as wide as the mode needs, and the desk pays for a choice its owner made. Measured
  /// the way the 280 was, and by the same test: the captioned row clears at 366, so 372 carries
  /// the few points of slack the other number does. `ToolbarRowFitsTests` measures both.
  static func filesPanelMinimumWidth(labelled: Bool) -> CGFloat { labelled ? 372 : 280 }

  /// The rail's floor, on the same rule. What the captions cost here is the sidebar toggle
  /// AppKit itself draws — 44pt becomes 58 with "Sidebar" under it — and the section's own
  /// filter is what runs out of room: a toolbar item that no longer fits is not shrunk but
  /// moved to the overflow menu, so the field does not narrow, it vanishes. Measured: captioned,
  /// the filter survives down to 281, which is the one point above the uncaptioned floor that
  /// makes this a second number at all.
  static func railMinimumWidth(labelled: Bool) -> CGFloat { labelled ? 288 : 280 }

  /// What the desk is allowed to ask for, and how hard it holds it. A tab whose content resists
  /// compression harder than this does not get a wider desk — it wins the argument, moves the
  /// divider and takes the width out of the transcript column beside it, which is what opening a
  /// commit tab used to do. `CommitTabTests` sets the two against each other and is where the next
  /// stubborn label fails.
  static let deskMinimumWidth: CGFloat = 320
  static let deskHoldingPriority = NSLayoutConstraint.Priority(260)

  /// Held for as long as the window is: dropping it stops the floors following the mode.
  private var displayModeObservation: NSKeyValueObservation?

  /// The floors the toolbar's row imposes on the columns under it, re-read whenever the display
  /// mode moves. Captions make every section wider, and a section that outgrows its column is
  /// what puts the panel's filter out over the desk and drops the rail's into the overflow menu.
  ///
  /// The window's own minimum goes up with them, or the split view is asked to honour floors
  /// that do not fit inside it and takes the difference out of one of the columns — which is
  /// the spill this exists to prevent, arrived at by another route.
  /// Whether the captions' floors are what the columns are sitting on — see `recordColumnWidths`.
  private var isDisplayModeHoldingTheColumns: Bool {
    filesPanelItem.minimumThickness > Self.filesPanelMinimumWidth(labelled: false)
  }

  func applyToolbarDisplayMode() {
    let labelled = window?.toolbar?.displayMode != .iconOnly
    let panel = Self.filesPanelMinimumWidth(labelled: labelled)
    let rail = Self.railMinimumWidth(labelled: labelled)
    guard filesPanelItem.minimumThickness != panel || railItem.minimumThickness != rail else {
      return
    }
    filesPanelItem.minimumThickness = panel
    railItem.minimumThickness = rail
    window?.minSize = NSSize(
      width: rail + Self.columnsMinimumWidth + panel, height: Self.windowMinimumHeight)
  }

  private var isArrangingColumns = true
  private var hasArrangedColumns = false

  /// Set once AppKit has finished restoring, so a window built during launch does not
  /// arrange itself before its saved widths arrive.
  static var hasFinishedLaunching = false

  private func recordColumnWidths() {
    guard !isArrangingColumns else { return }
    // Nothing measured under the captions is saved, because the captions are not: a restored
    // window's bar starts at icons, and `Icon and Text` pushes the panel out to a width nobody
    // dragged it to — which the transcript beside it pays for, so the drift is not the panel's
    // alone. The whole arrangement belongs to a mode that will not be there next time, and the
    // widths from before it are the ones that will still mean something.
    guard !isDisplayModeHoldingTheColumns else { return }
    // Nor anything measured while one column has the window: those widths belong to a mode that
    // is not saved either, and the arrangement to go back to is the one it was entered from. The
    // zero guard below does not cover it — a maximized desk folds both of the columns this
    // reads, so they measure nothing and it catches them, but a maximized session leaves the
    // transcript standing at the full width of the window.
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
    // Zero while the section is folded, which the same rule covers: keep the height it will
    // reopen at rather than recording the fold as a height of nothing.
    let history = files.panel.historyHeight > 0 ? Double(files.panel.historyHeight) : nil
    let historyChanged = history.map { $0 != workspace.historyHeight } ?? false
    if let history, historyChanged { workspace.historyHeight = history }
    guard widths.allSatisfy({ $0 > 0 }) else { return }
    guard widths != workspace.columnWidths || historyChanged else { return }
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
      .filesScope, .toggleHistory, .toggleFiles,
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
    case .toggleHistory:
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.label = "History"
      // The panel's other half, folded from the same row as the ± beside it — and accented the
      // same way while it is open, rather than filling a pill.
      item.image = Self.historyImage(on: false)
      item.isBordered = false
      item.target = self
      item.action = #selector(toggleHistorySection(_:))
      historyToolbarItem = item
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
    if let historyToolbarItem {
      historyToolbarItem.isHidden = !shown
      // Nothing committed in this worktree means nothing to fold — the glyph goes grey rather
      // than toggling a section that is not drawn, the same way the ± does with nothing changed.
      historyToolbarItem.isEnabled = files.hasHistory
      historyToolbarItem.toolTip =
        files.hasHistory
        ? (files.isHistoryVisible ? "Hide History" : "Show History")
        : "Nothing committed in this worktree"
      historyToolbarItem.image = Self.historyImage(on: files.isHistoryVisible)
    }
    guard let filesToolbarItem else { return }
    filesToolbarItem.toolTip = shown ? "Hide Files" : "Show Files"
  }

  /// The History glyph, accented while the section is open — the ± convention, next to it.
  ///
  /// A region, not a clock: the button shows and hides the bottom band of this column, which is
  /// what the glyph draws, and it rhymes with the `sidebar.trailing` of the panel toggle beside
  /// it. A clock read as the heaviest thing in the bar next to the ±'s thin strokes, and the word
  /// "History" is already carried by the tooltip and the View menu.
  private static func historyImage(on: Bool) -> NSImage? {
    barGlyph("rectangle.bottomthird.inset.filled", description: "History", accented: on)
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

  private weak var historyToolbarItem: NSToolbarItem?
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
  /// The slash commands the last engine to start reported. See `attach` for why it is one list
  /// per window and why it is never saved.
  private var commandRoster: [ClaudeCommand] = []

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

  /// A terminal tab is named for the command holding its pty (see `TerminalSession.title`), and
  /// nothing announces one starting, so the set is polled. Quick enough that a command's name is
  /// there by the time you look at the tab, and each tick is two syscalls per terminal.
  private static let terminalTitleInterval: TimeInterval = 0.5
  private var terminalTitleTimer: Timer?

  /// Poll only while terminals exist: the first one starts the timer and the tick that finds none
  /// left stops it, which covers every way a terminal can go — ⌘W, `exit`, a closed repository —
  /// without each of those having to remember.
  private func startTerminalTitleTimerIfNeeded() {
    guard terminalTitleTimer == nil else { return }
    let timer = Timer(timeInterval: Self.terminalTitleInterval, repeats: true) {
      [weak self] timer in
      guard let self, !self.workspace.terminals.isEmpty else {
        timer.invalidate()
        self?.terminalTitleTimer = nil
        return
      }
      for terminal in self.workspace.terminals { terminal.refreshForegroundProcess() }
    }
    RunLoop.main.add(timer, forMode: .common)
    terminalTitleTimer = timer
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
    // The frame is AppKit's to put back from here on — see `applyDefaultFrame`.
    controller.isRestored = true
    completionHandler(controller.window, nil)
  }

  func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
    // The tabs in strip order, and the order itself — the desk's, since the strip is.
    workspace.encodeState(
      to: state, browserTabs: files.desk.restorableBrowserTabs,
      terminals: files.desk.restorableTerminals(workspace.terminals),
      tabOrder: files.desk.restorableTabOrder)
  }

  func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
    workspace.decodeState(from: state)
    materializeRestoredTerminals()
    files.desk.restoreBrowserTabs(workspace.takeRestoredBrowserTabs())
    // Only once both kinds are back, since the order names them by position.
    files.desk.restoreTabOrder(workspace.takeRestoredTabOrder())
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
    // One list for the window. The commands are the engine's, and every session in a window is
    // talking to the same install of it, so the first engine up answers for the rest — which is
    // what makes a `/` typed into a session that has never started complete anything at all.
    // Not saved with the window: a list read at launch would be a stale answer for as long as the
    // window lived, and a completion offering a skill that has since been removed is worse than
    // no completion. It costs one session's initialize to be right again.
    session.onCommands = { [weak self] commands in
      guard let self else { return }
      self.commandRoster = commands
      for other in self.workspace.sessions { other.seedCommands(commands) }
    }
    session.seedCommands(commandRoster)
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

  /// File ▸ New Terminal (⌃⌘T). A shell in the selected worktree, shown as a tab on its desk.
  @objc func newTerminal(_ sender: Any?) {
    guard let worktreeID = workspace.selectedWorktreeID,
      let worktree = workspace.worktree(id: worktreeID)
    else { return }
    createTerminal(in: worktree)
  }

  /// The scripting seam (`make new terminal`), mirroring `makeSession`.
  func makeTerminal(in worktree: Worktree) -> TerminalSession {
    createTerminal(in: worktree)
  }

  /// A link pressed in the transcript. It opens on this worktree's desk rather than in the
  /// default browser, because the address an agent writes is the task's — the PR it just opened,
  /// the issue it is working from — and that is what the desk's web tab is for. Only http(s):
  /// anything else is the system's, on the same table the web view's own navigation policy uses.
  ///
  /// ⌘ sends it out instead, which is the way out for a page hukan cannot sign into — passkeys
  /// and iCloud Keychain autofill need browser-vendor entitlements and are measured not to work
  /// here.
  ///
  /// Never automatic: a link is opened because a person pressed it. hukan following an address
  /// out of the transcript on its own would be the agent driving the browser, which is the same
  /// line the scripting surface draws around `approve`.
  @discardableResult
  private func openFromTranscript(_ url: URL) -> Bool {
    guard !NSEvent.modifierFlags.contains(.command), BrowserEnvironment.opensAsWebTab(url) else {
      NSWorkspace.shared.open(url)
      return true
    }
    files.openBrowser(url: url)
    return true
  }

  /// File ▸ New Browser (⌘T). A web tab in the selected worktree's desk, over the shared
  /// cookie store, address field focused.
  @objc func newBrowserTab(_ sender: Any?) {
    files.openBrowser()
  }

  @discardableResult
  private func createTerminal(in worktree: Worktree) -> TerminalSession {
    let terminal = TerminalSession(worktreeID: worktree.id, cwd: worktree.url)
    registerTerminal(terminal)
    // Show it now only if its worktree is the one on screen; otherwise it waits, unspawned, for
    // that worktree to be selected (scripting can make a terminal in any worktree).
    if workspace.selectedWorktreeID == worktree.id {
      files.openTerminal(id: terminal.id)
    }
    return terminal
  }

  /// Wire a terminal's callbacks and add it to the workspace — shared by live creation and
  /// restore. Invalidates restorable state so the terminal set (and its scrollback) is saved.
  private func registerTerminal(_ terminal: TerminalSession) {
    // Capture the id, not the terminal — the terminal owns these closures, so holding it back
    // would be a cycle that outlives its removal.
    let id = terminal.id
    terminal.onTitleChange = { [weak self] in self?.files.refreshTerminalTabs() }
    startTerminalTitleTimerIfNeeded()
    terminal.onExit = { [weak self] in
      self?.workspace.removeTerminal(id: id)
      self?.files.reload()
      self?.window?.invalidateRestorableState()
    }
    workspace.terminals.append(terminal)
    window?.invalidateRestorableState()
  }

  /// Turn the terminals decoded from restoration state into live sessions — the scrollback is
  /// carried on the model and replayed above a fresh shell when the desk first shows it.
  private func materializeRestoredTerminals() {
    for pending in workspace.takeRestoredTerminals() {
      guard let worktree = workspace.worktree(id: pending.worktreeID) else { continue }
      // Reopen where the shell was, unless that directory is gone — then fall back to the worktree.
      var isDirectory: ObjCBool = false
      let exists =
        !pending.directory.isEmpty
        && FileManager.default.fileExists(atPath: pending.directory, isDirectory: &isDirectory)
        && isDirectory.boolValue
      let directory = exists ? URL(fileURLWithPath: pending.directory) : nil
      registerTerminal(
        TerminalSession(
          worktreeID: worktree.id, cwd: worktree.url, restoredDirectory: directory,
          sessionID: pending.sessionID.isEmpty ? nil : pending.sessionID,
          restoredScrollback: pending.scrollback))
    }
    files.reload()
  }

  /// File ▸ Close Tab (⌘W). Closes the active tab — an open file (after the unsaved-edit prompt)
  /// or a terminal — and is validated off when the desk is empty.
  @objc func closeTab(_ sender: Any?) {
    files.closeActiveTab()
  }

  /// Edit ▸ Clear Terminal (⌘K). Drops the active terminal's scrollback, as in Terminal.app.
  @objc func clearTerminal(_ sender: Any?) {
    files.clearActiveTerminal()
  }

  /// Edit ▸ Find (⌘F). Finds within the active tab — a terminal's bar (SwiftTerm's own) or a
  /// file's (the text view's) — scoped to the desk so it does not fight the rail's session search.
  @objc func find(_ sender: Any?) {
    files.findInActiveSurface(sender)
  }

  /// View ▸ Back / Forward (⌘[ / ⌘]). The web tab's history, the keys Safari and Apple's own
  /// shortcut list use — not ⌘←/→, which Safari leaves to the responder chain so a text field on
  /// the page keeps them as caret motion; a menu key would take them first and break that. Both
  /// validate off unless a web tab is showing with somewhere to go.
  @objc func browserGoBack(_ sender: Any?) {
    files.browserGoBack()
  }

  @objc func browserGoForward(_ sender: Any?) {
    files.browserGoForward()
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

  /// View ▸ History (⌘⇧L). Fold the panel's History section away, or bring it back — revealing
  /// the panel first if it is hidden, since a fold inside a hidden column would do nothing
  /// visible.
  @objc func toggleHistorySection(_ sender: Any?) {
    // Asked for from a hidden panel, this is a request to see the history — reveal the column and
    // unfold the section, rather than folding something nobody can see.
    if filesPanelItem.isCollapsed {
      files.expandHistorySection()
      setFilesPanelCollapsed(false)
    } else {
      files.toggleHistorySection()
    }
    updateFilesToolbarItem()
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

  /// Window ▸ Select Next/Previous Tab (⌃⇥ / ⌃⇧⇥). Cycles the desk's file, browser and
  /// terminal tabs.
  @objc func selectNextTab(_ sender: Any?) {
    files.selectNextTab()
  }

  @objc func selectPreviousTab(_ sender: Any?) {
    files.selectPreviousTab()
  }

  /// ⌃⇥ / ⌃⇧⇥ from wherever the focus is. The Window menu carries both items — that is where a
  /// person looks a shortcut up — but the menu is not what matches the keystroke, because it
  /// never gets the chance: AppKit walks the key window's *views* with `performKeyEquivalent`
  /// before it offers the event to the main menu, and WKWebView answers yes to a key event while
  /// it is first responder (Tab is the web's own focus key), so ⌃⇥ was dead in exactly the tab a
  /// browser tab is. ⌃⇧⇥ was dead in all of them: macOS delivers Shift-Tab as NSBackTabCharacter
  /// (0x19), which a `"\t"` key equivalent cannot match — and AppKit compares the *next* item's
  /// mask loosely enough that a ⌃⇧⇥ arriving as a plain tab would have gone forward instead.
  /// So the keystroke is claimed by a local key-down monitor, the one hook ahead of both the view
  /// walk and the menu — the same reason the terminal's ⌥←/→ uses one. The items keep their key
  /// equivalents; what those are for now is the label.
  private static let tabCyclingMonitor: Any? = NSEvent.addLocalMonitorForEvents(matching: .keyDown)
  { event in
    guard let controller = event.window?.windowController as? WorkspaceWindowController,
      let delta = tabCycleDelta(for: event), controller.files.hasMultipleTabs
    else { return event }
    // With one tab there is nowhere to go, and the event is handed back rather than swallowed —
    // a page that binds ⌃⇥ itself keeps it until the desk has a second tab to switch to.
    if delta > 0 { controller.selectNextTab(nil) } else { controller.selectPreviousTab(nil) }
    return nil
  }

  /// +1 for ⌃⇥, −1 for ⌃⇧⇥, nil for anything else. Matched on the Tab key's code rather than on
  /// the characters the event carries, since those are the whole reason the menu could not do it:
  /// Shift-Tab arrives as 0x19, not as a shifted `"\t"`. Split out so it can be tested without a
  /// window, the way the terminal's word jump is.
  static func tabCycleDelta(for event: NSEvent) -> Int? {
    guard event.keyCode == 48 else { return nil }  // kVK_Tab
    switch event.modifierFlags.intersection([.command, .control, .option, .shift]) {
    case [.control]: return 1
    case [.control, .shift]: return -1
    default: return nil
    }
  }

  /// Window ▸ Select Tab ▸ Tab N (⌘1…⌘9). The item's tag is N; the strip counts from zero.
  @objc func selectTabAtIndex(_ sender: NSMenuItem) {
    files.selectTab(at: sender.tag - 1)
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
    case #selector(newTerminal(_:)), #selector(newBrowserTab(_:)):
      return workspace.selectedWorktreeID != nil
    case #selector(closeTab(_:)):
      return files.hasClosableTab
    case #selector(clearTerminal(_:)):
      return files.hasActiveTerminal
    case #selector(find(_:)):
      return files.canFind
    case #selector(browserGoBack(_:)):
      return files.canBrowserGoBack
    case #selector(browserGoForward(_:)):
      return files.canBrowserGoForward
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
    case #selector(toggleHistorySection(_:)):
      menuItem.title = files.isHistoryVisible ? "Hide History" : "Show History"
      return files.hasHistory
    default:
      return true
    }
  }
}
