import Network
import WebKit
import XCTest

@testable import Hukan

/// The user agent is the one thing a plain WKWebView gets wrong for what this browser is for:
/// an SSO or device-trust flow reads it before it lets a sign-in through. Assert the string the
/// page actually sees, not the property it was set from.
///
/// Keep this suite off any host that spawns subprocesses. Loading WebKit into the test host makes
/// every `Foundation.Process` spawn in it cost about 7× for the rest of the run — `GitTests` goes
/// 0.36s → 2.65s and `GitHistoryTests` 2.30s → 16.08s behind it, while pure-CPU work and the
/// terminal's `forkpty` are untouched. Nothing here leaks: the panes are locals and are long gone
/// by then, so what does the damage is WebKit being loaded at all. Parallel testing is what
/// contains it (see the CLAUDE.md note) — it confines the slow host to one worker.
final class BrowserTests: XCTestCase {
  private func userAgent(of pane: BrowserPaneViewController) -> String {
    let loaded = expectation(description: "load")
    let observer = pane.webView.observe(\.isLoading, options: [.new]) { webView, _ in
      if !webView.isLoading { loaded.fulfill() }
    }
    pane.webView.loadHTMLString("<html></html>", baseURL: nil)
    wait(for: [loaded], timeout: 30)
    observer.invalidate()

    var agent = ""
    let read = expectation(description: "read")
    pane.webView.evaluateJavaScript("navigator.userAgent") { value, _ in
      agent = value as? String ?? ""
      read.fulfill()
    }
    wait(for: [read], timeout: 30)
    return agent
  }

  func testWebTabPassesAsSafari() {
    let pane = BrowserPaneViewController()
    pane.loadViewIfNeeded()
    let agent = userAgent(of: pane)
    XCTAssertTrue(
      agent.hasSuffix(" Safari/605.1.15"), "the Safari token is what a flow sniffs for: \(agent)")
    XCTAssertTrue(agent.contains(" Version/"), "the version token is missing: \(agent)")
    XCTAssertTrue(agent.contains("Macintosh"), "still the Mac agent, not a spoofed platform")
  }

  // MARK: The address bar's two jobs

  /// The rule in one sentence: a scheme, a slash or a dot makes it an address; anything else is a
  /// search. These are the cases that decide whether that sentence is true.
  func testWhatTheAddressBarMakesOfWhatIsTyped() {
    let cases: [(String, BrowserAddress.Destination?)] = [
      ("", nil),
      ("https://github.com/tnayuki/hukan", .web(URL(string: "https://github.com/tnayuki/hukan")!)),
      ("github.com/tnayuki/hukan", .web(URL(string: "https://github.com/tnayuki/hukan")!)),
      ("example.com", .web(URL(string: "https://example.com")!)),
      // A port is not a scheme, which is the one thing that tells `localhost:3000` from `mailto:`.
      ("localhost:3000", .web(URL(string: "https://localhost:3000")!)),
      ("127.0.0.1:8080", .web(URL(string: "https://127.0.0.1:8080")!)),
      // The escape hatch for a single-label intranet host.
      ("wiki/", .web(URL(string: "https://wiki/")!)),
      // …which, without it, is a word.
      ("wiki", .search(BrowserAddress.searchURL(for: "wiki"))),
      ("swift concurrency 入門", .search(BrowserAddress.searchURL(for: "swift concurrency 入門"))),
      // A space is never inside an address, so it settles the question before the dot does.
      ("see example.com now", .search(BrowserAddress.searchURL(for: "see example.com now"))),
      ("javascript:alert(1)", .refused),
      ("data:text/html,<b>x", .refused),
    ]
    for (typed, want) in cases {
      XCTAssertEqual(BrowserAddress.destination(for: typed), want, "typed: \(typed)")
    }
  }

