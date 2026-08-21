import AppKit

extension NSToolbarItem.Identifier {
  static let status = NSToolbarItem.Identifier("status")
  static let usage = NSToolbarItem.Identifier("usage")
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
  private let files = FileColumnViewController()
  private let splitController = NSSplitViewController()

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

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1400, height: 880),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    super.init(window: window)

    window.delegate = self
    window.minSize = NSSize(width: 900, height: 520)
    window.title = "Hukan"

    let toolbar = NSToolbar(identifier: "dev.tnayuki.hukan.toolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    window.toolbar = toolbar
    // A separate title row wastes a whole row. Collapse it into the toolbar and put
    // "which worktree am I looking at" in the status on the toolbar's left.
    window.toolbarStyle = .unifiedCompact
    window.titleVisibility = .hidden
    window.titlebarSeparatorStyle = .line

    // The three pieces that hand window creation to AppKit's restoration machinery.
    // Without them the Space assignment is not restored.
    window.isRestorable = true
    window.restorationClass = WorkspaceWindowController.self
    window.identifier = WorkspaceWindowController.windowIdentifier

    // Left: overview. Middle: what is running. Right: files.
    // Columns with a lower holdingPriority resize first, and extra width should go to
    // the file column, so that one gets the lowest.
    let railItem = NSSplitViewItem(sidebarWithViewController: rail)
    railItem.minimumThickness = 200
    // The rail carries session titles, which run long — cap it high enough to read one at a
    // glance without truncation, not just to hold the dot and a few characters.
    railItem.maximumThickness = 480
    railItem.canCollapse = true
    railItem.holdingPriority = .init(262)

    let runningItem = NSSplitViewItem(viewController: running)
    runningItem.minimumThickness = 320
    runningItem.holdingPriority = .init(261)

    let filesItem = NSSplitViewItem(viewController: files)
    filesItem.minimumThickness = 420
    filesItem.holdingPriority = .init(260)

    splitController.addSplitViewItem(railItem)
    splitController.addSplitViewItem(runningItem)
    splitController.addSplitViewItem(filesItem)
    window.contentViewController = splitController

    rail.workspace = workspace
    running.workspace = workspace
    files.workspace = workspace
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
    rail.onNewSession = { [weak self] repositoryID in
      self?.newSession(inRepository: repositoryID)
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
    rail.onActivateSession = { [weak self] in
      guard let self else { return }
      self.window?.makeFirstResponder(self.running.inputField)
    }
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
    // A watched worktree's files moved: refresh in place, no full reload.
    workspace.onWorktreeFilesChanged = { [weak self] id in self?.worktreeFilesChanged(id) }

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

    for splitView in [splitController.splitView, files.splitView] {
      observers.append(
        NotificationCenter.default.addObserver(
          forName: NSSplitView.didResizeSubviewsNotification,
          object: splitView, queue: .main
        ) { [weak self] _ in self?.recordColumnWidths() })
    }
  }

  private var observers: [NSObjectProtocol] = []

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
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

    let widths = workspace.columnWidths
    if widths.count == 3, widths[0] > 0, widths[1] > 0 {
      splitView.setPosition(widths[0], ofDividerAt: 0)
      splitView.setPosition(widths[0] + widths[1], ofDividerAt: 1)
      files.sidebarWidth = widths[2]
      return
    }

    // Give the file column — the review surface — the most width, but start the rail wide
    // enough to read a session title, not just its first few characters.
    let rail: CGFloat = 300
    let running = max(420, (splitView.bounds.width - rail) * 0.42)
    splitView.setPosition(rail, ofDividerAt: 0)
    splitView.setPosition(rail + running, ofDividerAt: 1)
  }

  private var isArrangingColumns = true
  private var hasArrangedColumns = false

  /// Set once AppKit has finished restoring, so a window built during launch does not
  /// arrange itself before its saved widths arrive.
  static var hasFinishedLaunching = false

  private func recordColumnWidths() {
    guard !isArrangingColumns else { return }
    // The split view's own subviews, not the item view controllers' views: a sidebar item
    // insets its content, so recording the inner width and feeding it back to setPosition
    // loses that inset on every launch — the rail shrank 8pt each time.
    let columns = splitController.splitView.subviews.map(\.frame.width)
    guard columns.count == 3, columns.allSatisfy({ $0 > 0 }) else { return }
    let widths = [Double(columns[0]), Double(columns[1]), Double(files.sidebarWidth)]
    guard widths.allSatisfy({ $0 > 0 }), widths != workspace.columnWidths else { return }
    workspace.columnWidths = widths
    window?.invalidateRestorableState()
  }

  // MARK: - Toolbar

  // Interrupt and New Session used to sit here; they moved to where the hands already are —
  // stop into the composer, new-session into the rail — leaving the bar to carry only the
  // worktree name and diffstat, plus the standard sidebar toggle at the leading edge (the Mail
  // arrangement). The toggle is built by AppKit itself — the delegate is never asked for it —
  // and acts through the responder chain, landing on the split view controller like
  // View ▸ Hide Sidebar does.
  //
  // Deliberately *no* .sidebarTrackingSeparator: that item pins the toggle to the sidebar/
  // content divider, so collapsing the sidebar drags the divider — and the toggle with it —
  // to the far side of the bar. Without it the toggle stays put at the leading edge whether the
  // sidebar is open or closed, and the status capsule follows it directly (the bar was always
  // meant to be left-aligned).
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    // Usage rides the trailing edge (after a flexible space): it is an account-wide figure, not
    // tied to the worktree the leading status cluster names, so it belongs at the far end.
    [.toggleSidebar, .status, .flexibleSpace, .usage]
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

  /// Pull the latest account usage and show it at the toolbar's trailing edge. Coalesced and
  /// throttled inside `ClaudeUsage`, so it is safe to call on every reload and on window focus.
  /// A nil reading (API key, signed out, or a `/usage` format change) hides the item entirely.
  func refreshUsage() {
    ClaudeUsage.fetch { [weak self] snapshot in self?.applyUsage(snapshot) }
  }

  private func applyUsage(_ snapshot: ClaudeUsage.Snapshot?) {
    guard let snapshot else {
      usageLabel.attributedStringValue = NSAttributedString()
      usageLabel.toolTip = nil
      usageToolbarItem?.isHidden = true
      return
    }
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
      lines.append("Session: \(session.percent)% · resets \(session.resetsAt)")
    }
    for bar in snapshot.weekly {
      lines.append("Week (\(bar.label)): \(bar.percent)% · resets \(bar.resetsAt)")
    }
    usageLabel.toolTip = lines.joined(separator: "\n")
    usageToolbarItem?.isHidden = line.length == 0
  }

  /// A toolbar-sized, secondary-tinted SF Symbol for the usage cluster.
  private static func usageIcon(_ name: String) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
      .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(configuration)
  }

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
  private func worktreeFilesChanged(_ worktreeID: UUID) {
    rail.reload()
    guard worktreeID == workspace.selectedWorktreeID,
      let worktree = workspace.worktree(id: worktreeID)
    else { return }
    let stat = worktree.diffstat
    setDiffStat(added: stat.added, removed: stat.removed)
    files.refreshInPlace()
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
    let selected = workspace.selectedWorktreeID.flatMap { workspace.worktree(id: $0) }
    let target =
      (selected?.repositoryID == repositoryID ? selected : nil)
      ?? workspace.worktrees.first { $0.repositoryID == repositoryID }
    if let target { createSession(in: target) }
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
    session.onEnterWorktree = { [weak self] url in self?.moveSession(session, to: url) }
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
    splitController.toggleSidebar(sender)
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

  @objc func toggleOverview(_ sender: Any?) {
    workspace.isOverview.toggle()
    // TODO: the overview (a grid of cards) is not built yet; this only holds the state.
    reload()
  }

  @objc func toggleDiffMode(_ sender: Any?) {
    files.toggleDiffMode()
  }

  /// File ▸ Save (Cmd+S). Writes the open source file back to disk; a no-op with nothing edited.
  @objc func saveFile(_ sender: Any?) {
    files.saveCurrent()
  }

  @objc func toggleFileSidebarMode(_ sender: Any?) {
    workspace.fileSidebarMode = workspace.fileSidebarMode == .changed ? .all : .changed
    reload()
  }

  /// Bring a session into view across every open window — the target of a tapped notification.
  /// Like `focusNextPending`, it selects the session's worktree; unlike it, the session is
  /// named, so it also fronts the window that holds it. Activation is the caller's job.
  static func focusSession(id: UUID) {
    for controller in all where controller.workspace.sessions.contains(where: { $0.id == id }) {
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
    // A signed-out session is blocked on you too — it needs /login — so it ranks with the
    // things waiting, above the merely-done idle ones.
    let order: [RunState] = [.needsAttention, .signedOut, .idle]
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
  /// would perform ("Show Source" while the diff is up), not both states at once.
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
    case #selector(toggleRail(_:)):
      let collapsed = splitController.splitViewItems.first?.isCollapsed == true
      menuItem.title = collapsed ? "Show Sidebar" : "Hide Sidebar"
      return true
    case #selector(toggleDiffMode(_:)):
      menuItem.title = files.isShowingDiff ? "Show Source" : "Show Diff"
      return true
    case #selector(toggleFileSidebarMode(_:)):
      menuItem.title =
        workspace.fileSidebarMode == .changed ? "Show All Files" : "Show Changed Files"
      return true
    default:
      return true
    }
  }
}
