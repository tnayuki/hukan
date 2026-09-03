import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  func applicationWillFinishLaunching(_ notification: Notification) {
    // Wind libgit2 up before window restoration, which runs next and asks git about its
    // worktrees. Every git query hukan makes goes through libgit2 in-process — no subprocess.
    Git.initialize()

    // Which Space a restored window comes back to is AppKit's to decide, and it only asks the
    // question when this default says so — off, every window lands on whichever Space happens
    // to be in front, which is why quitting an app scatters across Spaces and gathers into one.
    // The saved state carries the Space either way; this is the switch on reading it back.
    // Registered rather than written, so a hand-set value still wins.
    //
    // And whether there is any saved state to read back at all is the System Settings checkbox
    // "Close windows when quitting an application", which is one switch over every app on the
    // machine — turned on for the sake of some other app, it takes hukan's window, its columns,
    // its worktrees and its web tabs with it. A window holding a morning's worth of parallel
    // agents is not a document another app's preference gets to decide about, so hukan asks for
    // the restoring side of it by name. Registered too, so the answer is a default and not a
    // decision: setting the key by hand in hukan's own domain still wins.
    UserDefaults.standard.register(defaults: [
      "NSWindowRestoresWorkspaceAtLaunch": true,
      "NSQuitAlwaysKeepsWindows": true,
    ])
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

    // `hukan ~/src/foo ~/src/bar` opens with those paths — the same resolution as a Finder
    // drop or the `edit` verb: a directory lands in the worktree containing it, a file opens
    // as a tab (see `openPath`).
    let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
    if !paths.isEmpty, let controller = WorkspaceWindowController.all.first {
      for path in paths {
        controller.openPath(URL(fileURLWithPath: path))
      }
    }

    // Restoration is finished by now, so the restored windows finally know how wide their
    // columns were left.
    WorkspaceWindowController.hasFinishedLaunching = true
    for controller in WorkspaceWindowController.all { controller.arrangeColumnsIfNeeded() }

    // Ask once, so an agent that blocks on you while the app sits in the background can pull
    // you back. No-op unless we are running from a real .app bundle.
    SessionNotifier.shared.requestAuthorization()

    // Ask the tap whether a newer hukan is being distributed — once now, then hourly. Release
    // builds only; see `AppUpdate`.
    AppUpdate.shared.start()

    NSApp.activate(ignoringOtherApps: true)
  }

  /// Quitting closes every window, so it owes every unsaved edit the prompt a closing tab gets —
  /// hukan keeps no copy of an unsaved buffer, and the tab that comes back after a relaunch comes
  /// back on the file as it stands on disk. A Cancel anywhere stops the quit where it stands; the
  /// windows already answered for keep whatever their answer wrote.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    for controller in WorkspaceWindowController.all where !controller.confirmClosingWindow() {
      return .terminateCancel
    }
    return .terminateNow
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
    // The sessions being deleted are in it too: their engines are mid-exit, and one nobody
    // closes is orphaned exactly like any other — while the unlink each is waiting for has to
    // land before we go, or the conversation is back on the rail next launch.
    let sessions = WorkspaceWindowController.all.flatMap {
      $0.workspace.sessions + $0.workspace.closingSessions
    }
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
    // The engines are gone, so what was waiting on their exit is due — `onExit` cannot deliver
    // it, its main-queue hop having no runloop to land on inside this synchronous deadline.
    for session in sessions { session.completePendingStop() }
  }

  /// Opt into secure coding for restorable state. Not returning true warns, and it also
  /// states the constraint: only strings, numbers and arrays survive restoration.
  /// Ask the tap now rather than waiting for the hour to turn.
  ///
  /// The check runs by itself and a 304 costs no body, so this is not what keeps the answer
  /// current — it is the way to *make* it current at the moment you thought to wonder, without
  /// hukan having to grow a second place that states what the toolbar already states. Where the
  /// answer goes is unchanged: the arrow appears if there is a release ahead, and nothing appears
  /// if there is not.
  @objc func checkForUpdates(_ sender: Any?) {
    AppUpdate.shared.check()
  }

  /// Disabled while a check is in flight, so pressing it twice does not read as though the first
  /// press had missed — and on a build the cask cannot be talking about, which is a Debug one:
  /// see `AppUpdate.isApplicable`.
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard menuItem.action == #selector(checkForUpdates(_:)) else { return true }
    return AppUpdate.isApplicable && !AppUpdate.shared.isChecking
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  /// Open a fresh, empty workspace window. Reached from File ▸ New Window (⌘N) and from the
  /// reopen handler below. A new Workspace carries no repositories — the window opens empty and
  /// Open Repository fills it — which is right: it is a new desk, not a copy of another one.
  @objc func newWindow(_ sender: Any?) {
    WorkspaceWindowController(workspace: Workspace()).showWindow(nil)
  }

  /// Open Recent ▸ Clear Menu. App-global, like the list itself, so it lives here rather than on a
  /// window — and it still answers with no window open, which is where a menu the user is tidying
  /// may well be reached from.
  @objc func clearRecentRepositories(_ sender: Any?) {
    RecentRepositories.shared.clear()
  }

  /// The app outlives its last window (see above), so clicking the Dock icon — or otherwise
  /// reopening — with nothing on screen has to put a window back, or the app is stuck alive and
  /// invisible with no way in. With a window already up, let AppKit do its usual unminiaturize.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag { newWindow(nil) }
    return true
  }

  /// A path arriving through `open` — the Standard Suite verb (`open POSIX file "…"`), a
  /// Finder drop, or Launch Services — lands through `openPath`: a directory in the worktree
  /// containing it (its repository opening first when none does), a file as a tab.
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
    // Files included — one dropped on the Dock used to be swallowed with a clean exit, which
    // read as "nothing happened". `openPath` selects and reloads as it goes; a path that does
    // not exist is the one thing it declines.
    for url in urls {
      controller.openPath(url)
    }
  }

  /// The whole menu, built once at launch. Not private so a test can walk it: what keys are
  /// spent, and on what, is a decision this file is the only record of — the README and CLAUDE.md
  /// deliberately carry no table of them — so the one thing worth asserting is that no two items
  /// have been given the same one.
  static func makeMainMenu() -> NSMenu {
    let main = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "About hukan",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    // Under About, the block that names the app itself, since the question it asks is about which
    // hukan this is. No ellipsis: nothing opens — the answer lands in the toolbar, an arrow if
    // there is one to show and nothing if there is not.
    appMenu.addItem(
      withTitle: "Check for Updates", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
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
    // Beside the panel it saves a trip through, and offered again on the rail's right-click and in
    // the empty state — the same three places Open Repository… is reached from. No key equivalent:
    // it is a submenu, and the entries under it are not stable enough to bind.
    let recent = fileMenu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
    recent.submenu = RecentRepositoriesMenu(title: "Open Recent")
    fileMenu.addItem(.separator())
    // Both are a worktree's, so both need one selected and disable without it. ⌘T is the
    // browser's: hukan's shell work is the agent's, so the terminal a person opens by hand is the
    // occasional one, while a task's issue, PR and docs breed tabs by simply being followed. That
    // also makes ⌘T mean what it means everywhere else — this really is a new browser tab — and
    // leaves the rest of the desk's vocabulary (⌘W, ⌘1…⌘9, ⌃⇥) reading as a browser's. The terminal
    // takes ⌃⌘T: ⇧⌘T stays free, because beside a browser tab it means reopen the closed one, and
    // spending it on a terminal would take that key from the desk for good.
    fileMenu.addItem(
      withTitle: "New Browser",
      action: #selector(WorkspaceWindowController.newBrowserTab(_:)), keyEquivalent: "t")
    let terminal = fileMenu.addItem(
      withTitle: "New Terminal", action: #selector(WorkspaceWindowController.newTerminal(_:)),
      keyEquivalent: "t")
    terminal.keyEquivalentModifierMask = [.command, .control]
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
    // Find inside whatever is being read — the conversation, or the desk's active tab (a file's
    // bar, a terminal's, the commit tab's field, the browser's). Which of the two it means is
    // where the focus is, the same rule ⌃⌘M follows for the column it maximizes. All four ride
    // one selector and differ only in the tag, which is the field every find bar reads its action
    // from; the controller is the target so the key never reaches a stray text field.
    for (title, key, action) in [
      ("Find", "f", NSFindPanelAction.showFindPanel),
      ("Find Next", "g", .next),
      ("Find Previous", "G", .previous),
      ("Use Selection for Find", "e", .setFindString),
    ] {
      let item = editMenu.addItem(
        withTitle: title, action: #selector(WorkspaceWindowController.find(_:)),
        keyEquivalent: key)
      item.tag = Int(action.rawValue)
    }
    editMenu.addItem(.separator())
    // One key per field, and ⏎ inside it does the rest. Each item names what *typing* in the
    // field does — narrow the tree by path, narrow the rail by title — because the escalation
    // ⏎ carries (search the contents, search the transcripts) is a gesture the field announces
    // itself while it has the focus. A menu item for it would be the same offer twice, which is
    // what ⌘⇧F was.
    editMenu.addItem(
      withTitle: "Go to File…", action: #selector(WorkspaceWindowController.goToFile(_:)),
      keyEquivalent: "p")
    editMenu.addItem(
      withTitle: "Go to Session…", action: #selector(WorkspaceWindowController.goToSession(_:)),
      keyEquivalent: "P")
    // Clear the active terminal's scrollback, where Terminal.app keeps its Cmd-K. Targets the
    // controller (not the responder chain), and disables unless a terminal is the active tab.
    editMenu.addItem(
      withTitle: "Clear Terminal",
      action: #selector(WorkspaceWindowController.clearTerminal(_:)), keyEquivalent: "k")
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
    // The files panel on the column's trailing edge. ⌘⇧E, where every editor puts its explorer.
    viewMenu.addItem(
      withTitle: "Hide Files",
      action: #selector(WorkspaceWindowController.toggleFilesPanel(_:)), keyEquivalent: "E")
    // The panel's other half, folded away or brought back. ⌘⇧L, next to ⌘⇧E for its neighbour.
    viewMenu.addItem(
      withTitle: "Hide History",
      action: #selector(WorkspaceWindowController.toggleHistorySection(_:)), keyEquivalent: "L")
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
    viewMenu.addItem(.separator())
    // A web tab's history. ⌘[ / ⌘], the keys Safari and Apple's shortcut list use; the arrow
    // keys are deliberately not here, so a text field on the page keeps ⌘←/→ as caret motion the
    // way Safari does. Both disable unless a web tab is showing with somewhere to go.
    viewMenu.addItem(
      withTitle: "Back", action: #selector(WorkspaceWindowController.browserGoBack(_:)),
      keyEquivalent: "[")
    viewMenu.addItem(
      withTitle: "Forward", action: #selector(WorkspaceWindowController.browserGoForward(_:)),
      keyEquivalent: "]")
    // The rest of the chrome's row under keys, and the group reads in the row's own order: back,
    // forward, reload, address. ⌘R is the browser's alone, which is a decision and not just what
    // Safari does — a web tab is the only tab on the desk with a manual re-read to give it, since
    // a file, the tree and the history all come back on the batch FSEvents hands them. The item
    // never becomes Stop the way the button does: a key that means reload or stop depending on
    // how far the page has got cannot be pressed without looking first, so stopping stays the
    // button's and Escape's. ⌘L is Safari's Open Location…, and it sits here rather than beside
    // Edit's ⌘P / ⌘⇧P — those two aim at the window's own indexes, where this field goes out to
    // the network, so it belongs with the tab it drives.
    //
    // All four are menu items where ⌃⇥ needed a key monitor, and the difference is not that the
    // page is out of the way: a focused web view answers yes to *every* ⌘-key put to it (measured
    // — ⌘R, ⌘L, ⌘[, ⌘], ⌘N alike), because it can only ask the web process what the page wants
    // and it re-dispatches whatever came back unwanted. What is actually lost that way is a key
    // the page really uses, and Tab is one of those where these are not.
    viewMenu.addItem(
      withTitle: "Reload", action: #selector(WorkspaceWindowController.browserReload(_:)),
      keyEquivalent: "r")
    viewMenu.addItem(
      withTitle: "Open Location…",
      action: #selector(WorkspaceWindowController.browserFocusAddress(_:)), keyEquivalent: "l")
    viewMenu.addItem(.separator())
    // The page zoom the keys were reserved for. ⌘+ is the key a person means and ⌘= is the key
    // they press — on a US layout the plus is a shifted equals, and on a JIS one it is somewhere
    // else again — so Zoom In is offered twice, the second hidden and kept live for its key
    // alone. Actual Size is not a walk back along the ladder: it is the rung marked 1.
    viewMenu.addItem(
      withTitle: "Zoom In", action: #selector(WorkspaceWindowController.zoomIn(_:)),
      keyEquivalent: "+")
    let zoomInEquals = viewMenu.addItem(
      withTitle: "Zoom In", action: #selector(WorkspaceWindowController.zoomIn(_:)),
      keyEquivalent: "=")
    zoomInEquals.isHidden = true
    zoomInEquals.allowsKeyEquivalentWhenHidden = true
    viewMenu.addItem(
      withTitle: "Zoom Out", action: #selector(WorkspaceWindowController.zoomOut(_:)),
      keyEquivalent: "-")
    viewMenu.addItem(
      withTitle: "Actual Size",
      action: #selector(WorkspaceWindowController.actualSize(_:)), keyEquivalent: "0")
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
    // Walk the desk's tabs (files, browsers, terminals) with ⌃⇥ / ⌃⇧⇥ — the Tab key carries
    // Control so it beats focus traversal, and enables only when there is more than one tab.
    // The keystroke itself is matched by the window controller's key-down monitor, not here;
    // these items are how it is found and what it is labelled (see `tabCyclingMonitor`).
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
    // ⌘0 is left alone: the desk's plain ⌘T is a browser tab now, so ⌘0/⌘+/⌘− belong to its zoom.
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