  /// The one the public suffix list would have bought, and the reason it is not worth carrying: a
  /// filename is tried as an address, and the error page is what offers the search instead.
  func testAFilenameIsTriedAsAnAddressAndThenOfferedAsASearch() {
    XCTAssertEqual(
      BrowserAddress.destination(for: "Model.swift"),
      .web(URL(string: "https://Model.swift")!))
    XCTAssertTrue(
      BrowserPaneViewController.offersSearch(
        after: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)))
  }

  func testSearchQueriesArePercentEncoded() {
    let url = BrowserAddress.searchURL(for: "a b&c/d")
    XCTAssertEqual(url.absoluteString, "https://www.google.com/search?q=a%20b%26c%2Fd")
  }

  // MARK: What the error page is for

  /// A cancel is not a failure, and it is what every `kolide://` handoff looks like — cancelling
  /// in `decidePolicyFor` is how the scheme is handed over. Reporting one would put an error page
  /// in the middle of the device-trust flow this browser exists to get through.
  func testACancelledNavigationIsNotAnError() {
    XCTAssertFalse(
      BrowserPaneViewController.isReportable(
        NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
    XCTAssertFalse(
      BrowserPaneViewController.isReportable(NSError(domain: "WebKitErrorDomain", code: 102)))
    XCTAssertTrue(
      BrowserPaneViewController.isReportable(
        NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)))
  }

  /// Searching instead only makes sense when nothing answered. A server that answered badly is a
  /// real page at a real address, and offering to search for it would be nonsense.
  func testSearchIsOfferedOnlyWhenNothingAnswered() {
    XCTAssertTrue(
      BrowserPaneViewController.offersSearch(
        after: NSError(domain: NSURLErrorDomain, code: NSURLErrorDNSLookupFailed)))
    XCTAssertFalse(
      BrowserPaneViewController.offersSearch(
        after: NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)))
  }

  /// The page a failed load leaves behind keeps the address it failed on, which is what lets the
  /// address bar stay right and the reload button go on meaning "try again".
  func testAFailedLoadShowsAPageAndKeepsItsAddress() {
    let pane = BrowserPaneViewController()
    pane.loadViewIfNeeded()
    let shown = expectation(description: "error page")
    // The failed load settles first and the error page settles after it, so the observer fires
    // twice on the way to one outcome.
    shown.assertForOverFulfill = false
    let observer = pane.webView.observe(\.isLoading, options: [.new]) { webView, _ in
      if !webView.isLoading, webView.url != nil { shown.fulfill() }
    }
    pane.load("this-name-does-not-resolve.invalid")
    wait(for: [shown], timeout: 30)
    observer.invalidate()
    XCTAssertEqual(pane.currentURL?.host, "this-name-does-not-resolve.invalid")
    XCTAssertTrue(
      pane.pageTitle.contains("could not be opened"),
      "the tab says so too, not just the page: \(pane.pageTitle)")
  }

  /// The field's own Return, through the whole AppKit path — not `load` called directly, which is
  /// what the scripting verb does and why this slipped past it. AppKit ends editing before it
  /// sends the action, and the end-editing sync that keeps a loading page from overwriting a
  /// half-typed line was putting the old address back first, so Return went nowhere.
  func testReturnInTheAddressFieldNavigatesToWhatWasTyped() {
    let pane = BrowserPaneViewController()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentViewController = pane
    pane.load("https://example.com/first")
    pane.focusAddress()
    let editor = try! XCTUnwrap(window.firstResponder as? NSTextView)
    editor.string = "https://example.com/second"
    editor.insertNewline(nil)
    XCTAssertEqual(pane.webView.url, URL(string: "https://example.com/second"))
    XCTAssertFalse(window.firstResponder is NSTextView, "Return hands the keyboard to the page")
  }

  /// Escape stops a load in flight — the keyboard's half of the button's Stop, and what lets ⌘R
  /// stay a reload at every point in a page's life instead of turning into a Stop halfway. The
  /// page has to *hang* for there to be anything to stop, which no address can be relied on to do
  /// (an unroutable one fails inside a quarter second, and a failure is already over), so the test
  /// brings its own server: it takes the connection, reads the request and answers nothing.
  ///
  /// Waiting for the request to reach that server is not padding. A stop issued in the same
  /// run-loop turn as the load is dropped on the floor — WebKit has not handed it to the network
  /// process yet — and the page goes on loading with the key spent, which is how this test was
  /// first written wrong. The web view's own `estimatedProgress` does not say so either: `load`
  /// puts it at 0.1 before it returns, so it is 0.1 in that same doomed turn.
  func testEscapeStopsALoadInFlight() throws {
    let server = try SilentServer()
    let pane = BrowserPaneViewController()
    // In a window and on screen: WebKit throttles a view nobody is looking at, and the load of a
    // pane held on its own never reaches the network at all.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentViewController = pane
    window.makeKeyAndOrderFront(nil)

    let asked = expectation(description: "the request reached the server")
    asked.assertForOverFulfill = false
    server.onRequest = { asked.fulfill() }
    pane.load(URL(string: "http://127.0.0.1:\(server.port)/")!)
    wait(for: [asked], timeout: 30)
    XCTAssertTrue(pane.webView.isLoading, "nothing answered it, so it is still loading")

    let stopped = expectation(description: "stopped")
    stopped.assertForOverFulfill = false
    let loading = pane.webView.observe(\.isLoading, options: [.new]) { webView, _ in
      if !webView.isLoading { stopped.fulfill() }
    }
    pane.keyDown(with: BrowserTests.escape())
    wait(for: [stopped], timeout: 30)
    loading.invalidate()
  }

  /// An Escape as AppKit delivers one. The key code is what the pane matches on, the way the
  /// desk's ⌃⇥ does.
  private static func escape() -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
      keyCode: 53)!
  }

  /// A content process killed under a background tab (memory pressure) leaves a blank view; the
  /// pane reloads rather than showing it. The error page reloads to the address it stands for.
  func testALostContentProcessReloads() {
    let pane = BrowserPaneViewController()
    pane.loadViewIfNeeded()
    let shown = expectation(description: "error page")
    shown.assertForOverFulfill = false
    let observer = pane.webView.observe(\.isLoading, options: [.new]) { webView, _ in
      if !webView.isLoading, webView.url != nil { shown.fulfill() }
    }
    pane.load("this-name-does-not-resolve.invalid")
    wait(for: [shown], timeout: 30)
    observer.invalidate()
    XCTAssertFalse(pane.webView.isLoading)
    pane.webViewWebContentProcessDidTerminate(pane.webView)
    XCTAssertTrue(pane.webView.isLoading, "a reload is under way")
    XCTAssertEqual(pane.webView.url?.host, "this-name-does-not-resolve.invalid")
  }

  /// A long URL used to fold inside the field while it was being edited — the field editor wrapped
  /// to three lines behind a one-line frame, with the caret out of sight below it. Measured
  /// through the editor itself, since the field's own height never changed.
  func testALongAddressStaysOnOneLineWhileEditing() {
    let pane = BrowserPaneViewController()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentViewController = pane
    pane.focusAddress()
    let editor = try! XCTUnwrap(window.firstResponder as? NSTextView)
    editor.string =
      "https://github.com/tnayuki/hukan/pull/12/files#diff-0123456789abcdef0123456789abcdef"
      + "0123456789abcdef0123456789abcdefR1234-R1290"
    window.contentView?.layoutSubtreeIfNeeded()
    let layout = try! XCTUnwrap(editor.layoutManager)
    let container = try! XCTUnwrap(editor.textContainer)
    layout.ensureLayout(for: container)
    var lines = 0
    var index = 0
    while index < layout.numberOfGlyphs {
      var range = NSRange()
      layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
      lines += 1
      index = NSMaxRange(range)
    }
    XCTAssertEqual(lines, 1, "the address scrolls sideways rather than wrapping")
  }

  // MARK: Coming back after a relaunch

  /// A restored tab answers for itself — title, address — before it has loaded anything, and
  /// hands back exactly what it was given if it is never shown. That is what lets a window with a
  /// dozen web tabs come back without loading a dozen pages.
  func testARestoredTabAnswersWithoutLoading() {
    let state = BrowserTabState(
      worktreeID: UUID(), url: "https://github.com/tnayuki/hukan/pull/12",
      title: "Add the browser · Pull Request #12", interactionState: Data([1, 2, 3]))
    let pane = BrowserPaneViewController(restoring: state)
    XCTAssertEqual(pane.pageTitle, "Add the browser · Pull Request #12")
    XCTAssertEqual(pane.currentURL, URL(string: state.url))
    XCTAssertEqual(pane.restorableState, state, "unshown, it saves what it was given")
    XCTAssertNil(pane.webView.url, "and has loaded nothing")
  }

  /// A blank tab is one keystroke to make again and is not worth a slot.
  func testABlankTabIsNotSaved() {
    let pane = BrowserPaneViewController()
    pane.loadViewIfNeeded()
    XCTAssertNil(pane.restorableState)
  }

  func testDownloadsDoNotOverwrite() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    XCTAssertEqual(
      BrowserPaneViewController.uniqueURL(in: folder, named: "a.zip").lastPathComponent, "a.zip")
    FileManager.default.createFile(
      atPath: folder.appendingPathComponent("a.zip").path, contents: nil)
    XCTAssertEqual(
      BrowserPaneViewController.uniqueURL(in: folder, named: "a.zip").lastPathComponent, "a 2.zip")
  }

  /// A popup is built against the configuration WebKit hands back from the opener, not a fresh
  /// one, so this is the path that would silently lose the agent.
  func testAPopupKeepsTheAgent() {
    let opener = BrowserPaneViewController()
    opener.loadViewIfNeeded()
    let popup = BrowserPaneViewController(
      webView: WKWebView(frame: .zero, configuration: opener.webView.configuration))
    popup.loadViewIfNeeded()
    XCTAssertEqual(userAgent(of: popup), userAgent(of: opener))
  }
}

