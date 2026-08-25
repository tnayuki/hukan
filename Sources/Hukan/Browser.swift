import AppKit
import WebKit

/// One shared cookie store for every web tab, in every worktree: the same login carries from an
/// issue page to its PR. The persistent default data store is what makes the session common — and
/// what keeps it across a relaunch. No process pool: it used to be set too, on the belief that it
/// was part of what shared the sign-in, and it never was — WebKit has managed its own processes
/// since macOS 12 (one per web view, measured) and the property is a no-op.
enum BrowserEnvironment {
  /// Pass as Safari. A plain WKWebView's user agent stops at `(KHTML, like Gecko)` — the
  /// `Version/… Safari/…` tokens Safari appends are missing — and that truncated string is what
  /// an SSO or device-trust flow reads to decide this is not a browser it will let through.
  /// Appending them makes the agent byte-identical to the Safari on this machine.
  ///
  /// The version is read from that Safari rather than pinned here, for the reason master data
  /// always is: a literal would rot into a claim about a Safari that shipped years ago, and
  /// nothing in hukan would notice.
  private static let applicationName: String = {
    let safari = Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))
    let version = safari?.infoDictionary?["CFBundleShortVersionString"] as? String
    return "Version/\(version ?? "26.0") Safari/605.1.15"
  }()

  static func makeConfiguration() -> WKWebViewConfiguration {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    // A popup arrives with a copy of its opener's configuration, so this carries to those too.
    config.applicationNameForUserAgent = applicationName
    return config
  }

  /// What a web view may keep navigating to. Anything else belongs to the system — a `kolide://`
  /// device-trust handoff, a `mailto:` — and is handed over rather than rendered.
  static func rendersInWebTab(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return ["http", "https", "about", "blob", "data", "file"].contains(scheme)
  }

  /// What may *open* a web tab from elsewhere in the window — a link in the transcript, a script.
  /// Not the same question as `rendersInWebTab`: a page already showing may carry on into `blob:`
  /// or `data:`, but a click in another column must never conjure a tab out of one, so this is
  /// the narrow half of the pair. Both tables live here so the two cannot drift apart.
  static func opensAsWebTab(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
  }
}

/// What a line typed into the address bar means. The field is an address bar and a search box at
/// once, and which one it is being read as is decided by the text, not by a gesture: the files
/// panel's field splits its two jobs by Return because one of them (a content search) costs far
/// more than the other, and a person has to choose. Here both jobs are one Return and one
/// request, and being wrong costs a back click — so nothing is gained by making anyone choose.
///
/// The rule is one sentence, which is what keeps it explicable the way the panel's plain
/// substring match is: **a scheme, a slash or a dot makes it an address; anything else is a
/// search.** No table of real TLDs stands behind it — carrying the public suffix list to know
/// that `.swift` is not one is far more than this is worth, so `Model.swift` is tried as an
/// address, fails to resolve, and the error page offers the search instead.
enum BrowserAddress {
  enum Destination: Equatable {
    /// Navigate here.
    case web(URL)
    /// The text was not an address; search the web for it.
    case search(URL)
    /// A scheme that exists to smuggle code past a person reading the bar. Never run from here.
    case refused
  }

  /// One constant, deliberately not a preference: hukan has no settings window, and the engines
  /// differ in nothing that matters to "the search you would otherwise have run in Safari".
  private static let searchPrefix = "https://www.google.com/search?q="

  static func searchURL(for text: String) -> URL {
    // Percent-encode everything outside the unreserved set. Encoding more than strictly needed
    // is always safe in a query value, where guessing which reserved character this particular
    // engine will re-parse is not.
    let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    let encoded = text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    return URL(string: searchPrefix + encoded) ?? URL(string: searchPrefix)!
  }

