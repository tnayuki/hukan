import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillFinishLaunching(_ notification: Notification) {
    // Wind libgit2 up before window restoration, which runs next and asks git about its
    // worktrees. Every git query hukan makes goes through libgit2 in-process — no subprocess.
    Git.initialize()

    // Which Space a restored window comes back to is AppKit's to decide, and it only asks the
    // question when this default says so — off, every window lands on whichever Space happens
    // to be in front, which is why quitting an app scatters across Spaces and gathers into one.
    // The saved state carries the Space either way; this is the switch on reading it back.
    // Registered rather than written, so a hand-set value still wins.
    UserDefaults.standard.register(defaults: ["NSWindowRestoresWorkspaceAtLaunch": true])
    NSApp.mainMenu = AppDelegate.makeMainMenu()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Under XCTest the app is only a host for the unit tests — don't open a window, ask for
    // notification permission, or steal focus. (Xcode sets this env var for the test run.)
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

    // Window restoration runs between willFinishLaunching and didFinishLaunching.
    // Only open a fresh window if nothing came back. Creating one ourselves makes it
    // a new window as far as AppKit is concerned, which loses the Space assignment.
    if WorkspaceWindowController.all.isEmpty {
      WorkspaceWindowController(workspace: Workspace()).showWindow(nil)
    }

    // `hukan ~/src/foo ~/src/bar` opens with those worktrees.
    let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
    if !paths.isEmpty, let controller = WorkspaceWindowController.all.first {
      for path in paths {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
          isDirectory.boolValue
        else { continue }
        controller.workspace.openRepository(URL(fileURLWithPath: path))
      }
      controller.reload()
    }

    // Restoration is finished by now, so the restored windows finally know how wide their
    // columns were left.
    WorkspaceWindowController.hasFinishedLaunching = true
    for controller in WorkspaceWindowController.all { controller.arrangeColumnsIfNeeded() }

    // Ask once, so an agent that blocks on you while the app sits in the background can pull
    // you back. No-op unless we are running from a real .app bundle.
    SessionNotifier.shared.requestAuthorization()

    NSApp.activate(ignoringOtherApps: true)
  }

  /// Stop every agent before quitting. `claude -p` runs as a child process, and a child is not
  /// killed when its parent exits — so without this, quitting (or the relaunch `restart` does)
  /// orphans each one to launchd, where it keeps running its turn, and the next launch resumes
  /// the same session on top of it: two claudes writing one transcript.
  ///
  /// Gracefully: close every stdin first (EOF starts the engine's own clean shutdown, which is
  /// where it flushes the transcript tail — SIGTERM straight away was cutting the last entries
  /// off the `.jsonl`), hold the door briefly for those exits, then SIGTERM the stragglers, and
  /// finally SIGKILL whatever still lives — a mid-turn engine that ignores EOF and SIGTERM is
  /// reparented to launchd the instant we return here, and that orphan keeps the session's
  /// transcript open, which the next launch's `liveProcessOwning` guard then refuses to resume
  /// on top of ("restart, and every session is already open elsewhere"). The whole sequence is
  /// one shared deadline across all sessions, driven synchronously right here: a background
  /// waiter would die with the process before ever escalating. The trailing wait after SIGKILL
  /// lets the kernel actually reap the children before we exit, so none reparents.
  func applicationWillTerminate(_ notification: Notification) {
    let sessions = WorkspaceWindowController.all.flatMap { $0.workspace.sessions }
    func waitWhileRunning(upTo seconds: TimeInterval) {
      let deadline = Date().addingTimeInterval(seconds)
      while Date() < deadline, sessions.contains(where: { $0.isRunning }) {
        Thread.sleep(forTimeInterval: 0.05)
      }
    }
    for session in sessions { session.beginStop() }  // EOF: clean exit + transcript flush
    waitWhileRunning(upTo: 2)
    for session in sessions where session.isRunning { session.forceStop() }  // SIGTERM
    waitWhileRunning(upTo: 1)
    // SIGKILL — never orphan.
    for session in sessions where session.isRunning { session.killStop() }
    waitWhileRunning(upTo: 1)
  }

  /// Opt into secure coding for restorable state. Not returning true warns, and it also
  /// states the constraint: only strings, numbers and arrays survive restoration.
  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  /// Open a fresh, empty workspace window. Reached from File ▸ New Window (⌘N) and from the
  /// reopen handler below. A new Workspace carries no repositories — the window opens empty and
  /// Open Repository fills it — which is right: it is a new desk, not a copy of another one.
  @objc func newWindow(_ sender: Any?) {
    WorkspaceWindowController(workspace: Workspace()).showWindow(nil)
  }

  /// The app outlives its last window (see above), so clicking the Dock icon — or otherwise
  /// reopening — with nothing on screen has to put a window back, or the app is stuck alive and
  /// invisible with no way in. With a window already up, let AppKit do its usual unminiaturize.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag { newWindow(nil) }
    return true
  }

  /// A directory arriving through `open` — the Standard Suite verb (`open POSIX file "…"`),
  /// a Finder drop, or Launch Services — opens as a repository in the front workspace window,
  /// the same move as File ▸ Open Repository.
  func application(_ application: NSApplication, open urls: [URL]) {
    let controller: WorkspaceWindowController
    if let existing = (NSApp.keyWindow?.windowController as? WorkspaceWindowController)
      ?? WorkspaceWindowController.all.first
    {
      controller = existing
    } else {
      controller = WorkspaceWindowController(workspace: Workspace())
      controller.showWindow(nil)
    }
    var opened: Worktree?
    for url in urls {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { continue }
      opened = controller.workspace.openRepository(url)
    }
    guard let opened else { return }
    controller.workspace.selectedWorktreeID = opened.id
    controller.reload()
  }

  private static func makeMainMenu() -> NSMenu {
    let main = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "About hukan",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    // The standard app-menu block AppKit runs for free once the hooks are set: the system
    // fills the Services submenu, and the hide/show trio is NSApplication's own.
    let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
    let servicesMenu = NSMenu(title: "Services")
    servicesItem.submenu = servicesMenu
    NSApplication.shared.servicesMenu = servicesMenu
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Hide hukan", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = appMenu.addItem(
      withTitle: "Hide Others",
      action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(
      withTitle: "Show All",
      action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit hukan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    // New Session is the primary act in a single-window design, so it takes the reflexive
    // ⌘N (lowercase "n"); New Window — the discouraged one — is demoted to ⌘⇧N (uppercase
    // "N" auto-adds shift). New Window keeps its nil-via-AppDelegate target, so it still
    // works with no window open; ⌘N (New Session) needs a window and disables without one,
    // which is the rarer state.
    fileMenu.addItem(
      withTitle: "New Session", action: #selector(WorkspaceWindowController.newSession(_:)),
      keyEquivalent: "n")
    fileMenu.addItem(
      withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "N")
    fileMenu.addItem(
      withTitle: "Open Repository…",
      action: #selector(WorkspaceWindowController.openRepository(_:)), keyEquivalent: "O")
    fileMenu.addItem(.separator())
    // Save the edited source file. Only the Source pane is editable, so this is disabled unless
    // an edit is pending; plain ⌘S, since Hide Sidebar took ⌃⌘S.
    fileMenu.addItem(
      withTitle: "Save", action: #selector(WorkspaceWindowController.saveFile(_:)),
      keyEquivalent: "s")
    fileMenu.addItem(.separator())
    // ⌘W closes the active tab on the worktree's desk — a terminal for now, web/file tabs later —
    // and disables when the file surface is showing (nothing to close). Close Window sits at ⌘⇧W
    // (uppercase "W") to leave ⌘W that room. Close Repository, the deliberate open/close unit,
    // carries no key equivalent: it is a rail action (right-click a repository) the way Zed
    // removes a folder from its project panel, kept in this menu only for discoverability.
    fileMenu.addItem(
      withTitle: "Close Tab", action: #selector(WorkspaceWindowController.closeTab(_:)),
      keyEquivalent: "w")
    fileMenu.addItem(
      withTitle: "Close Repository",
      action: #selector(WorkspaceWindowController.closeRepository(_:)), keyEquivalent: "")
    fileMenu.addItem(
      withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
    fileItem.submenu = fileMenu
    main.addItem(fileItem)

    // Without an Edit menu, ⌘C/⌘V/⌘X/⌘A have nowhere to route — the shortcuts are matched
    // against menu items — so nothing copies or pastes anywhere, transcript or composer. These
    // use the standard responder-chain selectors (nil target), so they reach whichever text
    // view is focused.
    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenu.addItem(.separator())
    // Find in the active tab (the file's own bar). The tag is the sender field
    // performFindPanelAction reads — showFindPanel opens the bar. Targets the controller so it
    // stays clear of the rail's session search.
    let find = editMenu.addItem(
      withTitle: "Find", action: #selector(WorkspaceWindowController.find(_:)),
      keyEquivalent: "f")
    find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
    // Both land on the files panel's one field; they differ in which of its two operations runs —
    // ⌘P leaves it filtering the tree by path, ⌘⇧F searches the files' contents (what Return in
    // the field does). Neither opens a surface of its own.
    editMenu.addItem(
      withTitle: "Go to File…", action: #selector(WorkspaceWindowController.goToFile(_:)),
      keyEquivalent: "p")
    editMenu.addItem(
      withTitle: "Find in Files…", action: #selector(WorkspaceWindowController.findInFiles(_:)),
      keyEquivalent: "F")
    editItem.submenu = editMenu
    main.addItem(editItem)

    // The toggles' titles here are placeholders: WorkspaceWindowController.validateMenuItem
    // rewrites each to name the action it would perform ("Hide Sidebar" ⇄ "Show Sidebar"), so the
    // menu reads the current state instead of a both-ways slash.
    let viewItem = NSMenuItem()
    let viewMenu = NSMenu(title: "View")
    // One column alone, with every other folded away — the coarsest of the three, so it opens
    // the menu. ⌃⌘ is this menu's family: what the window is showing. Which column it means is
    // where the focus is (the validator names it), so the tab and the conversation share the key
    // rather than the second one taking a modifier of its own.
    let maximize = viewMenu.addItem(
      withTitle: "Maximize Tab",
      action: #selector(WorkspaceWindowController.toggleMaximize(_:)), keyEquivalent: "m")
    maximize.keyEquivalentModifierMask = [.command, .control]
    // The files panel docks on the desk's trailing edge; ⌘⇧E is the key editors give it.
    let filesPanel = viewMenu.addItem(
      withTitle: "Hide Files",
      action: #selector(WorkspaceWindowController.toggleFilesPanel(_:)), keyEquivalent: "E")
    filesPanel.keyEquivalentModifierMask = [.command, .shift]
    viewMenu.addItem(.separator())
    let sidebar = viewMenu.addItem(
      withTitle: "Hide Sidebar",
      action: #selector(WorkspaceWindowController.toggleRail(_:)), keyEquivalent: "s")
    sidebar.keyEquivalentModifierMask = [.command, .control]
    viewMenu.addItem(.separator())
    // AppKit owns items wired to toggleFullScreen: — it retitles Enter/Exit itself.
    let fullScreen = viewMenu.addItem(
      withTitle: "Enter Full Screen",
      action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    fullScreen.keyEquivalentModifierMask = [.command, .control]
    viewItem.submenu = viewMenu
    main.addItem(viewItem)

    // The app-specific menu, between View and Window. Allow/Deny make an approval answerable
    // without the mouse — ⌘⏎ lands on the session that is waiting, ⇧⌘⏎ allows, and ⌘. (the
    // standard cancel key) denies. The card's buttons stay as the visible, clickable surface.
    let sessionItem = NSMenuItem()
    let sessionMenu = NSMenu(title: "Session")
    sessionMenu.addItem(
      withTitle: "Go to Next Pending",
      action: #selector(WorkspaceWindowController.focusNextPending(_:)), keyEquivalent: "\r")
    sessionMenu.addItem(.separator())
    let allow = sessionMenu.addItem(
      withTitle: "Allow",
      action: #selector(WorkspaceWindowController.allowPendingApproval(_:)), keyEquivalent: "\r")
    allow.keyEquivalentModifierMask = [.command, .shift]
    sessionMenu.addItem(
      withTitle: "Deny",
      action: #selector(WorkspaceWindowController.denyPendingApproval(_:)), keyEquivalent: ".")
    sessionMenu.addItem(.separator())
    sessionMenu.addItem(
      withTitle: "Interrupt", action: #selector(WorkspaceWindowController.interruptSession(_:)),
      keyEquivalent: "")
    sessionItem.submenu = sessionMenu
    main.addItem(sessionItem)

    // One window by design, but the Window menu still carries Minimize/Zoom for keyboard
    // access, and registering it as windowsMenu lets AppKit append the open-windows list.
    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(
      withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowMenu.addItem(.separator())
    // Walk the desk's tabs (files) with ⌃⇥ / ⌃⇧⇥ — the Tab key carries
    // Control so it beats focus traversal, and enables only when there is more than one tab.
    let nextTab = windowMenu.addItem(
      withTitle: "Select Next Tab",
      action: #selector(WorkspaceWindowController.selectNextTab(_:)), keyEquivalent: "\t")
    nextTab.keyEquivalentModifierMask = [.control]
    let previousTab = windowMenu.addItem(
      withTitle: "Select Previous Tab",
      action: #selector(WorkspaceWindowController.selectPreviousTab(_:)), keyEquivalent: "\t")
    previousTab.keyEquivalentModifierMask = [.control, .shift]
    // ⌘1…⌘9 pick the Nth tab of the strip. Nine items would bury Minimize and Zoom, so they sit
    // in a submenu — a key equivalent still matches from inside one — and the menu stays a line.
    let selectTab = NSMenuItem(title: "Select Tab", action: nil, keyEquivalent: "")
    let selectTabMenu = NSMenu(title: "Select Tab")
    for n in 1...9 {
      let item = selectTabMenu.addItem(
        withTitle: "Tab \(n)",
        action: #selector(WorkspaceWindowController.selectTabAtIndex(_:)), keyEquivalent: "\(n)")
      item.tag = n
    }
    selectTab.submenu = selectTabMenu
    windowMenu.addItem(selectTab)
    windowMenu.addItem(.separator())
    windowMenu.addItem(
      withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)),
      keyEquivalent: "")
    windowItem.submenu = windowMenu
    main.addItem(windowItem)
    NSApplication.shared.windowsMenu = windowMenu

    return main
  }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