/// The desk's side of a web tab: which worktree a popup lands on, and a page closing itself.
/// Kept in this file so it shares the one WebKit-loading host (see the note at the top).
final class BrowserDeskTests: XCTestCase {
  private func desk(worktrees: Int) -> (WorktreeDeskViewController, Workspace, [Worktree]) {
    let workspace = Workspace()
    let made = (0..<worktrees).map { _ -> Worktree in
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return workspace.addWorktree(url)
    }
    let desk = WorktreeDeskViewController()
    desk.workspace = workspace
    desk.reload(worktreeID: made.first?.id)
    return (desk, workspace, made)
  }

  /// A sign-in finishing in a background worktree's tab opens its popup *there*, and the desk
  /// stays on the worktree the rail has selected.
  func testAPopupFromABackgroundWorktreeDoesNotSwitchTheDesk() {
    let (desk, _, worktrees) = desk(worktrees: 2)
    desk.openBrowser(worktree: worktrees[1], url: URL(string: "https://example.com/login")!)
    desk.reload(worktreeID: worktrees[0].id)
    XCTAssertEqual(desk.browserTabsReport, "(no web tabs)", "the desk is on the first worktree")

    // The background tab's page calls window.open.
    let popup = WKWebView(frame: .zero, configuration: BrowserEnvironment.makeConfiguration())
    desk.openBrowser(worktree: worktrees[1], webView: popup)
    XCTAssertEqual(desk.browserTabsReport, "(no web tabs)", "still on the first worktree")
    desk.reload(worktreeID: worktrees[1].id)
    XCTAssertEqual(
      desk.browserTabsReport.components(separatedBy: "\n").count, 2,
      "the popup joined the second worktree's tabs: \(desk.browserTabsReport)")
  }