  /// `nil` for an empty line — the one input that means "do nothing".
  static func destination(for text: String) -> Destination? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lowered = trimmed.lowercased()
    if lowered.hasPrefix("javascript:") || lowered.hasPrefix("data:") { return .refused }
    // A space can never be inside an address, so it settles the question before anything else.
    if !trimmed.contains(" ") {
      if hasScheme(trimmed) {
        if let url = URL(string: trimmed), url.scheme != nil { return .web(url) }
      } else if looksLikeHost(trimmed), let url = URL(string: "https://\(trimmed)") {
        return .web(url)
      }
    }
    return .search(searchURL(for: trimmed))
  }

  /// A leading `scheme:`, but not a `host:port` — `localhost:3000` parses as the scheme
  /// `localhost` otherwise, and a bare port is the one thing that tells the two apart.
  private static func hasScheme(_ text: String) -> Bool {
    guard let colon = text.firstIndex(of: ":") else { return false }
    let scheme = text[text.startIndex..<colon]
    guard let first = scheme.first, first.isLetter,
      scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
    else { return false }
    let rest = text[text.index(after: colon)...]
    let port = rest.prefix { $0.isNumber }
    return port.isEmpty || port.count != rest.prefix(while: { $0 != "/" }).count
  }

  /// The part before the first slash has to look like a machine: a dot in it, or `localhost`.
  /// A slash is therefore the escape hatch for a single-label intranet host — `wiki/` is an
  /// address where `wiki` is a search.
  private static func looksLikeHost(_ text: String) -> Bool {
    let host = text.prefix { $0 != "/" }
    guard !host.isEmpty else { return false }
    if host.contains(".") { return true }
    if host.prefix(while: { $0 != ":" }) == "localhost" { return true }
    return host.count < text.count
  }
}

/// What a web tab keeps across a relaunch. Everything but the title is WebKit's own
/// `interactionState` — the back/forward list and where the current entry was scrolled to — held
/// opaque and stored as it comes; the title and URL ride beside it so the tab can be named, and
/// found again by address, before the page has loaded. Only a tab that got somewhere is worth a
/// slot: a blank new tab is one keystroke to make again.
struct BrowserTabState: Equatable {
  var worktreeID: UUID
  var url: String
  var title: String
  var interactionState: Data?
}

