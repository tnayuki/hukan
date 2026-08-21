import AppKit

// MARK: - Left: SESSIONS (the overview)

/// A row in the rail. Sessions are what the rail lists; the worktree a session currently
/// works in rides along as a subtitle rather than a level of its own.
final class RailNode: NSObject {
  let title: String
  let subtitle: String?
  let state: RunState?
  let isDetached: Bool
  let added: Int
  let removed: Int
  let terminalCount: Int
  let worktree: Worktree?
  let session: AgentSession?
  var children: [RailNode]

  /// Set on a time-bucket sub-heading ("Today", "Older", …). Carries the key its collapse
  /// state is remembered under, plus whether the bucket hides itself until asked. A bucket is
  /// a heading like a repository, so it is still `isGroup`; this is what tells the two apart.
  let bucketKey: String?
  let bucketCollapsedByDefault: Bool

  /// Set on a search-hit row: the character offset (and length) in the session's rendered
  /// transcript to jump to when the row is clicked. The title carries the snippet. A hit belongs
  /// to a session like a header does, so `matchOffset` is what tells a hit row from its header.
  let matchOffset: Int?
  let matchLength: Int
  var isHit: Bool { matchOffset != nil }

  var isGroup: Bool { worktree == nil && session == nil }
  var isBucket: Bool { bucketKey != nil }

  /// A stable identity for this row across reloads — a session by its id, a group by its
  /// repository, an empty worktree by its own id. The rail compares these before and after a
  /// reload to tell a pure reorder (worth a little animation) from a content-only change.
  var identityKey: String {
    if let session, let matchOffset { return "h:" + session.id.uuidString + ":\(matchOffset)" }
    if let session { return "s:" + session.id.uuidString }
    if let bucketKey { return "b:" + bucketKey }
    if isGroup { return "g:" + (repositoryID ?? title) }
    if let worktree { return "w:" + worktree.id.uuidString }
    return title
  }

  /// Which repository this row belongs to. Group headers carry it directly; every other row
  /// gets it from its worktree, so a right-click anywhere in the rail knows what to close.
  var repositoryID: String? { groupRepositoryID ?? worktree?.repositoryID }
  private let groupRepositoryID: String?

  init(
    title: String, subtitle: String? = nil, state: RunState? = nil, isDetached: Bool = false,
    added: Int = 0, removed: Int = 0, terminalCount: Int = 0,
    worktree: Worktree? = nil, session: AgentSession? = nil, children: [RailNode] = [],
    groupRepositoryID: String? = nil, bucketKey: String? = nil,
    bucketCollapsedByDefault: Bool = false,
    matchOffset: Int? = nil, matchLength: Int = 0
  ) {
    self.groupRepositoryID = groupRepositoryID
    self.title = title
    self.subtitle = subtitle
    self.state = state
    self.isDetached = isDetached
    self.added = added
    self.removed = removed
    self.terminalCount = terminalCount
    self.worktree = worktree
    self.session = session
    self.children = children
    self.bucketKey = bucketKey
    self.bucketCollapsedByDefault = bucketCollapsedByDefault
    self.matchOffset = matchOffset
    self.matchLength = matchLength
  }
}

/// The rail's outline view, subclassed only to turn Return/Enter into an "enter this session"
/// signal. Arrow keys and type-select fall through to AppKit, so navigating the rail stays a
/// plain selection change; pressing Return is the master-detail dive that carries focus into the
/// composer.
final class RailOutlineView: NSOutlineView {
  var onActivate: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    // 36 = Return, 76 = keypad Enter. Everything else (arrows, first-letter jump) falls through
    // so the rail still navigates without stealing focus.
    if event.keyCode == 36 || event.keyCode == 76 {
      onActivate?()
      return
    }
    super.keyDown(with: event)
  }
}