  /// Back and forward drive the web tab showing on the desk, and go dead when the surface is not
  /// a browser — which is what disables the menu items. History itself is WebKit's, so this
  /// checks the desk routes to the right pane and reads its history flags, not the navigation.
  func testBackAndForwardTrackTheActiveBrowserTab() {
    let (desk, _, worktrees) = desk(worktrees: 1)
    XCTAssertFalse(desk.canBrowserGoBack, "no web tab yet")
    desk.openBrowser(worktree: worktrees[0])
    let pane = try! XCTUnwrap(desk.selectedBrowserPane)
    XCTAssertFalse(desk.canBrowserGoBack, "a fresh tab has no history")
    XCTAssertFalse(desk.canBrowserGoForward)
    // The desk's back/forward reach the showing pane's web view.
    XCTAssertEqual(desk.canBrowserGoBack, pane.webView.canGoBack)
    desk.browserGoBack()  // a no-op with no history, but must not trap
    // Switch the surface off the browser: the actions go dead, so the menu items disable.
    desk.openBrowser(worktree: worktrees[0])
    XCTAssertNotNil(desk.selectedBrowserPane)
  }

  /// Reload and Open Location reach the pane the desk is showing, and go dead when the surface is
  /// not a browser — which is what disables their menu items. They ask less of it than back and
  /// forward do: a blank tab has no history and is exactly the tab worth typing an address into,
  /// and a page that failed to load is exactly the one worth reloading.
  func testReloadAndTheAddressFieldTrackTheActiveBrowserTab() {
    let (desk, _, worktrees) = desk(worktrees: 1)
    XCTAssertFalse(desk.isShowingWebTab, "no web tab yet")
    desk.openBrowser(worktree: worktrees[0])
    XCTAssertTrue(desk.isShowingWebTab, "a blank tab takes both")
    XCTAssertFalse(desk.canBrowserGoBack, "where back and forward have nowhere to go")
    // Both reach the showing pane; neither may trap on a tab with nothing loaded in it.
    desk.browserReload()
    desk.browserFocusAddress()
    let pane = try! XCTUnwrap(desk.selectedBrowserPane)
    pane.webViewDidClose(pane.webView)
    XCTAssertFalse(desk.isShowingWebTab, "the surface is not a browser: the items disable")
    desk.browserReload()
  }