/// A web tab: a WKWebView under a slim chrome (back / forward / reload / address). Reading comes
/// first — this is the task's browser, an issue or a PR next to the work — so it stays deliberately
/// plain. What is wired is the host's side of WKWebView, which is not the same as the browser's:
/// the chrome is read off the view (a client-side navigation moves the address with nothing
/// committed), popups open as their own tab and close themselves, a page's file picker, dialogs,
/// downloads and authentication get the system's panels, and a non-web scheme (`kolide://`, a
/// device-trust handoff) is handed to the system.
final class BrowserPaneViewController: NSViewController, WKNavigationDelegate, WKUIDelegate,
  WKDownloadDelegate, NSSearchFieldDelegate
{
  /// The page retitled itself, or moved — relabel the tab, and mark the window's state stale.
  var onTitleChange: (() -> Void)?
  /// A popup (`target=_blank`, `window.open`) wants its own window; the desk turns it into a tab.
  /// Answers whether it could — a worktree that is gone has no desk to open on.
  var onOpenPopup: ((WKWebView) -> Bool)?
  /// The page closed itself (`window.close()`, which is how an SSO popup ends). The desk closes
  /// the tab, since a web view with nothing in it is not a tab anyone chose to keep.
  var onClose: (() -> Void)?

  private(set) var pageTitle = "New Tab"
  let webView: WKWebView
  private let address = NSTextField()
  private let back = NSButton()
  private let forward = NSButton()
  private let reload = NSButton()
  private let progress = NSView()
  private lazy var progressWidth = progress.widthAnchor.constraint(equalToConstant: 0)
  private let findField = NSSearchField()
  private let findLabel = NSTextField(labelWithString: "")
  private var observers: [NSKeyValueObservation] = []
  /// Downloads in flight. WebKit hands each one over and keeps no strong reference of its own.
  private var downloads: Set<WKDownload> = []

  /// What was typed to get here, kept only so the error page can offer to search for it as it was
  /// written — the failed URL has lowercased the host and prefixed a scheme by then.
  private var lastInput: String?
  /// The address the error page on screen is standing in for, so its Retry and Open in Safari have
  /// something to aim at. Nil whenever a real page is showing.
  private(set) var failedURL: URL?
  /// What the tab is called while that page is up. Taken from the failure rather than read back
  /// out of the page's `<title>`, so the strip says a load failed from the moment it did — the
  /// title round-trip lands a beat later, and a tab named after the host it could not reach is
  /// indistinguishable from one showing it.
  private var failureTitle: String?
  /// A restored tab's state, applied the first time the pane is shown rather than when the window
  /// comes back: a restored window may carry a dozen web tabs across its worktrees, and loading
  /// them all at launch is what a browser's session restore is known for. Until then the tab
  /// answers from the saved title and URL.
  private var pendingRestore: BrowserTabState?
  /// The title a restored tab was saved under, kept on the tab until the page reports its own —
  /// without it the strip renames every restored tab to a bare host name the moment it loads.
  private var restoredTitle: String?

  /// A fresh tab makes its own web view; a popup arrives already built against the shared
  /// configuration (WebKit requires the exact instance it handed us), so it is passed straight in.
  init(webView: WKWebView? = nil) {
    self.webView =
      webView ?? WKWebView(frame: .zero, configuration: BrowserEnvironment.makeConfiguration())
    super.init(nibName: nil, bundle: nil)
  }

  /// A tab coming back from the last run. Nothing loads until the pane is shown.
  convenience init(restoring state: BrowserTabState) {
    self.init()
    pendingRestore = state
    restoredTitle = state.title.isEmpty ? nil : state.title
    pageTitle = restoredTitle ?? (URL(string: state.url)?.host ?? "New Tab")
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit {
    for observer in observers { observer.invalidate() }
  }

  /// What to save for this tab, or nil for one not worth a slot. A tab restored and never shown
  /// hands back exactly what it was given.
  var restorableState: BrowserTabState? {
    if let pendingRestore { return pendingRestore }
    guard let url = currentURL, url.scheme != "about" else { return nil }
    return BrowserTabState(
      worktreeID: UUID(), url: url.absoluteString, title: pageTitle,
      interactionState: webView.interactionState as? Data)
  }

  override func loadView() {
    view = NSView()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    webView.translatesAutoresizingMaskIntoConstraints = false

    for (button, symbol, action) in [
      (back, "chevron.backward", #selector(goBack)),
      (forward, "chevron.forward", #selector(goForward)),
      (reload, "arrow.clockwise", #selector(reloadOrStop)),
    ] {
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      button.imagePosition = .imageOnly
      button.isBordered = false
      button.bezelStyle = .accessoryBarAction
      button.target = self
      button.action = action
    }
    back.isEnabled = false
    forward.isEnabled = false

    // The field takes a search as readily as an address (see `BrowserAddress`), and the old
    // "Enter a URL" said the opposite. It is not here to advertise two jobs — the panel's field
    // has two and names only one — but to stop claiming something untrue.
    address.placeholderString = "Search or enter address"
    address.font = .systemFont(ofSize: 12)
    address.bezelStyle = .roundedBezel
    // A field made in code defaults to a label's habits — it wraps and does not scroll — so a
    // long URL folded inside the 23pt box while being edited: the first line showed, the rest and
    // the caret sat below the frame. One line that scrolls while editing and truncates at rest.
    address.usesSingleLineMode = true
    address.lineBreakMode = .byTruncatingTail
    address.cell?.isScrollable = true
    address.delegate = self
    address.target = self
    address.action = #selector(submitAddress)
    address.setContentHuggingPriority(.defaultLow, for: .horizontal)

    // The find bar is the commit tab's: a field in the pane's own row that steps on Return,
    // rather than a bar of its own dropping in over the page. Hidden until ⌘F asks for it.
    findField.placeholderString = "Find"
    findField.controlSize = .small
    findField.font = .systemFont(ofSize: 11)
    findField.delegate = self
    findField.target = self
    findField.action = #selector(findReturned)
    findField.sendsWholeSearchString = true
    findField.widthAnchor.constraint(equalToConstant: 150).isActive = true
    findField.isHidden = true
    findLabel.font = .systemFont(ofSize: 11)
    findLabel.textColor = .secondaryLabelColor
    findLabel.isHidden = true

    let bar = NSStackView(views: [back, forward, reload, address, findLabel, findField])
    bar.orientation = .horizontal
    bar.alignment = .centerY
    bar.spacing = 4
    bar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
    bar.translatesAutoresizingMaskIntoConstraints = false

    // A load's progress is a line along the bar's foot, the way Safari draws it in the field —
    // the one signal that a slow page is coming rather than nothing happening.
    progress.wantsLayer = true
    progress.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    progress.translatesAutoresizingMaskIntoConstraints = false
    progress.isHidden = true

    view.addSubview(bar)
    view.addSubview(webView)
    view.addSubview(progress)
    NSLayoutConstraint.activate([
      bar.topAnchor.constraint(equalTo: view.topAnchor),
      bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      progress.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
      progress.heightAnchor.constraint(equalToConstant: 2),
      progressWidth,
    ])

    // The chrome reads the view, not the navigation delegate. `didCommit` fires for a document
    // load and nothing else, and GitHub — the page this browser exists for — moves between an
    // issue and its PR without one: the address, title and history all change with nothing
    // committed, and a chrome synced there stayed on the first page all day.
    observers = [
      webView.observe(\.url) { [weak self] _, _ in self?.syncChrome() },
      webView.observe(\.title) { [weak self] _, _ in self?.syncChrome() },
      webView.observe(\.canGoBack) { [weak self] _, _ in self?.syncChrome() },
      webView.observe(\.canGoForward) { [weak self] _, _ in self?.syncChrome() },
      webView.observe(\.isLoading) { [weak self] _, _ in self?.syncLoading() },
      webView.observe(\.estimatedProgress) { [weak self] _, _ in self?.syncLoading() },
    ]

    if let state = pendingRestore {
      pendingRestore = nil
      restore(state)
    }
  }

  /// Put a restored tab back where it was. The interaction state carries the whole back/forward
  /// list and navigates to the current entry; a state that is missing or that WebKit will not
  /// take (its format is WebKit's own, and a WebKit update may decline the last one's) falls back
  /// to the URL, which is what the tab was mostly for.
  private func restore(_ state: BrowserTabState) {
    if let data = state.interactionState {
      webView.interactionState = data
      if webView.url != nil || webView.backForwardList.currentItem != nil { return }
    }
    if let url = URL(string: state.url) { webView.load(URLRequest(url: url)) }
  }

  /// Load what was typed — an address, or a search for it when it is not one.
  func load(_ text: String) {
    loadViewIfNeeded()
    lastInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch BrowserAddress.destination(for: text) {
    case .web(let url), .search(let url):
      clearFailure()
      webView.load(URLRequest(url: url))
    case .refused:
      // `javascript:` and `data:` in an address bar are how a pasted line becomes code running
      // inside someone else's session. Refusing is the whole handling; there is nothing to
      // offer instead, and searching for the payload would be its own kind of silly.
      present(
        failure: "That address will not be opened here",
        detail: "A javascript: or data: address typed into the address bar is not run.",
        for: nil, offeringSearch: false)
    case .none:
      break
    }
  }

  /// Open a known address — a link followed from the transcript, or a script's.
  func load(_ url: URL) {
    loadViewIfNeeded()
    lastInput = nil
    clearFailure()
    webView.load(URLRequest(url: url))
  }

  private func clearFailure() {
    failedURL = nil
    failureTitle = nil
  }

  /// The address showing, for the tab-reuse check and the scripting report. The error page keeps
  /// the address it failed on, so a tab reads as the page it was asked for either way; a restored
  /// tab not yet shown answers with what it will load.
  var currentURL: URL? {
    if let pendingRestore { return URL(string: pendingRestore.url) }
    return failedURL ?? webView.url
  }

  /// Put the cursor in the address field — a blank new tab opens ready to type.
  func focusAddress() {
    loadViewIfNeeded()
    view.window?.makeFirstResponder(address)
    address.currentEditor()?.selectAll(nil)
  }

  @objc private func goBack() { webView.goBack() }
  @objc private func goForward() { webView.goForward() }
  @objc private func reloadOrStop() {
    if webView.isLoading {
      webView.stopLoading()
    } else if let failedURL {
      load(failedURL)
    } else {
      webView.reload()
    }
  }
  @objc private func submitAddress() {
    load(address.stringValue)
    view.window?.makeFirstResponder(webView)
  }

  private func syncChrome() {
    back.isEnabled = webView.canGoBack
    forward.isEnabled = webView.canGoForward
    // Never over what is being typed: a page finishing under a half-written address would put
    // its own back in the field — and the field is a search box now, so the half-written line is
    // the usual state, not an edge. The field catches up when editing ends (see the delegate).
    if address.currentEditor() == nil, let url = currentURL?.absoluteString {
      address.stringValue = url
    }
    let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !title.isEmpty { restoredTitle = nil }
    let fallback = restoredTitle ?? currentURL?.host ?? "New Tab"
    let next = failureTitle ?? (title.isEmpty ? fallback : title)
    if next != pageTitle { pageTitle = next }
    // The desk relabels the tab and marks the window's restorable state stale on either — a
    // move is as much a change to what is saved as a retitle is.
    onTitleChange?()
  }

  /// Reload becomes Stop while a page is loading, and the progress line runs under the bar.
  private func syncLoading() {
    let loading = webView.isLoading
    reload.image = NSImage(
      systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: nil)
    reload.toolTip = loading ? "Stop" : "Reload"
    progress.isHidden = !loading
    progressWidth.constant = loading ? view.bounds.width * webView.estimatedProgress : 0
  }

  // MARK: The find bar

  /// ⌘F: show the field and put the cursor in it; Return steps forward, ⇧Return back. The tag is
  /// the one the menu item carries for `performFindPanelAction` — Find Next and Find Previous
  /// step without taking focus.
  func performFind(_ sender: Any?) {
    loadViewIfNeeded()
    switch NSFindPanelAction(rawValue: UInt((sender as? NSMenuItem)?.tag ?? 1)) {
    case .next?: step(backwards: false)
    case .previous?: step(backwards: true)
    default:
      findField.isHidden = false
      view.window?.makeFirstResponder(findField)
      findField.currentEditor()?.selectAll(nil)
    }
  }

  @objc private func findReturned(_ sender: Any?) {
    step(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
  }

  /// WebKit's find is a step, not a list: it selects the next match from the current one and
  /// says whether there was any. The count the commit tab shows is not on offer, so the label
  /// says only the thing worth saying — that there was nothing to find.
  private func step(backwards: Bool) {
    let term = findField.stringValue
    guard !term.isEmpty else {
      findLabel.isHidden = true
      return
    }
    let configuration = WKFindConfiguration()
    configuration.backwards = backwards
    webView.find(term, configuration: configuration) { [weak self] result in
      guard let self else { return }
      self.findLabel.stringValue = result.matchFound ? "" : "not found"
      self.findLabel.isHidden = result.matchFound
    }
  }

  private func hideFind() {
    findField.isHidden = true
    findLabel.isHidden = true
    view.window?.makeFirstResponder(webView)
  }

  // MARK: NSTextFieldDelegate

  func controlTextDidChange(_ notification: Notification) {
    if (notification.object as? NSSearchField) === findField { step(backwards: false) }
  }

  /// The address field catches up with the page once you leave it — the sync it skipped while
  /// you were typing (see `syncChrome`). Not on Return: AppKit ends editing *before* it sends the
  /// action, so restoring the URL here would hand `submitAddress` the old address instead of the
  /// typed one, and Return would go nowhere. The action consumes the text; only leaving by any
  /// other route (a click elsewhere, Tab) puts the page's address back.
  func controlTextDidEndEditing(_ notification: Notification) {
    guard (notification.object as? NSTextField) === address else { return }
    let movement = (notification.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init)
    guard movement != .return, let url = currentURL?.absoluteString else { return }
    address.stringValue = url
  }

  /// Escape in either field: the find bar folds; the address field gives the page's address back
  /// and lets go of the keyboard, the way a browser's does.
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
    if control === findField {
      hideFind()
    } else {
      address.stringValue = currentURL?.absoluteString ?? ""
      view.window?.makeFirstResponder(webView)
    }
    return true
  }

  // MARK: The error page

  /// A failed load used to show nothing at all: WKWebView keeps the previous content, which on a
  /// fresh tab is a white rectangle, and `didCommit` never fires so even the chrome stayed as it
  /// was. Every wrong address read as "Return did nothing".
  ///
  /// It is drawn as a simulated response rather than an `NSView` banner over the page, because
  /// that keeps the failed address as the web view's own URL: the address bar stays right, and
  /// the reload button and ⌘R go on meaning "try again" without hukan having to remember what
  /// they mean. Its three actions ride on a private scheme intercepted in `decidePolicyFor`,
  /// which is also why that interception has to run before the hand-it-to-the-system rule.
  private func present(failure: String, detail: String, for url: URL?, offeringSearch: Bool) {
    failedURL = url
    failureTitle = failure
    let query = lastInput ?? url?.host ?? ""
    var actions = ["<a href=\"x-hukan:retry\">Try again</a>"]
    if offeringSearch, !query.isEmpty {
      actions.append("<a href=\"x-hukan:search\">Search for &ldquo;\(escaped(query))&rdquo;</a>")
    }
    if url != nil { actions.append("<a href=\"x-hukan:safari\">Open in Safari</a>") }
    let html = """
      <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(escaped(failure))</title>
      <style>
        :root { color-scheme: light dark; }
        body { font: 13px -apple-system, system-ui; margin: 0;
               display: flex; align-items: center; justify-content: center;
               height: 100vh; text-align: center; }
        main { max-width: 34em; padding: 0 2em; }
        h1 { font-size: 15px; font-weight: 600; margin: 0 0 .6em; }
        p { margin: 0 0 1.4em; opacity: .7; line-height: 1.5; }
        code { font-family: ui-monospace, monospace; font-size: 12px; word-break: break-all; }
        nav a { margin: 0 .7em; }
      </style></head><body><main>
      <h1>\(escaped(failure))</h1>
      <p>\(escaped(detail))<br><code>\(escaped(url?.absoluteString ?? lastInput ?? ""))</code></p>
      <nav>\(actions.joined(separator: ""))</nav>
      </main></body></html>
      """
    let request = URLRequest(url: url ?? URL(string: "about:blank")!)
    webView.loadSimulatedRequest(request, responseHTML: html)
    syncChrome()
  }

  private func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  /// Which failures the error page is for. A cancel is not one: it is what a second click while
  /// the first is loading looks like, and — the one that would have made this unusable — what
  /// every `kolide://` handoff looks like, since cancelling in `decidePolicyFor` is how the
  /// scheme is handed over. `WebKitErrorDomain` 102 is the same event under another name.
  static func isReportable(_ error: Error) -> Bool {
    let error = error as NSError
    if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return false }
    if error.domain == "WebKitErrorDomain", error.code == 102 { return false }
    return true
  }

  /// Whether searching instead makes sense for this failure. It does when the address did not
  /// resolve to a machine — which is the shape `Model.swift` and every other not-really-an-address
  /// takes — and does not when a real server answered badly.
  static func offersSearch(after error: Error) -> Bool {
    let error = error as NSError
    guard error.domain == NSURLErrorDomain else { return false }
    return [
      NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorUnsupportedURL,
      NSURLErrorCannotConnectToHost,
    ].contains(error.code)
  }

  private func report(_ error: Error, url: URL?) {
    guard Self.isReportable(error) else { return }
    present(
      failure: "This page could not be opened",
      detail: (error as NSError).localizedDescription, for: url ?? webView.url,
      offeringSearch: Self.offersSearch(after: error))
  }

  // MARK: WKNavigationDelegate

  /// Any navigation but the error page's own supersedes the error page — the back button's
  /// included, which is the only way off it that does not go through `load`. Decided here rather
  /// than off the URL in `syncChrome`, because between the failure and the error page committing
  /// the view's URL is still the previous page's, and that read as "superseded" too.
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    if let failedURL, webView.url != failedURL { clearFailure() }
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    report(error, url: (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL)
  }

  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    report(error, url: nil)
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    // The error page's own actions, before anything else: they wear a scheme, and the rule below
    // would otherwise hand them to the system as one.
    if let url = navigationAction.request.url, url.scheme == "x-hukan" {
      perform(errorPageAction: String(url.absoluteString.dropFirst("x-hukan:".count)))
      decisionHandler(.cancel)
      return
    }
    // Web schemes render here; anything else — a `kolide://` device-trust handoff, `mailto:` —
    // belongs to the system, so cancel and hand it over.
    if let url = navigationAction.request.url, !BrowserEnvironment.rendersInWebTab(url) {
      NSWorkspace.shared.open(url)
      decisionHandler(.cancel)
      return
    }
    // A link marked `download` is one; so is anything the page cannot show (below).
    decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
  ) {
    // A release asset, a `.patch`, a zip: what WebKit cannot render is a file, and a file goes to
    // Downloads rather than nowhere — which is where a click on one used to go.
    decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
  }

  func webView(
    _ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload
  ) {
    adopt(download)
  }

  func webView(
    _ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload
  ) {
    adopt(download)
  }

  private func adopt(_ download: WKDownload) {
    download.delegate = self
    downloads.insert(download)
  }

  /// Basic and Digest ask for a name and password; a client certificate is looked up by the
  /// issuers the server named, which is the question a device-trust proxy asks and the one thing
  /// there is no panel for. Server trust is left to the system's own evaluation, as it should be.
  func webView(
    _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let space = challenge.protectionSpace
    switch space.authenticationMethod {
    case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
      NSURLAuthenticationMethodNTLM:
      askForCredential(space: space, retrying: challenge.previousFailureCount > 0) { credential in
        completionHandler(
          credential == nil ? .cancelAuthenticationChallenge : .useCredential,
          credential)
      }
    case NSURLAuthenticationMethodClientCertificate:
      if let identity = Self.identity(issuedBy: space.distinguishedNames ?? []) {
        completionHandler(
          .useCredential,
          URLCredential(identity: identity, certificates: nil, persistence: .forSession))
      } else {
        completionHandler(.performDefaultHandling, nil)
      }
    default:
      completionHandler(.performDefaultHandling, nil)
    }
  }

  /// The first identity in the keychain that one of the server's named issuers signed. No
  /// chooser: this machine has one device certificate, and a second one is a problem for the day
  /// it exists.
  private static func identity(issuedBy issuers: [Data]) -> SecIdentity? {
    guard !issuers.isEmpty else { return nil }
    let query: [CFString: Any] = [
      kSecClass: kSecClassIdentity,
      kSecMatchIssuers: issuers as CFArray,
      kSecReturnRef: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let result
    else { return nil }
    return (result as! SecIdentity)
  }

  private func askForCredential(
    space: URLProtectionSpace, retrying: Bool, completion: @escaping (URLCredential?) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = "\(space.host) asks for a name and password"
    alert.informativeText =
      (retrying ? "The name or password was not accepted. " : "")
      + (space.realm.map { "Realm: \($0)" } ?? "")
    alert.addButton(withTitle: "Sign In")
    alert.addButton(withTitle: "Cancel")
    let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24))
    name.placeholderString = "Name"
    let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    password.placeholderString = "Password"
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 54))
    box.addSubview(name)
    box.addSubview(password)
    alert.accessoryView = box
    alert.window.initialFirstResponder = name
    runSheet(alert) { response in
      guard response == .alertFirstButtonReturn else { return completion(nil) }
      completion(
        URLCredential(
          user: name.stringValue, password: password.stringValue, persistence: .forSession))
    }
  }

  // MARK: WKDownloadDelegate

  /// Into Downloads under the name the server suggested, made unique the way the Finder does.
  /// Nothing else is built — no list, no progress — because a download here is the occasional
  /// asset, and the Downloads stack in the Dock already is the list.
  func download(
    _ download: WKDownload, decideDestinationUsing response: URLResponse,
    suggestedFilename: String, completionHandler: @escaping (URL?) -> Void
  ) {
    let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    completionHandler(Self.uniqueURL(in: folder, named: suggestedFilename))
  }

  static func uniqueURL(in folder: URL, named name: String) -> URL {
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var candidate = folder.appendingPathComponent(name)
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
      candidate = folder.appendingPathComponent(numbered)
      counter += 1
    }
    return candidate
  }

  func downloadDidFinish(_ download: WKDownload) {
    downloads.remove(download)
    // The Dock's Downloads stack bounces on this, which is Safari's own signal — and the whole of
    // the UI a download gets here.
    if let path = download.progress.fileURL?.path {
      DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.apple.DownloadFileFinished"), object: path, userInfo: nil,
        deliverImmediately: true)
    }
  }

  func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    downloads.remove(download)
    guard Self.isReportable(error) else { return }
    let alert = NSAlert()
    alert.messageText = "The download did not finish"
    alert.informativeText = error.localizedDescription
    runSheet(alert) { _ in }
  }

  private func perform(errorPageAction action: String) {
    switch action {
    case "retry":
      if let failedURL { load(failedURL) }
    case "search":
      guard let query = lastInput ?? failedURL?.host else { return }
      load(BrowserAddress.searchURL(for: query))
    case "safari":
      if let failedURL { NSWorkspace.shared.open(failedURL) }
    default:
      break
    }
  }

  // MARK: WKUIDelegate

  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    // Return a real web view so the popup opens as its own tab rather than being dropped — the SSO
    // dance relies on it. WebKit loads the request into the instance we return; a desk that has
    // nowhere to put it (its worktree is gone) declines, and WebKit drops the popup cleanly
    // rather than loading it into a view no one will ever see.
    let popup = WKWebView(frame: .zero, configuration: configuration)
    return onOpenPopup?(popup) == true ? popup : nil
  }

  func webViewDidClose(_ webView: WKWebView) {
    onClose?()
  }

  /// The content process went away under the page — memory pressure, a WebKit crash — which
  /// leaves the view blank and every button dead. Reload, as Safari does: a tab off screen for
  /// hours in a background worktree is exactly the one this happens to, and it must not come
  /// back as a white rectangle. The error page reloads to the address it stands for.
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    if let failedURL { load(failedURL) } else { webView.reload() }
  }

  /// A page's `alert`, `confirm` and `prompt`, as sheets. Each used to return at once with
  /// nothing shown — `confirm` as false — so a "really close this issue?" was unanswerable.
  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
  ) {
    let alert = dialog(message, from: frame)
    alert.addButton(withTitle: "OK")
    runSheet(alert) { _ in completionHandler() }
  }

  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
  ) {
    let alert = dialog(message, from: frame)
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    runSheet(alert) { completionHandler($0 == .alertFirstButtonReturn) }
  }

  func webView(
    _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
    defaultText: String?, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping (String?) -> Void
  ) {
    let alert = dialog(prompt, from: frame)
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = defaultText ?? ""
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    runSheet(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
  }

  private func dialog(_ message: String, from frame: WKFrameInfo) -> NSAlert {
    let alert = NSAlert()
    alert.messageText =
      frame.securityOrigin.host.isEmpty ? "This page says" : frame.securityOrigin.host
    alert.informativeText = message
    return alert
  }

  /// A page's `<input type=file>`: the system's open panel, over the window.
  func webView(
    _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void
  ) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    panel.canChooseDirectories = parameters.allowsDirectories
    panel.canChooseFiles = true
    guard let window = view.window else { return completionHandler(nil) }
    panel.beginSheetModal(for: window) { response in
      completionHandler(response == .OK ? panel.urls : nil)
    }
  }

  /// Sheets over the window when there is one, modal when there is not (a pane being driven
  /// before it is on screen), so a completion handler is always called.
  private func runSheet(
    _ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void
  ) {
    if let window = view.window {
      alert.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(alert.runModal())
    }
  }
}