final class SessionRailViewController: NSViewController, NSOutlineViewDataSource,
  NSOutlineViewDelegate, NSMenuDelegate, NSSearchFieldDelegate
{
  var workspace: Workspace?
  var onSelectWorktree: ((UUID) -> Void)?
  var onSelectSession: ((AgentSession) -> Void)?
  var onCloseRepository: ((String) -> Void)?
  var onNewSession: ((String) -> Void)?
  /// Fired whenever the query changes, so the window can re-highlight the open transcript for the
  /// new terms. Distinct from a rail reload: the rail filters itself, but the running column needs
  /// the terms to mark where a session matched.
  var onSearchChanged: (() -> Void)?
  /// A specific search hit was clicked: open its session and jump the transcript to that offset.
  /// The offset is into the session's rendered transcript, which is what the view shows.
  var onSelectMatch: ((AgentSession, Int, Int) -> Void)?
  /// A deliberate "enter this session" — Return or a double-click on a session row, as opposed to
  /// arrowing past it. Selection has already moved via `onSelectSession`; the window uses this only
  /// to dive focus into the composer. Surveying the rail with the arrows does not fire it.
  var onActivateSession: (() -> Void)?

  private let outlineView = RailOutlineView()
  private let searchField = NSSearchField()
  private let emptyLabel = NSTextField(labelWithString: "No matching sessions")
  private let contextMenu = NSMenu()
  private var nodes: [RailNode] = []

  /// The full-text filter. `matches` is the set of session ids the current query hits, or nil
  /// when there is no query — nil means "show everything", which is a different state from an
  /// empty set (a query that matched nothing). The query is transient on purpose: it is momentary
  /// state, and restoring a stale filter that hides the whole rail on launch would be the same
  /// mistake as writing an empty session list over a good one.
  private var matches: Set<UUID>?
  /// One occurrence of the query inside a session's rendered transcript: where to jump, and a
  /// snippet of surrounding text to show in the results list.
  struct Hit {
    let offset: Int
    let length: Int
    let snippet: String
  }
  /// Per matched session, its hits in transcript order — the rows the results list expands to.
  private var hits: [UUID: [Hit]] = [:]
  /// Searchable bodies keyed by session id, invalidated on the transcript's mtime so a changed
  /// conversation reparses and an unchanged one is a straight substring scan. Touched only on
  /// `searchQueue`, which is what keeps this dictionary off the concurrent-access cliff. The
  /// second cache holds the *rendered* transcript string (with formatting, the way the view shows
  /// it), so hit offsets line up with the text view; the filter still gates on the body-only text.
  private var searchCache: [UUID: (mtime: Date, text: String)] = [:]
  private var renderCache: [UUID: (mtime: Date, text: String)] = [:]
  private let searchQueue = DispatchQueue(label: "dev.tnayuki.hukan.rail-search")
  /// A typed query is heavy (it can read many files), so it is debounced; the token drops a run
  /// whose keystroke was superseded before it fired.
  private var pendingSearch: DispatchWorkItem?
  /// Bumped per query so a slow background scan that lands after a newer one is discarded.
  private var searchGeneration = 0
  private var isSearching: Bool { matches != nil }
  /// reloadData() clears the selection, and restoring it fires the selection-changed
  /// delegate. That runs onSelectWorktree, which reloads the window, which lands back here —
  /// mutual recursion that crashes. Ignore notifications while we are the ones driving.
  private var isUpdatingSelection = false
  /// The notification does not always arrive inside the flag's window — NSOutlineView can
  /// post it a runloop turn later, by which point the flag is back down and our own
  /// selection looks like a click. Remember the row we set so it can be recognised.
  private var programmaticRow: Int?
  /// The rail's disclosure state lives on the workspace (so it rides the window's restorable
  /// state across a restart) — these bridge to it, leaving the rest of the rail's code unchanged.
  /// `collapsedRepositories`: repositories whose rows are folded. The two bucket sets record
  /// buckets flipped away from their default (a key in neither follows the default), so a bucket
  /// keeps an explicit choice across the reloads that rebuild the tree.
  private var collapsedRepositories: Set<String> {
    get { workspace?.collapsedRepositories ?? [] }
    set { workspace?.collapsedRepositories = newValue }
  }
  private var bucketsCollapsedByUser: Set<String> {
    get { workspace?.bucketsCollapsedByUser ?? [] }
    set { workspace?.bucketsCollapsedByUser = newValue }
  }
  private var bucketsExpandedByUser: Set<String> {
    get { workspace?.bucketsExpandedByUser ?? [] }
    set { workspace?.bucketsExpandedByUser = newValue }
  }

  private func bucketIsCollapsed(key: String, defaultCollapsed: Bool) -> Bool {
    if bucketsExpandedByUser.contains(key) { return false }
    if bucketsCollapsedByUser.contains(key) { return true }
    return defaultCollapsed
  }

  override func loadView() {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rail"))
    column.resizingMask = .autoresizingMask
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column
    outlineView.headerView = nil
    outlineView.style = .sourceList
    outlineView.rowHeight = 26
    outlineView.indentationPerLevel = 10
    outlineView.floatsGroupRows = false
    outlineView.dataSource = self
    outlineView.delegate = self
    // Return/Enter and a double-click both mean "enter this session"; a single click or an arrow
    // keypress only selects. This is the master-detail split — see `onActivateSession`.
    outlineView.onActivate = { [weak self] in self?.activateSelectedSession() }
    outlineView.target = self
    outlineView.doubleAction = #selector(sessionRowDoubleClicked)
    contextMenu.delegate = self
    outlineView.menu = contextMenu
    // Layer-backed so a reorder can be cross-faded (see `reload`). Without this the layer is
    // nil and the transition is simply skipped, so the rail still updates — just without the
    // little fade.
    outlineView.wantsLayer = true

    let scrollView = NSScrollView()
    scrollView.documentView = outlineView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    // The full-text filter over every session, opened or not. Live-as-you-type via the text
    // delegate rather than the search field's own send-on-pause, so the rail narrows while you
    // type; the actual scan is debounced and off the main thread (see `controlTextDidChange`).
    searchField.placeholderString = "Search sessions"
    searchField.delegate = self
    searchField.sendsWholeSearchString = false
    searchField.sendsSearchStringImmediately = false
    searchField.translatesAutoresizingMaskIntoConstraints = false

    // Shown only while a query matches nothing, so an empty rail during search does not read as
    // "no sessions at all". Hidden otherwise.
    emptyLabel.font = .systemFont(ofSize: 12)
    emptyLabel.textColor = .tertiaryLabelColor
    emptyLabel.alignment = .center
    emptyLabel.isHidden = true
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false

    // New sessions are made from each repository heading's own `+` (and File ▸ New Session,
    // ⌘⇧N), so the rail needs no global footer button — the search field caps the column and the
    // scroll view fills the rest.
    let container = NSView()
    container.addSubview(searchField)
    container.addSubview(scrollView)
    container.addSubview(emptyLabel)
    NSLayoutConstraint.activate([
      searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
      searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
      searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
      scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
      emptyLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 24),
      emptyLabel.leadingAnchor.constraint(
        greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
      emptyLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: container.trailingAnchor, constant: -12),
    ])
    view = container
  }

  // MARK: - Full-text search

  /// The rail narrowed to the current query on every keystroke. The scan itself is deferred and
  /// coalesced (`scheduleSearch`) — this only records the text and kicks the timer.
  func controlTextDidChange(_ obj: Notification) {
    guard (obj.object as? NSSearchField) === searchField else { return }
    scheduleSearch(searchField.stringValue)
  }

  private func scheduleSearch(_ text: String) {
    pendingSearch?.cancel()
    // Clearing the field should feel instant — no reason to wait out the debounce to un-filter.
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      runSearch("")
      return
    }
    let work = DispatchWorkItem { [weak self] in self?.runSearch(text) }
    pendingSearch = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
  }

  /// Compute the matching session ids for `raw` and re-filter the rail. The disk scan runs on
  /// `searchQueue` (which also owns the cache); the result lands back on the main thread and is
  /// dropped if a newer query has since started.
  private func runSearch(_ raw: String) {
    let terms = Self.terms(raw)
    guard !terms.isEmpty else {
      matches = nil
      reload()
      onSearchChanged?()
      return
    }
    let requests = searchRequests()
    searchGeneration += 1
    let generation = searchGeneration
    searchQueue.async { [weak self] in
      guard let self else { return }
      let result = self.scan(terms: terms, requests: requests)
      DispatchQueue.main.async {
        guard generation == self.searchGeneration else { return }
        self.matches = result.matches
        self.hits = result.hits
        self.reload()
        self.onSearchChanged?()
      }
    }
  }

  /// The scripting entry point (`session filter` on the window). Same filter as typing, but run to
  /// completion synchronously so a script can set the query and read the result on the next line —
  /// it is already on the main thread, and an automated call reading a few files inline is fine
  /// where a keystroke would not be. Any in-flight typed scan is dropped by the generation bump.
  func applyScriptedSearch(_ raw: String) {
    loadViewIfNeeded()
    pendingSearch?.cancel()
    searchField.stringValue = raw
    searchGeneration += 1
    let terms = Self.terms(raw)
    guard !terms.isEmpty else {
      matches = nil
      reload()
      onSearchChanged?()
      return
    }
    let requests = searchRequests()
    let result = searchQueue.sync { scan(terms: terms, requests: requests) }
    matches = result.matches
    hits = result.hits
    reload()
    onSearchChanged?()
  }

  /// The current query text, and the sessions the filter shows (all of them when none is set) —
  /// both read by the scripting bridge so the filter is drivable and its result checkable without
  /// a screenshot.
  var searchQuery: String {
    loadViewIfNeeded()
    return searchField.stringValue
  }
  /// The query split into the terms the transcript highlight paints — same split the filter uses.
  var searchTerms: [String] {
    loadViewIfNeeded()
    return Self.terms(searchField.stringValue)
  }
  var filteredSessionIDs: [UUID] {
    let all = workspace?.sessions.map(\.id) ?? []
    guard let matches else { return all }
    return all.filter(matches.contains)
  }

  private static func terms(_ raw: String) -> [String] {
    raw.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
  }

  /// Snapshot what to scan on the main thread — session objects are not to be touched off it.
  private func searchRequests() -> [(id: UUID, title: String, url: URL)] {
    guard let workspace else { return [] }
    return workspace.sessions.compactMap { session in
      guard let worktree = workspace.worktree(id: session.worktreeID) else { return nil }
      return (session.id, (session.title ?? "").lowercased(), worktree.url)
    }
  }

  /// Which of `requests` contain every term (title plus body), and — for those that do — where the
  /// terms land in the rendered transcript. Runs on `searchQueue`, the only place the caches are
  /// touched. The filter gates on the body-only text (the user's choice — no tool calls); the hit
  /// offsets come from the rendered transcript so they line up with what the view shows.
  private func scan(terms: [String], requests: [(id: UUID, title: String, url: URL)])
    -> (matches: Set<UUID>, hits: [UUID: [Hit]])
  {
    var found = Set<UUID>()
    var hits: [UUID: [Hit]] = [:]
    for request in requests {
      let haystack = request.title + "\n" + cachedSearchText(id: request.id, url: request.url)
      guard terms.allSatisfy({ haystack.contains($0) }) else { continue }
      found.insert(request.id)
      hits[request.id] = renderedHits(id: request.id, url: request.url, terms: terms)
    }
    return (found, hits)
  }

  /// Every occurrence of any term in the session's rendered transcript, in order, each with a
  /// one-line snippet for the results list. Empty when the match was on the title alone (the
  /// title is not part of the transcript). Runs on `searchQueue`.
  private func renderedHits(id: UUID, url: URL, terms: [String]) -> [Hit] {
    let rendered = cachedRenderedText(id: id, url: url) as NSString
    guard rendered.length > 0 else { return [] }
    var found: [(offset: Int, length: Int)] = []
    for term in terms where !term.isEmpty {
      var scan = NSRange(location: 0, length: rendered.length)
      while scan.length > 0 {
        let r = rendered.range(of: term, options: .caseInsensitive, range: scan)
        guard r.location != NSNotFound else { break }
        found.append((r.location, r.length))
        let next = r.location + max(r.length, 1)
        scan = NSRange(location: next, length: rendered.length - next)
      }
    }
    // Terms interleave, so sort by position and drop duplicate starts (two terms sharing a spot).
    found.sort { $0.offset < $1.offset }
    var result: [Hit] = []
    var lastOffset = -1
    for match in found where match.offset != lastOffset {
      lastOffset = match.offset
      result.append(
        Hit(
          offset: match.offset, length: match.length,
          snippet: Self.snippet(in: rendered, around: match.offset, length: match.length)))
    }
    return result
  }

  /// A single trimmed line of context around a match — a little before, the rest after, newlines
  /// flattened to spaces so it fits one row. Ellipses mark where it was cut.
  private static func snippet(in text: NSString, around offset: Int, length: Int) -> String {
    let lead = 18
    let start = max(0, offset - lead)
    let end = min(text.length, offset + length + 46)
    var piece = text.substring(with: NSRange(location: start, length: end - start))
    piece = piece.replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\t", with: " ")
      .trimmingCharacters(in: .whitespaces)
    while piece.contains("  ") { piece = piece.replacingOccurrences(of: "  ", with: " ") }
    return (start > 0 ? "…" : "") + piece + (end < text.length ? "…" : "")
  }

  /// The rendered transcript string for one session, cached by mtime — the same
  /// `ClaudeSessionStore.history` render the view loads, so a hit's offset is a valid location in
  /// the text view once the session is open. Runs only on `searchQueue`.
  private func cachedRenderedText(id: UUID, url: URL) -> String {
    let mtime = ClaudeSessionStore.lastModified(id: id, worktree: url) ?? .distantPast
    if let entry = renderCache[id], entry.mtime == mtime { return entry.text }
    let text = Transcript.render(ClaudeSessionStore.history(id: id, worktree: url)?.records ?? [])
      .string
    renderCache[id] = (mtime, text)
    return text
  }

  /// The lowercased body for one session, from cache when the transcript has not changed since it
  /// was last read. Runs only on `searchQueue`, so the cache needs no further locking.
  private func cachedSearchText(id: UUID, url: URL) -> String {
    let mtime = ClaudeSessionStore.lastModified(id: id, worktree: url) ?? .distantPast
    if let entry = searchCache[id], entry.mtime == mtime { return entry.text }
    let text = ClaudeSessionStore.searchableText(id: id, worktree: url)
    searchCache[id] = (mtime, text)
    return text
  }

  func reload() {
    loadViewIfNeeded()
    guard let workspace else { return }
    let before = flattenedKeys(nodes)
    func node(for entry: Workspace.RailEntry) -> RailNode {
      let (session, worktree) = (entry.session, entry.worktree)
      let stat = worktree.diffstat
      return RailNode(
        title: session.title ?? "New session",
        subtitle: worktree.displayName,
        state: session.state,
        isDetached: session.isDetached,
        added: stat.added,
        removed: stat.removed,
        terminalCount: workspace.terminals(inWorktree: worktree.id).count,
        worktree: worktree,
        session: session)
    }
    // A live query turns the rail into a results list (see `resultsNodes`); otherwise it is the
    // usual repository → time-bucket → session tree.
    if isSearching {
      nodes = resultsNodes(node)
    } else {
      nodes = workspace.groupedSections.map { section in
        // Each bucket becomes a sub-heading with the sessions of that age under it. A
        // repository with no sessions yet is a bare heading — its `+` starts the first one.
        let children = section.buckets.map { bucket in
          RailNode(
            title: bucket.bucket.title,
            children: bucket.entries.map(node(for:)),
            groupRepositoryID: section.repositoryID,
            bucketKey: "\(section.repositoryID)#\(bucket.bucket.rawValue)",
            bucketCollapsedByDefault: bucket.bucket.collapsedByDefault)
        }
        return RailNode(
          title: section.repositoryName.uppercased(),
          children: children,
          groupRepositoryID: section.repositoryID)
      }
    }
    // The "nothing matched" note, shown only when a query is live and cleared everything.
    emptyLabel.isHidden = !(isSearching && nodes.isEmpty)

    isUpdatingSelection = true
    defer { isUpdatingSelection = false }

    // The rows moved but the set is the same (a session rose or sank in the order): cross-fade
    // the reload so the reshuffle registers as motion rather than an instant jump. Restricted
    // to a pure reorder — a row appearing or disappearing is a different event and updates
    // plainly, and the first population (empty `before`) has nothing to animate from.
    let after = flattenedKeys(nodes)
    if !before.isEmpty, before != after, Set(before) == Set(after) {
      let transition = CATransition()
      transition.type = .fade
      transition.duration = 0.22
      outlineView.layer?.add(transition, forKey: "reorder")
    }

    outlineView.reloadData()
    // Expand every repository except the ones the disclosure has collapsed. reloadData leaves
    // items collapsed, so this is what makes a group's rows show at all.
    let selectedSession = workspace.selectedSession?.id
    for repository in nodes where !repository.children.isEmpty {
      // A collapsed repository stays folded — except during a search, where hiding matches
      // behind a fold would read as no match.
      if !isSearching, let repositoryID = repository.repositoryID,
        collapsedRepositories.contains(repositoryID)
      {
        outlineView.collapseItem(repository)
        continue
      }
      outlineView.expandItem(repository)
      // Then each time bucket under it: Older stays folded until asked, unless the selected
      // session lives inside — a bucket that hides the current selection would leave the
      // transcript showing a row the rail cannot point at. A live query overrides all of this
      // and expands every bucket: a match filtered into "Older" that stayed folded would look
      // like the search had missed it.
      for bucket in repository.children where bucket.isBucket && !bucket.children.isEmpty {
        let holdsSelection =
          selectedSession != nil
          && bucket.children.contains { $0.session?.id == selectedSession }
        let collapsed =
          !isSearching && !holdsSelection
          && bucketIsCollapsed(
            key: bucket.bucketKey ?? "", defaultCollapsed: bucket.bucketCollapsedByDefault)
        if collapsed { outlineView.collapseItem(bucket) } else { outlineView.expandItem(bucket) }
      }
    }

    let row = (0..<outlineView.numberOfRows).first { index in
      guard let node = outlineView.item(atRow: index) as? RailNode else { return false }
      if let session = node.session { return session.id == selectedSession }
      return selectedSession == nil && node.worktree?.id == workspace.selectedWorktreeID
    }
    if let row, outlineView.selectedRow != row {
      programmaticRow = row
      outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
  }

  /// The search-results tree: one header per matched session (recency order, the normal session
  /// row) expanding to a row per hit — the snippet, carrying the offset a click jumps to. A
  /// session that matched on its title alone has no hits, so it shows as a bare header.
  private func resultsNodes(_ makeSessionRow: (Workspace.RailEntry) -> RailNode) -> [RailNode] {
    guard let workspace, let matches else { return [] }
    let matched = workspace.sessions
      .filter { matches.contains($0.id) }
      .sorted { $0.updatedAt > $1.updatedAt }
    return matched.compactMap { session -> RailNode? in
      guard let worktree = workspace.worktree(id: session.worktreeID) else { return nil }
      let header = makeSessionRow(Workspace.RailEntry(session: session, worktree: worktree))
      header.children = (hits[session.id] ?? []).map { hit in
        RailNode(
          title: hit.snippet, session: session,
          matchOffset: hit.offset, matchLength: hit.length)
      }
      return header
    }
  }

  /// The rail's rows top to bottom as identity keys, so two reloads can be compared to tell a
  /// reorder from a content change. Group then its children, matching the on-screen order.
  private func flattenedKeys(_ nodes: [RailNode]) -> [String] {
    nodes.flatMap { [$0.identityKey] + flattenedKeys($0.children) }
  }

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    (item as? RailNode)?.children.count ?? nodes.count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    (item as? RailNode)?.children[index] ?? nodes[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    !((item as? RailNode)?.children.isEmpty ?? true)
  }

  // Deliberately not a group item to AppKit: a source-list group row grows its own Show/Hide
  // disclosure on hover at the trailing edge, which would fight the always-visible one drawn in
  // the cell. The heading still reads as a heading because the cell styles it, and it stays
  // unselectable via shouldSelectItem below.
  func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
    false
  }

  // Suppress AppKit's own disclosure triangle too; the heading carries its own chevron.
  func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
    false
  }

  func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
    !((item as? RailNode)?.isGroup ?? true)
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
    -> NSView?
  {
    guard let node = item as? RailNode else { return nil }
    let cell = NSTableCellView()

    if node.isBucket, let bucketKey = node.bucketKey {
      // A time sub-heading: the title in plain case (the repository heading is uppercased, so
      // the two never read alike) and a disclosure that folds just this bucket. No `+` — new
      // sessions are made from the repository heading, which owns the whole group.
      let label = NSTextField(labelWithString: node.title)
      label.font = .systemFont(ofSize: 11, weight: .medium)
      label.textColor = .tertiaryLabelColor
      label.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(label)

      let collapsed = bucketIsCollapsed(
        key: bucketKey, defaultCollapsed: node.bucketCollapsedByDefault)
      let disclose = NSButton()
      disclose.translatesAutoresizingMaskIntoConstraints = false
      disclose.isBordered = false
      disclose.bezelStyle = .regularSquare
      disclose.imagePosition = .imageOnly
      disclose.image = NSImage(
        systemSymbolName: collapsed ? "chevron.forward" : "chevron.down",
        accessibilityDescription: collapsed ? "Expand" : "Collapse")
      disclose.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
      disclose.contentTintColor = .tertiaryLabelColor
      disclose.toolTip = collapsed ? "Expand" : "Collapse"
      disclose.identifier = NSUserInterfaceItemIdentifier(bucketKey)
      // The default rides along so one toggle knows which way to flip from an untouched bucket.
      disclose.tag = node.bucketCollapsedByDefault ? 1 : 0
      disclose.target = self
      disclose.action = #selector(toggleBucket(_:))
      cell.addSubview(disclose)

      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        disclose.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        disclose.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        disclose.widthAnchor.constraint(equalToConstant: 16),
        disclose.heightAnchor.constraint(equalToConstant: 16),
        label.trailingAnchor.constraint(lessThanOrEqualTo: disclose.leadingAnchor, constant: -6),
      ])
      return cell
    }

    if node.isHit {
      // A single search hit: the snippet on one line, dimmed and slightly inset so it reads as
      // a detail under its session header. Clicking it jumps the transcript to the match.
      let label = NSTextField(labelWithString: node.title)
      label.font = .systemFont(ofSize: 11)
      label.textColor = .secondaryLabelColor
      label.lineBreakMode = .byTruncatingTail
      label.translatesAutoresizingMaskIntoConstraints = false
      label.toolTip = node.title
      cell.addSubview(label)
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
        label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
      return cell
    }

    if node.isGroup {
      let label = NSTextField(labelWithString: node.title)
      label.font = .systemFont(ofSize: 11, weight: .semibold)
      label.textColor = .tertiaryLabelColor
      label.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(label)

      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
      if let repositoryID = node.repositoryID {
        // Our own disclosure, always visible rather than AppKit's hover-only Show/Hide (which
        // is suppressed by returning false from isGroupItem). Because it is a fixed control,
        // the `+` pinned to its left never shifts. It carries its repositoryID on
        // `identifier`, so one action serves every heading; `repositoryID` on a group node is
        // the group's own.
        let collapsed = collapsedRepositories.contains(repositoryID)
        let disclose = NSButton()
        disclose.translatesAutoresizingMaskIntoConstraints = false
        disclose.isBordered = false
        disclose.bezelStyle = .regularSquare
        disclose.imagePosition = .imageOnly
        disclose.image = NSImage(
          systemSymbolName: collapsed ? "chevron.forward" : "chevron.down",
          accessibilityDescription: collapsed ? "Expand" : "Collapse")
        disclose.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        disclose.contentTintColor = .tertiaryLabelColor
        disclose.toolTip = collapsed ? "Expand" : "Collapse"
        disclose.identifier = NSUserInterfaceItemIdentifier(repositoryID)
        disclose.target = self
        disclose.action = #selector(toggleGroup(_:))
        cell.addSubview(disclose)

        // A per-repository new-session control on the heading itself. A single footer button
        // has to guess a target worktree once several repositories are open; on the heading
        // the repository is unambiguous.
        let add = NSButton()
        add.translatesAutoresizingMaskIntoConstraints = false
        add.isBordered = false
        add.bezelStyle = .regularSquare
        add.imagePosition = .imageOnly
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New session")
        add.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        add.contentTintColor = .tertiaryLabelColor
        add.toolTip = "New session"
        add.identifier = NSUserInterfaceItemIdentifier(repositoryID)
        add.target = self
        add.action = #selector(newSessionInGroup(_:))
        cell.addSubview(add)

        NSLayoutConstraint.activate([
          disclose.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
          disclose.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
          disclose.widthAnchor.constraint(equalToConstant: 16),
          disclose.heightAnchor.constraint(equalToConstant: 16),

          add.trailingAnchor.constraint(equalTo: disclose.leadingAnchor, constant: -4),
          add.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
          add.widthAnchor.constraint(equalToConstant: 16),
          add.heightAnchor.constraint(equalToConstant: 16),
          label.trailingAnchor.constraint(lessThanOrEqualTo: add.leadingAnchor, constant: -6),
        ])
      }
      return cell
    }

    let dot = NSImageView()
    // A restored-but-not-reattached session must not wear the same face as a live one.
    let symbol = node.isDetached ? "circle" : (node.state?.symbolName ?? "circle.dashed")
    // The dot is the rail's one signal, so it must not be color-only: the description gives
    // VoiceOver the state the tint encodes.
    dot.image = NSImage(
      systemSymbolName: symbol,
      accessibilityDescription: node.isDetached ? "detached" : node.state?.label)
    dot.contentTintColor =
      node.isDetached ? .quaternaryLabelColor : (node.state?.tint ?? .quaternaryLabelColor)
    dot.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
    // A thinking session pulses; idle (green check) and needs-you (orange !) stay still, so
    // scanning the rail the one moving dot is the one still working. The row view is rebuilt
    // on every state change, so the effect starts and stops with the turn on its own.
    // Gated on `isTurnActive` for the same reason as the transcript's pill: `start()` sets
    // `.running` optimistically before any turn exists, so `.running` alone would pulse a
    // started-but-unprompted session that is not actually thinking.
    dot.setThinkingPulse(
      !node.isDetached && node.state == .running && node.session?.isTurnActive == true)

    let name = NSTextField(labelWithString: node.title)
    name.font = .systemFont(ofSize: 13)
    name.lineBreakMode = .byTruncatingTail
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    var trailing: [NSView] = []
    if let subtitle = node.subtitle {
      // Which worktree a session sits in survives a long title: it is the thing that
      // tells two sessions of the same name apart, so the title is what gives way.
      // Capped so the reverse cannot happen either.
      let worktree = NSTextField(labelWithString: subtitle)
      worktree.font = .systemFont(ofSize: 11)
      worktree.textColor = .tertiaryLabelColor
      worktree.lineBreakMode = .byTruncatingTail
      worktree.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
      worktree.setContentHuggingPriority(.defaultHigh, for: .horizontal)
      worktree.widthAnchor.constraint(lessThanOrEqualToConstant: 90).isActive = true
      trailing.append(worktree)
    }
    if node.terminalCount > 0 {
      let terminals = NSTextField(labelWithString: "⌘\(node.terminalCount)")
      terminals.font = .systemFont(ofSize: 10, weight: .medium)
      terminals.textColor = .quaternaryLabelColor
      trailing.append(terminals)
    }
    // In results mode a session header carries its hit count, so the list reads as "N matches
    // here" before it is even expanded. Its children are hit rows; a title-only match has none.
    if isSearching, node.children.first?.isHit == true {
      let count = NSTextField(labelWithString: "\(node.children.count)")
      count.font = .systemFont(ofSize: 10, weight: .semibold)
      count.textColor = .secondaryLabelColor
      count.setContentHuggingPriority(.defaultHigh, for: .horizontal)
      trailing.append(count)
    }
    // No diffstat here — it lives in the top bar for the selected worktree. In the rail the
    // state dot is the signal; the change size would just crowd the row.

    let row = NSStackView(views: [dot, name] + trailing)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    cell.addSubview(row)
    row.pin(to: cell)
    return cell
  }

  /// Built per click rather than kept around: what it offers depends on where the click
  /// landed, and `clickedRow` is only meaningful during the click.
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    let row = outlineView.clickedRow
    let node = row >= 0 ? outlineView.item(atRow: row) as? RailNode : nil
    // Offered on any row of the repository, not just its heading — with a rail this dense
    // the heading is a small target, and every row belongs to exactly one repository.
    if let repositoryID = node?.repositoryID {
      let new = NSMenuItem(
        title: "New Session",
        action: #selector(newSessionInClickedRepository(_:)), keyEquivalent: "")
      new.target = self
      new.representedObject = repositoryID
      menu.addItem(new)
      let close = NSMenuItem(
        title: "Close \((repositoryID as NSString).lastPathComponent)",
        action: #selector(closeClickedRepository(_:)), keyEquivalent: "")
      close.target = self
      close.representedObject = repositoryID
      menu.addItem(close)
      menu.addItem(.separator())
    }

    // nil target: this walks the responder chain up to the window controller, the same way
    // the empty-state button reaches it.
    menu.addItem(
      NSMenuItem(
        title: "Open Repository…",
        action: #selector(WorkspaceWindowController.openRepository(_:)),
        keyEquivalent: ""))
  }

  @objc private func closeClickedRepository(_ sender: NSMenuItem) {
    guard let repositoryID = sender.representedObject as? String else { return }
    onCloseRepository?(repositoryID)
  }

  @objc private func newSessionInClickedRepository(_ sender: NSMenuItem) {
    guard let repositoryID = sender.representedObject as? String else { return }
    newSession(inRepository: repositoryID)
  }

  /// Making a session in a collapsed repository expands it first — otherwise the row you just
  /// created lands out of sight. The reload that follows creation redraws the chevron open.
  private func newSession(inRepository repositoryID: String) {
    collapsedRepositories.remove(repositoryID)
    onNewSession?(repositoryID)
  }

  /// The heading's disclosure. Toggles this repository's collapsed state and reloads so the
  /// rows and the chevron's direction both follow.
  @objc private func toggleGroup(_ sender: NSButton) {
    guard let repositoryID = sender.identifier?.rawValue else { return }
    if collapsedRepositories.contains(repositoryID) {
      collapsedRepositories.remove(repositoryID)
    } else {
      collapsedRepositories.insert(repositoryID)
    }
    reload()
    view.window?.invalidateRestorableState()
  }

  /// A time bucket's disclosure. Records the flip as an explicit choice (in whichever of the two
  /// sets is the opposite of where it lands) so the bucket keeps it across reloads regardless of
  /// its default. The bucket's default rides on the button's `tag`, set when the row was built.
  @objc private func toggleBucket(_ sender: NSButton) {
    guard let key = sender.identifier?.rawValue else { return }
    let collapsed = bucketIsCollapsed(key: key, defaultCollapsed: sender.tag == 1)
    if collapsed {
      bucketsCollapsedByUser.remove(key)
      bucketsExpandedByUser.insert(key)
    } else {
      bucketsExpandedByUser.remove(key)
      bucketsCollapsedByUser.insert(key)
    }
    reload()
    view.window?.invalidateRestorableState()
  }

  /// The heading's `+`. The repositoryID rides on the button's `identifier`, set when the row
  /// was built, so one action handles whichever heading was clicked.
  @objc private func newSessionInGroup(_ sender: NSButton) {
    guard let repositoryID = sender.identifier?.rawValue else { return }
    newSession(inRepository: repositoryID)
  }

  /// Return/Enter in the rail: dive into the selected session. A heading or an empty-worktree row
  /// has no composer to focus, so it is a no-op — Return there simply does nothing.
  private func activateSelectedSession() {
    guard let node = outlineView.item(atRow: outlineView.selectedRow) as? RailNode,
      node.session != nil
    else { return }
    onActivateSession?()
  }

  /// Double-click a session row: the same dive as Return. Gated on the clicked row being a session
  /// so double-clicking a heading does not steal focus.
  @objc private func sessionRowDoubleClicked() {
    let row = outlineView.clickedRow
    guard row >= 0, let node = outlineView.item(atRow: row) as? RailNode, node.session != nil
    else { return }
    onActivateSession?()
  }

  /// The session name leads; the worktree it sits in follows, dimmed. Leading with the
  /// worktree would bury the thing actually being supervised.
  func outlineViewSelectionDidChange(_ notification: Notification) {
    if let expected = programmaticRow, outlineView.selectedRow == expected {
      programmaticRow = nil
      return
    }
    programmaticRow = nil
    guard !isUpdatingSelection,
      let node = outlineView.item(atRow: outlineView.selectedRow) as? RailNode
    else { return }
    if let session = node.session, let offset = node.matchOffset {
      // A search hit: open its session and jump the transcript to this occurrence.
      onSelectMatch?(session, offset, node.matchLength)
    } else if let session = node.session {
      onSelectSession?(session)
    } else if let worktree = node.worktree {
      onSelectWorktree?(worktree.id)
    }
  }
}