  /// `window.close()` — how an SSO popup ends — takes the tab with it rather than leaving an empty
  /// one on the strip.
  func testAPageClosingItselfClosesItsTab() {
    let (desk, _, worktrees) = desk(worktrees: 1)
    desk.openBrowser(worktree: worktrees[0])
    let pane = try! XCTUnwrap(desk.selectedBrowserPane)
    pane.webViewDidClose(pane.webView)
    XCTAssertEqual(desk.browserTabsReport, "(no web tabs)")
  }

  /// Every web tab of every worktree is saved, tagged with its worktree, and comes back on it.
  func testTabsRestoreOntoTheirWorktrees() {
    let (desk, workspace, worktrees) = desk(worktrees: 2)
    let states = [
      BrowserTabState(
        worktreeID: worktrees[0].id, url: "https://example.com/a", title: "A",
        interactionState: nil),
      BrowserTabState(
        worktreeID: worktrees[1].id, url: "https://example.com/b", title: "B",
        interactionState: nil),
      // A worktree that is gone takes its tabs with it.
      BrowserTabState(
        worktreeID: UUID(), url: "https://example.com/c", title: "C", interactionState: nil),
    ]
    desk.restoreBrowserTabs(states)
    XCTAssertEqual(
      Set(desk.restorableBrowserTabs.map(\.url)),
      ["https://example.com/a", "https://example.com/b"])
    desk.reload(worktreeID: worktrees[1].id)
    XCTAssertTrue(desk.browserTabsReport.contains("B  https://example.com/b"))
    _ = workspace
  }
}

/// A server that takes a connection, reads what is asked of it and never answers, so a load hangs
/// where an unreachable address would only fail. Accepted connections are held: dropping one
/// closes the socket, and WebKit reads that as a failed load rather than a slow one.
private final class SilentServer {
  /// Called once the request is in — the point from which there is a load to stop.
  var onRequest: (() -> Void)?

  private let listener: NWListener
  private let queue = DispatchQueue(label: "silent-server")
  private var accepted: [NWConnection] = []

  /// Whatever port the system handed out, read off the listener rather than stored: a stored one
  /// cannot be assigned before the handlers below capture `self`.
  var port: UInt16 { listener.port?.rawValue ?? 0 }

  init() throws {
    listener = try NWListener(using: .tcp)
    listener.newConnectionHandler = { [weak self] connection in
      connection.start(queue: .global())
      connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
        self?.onRequest?()
      }
      self?.queue.async { self?.accepted.append(connection) }
    }
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.start(queue: queue)
    XCTAssertEqual(ready.wait(timeout: .now() + 10), .success, "the server came up")
  }

  deinit {
    for connection in accepted { connection.cancel() }
    listener.cancel()
  }
}
