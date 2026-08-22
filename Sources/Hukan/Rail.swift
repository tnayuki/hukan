import AppKit

// MARK: - Left: SESSIONS (the overview)

extension NSPasteboard.PasteboardType {
  /// The rail's reorder drag, carrying the dragged repository's id. Its own type rather than
  /// `.fileURL`, which is the obvious thing to write for a row that stands for a checkout and the
  /// wrong one: it would offer that checkout to Finder and to every app that takes a folder, when
  /// the only thing this drag means is "put this repository here".
  static let hukanRepositoryRow = NSPasteboard.PasteboardType("dev.tnayuki.hukan.repository-row")
}

/// A row in the rail. Sessions are what the rail lists; the worktree a session currently
/// works in rides along as a subtitle rather than a level of its own.
final class RailNode: NSObject {
  // What a row shows is mutable, so a reload that changed nothing structural can pour the fresh
  // state into the instance the outline already holds (see `adopt`) instead of handing it a new
  // one. What a row *is* — its session, worktree, keys — stays fixed, since that is its identity.
  var title: String
  var subtitle: String?
  var state: RunState?
  var isDetached: Bool
  /// Another live process owns this session (see `AgentSession.heldByPID`): the row greys and
  /// cannot be started, but stays selectable so its transcript still reads and searches.
  var heldElsewhere: Bool
  private(set) var worktree: Worktree?
  private(set) var session: AgentSession?
  var children: [RailNode]
  /// The two sub-headings a repository's rows carry. Both are labels over a run of rows rather
  /// than destinations — selecting one selects nothing — and both fold, each against its own
  /// default: `Worktrees` stands open unless its repository is in `collapsedWorktreeSections`,
  /// `Archived` stays folded unless its worktree is in `expandedArchives`.
  enum Section {
    case worktrees, archived
  }
  let section: Section?
  /// What the section's fold is remembered under: the repository id for `Worktrees`, the
  /// worktree id for `Archived`.
  let sectionKey: String?

  /// Take `other`'s state, keeping this instance. `other` was built for the same row — the same
  /// identity key, the same children in the same order — so only what is shown moves across;
  /// the session and worktree come too, because discovery can hand back a fresh object for the
  /// same id. Recurses, since a reload that left the tree's shape alone left every subtree's.
  func adopt(_ other: RailNode) {
    title = other.title
    subtitle = other.subtitle
    state = other.state
    isDetached = other.isDetached
    heldElsewhere = other.heldElsewhere
    worktree = other.worktree
    session = other.session
    for (mine, theirs) in zip(children, other.children) { mine.adopt(theirs) }
  }

  /// Set on a search-hit row: the character offset (and length) in the session's rendered
  /// transcript to jump to when the row is clicked. The title carries the snippet. A hit belongs
  /// to a session like a header does, so `matchOffset` is what tells a hit row from its header.
  let matchOffset: Int?
  let matchLength: Int
  var isHit: Bool { matchOffset != nil }

  var isSectionHeading: Bool { section != nil }
  /// The repository heading. It still carries main (selecting it selects main, so the row is a
  /// destination and not a bare label — an unselectable row here is what the selection restore's
  /// fallback used to land on and stick to), but main now has a row of its own beneath it and
  /// carries main's sessions. Told apart by `groupRepositoryID`.
  var isRepositoryHeading: Bool { groupRepositoryID != nil && session == nil }
  /// A worktree's heading, over its own sessions and reachable even when it has none. Every
  /// worktree gets one, main included — that is what makes a repository's children homogeneous,
  /// so the outline can own the indent and the fold instead of the rail drawing them.
  var isWorktreeHeading: Bool {
    worktree != nil && session == nil && groupRepositoryID == nil && section == nil
  }

  /// A stable identity for this row across reloads — a session by its id, a group by its
  /// repository, an empty worktree by its own id. The rail compares these before and after a
  /// reload to tell a pure reorder (worth a little animation) from a content-only change.
  var identityKey: String {
    if let session, let matchOffset { return "h:" + session.id.uuidString + ":\(matchOffset)" }
    if let session { return "s:" + session.id.uuidString }
    if let section, let sectionKey { return "\(section):" + sectionKey }
    if isRepositoryHeading { return "g:" + (repositoryID ?? title) }
    if let worktree { return "w:" + worktree.id.uuidString }
    return title
  }

  /// Which repository this row belongs to. Group headers carry it directly; every other row
  /// gets it from its worktree, so a right-click anywhere in the rail knows what to close.
  var repositoryID: String? { groupRepositoryID ?? worktree?.repositoryID }
  private let groupRepositoryID: String?

  /// Whether a heading's branch label would only repeat its directory name — the
  /// `git worktree add ../<repo>-<branch>` shape, where the two strings say one thing twice.
  /// A suffix, not a substring: "main" inside "domain" is a coincidence, not the convention.
  static func branchRepeatsDirectory(directory: String, branch: String) -> Bool {
    if directory == branch { return true }
    return ["-", "_", "."].contains { directory.hasSuffix($0 + branch) }
  }

  /// Whether this row is the one to land on when the prior selection is gone: the workspace's
  /// session if it has one, else that session's — or the selected worktree's — heading. Both
  /// pointers are unwrapped before anything is compared, because `worktree?.id == worktreeID`
  /// matched nil against nil and so picked the first row carrying no worktree, which is a time
  /// section heading: a label `shouldSelectItem` refuses, that a programmatic `selectRowIndexes`
  /// never asks about, and that then sticks through the next reload's `priorSelectionKey`.
  static func isFallbackSelection(_ node: RailNode, sessionID: UUID?, worktreeID: UUID?) -> Bool {
    if let session = node.session { return session.id == sessionID }
    // Only a row the rail would let you select — the restore path does not go through
    // `shouldSelectItem`, so the rule has to be applied here too.
    guard sessionID == nil, !node.isSectionHeading, let worktreeID else { return false }
    return node.worktree?.id == worktreeID
  }

  init(
    title: String, subtitle: String? = nil, state: RunState? = nil, isDetached: Bool = false,
    heldElsewhere: Bool = false,
    worktree: Worktree? = nil, session: AgentSession? = nil, children: [RailNode] = [],
    groupRepositoryID: String? = nil, section: Section? = nil, sectionKey: String? = nil,
    matchOffset: Int? = nil, matchLength: Int = 0
  ) {
    self.groupRepositoryID = groupRepositoryID
    self.title = title
    self.subtitle = subtitle
    self.state = state
    self.isDetached = isDetached
    self.heldElsewhere = heldElsewhere
    self.worktree = worktree
    self.session = session
    self.children = children
    self.section = section
    self.sectionKey = sectionKey
    self.matchOffset = matchOffset
    self.matchLength = matchLength
  }
}

/// A rail row. Nothing is drawn here any more: worktrees used to sit *beside* their repository
/// heading rather than under it, and a hairline down the gutter was what said "these belong to
/// HUKAN" in place of the level the tree did not have. Now that every child of a repository is a
/// worktree and every child of a worktree is a session, the outline's own indentation says it,
/// and a rule that is always on regardless is furniture rather than a signal.
///
/// The subclass stays because the rail asks for it in `rowViewForItem`, and because the one
/// constant below is still where every row's leading inset is read from.
final class RailRowView: NSTableRowView {
  /// How far in from the rail's leading edge a row's content starts. Levels past the first are
  /// already clear of it by the outline's own `indentationPerLevel`, so this is added once, to
  /// every row, rather than accumulated per level the way the old sibling layout had to.
  static let headingInset: CGFloat = 12
}

/// The rail's outline view, subclassed only to turn Return/Enter into an "enter this session"
/// signal. Arrow keys and type-select fall through to AppKit, so navigating the rail stays a
/// plain selection change; pressing Return is the master-detail dive that carries focus into the
/// composer.
final class RailOutlineView: NSOutlineView {
  var onActivate: (() -> Void)?
  /// ← or → asked for a fold: the item, and whether it is to be collapsed. Handed to the rail
  /// rather than done here with `collapseItem`, which AppKit refuses on an outline whose
  /// disclosure cell is hidden — this one's is, in favour of the chevron drawn into each heading.
  /// The rail folds the way its chevrons do: it writes the fold down and rebuilds.
  var onFold: ((Any, Bool) -> Void)?

  override func keyDown(with event: NSEvent) {
    // 36 = Return, 76 = keypad Enter, 123/124 = ← and →. Everything else (↑↓, first-letter jump)
    // falls through so the rail still navigates without stealing focus.
    switch event.keyCode {
    case 36, 76:
      onActivate?()
      return
    case 123 where moveFold(expand: false), 124 where moveFold(expand: true):
      return
    default:
      break
    }
    super.keyDown(with: event)
  }

  /// ← and → on the selected row, the way a source list behaves everywhere: → opens a folded row
  /// and steps into an open one, ← closes an open row and steps out of a closed one.
  ///
  /// Written out rather than left to AppKit, which was the assumption and was wrong: NSOutlineView
  /// hangs its own arrow handling off the disclosure triangle, and the rail suppresses that
  /// (`shouldShowOutlineCellForItem`) in favour of the chevron drawn into each heading — which
  /// also makes `collapseItem` a no-op, so the fold itself is the rail's (`onFold`).
  ///
  /// Returns whether the key was used; false falls through, so ← at the top level still does
  /// whatever AppKit would have done with it.
  private func moveFold(expand: Bool) -> Bool {
    let row = selectedRow
    guard row >= 0, let item = item(atRow: row) else { return false }
    func select(row target: Int) -> Bool {
      guard target >= 0, target < numberOfRows else { return false }
      selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
      scrollRowToVisible(target)
      return true
    }
    if expand {
      if isExpandable(item), !isItemExpanded(item) {
        onFold?(item, false)
        return true
      }
      // Already open: step into it. The first child is always the next row.
      guard isItemExpanded(item), numberOfChildren(ofItem: item) > 0 else { return false }
      return select(row: row + 1)
    }
    if isExpandable(item), isItemExpanded(item) {
      onFold?(item, true)
      return true
    }
    guard let parent = parent(forItem: item) else { return false }
    return select(row: self.row(forItem: parent))
  }
}

final class SessionRailViewController: NSViewController, NSOutlineViewDataSource,
  NSOutlineViewDelegate, NSMenuDelegate, NSSearchFieldDelegate
{
  var workspace: Workspace?
  var onSelectWorktree: ((UUID) -> Void)?
  var onSelectSession: ((AgentSession) -> Void)?
  var onCloseRepository: ((String) -> Void)?
  /// A repository was dragged to a new place in the rail's order. The workspace has already been
  /// rearranged; this only asks the window to redraw and re-record its state.
  var onReorderRepositories: (() -> Void)?
  var onNewSession: ((String) -> Void)?
  /// A linked worktree heading's `+`: start a session in that specific worktree (the repository
  /// heading's `+` starts one in main).
  var onNewSessionInWorktree: ((UUID) -> Void)?
  /// A file row folded into the rail was picked (a single click): open it as a preview tab, the one
  /// reused by the next pick so tabs do not pile up.
  var onStartSession: ((AgentSession) -> Void)?
  /// Delete a session for good — the rail has already confirmed, so the window just does it.
  var onDeleteSession: ((AgentSession) -> Void)?
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
  private let searchField = GestureSearchField()
  /// Says what ⏎ escalates to, while the field is focused. See `showSearchHint`.
  private let hintLabel = NSTextField(labelWithString: "")
  private lazy var hintHeight = hintLabel.heightAnchor.constraint(equalToConstant: 0)
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
  /// The rail is showing transcript matches (Return) rather than a title filter (typing). What
  /// Escape steps back out of, and what a reload has to keep rather than recompute.
  private var isSearchingTranscripts = false
  /// A transcript scan is in flight — the note under the rail says so, since a scan over every
  /// session's transcript is the one search here that is not instant. The note waits a beat
  /// (`scanNote`) so a scan that answers at once does not flash it.
  private var isScanning = false
  private var showsScanNote = false
  private var scanNote: DispatchWorkItem?
  /// Sessions whose hit rows are folded away in the result list. A long transcript can match
  /// dozens of times, and one such session would otherwise bury every other result; folding it
  /// leaves the session on the list (with its count) while giving the space back. Transient —
  /// a new query is a new result set, so it starts fresh.
  private var collapsedResultSessions: Set<UUID> = []
  /// Everything that decides which rows are *open*, as of the last reload. A reload whose tree
  /// has the same shape but a different arrangement still has to rebuild: `collapseItem` is
  /// refused on an outline whose disclosure cell is hidden, which this one's is, so the only way
  /// to apply a fold is `reloadData()` — which collapses everything — and then not expanding the
  /// row. Read off the workspace on each reload rather than flagged by whoever wrote a fold, so a
  /// set changed from anywhere — a chevron, a key, a script, a restore — is seen the same way.
  private struct Arrangement: Equatable {
    var repositories: Set<String>
    var worktrees: Set<String>
    var archives: Set<String>
    var worktreeSections: Set<String>
    var results: Set<UUID>
    /// A results list and the tree never share a shape, but they can share a key sequence (a
    /// results list of main's sessions reads like the tree minus its heading), so the mode is
    /// part of the arrangement rather than inferred from the keys.
    var searching: Bool
  }
  private var lastArrangement: Arrangement?
  private var arrangement: Arrangement {
    Arrangement(
      repositories: collapsedRepositories, worktrees: collapsedWorktrees,
      archives: expandedArchives, worktreeSections: collapsedWorktreeSections,
      results: collapsedResultSessions, searching: isSearching)
  }
  /// reloadData() clears the selection, and restoring it fires the selection-changed
  /// delegate. That runs onSelectWorktree, which reloads the window, which lands back here —
  /// mutual recursion that crashes. Ignore notifications while we are the ones driving.
  private var isUpdatingSelection = false
  /// The notification does not always arrive inside the flag's window — NSOutlineView can
  /// post it a runloop turn later, by which point the flag is back down and our own
  /// selection looks like a click. Remember the row we set so it can be recognised.
  private var programmaticRow: Int?
  /// The row navigation follows while several are selected: the one that joined the selection
  /// last. AppKit exposes no anchor, and `selectedRow` is the *lowest* selected index — which
  /// would send the transcript column to the top of a range the moment you shift-clicked
  /// downwards. Diffed against the previous selection instead, which is what "the row you last
  /// touched" actually means.
  private var selectedRows = IndexSet()
  private var anchorRow: Int?
  /// The `selectedSessionID` the last reload acted on. A fresh, non-nil session pick (a new
  /// session, an activation) differs from it and takes the rail's highlight; a background refresh,
  /// where it has not moved, leaves the user's own selection alone — a file row or a worktree
  /// heading that `selectedSessionID` does not describe, and which used to snap back to the session
  /// on every reload.
  private var lastAppliedSessionID: UUID?
  /// The rail's disclosure state lives on the workspace (so it rides the window's restorable
  /// state across a restart) — these bridge to it, leaving the rest of the rail's code unchanged.
  /// Each is the exception set to one default: a repository and a worktree stand open unless
  /// listed, an Archived section stays folded unless listed. One default apiece is what keeps
  /// these one set each — the time buckets needed two, because a bucket's default depended on
  /// which bucket it was.
  private var collapsedRepositories: Set<String> {
    get { workspace?.collapsedRepositories ?? [] }
    set { workspace?.collapsedRepositories = newValue }
  }
  private var collapsedWorktrees: Set<String> {
    get { workspace?.collapsedWorktrees ?? [] }
    set { workspace?.collapsedWorktrees = newValue }
  }
  private var expandedArchives: Set<String> {
    get { workspace?.expandedArchives ?? [] }
    set { workspace?.expandedArchives = newValue }
  }
  private var collapsedWorktreeSections: Set<String> {
    get { workspace?.collapsedWorktreeSections ?? [] }
    set { workspace?.collapsedWorktreeSections = newValue }
  }

  /// Up while the rail is telling the window where the selection went. The window answers by
  /// reloading, and reloading the *rail* there is both pointless and destructive: the rows are the
  /// ones it just drew, and rebuilding them clears the outline's selection — taking AppKit's own
  /// range origin with it, which is what ⇧↑/⇧↓ extends from. That is why a shift-extension could
  /// never reach a third row. Every keypress told the window, the window reloaded, and the reload
  /// handed the outline a brand-new selection whose origin was wherever the restore happened to
  /// put it, so the next ⇧ started over from two.
  private var isNotifyingSelection = false

  /// Keeps the rows' ages current: `3m` has to become `4m` with nothing else happening, and no
  /// reload runs for that. Redraws the rows in place — the cheap reload — once a minute while the
  /// rail is on screen, and stops when it is not. A minute, since that is the finest unit shown
  /// past the first one; the seconds a fresh session counts through are not worth a tick apiece.
  private var ageTick: Timer?

  /// Set across the reload a drop triggers, so the reorder cross-fade stays out of it. That fade
  /// exists to make a row that rose *on its own* register as motion; a row you just dragged needs
  /// no such announcement, and fading the whole list under the cursor reads as a glitch.
  private var isApplyingDrop = false

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
    outlineView.onFold = { [weak self] item, collapsed in self?.setFold(item, collapsed: collapsed)
    }
    // Several sessions can be selected at once, so one act — Archive, Delete, Stop — can reach a
    // handful of rows. It never changes what navigation means: the transcript column follows the
    // row you last touched (see `outlineViewSelectionDidChange`), so widening the selection widens
    // only what the context menu acts on. Restricted to sessions, and to one kind at a time, by
    // `selectionIndexesForProposedSelection`.
    outlineView.allowsMultipleSelection = true
    outlineView.target = self
    outlineView.doubleAction = #selector(sessionRowDoubleClicked)
    contextMenu.delegate = self
    outlineView.menu = contextMenu
    // Reordering the repositories. `.move` only inside this window, and nothing at all outside
    // it: the drag rearranges a list, it does not hand anything over.
    outlineView.registerForDraggedTypes([.hukanRepositoryRow])
    outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
    outlineView.setDraggingSourceOperationMask([], forLocal: false)
    // An insertion line rather than a gap: a repository is one outline item now, so a gap opened
    // inside the tree would read as a place among some worktree's rows — which is never where a
    // repository can land. The line only ever sits between two repositories.
    outlineView.draggingDestinationFeedbackStyle = .regular
    // Layer-backed so a reorder can be cross-faded (see `reload`). Without this the layer is
    // nil and the transition is simply skipped, so the rail still updates — just without the
    // little fade.
    outlineView.wantsLayer = true

    let scrollView = NSScrollView()
    scrollView.documentView = outlineView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    // One field, two operations told apart by gesture — the same rule the files panel follows.
    // Typing filters by title: in memory, instant, no disk touched. Return searches the
    // transcripts themselves, which means reading every session's file, so it waits to be asked
    // for and runs off the main thread from the moment the key lands.
    // The same word the files panel's field carries: what typing does is filter. Left unset,
    // AppKit substitutes "Search", which names the wrong one of the two gestures — and what ⏎
    // adds is said by `hintLabel`, for as long as the field has the focus that makes ⏎ mean
    // anything.
    searchField.placeholderString = "Filter"
    searchField.onFocusChange = { [weak self] focused in self?.showSearchHint(focused) }
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
    // Sits directly under the field, which is in the toolbar over this column, and only while
    // that field is being typed in.
    hintLabel.stringValue = "⏎ to search transcripts"
    hintLabel.font = .systemFont(ofSize: 11)
    hintLabel.textColor = .tertiaryLabelColor
    hintLabel.alignment = .center
    hintLabel.isHidden = true
    hintLabel.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(hintLabel)
    container.addSubview(scrollView)
    container.addSubview(emptyLabel)
    NSLayoutConstraint.activate([
      // The list starts at the safe area: the rail runs the window's full height, and the
      // titlebar region above — traffic lights, the sidebar toggle, and now this rail's own
      // search field (`filterSearchField`) — is the toolbar's, not the list's.
      hintLabel.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
      hintLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      hintLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      hintHeight,
      scrollView.topAnchor.constraint(equalTo: hintLabel.bottomAnchor),
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

  override func viewWillAppear() {
    super.viewWillAppear()
    ageTick?.invalidate()
    let tick = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
      guard let self, isViewLoaded else { return }
      outlineView.reloadData(
        forRowIndexes: IndexSet(0..<outlineView.numberOfRows), columnIndexes: IndexSet(integer: 0))
    }
    tick.tolerance = 10
    RunLoop.main.add(tick, forMode: .common)
    ageTick = tick
  }

  override func viewDidDisappear() {
    super.viewDidDisappear()
    ageTick?.invalidate()
    ageTick = nil
  }

  // MARK: - Full-text search

  /// Typing filters by title, live and in memory. Editing the query also drops any transcript
  /// results: what is on the rail must never be the answer to a query no longer in the field.
  /// The field took or lost focus: show or hide the line that names the second gesture. Animated
  /// so the list does not jump under the eye.
  private func showSearchHint(_ shown: Bool) {
    guard isViewLoaded else { return }
    hintLabel.isHidden = !shown
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      hintHeight.animator().constant = shown ? 18 : 0
    }
  }

  func controlTextDidChange(_ obj: Notification) {
    guard (obj.object as? NSSearchField) === searchField else { return }
    applyTitleFilter()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard control === searchField else { return false }
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      runTranscriptSearch()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      // Escape backs out one step: the transcript results first, then the query itself.
      if isSearchingTranscripts {
        applyTitleFilter()
      } else if !searchField.stringValue.isEmpty {
        searchField.stringValue = ""
        applyTitleFilter()
      }
      return true
    default:
      return false
    }
  }

  /// Narrow to the sessions whose title contains every term. No disk, no queue — the titles are
  /// already in memory, so this is the keystroke-rate half of the field.
  private func applyTitleFilter() {
    pendingSearch?.cancel()
    // Any transcript scan still running belongs to an older query now.
    searchGeneration += 1
    scanNote?.cancel()
    isScanning = false
    showsScanNote = false
    isSearchingTranscripts = false
    hits = [:]
    let terms = Self.terms(searchField.stringValue)
    guard !terms.isEmpty else {
      matches = nil
      reload()
      onSearchChanged?()
      return
    }
    matches = Set(
      searchRequests().filter { request in
        terms.allSatisfy { request.title.contains($0) }
      }.map(\.id))
    reload()
    onSearchChanged?()
  }

  /// Return: search the transcripts. Kicked off at once — no debounce, since the gesture *is*
  /// the commit — and the reading happens on `searchQueue`, so the field stays live throughout.
  private func runTranscriptSearch() {
    pendingSearch?.cancel()
    guard !Self.terms(searchField.stringValue).isEmpty else {
      applyTitleFilter()
      return
    }
    isSearchingTranscripts = true
    isScanning = true
    collapsedResultSessions = []
    scanNote?.cancel()
    showsScanNote = false
    let note = DispatchWorkItem { [weak self] in
      guard let self, self.isScanning else { return }
      self.showsScanNote = true
      self.reload()
    }
    scanNote = note
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: note)
    reload()
    runSearch(searchField.stringValue)
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
        self.scanNote?.cancel()
        self.isScanning = false
        self.showsScanNote = false
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
    scanNote?.cancel()
    isScanning = false
    showsScanNote = false
    isSearchingTranscripts = !Self.terms(raw).isEmpty
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

  /// The field itself, for the toolbar's sidebar section to host in an `NSSearchToolbarItem` —
  /// the rail's own header row moved up beside the sidebar toggle, into the strip the traffic
  /// lights already occupy, so the list starts at the top of the rail. The rail keeps the field
  /// (delegate, the two gestures, the query everything below reads); the window only places it.
  var filterSearchField: NSSearchField {
    loadViewIfNeeded()
    return searchField
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

  /// Every selected row's session, top to bottom — the anchor is `workspace.selectedSession`.
  /// Exposed for the scripting surface: a multi-selection is rows on a list with no text to read
  /// back, so checking one any other way means clicking at coordinates.
  var selectedSessionIDs: [UUID] {
    outlineView.selectedRowIndexes.compactMap {
      (outlineView.item(atRow: $0) as? RailNode)?.session?.id
    }
  }

  /// The outline itself, for the tests that have to drive a real one — the selection rules are
  /// delegate callbacks, so there is nothing to exercise without a view behind them.
  var outlineViewForTesting: NSOutlineView { outlineView }

  /// `setArchived` without a menu item in front of it, for the same reason.
  func archiveForTesting(_ sessions: [AgentSession]) { setArchived(true, sessions) }

  /// Select exactly these sessions, the last of them as the anchor — the scripted counterpart of
  /// ⌘-clicking a few rows. Rows that are not on the rail (a session inside a folded section, one
  /// filtered away) are skipped rather than refused, the way a click on a row that is not there
  /// would be. Drives the same selection change a click does, so the anchor, the transcript column
  /// and the context menu all follow from it.
  func selectSessions(_ ids: [UUID]) {
    loadViewIfNeeded()
    var rows = IndexSet()
    var anchor: Int?
    for id in ids {
      guard
        let row = (0..<outlineView.numberOfRows).first(where: {
          (outlineView.item(atRow: $0) as? RailNode)?.session?.id == id
        })
      else { continue }
      rows.insert(row)
      anchor = row
    }
    guard !rows.isEmpty else { return }
    // Both set *before* the selection changes, because the delegate that follows derives the
    // anchor by diffing the new selection against `selectedRows` — left describing the old set, it
    // would take the highest new row and overrule the anchor named here. Written as the incoming
    // set, the diff is empty and the delegate keeps the anchor it is given.
    selectedRows = rows
    anchorRow = anchor
    programmaticRow = nil
    outlineView.selectRowIndexes(rows, byExtendingSelection: false)
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
    // See `isNotifyingSelection`. The pointer is taken anyway, so the next real reload does not
    // mistake it for a pick made somewhere else.
    if isNotifyingSelection {
      lastAppliedSessionID = workspace.selectedSessionID
      return
    }
    let before = flattenedKeys(nodes)
    let previous = nodes
    // `subtitled` tags the row with its worktree — wanted only in search results, where matched
    // sessions from every worktree sit in one flat list. In the tree the session already hangs
    // under its worktree's heading, so repeating the branch on every row said nothing.
    func node(for entry: Workspace.RailEntry, subtitled: Bool = false) -> RailNode {
      let (session, worktree) = (entry.session, entry.worktree)
      return RailNode(
        title: session.title ?? "New session",
        subtitle: subtitled ? worktree.displayName : nil,
        state: session.state,
        isDetached: session.isDetached,
        heldElsewhere: session.heldByPID != nil,
        worktree: worktree,
        session: session)
    }
    // A worktree's rows: its sessions plainly, then the Archived section if it holds anything.
    // There is no "Sessions" label over the plain ones — a worktree's rows *are* its sessions, so
    // the label would name the obvious and charge an indent for it. The section below them names
    // something the rows do not say, which is the difference.
    func worktreeChildren(_ railWorktree: Workspace.RailWorktree) -> [RailNode] {
      var rows = railWorktree.sessions.map { node(for: $0) }
      guard !railWorktree.archived.isEmpty else { return rows }
      rows.append(
        RailNode(
          title: "Archived",
          children: railWorktree.archived.map { node(for: $0) },
          section: .archived, sectionKey: railWorktree.worktree.id.uuidString))
      return rows
    }
    // A linked worktree's heading, over its own rows. It names its directory then its branch —
    // whoever ran `git worktree add` chose the directory and git chose the branch, so the two
    // drift, and a path in an agent's output has to match something on screen. Main has no heading
    // of its own: it is the repository heading, which says its branch there.
    func worktreeNode(_ railWorktree: Workspace.RailWorktree) -> RailNode {
      let worktree = railWorktree.worktree
      return RailNode(
        title: worktree.url.lastPathComponent, subtitle: worktree.branch,
        worktree: worktree,
        children: worktreeChildren(railWorktree))
    }
    // A live query turns the rail into a results list (see `resultsNodes`); otherwise it is the
    // worktree-first tree: the repository heading is its main worktree, carrying main's rows, and
    // each linked worktree a heading beneath it with its own.
    func resultRow(_ entry: Workspace.RailEntry) -> RailNode { node(for: entry, subtitled: true) }
    if isSearching {
      nodes = resultsNodes(resultRow)
    } else {
      // Linked worktrees are *children* of the repository heading. They used to stand beside it as
      // top-level rows, which meant a repository was a run of rows rather than one item, and the
      // three things an outline does for a tree all had to be done by hand: the fold (collapsing
      // the heading hid only its own children), the indent (a linked worktree's sessions were at
      // level 1, the same as main's, so which parent a row had was unreadable to the outline) and
      // the drag (a drop had to snap back to the start of a block). A hairline down the gutter was
      // drawn in place of the level that was missing — and that was the level's real absence, not
      // the fact that a repository's children are two kinds. As children they sit under the
      // heading already, so there is nothing left for a rule to say.
      nodes = workspace.railRepositories.map { repo in
        // The linked worktrees under a heading of their own, beneath main's rows. A repository's
        // children are two kinds — main's sessions and its worktrees — and the label is what tells
        // the block of worktree rows from the session rows above it. Only when there are any: a
        // repository with one checkout has no section, not an empty one.
        var children = repo.main.map(worktreeChildren) ?? []
        if !repo.linked.isEmpty {
          children.append(
            RailNode(
              title: "Worktrees", children: repo.linked.map(worktreeNode),
              section: .worktrees, sectionKey: repo.repositoryID))
        }
        return RailNode(
          title: repo.repositoryName.uppercased(),
          // Main's branch, after the project name — the heading *is* the main worktree, and the
          // linked worktrees all name their branch on their own headings, so the root says its the
          // same way. `branch` directly, not displayName: its fallback is the folder name, which
          // would just repeat the heading.
          subtitle: repo.main?.worktree.branch,
          worktree: repo.main?.worktree,
          children: children,
          groupRepositoryID: repo.repositoryID)
      }
    }
    // The "nothing matched" note, shown only when a query is live and cleared everything.
    // "Searching…" while a transcript scan is out, so an empty rail mid-scan does not read as
    // "nothing matched"; the no-match note takes over once the answer is in.
    emptyLabel.stringValue = showsScanNote ? "Searching transcripts…" : "No matching sessions"
    emptyLabel.isHidden = !((isSearching || showsScanNote) && nodes.isEmpty)

    isUpdatingSelection = true
    defer {
      isUpdatingSelection = false
      lastArrangement = arrangement
      lastAppliedSessionID = workspace.selectedSessionID
    }

    // Two kinds of reload. Most are the first: something a row *shows* moved — a title arrived,
    // a dot changed colour, a diffstat ticked — and the tree's shape did not. Those are redrawn in
    // place, into the instances the outline already holds, so AppKit keeps everything it owns:
    // the selection, the row a ⇧-range extends from, which items are open, where the scroll is.
    // The rail used to `reloadData()` for all of them, and every one of those cleared the lot;
    // the restore below put the selection back but could not put back the range's origin, which
    // is what made a ⇧↑ never reach a third row. Only a change of shape — a row appearing,
    // leaving or moving, a fold, the switch into or out of a results list — rebuilds.
    let after = flattenedKeys(nodes)
    let sameShape = !before.isEmpty && before == after && arrangement == lastArrangement
    if sameShape {
      for (mine, theirs) in zip(previous, nodes) { mine.adopt(theirs) }
      nodes = previous
      outlineView.reloadData(
        forRowIndexes: IndexSet(0..<outlineView.numberOfRows), columnIndexes: IndexSet(integer: 0))
      applyExternalPick(workspace)
      return
    }

    // The reader's scroll position, to put back at the end. `reloadData()` collapses the whole
    // tree before the re-expansion below rebuilds it, and because the RailNodes are made fresh
    // the outline cannot anchor to its old items — the clip origin clamps to the momentarily-
    // shrunken height and the view jumps (usually to the top).
    let clip = outlineView.enclosingScrollView?.contentView
    let savedScrollOrigin = clip?.bounds.origin
    // The rows the user was on, by stable identity, to put the highlight back after `reloadData()`
    // clears it. A set, not one key: a batch act may be lined up on several. Captured now, while
    // the old items are still in the outline.
    let priorSelectionKeys = Set(
      outlineView.selectedRowIndexes.compactMap { selectionKey(of: outlineView.item(atRow: $0)) })
    let priorAnchorKey = anchorRow.flatMap { selectionKey(of: outlineView.item(atRow: $0)) }

    // The rows moved but the set is the same (a session rose or sank in the order): cross-fade
    // the reload so the reshuffle registers as motion rather than an instant jump. Restricted
    // to a pure reorder — a row appearing or disappearing is a different event and updates
    // plainly, and the first population (empty `before`) has nothing to animate from.
    if !isApplyingDrop, !before.isEmpty, before != after, Set(before) == Set(after) {
      let transition = CATransition()
      transition.type = .fade
      transition.duration = 0.22
      outlineView.layer?.add(transition, forKey: "reorder")
    }

    outlineView.reloadData()
    // reloadData leaves every item collapsed, so this pass is what makes anything below the top
    // level show at all. Three defaults, one exception set each (see `collapsedRepositories`).
    // Nothing is folded during a search — hiding a match behind a fold reads as no match. A fold
    // *is* allowed to hide the selected row: the transcript column goes on showing what it was
    // showing, which is what a sidebar fold does everywhere. The time buckets needed the opposite
    // rule only because their fold was automatic — "Older" collapsed itself on every reload, so a
    // session selected inside it was folded away again by the next background refresh, without
    // anyone having asked. Every fold left is an explicit one.
    func isCollapsed(_ node: RailNode) -> Bool {
      guard !isSearching else { return false }
      if node.isRepositoryHeading, let repositoryID = node.repositoryID {
        return collapsedRepositories.contains(repositoryID)
      }
      if node.isWorktreeHeading, let worktree = node.worktree {
        return collapsedWorktrees.contains(worktree.id.uuidString)
      }
      if let section = node.section, let key = node.sectionKey {
        switch section {
        case .archived: return !expandedArchives.contains(key)
        case .worktrees: return collapsedWorktreeSections.contains(key)
        }
      }
      // A matched session's hit rows in results mode, folded by the reader.
      if let session = node.session { return collapsedResultSessions.contains(session.id) }
      return false
    }
    // A folded node's children still get their state applied — expanding it later must reveal them
    // in the shape they were left, not a fresh-from-reloadData collapse.
    func applyNode(_ node: RailNode) {
      guard !node.children.isEmpty else { return }
      if !isCollapsed(node) { outlineView.expandItem(node) }
      for child in node.children { applyNode(child) }
    }
    for node in nodes { applyNode(node) }

    // Put the rail's highlighted rows back. reloadData() cleared them; the rows to restore are the
    // ones the user was on — sessions, but also a worktree heading, which `selectedSessionID`
    // cannot describe. A pick from elsewhere overrides that (see `applyExternalPick`).
    var targetRows = IndexSet()
    var targetAnchor: Int?
    if !applyExternalPick(workspace), !priorSelectionKeys.isEmpty {
      for row in 0..<outlineView.numberOfRows {
        guard let key = selectionKey(of: outlineView.item(atRow: row)) else { continue }
        if priorSelectionKeys.contains(key) { targetRows.insert(row) }
        if key == priorAnchorKey { targetAnchor = row }
      }
    }
    if targetRows.isEmpty, outlineView.selectedRowIndexes.isEmpty {
      // The prior selection is gone (its session closed, its row folded away): fall back to
      // whatever the workspace points at — the session, else its worktree heading. Nothing selected
      // at all (a window restored with an empty pointer) leaves the rail unhighlighted, which is
      // the honest answer; see `isFallbackSelection`.
      if let row = (0..<outlineView.numberOfRows).first(where: { index in
        guard let node = outlineView.item(atRow: index) as? RailNode else { return false }
        return RailNode.isFallbackSelection(
          node, sessionID: workspace.selectedSessionID, worktreeID: workspace.selectedWorktreeID)
      }) {
        targetRows = IndexSet(integer: row)
        targetAnchor = row
      }
    }
    if !targetRows.isEmpty, outlineView.selectedRowIndexes != targetRows {
      // Only a single restore can be recognised later by row (see `programmaticRow`); a wider one
      // is covered by `isUpdatingSelection`, which is up for the whole of this block.
      programmaticRow = targetRows.count == 1 ? targetRows.first : nil
      outlineView.selectRowIndexes(targetRows, byExtendingSelection: false)
      selectedRows = targetRows
      anchorRow = targetAnchor ?? targetRows.last
    }

    // Put the reader back where they were. A shorter tree clamps this to the new bottom on its
    // own; selection is left as found, so this never fights a click (a clicked row is already in
    // view). Only a content refresh is being smoothed here, not a deliberate navigation.
    if let clip, let savedScrollOrigin, clip.bounds.origin != savedScrollOrigin {
      clip.scroll(to: savedScrollOrigin)
      outlineView.enclosingScrollView?.reflectScrolledClipView(clip)
    }
  }

  /// A pick from *elsewhere* — a new session, a tapped notification, an activation by key —
  /// replaces the selection outright: the window is pointing somewhere new, and carrying a
  /// multi-selection into that would leave rows highlighted that have nothing to do with where
  /// you just went. Returns whether there was one.
  ///
  /// A pick the rail itself made is not that, and telling them apart is what the last test is
  /// for: ⌘-clicking a second row moves the anchor, which the window follows by pointing at it,
  /// and a reload that treated that as a fresh pick would collapse the selection to one row the
  /// instant it was widened. The row already being selected is exactly what says which it is.
  @discardableResult
  private func applyExternalPick(_ workspace: Workspace) -> Bool {
    guard let sessionID = workspace.selectedSessionID, sessionID != lastAppliedSessionID,
      !selectedSessionIDs.contains(sessionID),
      let row = (0..<outlineView.numberOfRows).first(where: {
        (outlineView.item(atRow: $0) as? RailNode)?.session?.id == sessionID
      })
    else { return false }
    programmaticRow = row
    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    selectedRows = IndexSet(integer: row)
    anchorRow = row
    return true
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
  /// reorder from a content change — and, since `reload` redraws in place when they are equal,
  /// to tell the same *shape*. The depth rides in the key for that: a flat sequence alone cannot
  /// say which parent a row is under.
  private func flattenedKeys(_ nodes: [RailNode], depth: Int = 0) -> [String] {
    nodes.flatMap { ["\(depth):" + $0.identityKey] + flattenedKeys($0.children, depth: depth + 1) }
  }

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    if let node = item as? RailNode { return node.children.count }
    return nodes.count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    if let node = item as? RailNode { return node.children[index] }
    return nodes[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    if let node = item as? RailNode { return !node.children.isEmpty }
    return false
  }

  // Deliberately not a group item to AppKit: a source-list group row grows its own Show/Hide
  // disclosure on hover at the trailing edge, which would fight the always-visible one drawn in
  // the cell. The heading still reads as a heading because the cell styles it, and it stays
  // unselectable via shouldSelectItem below.
  func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
    false
  }

  // Suppress AppKit's own disclosure triangle: every heading carries its own chevron. This also
  // makes `collapseItem` a no-op — AppKit ties collapsibility to the cell — which is why every
  // fold here goes through the exception sets and a rebuild (see `Arrangement`).
  func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
    false
  }

  // MARK: - Reordering repositories

  /// Only the repository heading is a handle, because it is the only row that *is* what moves:
  /// grab it and everything under it comes along, because it *is* one outline item now. A worktree
  /// heading is inside it, so dragging one would move something above it — the same "you cannot
  /// tell what you grabbed" that keeps session rows out, and the reason neither is offered even
  /// though the context menu is offered on every row (a menu names what it acts on; a drag
  /// cannot).
  ///
  /// Never while searching: the results list is not in repository order, so there is no order
  /// there to rearrange.
  func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any)
    -> NSPasteboardWriting?
  {
    guard !isSearching, let node = item as? RailNode, node.isRepositoryHeading,
      let repositoryID = node.repositoryID
    else { return nil }
    let entry = NSPasteboardItem()
    entry.setString(repositoryID, forType: .hukanRepositoryRow)
    return entry
  }

  func outlineView(
    _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
    proposedChildIndex index: Int
  ) -> NSDragOperation {
    guard !isSearching, draggedRepositoryID(from: info) != nil,
      let boundary = dropBoundary(item: item, childIndex: index)
    else { return [] }
    // Retarget rather than refuse. Most of what the outline proposes — a drop *on* a row, or a
    // place among some heading's children — is not a position in the repository order at all, and
    // refusing those would blink the insertion line out over most of the rail: "not here", when
    // the answer is "here, at this boundary".
    outlineView.setDropItem(nil, dropChildIndex: boundary)
    return .move
  }

  func outlineView(
    _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int
  ) -> Bool {
    guard let workspace, let repositoryID = draggedRepositoryID(from: info),
      let boundary = dropBoundary(item: item, childIndex: index)
    else { return false }
    // The boundary is a row; what the move needs is the repository that row starts — or nil at the
    // end of the list, which is the one boundary with no repository after it.
    let before = boundary < nodes.count ? nodes[boundary].repositoryID : nil
    guard workspace.moveRepository(repositoryID, before: before) else { return false }
    isApplyingDrop = true
    defer { isApplyingDrop = false }
    onReorderRepositories?()
    return true
  }

  private func draggedRepositoryID(from info: NSDraggingInfo) -> String? {
    info.draggingPasteboard.string(forType: .hukanRepositoryRow)
  }

  /// The repository boundary a proposed drop belongs to, as an index into the top level. A
  /// repository is one outline item, so its own index is already a position in the order — a drop
  /// anywhere inside it is a drop on it, and there is no run of rows to snap down through. `-1`,
  /// which is what the space under the last row proposes ("on the outline itself"), is the end of
  /// the list.
  ///
  /// Static, and given the nodes, so the rule can be exercised without an outline view behind it.
  static func dropBoundary(_ nodes: [RailNode], item: Any?, childIndex index: Int) -> Int? {
    guard !nodes.isEmpty else { return nil }
    if let node = item as? RailNode { return topLevelIndex(nodes, of: node) }
    return index < 0 ? nodes.count : min(max(index, 0), nodes.count)
  }

  /// Which top-level row a node sits under — itself, if it is one.
  static func topLevelIndex(_ nodes: [RailNode], of node: RailNode) -> Int? {
    func holds(_ parent: RailNode) -> Bool {
      parent === node || parent.children.contains(where: holds)
    }
    return nodes.firstIndex(where: holds)
  }

  private func dropBoundary(item: Any?, childIndex index: Int) -> Int? {
    Self.dropBoundary(nodes, item: item, childIndex: index)
  }

  func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
    RailRowView()
  }

  func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
    // A repository or worktree heading is a destination — selecting it selects that worktree and
    // shows its desk, so a worktree with no session is still reachable. Only the two section
    // headings are pure labels.
    guard let node = item as? RailNode else { return false }
    return !node.isSectionHeading
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
    -> NSView?
  {
    guard let node = item as? RailNode else { return nil }
    let cell = NSTableCellView()
    // One inset for every row: the outline's own `indentationPerLevel` does the rest, because the
    // tree is now a real one — HUKAN at 12, its worktrees at 22, their sessions at 32, an Archived
    // section beside the sessions and its rows at 42. This used to have to be worked out by
    // walking up the tree, since a session under a linked worktree and one under the repository
    // heading were both at level 1 and the outline could not tell them apart.
    let indent = RailRowView.headingInset

    if let section = node.section, let sectionKey = node.sectionKey {
      // A section heading — Worktrees over the linked worktrees, Archived at the foot of main's
      // sessions. Plain case and dimmed, so it never reads like the uppercased repository heading
      // above it. No count: what is in it is one click away, and a number beside every label is
      // a second thing to read on a row whose job is to be one word. No `+` either: nothing new
      // is ever made here.
      let label = NSTextField(labelWithString: node.title)
      label.font = .systemFont(ofSize: 11, weight: .medium)
      label.textColor = .tertiaryLabelColor
      label.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(label)

      let expanded: Bool
      switch section {
      case .archived: expanded = expandedArchives.contains(sectionKey)
      case .worktrees: expanded = !collapsedWorktreeSections.contains(sectionKey)
      }
      let disclose = NSButton()
      disclose.translatesAutoresizingMaskIntoConstraints = false
      disclose.isBordered = false
      disclose.bezelStyle = .regularSquare
      disclose.imagePosition = .imageOnly
      disclose.image = NSImage(
        systemSymbolName: expanded ? "chevron.down" : "chevron.forward",
        accessibilityDescription: expanded ? "Collapse" : "Expand")
      disclose.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
      disclose.contentTintColor = .tertiaryLabelColor
      disclose.toolTip = expanded ? "Collapse" : "Expand"
      disclose.identifier = NSUserInterfaceItemIdentifier(sectionKey)
      // Which section rides on `tag`, so one action serves both headings.
      disclose.tag = section == .archived ? 0 : 1
      disclose.target = self
      disclose.action = #selector(toggleSection(_:))
      cell.addSubview(disclose)

      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: indent),
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
        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: indent + 8),
        label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
      return cell
    }

    if node.isRepositoryHeading {
      let label = NSTextField(labelWithString: node.title)
      label.font = .systemFont(ofSize: 11, weight: .semibold)
      label.textColor = .tertiaryLabelColor
      label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
      label.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(label)

      NSLayoutConstraint.activate([
        // Past the gutter the line runs down. This is the rail's leftmost edge — everything else
        // is a step in from it.
        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: indent),
        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
      // Main's branch, after the project name. Plain case (branch names are case-sensitive;
      // uppercasing is the project name's own dress) and quieter weight, so the pair reads as
      // name-then-detail. It truncates before the name does — the project tells you where you are,
      // the branch is the refinement.
      var branchLabel: NSTextField?
      if let branch = node.subtitle {
        let detail = NSTextField(labelWithString: branch)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .quaternaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(detail)
        NSLayoutConstraint.activate([
          detail.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
          detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        branchLabel = detail
      }
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

        // A per-repository new-session control on the heading itself, which is main: a single
        // footer button has to guess a target worktree once several repositories are open, and on
        // the heading the repository is unambiguous.
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
          // The rightmost text — the branch when it shows, else the name — stops short of the
          // controls, so a long branch truncates rather than running under the `+`.
          (branchLabel ?? label).trailingAnchor.constraint(
            lessThanOrEqualTo: add.leadingAnchor, constant: -6),
        ])
      }
      return cell
    }

    if node.isWorktreeHeading, let worktree = node.worktree {
      // A linked worktree's heading — plain case, medium, dimmed, so it sits between the
      // uppercased repository above and the session rows below. It carries its own `+` so a
      // session can start in this worktree, stays selectable (its files reachable) even with no
      // session under it, and folds: a worktree you are not on is a block of rows you are not
      // reading. Main has no such row — it is the repository heading, which folds the same way.
      let label = NSTextField(labelWithString: node.title)
      label.font = .systemFont(ofSize: 11, weight: .medium)
      label.textColor = .tertiaryLabelColor
      // Truncated at the head, not the tail. These names share a prefix and differ at the end
      // (`hukan-worktree-heading`, `hukan-files-panel`), so tail truncation dropped exactly the
      // half that identifies the worktree and left three rows all reading `hukan-worktree-…`.
      label.lineBreakMode = .byTruncatingHead
      label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
      label.translatesAutoresizingMaskIntoConstraints = false
      // Whatever the row had to shorten stays readable here, the branch included even when it
      // has no label of its own.
      label.toolTip = [node.title, node.subtitle].compactMap { $0 }.joined(separator: " — ")
      cell.addSubview(label)

      // Directory then branch, for a linked worktree — git names the branch but whoever created
      // the worktree named the directory, so the two drift, and a path in an agent's output has to
      // match something on screen. Main carries no branch label because its title already *is* its
      // branch (see `worktreeNode`). Read as name-then-detail rather than a level of its own.
      //
      // Unless the directory name already ends in the branch, which is what `git worktree add
      // ../<repo>-<branch>` produces and so the common case: past the source-list inset, the
      // indent and the `+`, a 200pt rail leaves this row about 117pt, and the directory name
      // alone wants more than that. Spending it on the same string twice squeezed the branch to
      // nothing and truncated the name as well, so the half that repeats is the half to drop.
      var branchLabel: NSTextField?
      if let branch = node.subtitle,
        !RailNode.branchRepeatsDirectory(directory: node.title, branch: branch)
      {
        let detail = NSTextField(labelWithString: branch)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .quaternaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(detail)
        NSLayoutConstraint.activate([
          detail.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
          detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        branchLabel = detail
      }

      let add = NSButton()
      add.translatesAutoresizingMaskIntoConstraints = false
      add.isBordered = false
      add.bezelStyle = .regularSquare
      add.imagePosition = .imageOnly
      add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New session")
      add.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
      add.contentTintColor = .tertiaryLabelColor
      add.toolTip = "New session"
      add.identifier = NSUserInterfaceItemIdentifier(worktree.id.uuidString)
      add.target = self
      add.action = #selector(newSessionInWorktree(_:))
      cell.addSubview(add)

      // Its own chevron, the way the repository heading carries one — the rail suppresses AppKit's
      // triangle, so this is what folds a worktree by mouse. A worktree with nothing under it
      // shows none: a control that would do nothing is worse than no control.
      var disclose: NSButton?
      if !node.children.isEmpty {
        let collapsed = collapsedWorktrees.contains(worktree.id.uuidString)
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.image = NSImage(
          systemSymbolName: collapsed ? "chevron.forward" : "chevron.down",
          accessibilityDescription: collapsed ? "Expand" : "Collapse")
        button.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        button.contentTintColor = .tertiaryLabelColor
        button.toolTip = collapsed ? "Expand" : "Collapse"
        button.identifier = NSUserInterfaceItemIdentifier(worktree.id.uuidString)
        button.target = self
        button.action = #selector(toggleWorktree(_:))
        cell.addSubview(button)
        NSLayoutConstraint.activate([
          button.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
          button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
          button.widthAnchor.constraint(equalToConstant: 16),
          button.heightAnchor.constraint(equalToConstant: 16),
        ])
        disclose = button
      }

      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: indent),
        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        disclose.map { add.trailingAnchor.constraint(equalTo: $0.leadingAnchor, constant: -4) }
          ?? add.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        add.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        add.widthAnchor.constraint(equalToConstant: 16),
        add.heightAnchor.constraint(equalToConstant: 16),
        (branchLabel ?? label).trailingAnchor.constraint(
          lessThanOrEqualTo: add.leadingAnchor, constant: -6),
      ])
      return cell
    }

    let dot = NSImageView()
    // Held-elsewhere and detached are both process-ownership facts that override the turn state:
    // a session another process holds cannot be acted on (a lock), and a restored-but-not-
    // reattached one must not wear a live face (a plain grey ring). Held outranks detached — a
    // held session is detached too, but "someone else has it" is the more useful thing to show.
    let symbol: String
    let tint: NSColor
    let axLabel: String?
    if node.heldElsewhere {
      symbol = "lock.circle"
      tint = .tertiaryLabelColor
      axLabel = "held by another process"
    } else if node.isDetached {
      symbol = "circle"
      tint = .quaternaryLabelColor
      axLabel = "detached"
    } else {
      symbol = node.state?.symbolName ?? "circle.dashed"
      tint = node.state?.tint ?? .quaternaryLabelColor
      axLabel = node.state?.label
    }
    // The dot is the rail's one signal, so it must not be color-only: the description gives
    // VoiceOver the state the tint encodes.
    dot.image = NSImage(systemSymbolName: symbol, accessibilityDescription: axLabel)
    dot.contentTintColor = tint
    dot.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
    // A thinking session pulses; idle (green check) and needs-you (orange !) stay still, so
    // scanning the rail the one moving dot is the one still working. The row view is rebuilt
    // on every state change, so the effect starts and stops with the turn on its own.
    // Gated on `isTurnActive` for the same reason as the transcript's pill: `start()` sets
    // `.running` optimistically before any turn exists, so `.running` alone would pulse a
    // started-but-unprompted session that is not actually thinking.
    dot.setThinkingPulse(
      !node.isDetached && !node.heldElsewhere && node.state == .running
        && node.session?.isTurnActive == true)

    let name = NSTextField(labelWithString: node.title)
    name.font = .systemFont(ofSize: 13)
    // A held session is greyed whole — the row reads as "not yours right now" at a glance, the
    // same signal the locked dot carries.
    if node.heldElsewhere { name.textColor = .tertiaryLabelColor }
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
    // In results mode a session header carries its hit count, so the list reads as "N matches
    // here" before it is even expanded. Its children are hit rows; a title-only match has none.
    if isSearching, node.children.first?.isHit == true, let session = node.session {
      let count = NSTextField(labelWithString: "\(node.children.count)")
      count.font = .systemFont(ofSize: 10, weight: .semibold)
      count.textColor = .secondaryLabelColor
      count.setContentHuggingPriority(.defaultHigh, for: .horizontal)
      trailing.append(count)

      // Its own chevron, the way the repository and bucket headings carry theirs — the rail
      // suppresses AppKit's triangle, so this is what folds a session's hits by mouse.
      let collapsed = collapsedResultSessions.contains(session.id)
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
      disclose.toolTip = collapsed ? "Show matches" : "Hide matches"
      disclose.identifier = NSUserInterfaceItemIdentifier(session.id.uuidString)
      disclose.target = self
      disclose.action = #selector(toggleResultSession(_:))
      disclose.setContentHuggingPriority(.required, for: .horizontal)
      disclose.widthAnchor.constraint(equalToConstant: 16).isActive = true
      disclose.heightAnchor.constraint(equalToConstant: 16).isActive = true
      trailing.append(disclose)
    }
    // How long since you last instructed it, at the trailing edge. The instruction rather than
    // the last activity, because it is the sort key: the numbers then read in order down the
    // column, where "last activity" would put a `2m` above a `30s` whenever an agent was still
    // talking. This is the date information the time buckets carried, without their boundaries.
    // Read off the session at draw time, not stored on the node, so the minute tick (see
    // `ageTick`) redraws it without a reload.
    var age: NSTextField?
    if let session = node.session, node.matchOffset == nil,
      let text = AgentSession.age(since: session.lastInstructedAt)
    {
      let label = NSTextField(labelWithString: text)
      label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
      // Tertiary: quaternary is for a refinement of something already on the row, and this is
      // the one thing here that is read as a value in its own right.
      label.textColor = .tertiaryLabelColor
      label.setContentHuggingPriority(.required, for: .horizontal)
      label.setContentCompressionResistancePriority(.required, for: .horizontal)
      age = label
    }
    // No diffstat here — it lives in the top bar for the selected worktree. In the rail the
    // state dot is the signal; the change size would just crowd the row.

    let row = NSStackView(views: [dot, name] + trailing)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    // The age sits in the trailing gravity area, so it lines up down the column at the edge —
    // the same edge the headings' chevrons keep — rather than following each title's length.
    if let age { row.addView(age, in: .trailing) }
    row.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: indent),
      row.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
      row.topAnchor.constraint(equalTo: cell.topAnchor),
      row.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
    ])
    return cell
  }

  /// The sessions a click on `row` acts on. The AppKit rule, spelled out because getting it wrong
  /// means deleting four things when one was meant: a click inside the selection acts on the
  /// selection, a click outside it acts on that row alone. Sessions only — a heading is never part
  /// of a batch.
  private func clickedSessions(row: Int) -> [AgentSession] {
    guard row >= 0 else { return [] }
    let rows = outlineView.selectedRowIndexes.contains(row) ? outlineView.selectedRowIndexes : [row]
    return rows.compactMap { (outlineView.item(atRow: $0) as? RailNode)?.session }
  }

  /// Built per click rather than kept around: what it offers depends on where the click
  /// landed, and `clickedRow` is only meaningful during the click.
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    let row = outlineView.clickedRow
    let node = row >= 0 ? outlineView.item(atRow: row) as? RailNode : nil
    // What the lifecycle items act on: never a held session — it belongs to another process, and
    // we do not act on what we do not own — so a batch quietly narrows to the ones that are ours
    // rather than refusing outright.
    let clicked = clickedSessions(row: row).filter { $0.heldByPID == nil }
    // A session's own lifecycle, from its row. Running: Restart (cycle the engine, resume)
    // and Stop (take it down; the next send resumes). Not running: Start, the deliberate eager
    // bring-up that is the counterpart to Stop. All distinct from Escape's turn-interrupt, which
    // stops the turn but leaves the engine up.
    if !clicked.isEmpty {
      /// `count` suffixes a batch and is left off a single: "Stop Session" reads better than
      /// "Stop 1 Session", and the singular is overwhelmingly the case.
      func label(_ verb: String, _ noun: String = "Session") -> String {
        clicked.count == 1 ? "\(verb) \(noun)" : "\(verb) \(clicked.count) \(noun)s"
      }
      func add(_ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = clicked
        menu.addItem(item)
      }
      // A mixed batch gets both, each acting on the half it applies to — refusing a batch because
      // one row of it is already running would make the act depend on state you cannot see once
      // five rows are selected.
      if clicked.contains(where: \.isRunning) {
        add(label("Restart"), #selector(restartClickedSessions(_:)))
        add(label("Stop"), #selector(stopClickedSessions(_:)))
      }
      if clicked.contains(where: { !$0.isRunning }) {
        add(label("Start"), #selector(startClickedSessions(_:)))
      }
      menu.addItem(.separator())
      // Archive and Delete are one pair, in that order: both are "get this row out of the way",
      // and they are the two answers to it — the reversible one, then the one that cannot be
      // undone. Reading them together is what says which is which, so no separator comes between.
      // Which way Archive goes is read off the set rather than offered both ways — a batch holding
      // some of each archives, since that is the direction that makes the selection uniform.
      // Only main's sessions are offered it at all (see `Workspace.canArchive`), so a right-click
      // in a linked worktree simply does not carry the pair — an item that would refuse is worse
      // than no item.
      let archivable = clicked.filter { workspace?.canArchive($0) == true }
      let unarchived = archivable.filter { workspace?.archivedSessionIDs.contains($0.id) != true }
      if archivable.isEmpty {
        // Nothing to offer.
      } else if unarchived.isEmpty {
        let item = NSMenuItem(
          title: archivable.count == 1
            ? "Unarchive Session" : "Unarchive \(archivable.count) Sessions",
          action: #selector(unarchiveClickedSessions(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = archivable
        menu.addItem(item)
      } else {
        let item = NSMenuItem(
          title: unarchived.count == 1
            ? "Archive Session" : "Archive \(unarchived.count) Sessions",
          action: #selector(archiveClickedSessions(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = unarchived
        menu.addItem(item)
      }
      add(label("Delete", "Session") + "…", #selector(deleteClickedSessions(_:)))
      menu.addItem(.separator())
    }
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

  @objc private func stopClickedSessions(_ sender: NSMenuItem) {
    guard let sessions = sender.representedObject as? [AgentSession] else { return }
    guard
      confirmBusyTeardown(
        sessions, title: "Stop",
        detail: "Stopping interrupts the current turn; the next message resumes the session.")
    else { return }
    for session in sessions { session.stop() }
    // The session's own `onStateChange` reloads on exit, but that lands asynchronously; reflect
    // the intent now so the row does not sit on a stale "thinking" until the engine is gone.
    reload()
  }

  @objc private func restartClickedSessions(_ sender: NSMenuItem) {
    guard let sessions = sender.representedObject as? [AgentSession] else { return }
    guard
      confirmBusyTeardown(
        sessions, title: "Restart",
        detail: "Restarting interrupts the current turn, then brings the session back up.")
    else { return }
    for session in sessions where session.isRunning { session.restart() }
    reload()
  }

  @objc private func startClickedSessions(_ sender: NSMenuItem) {
    guard let sessions = sender.representedObject as? [AgentSession] else { return }
    for session in sessions where !session.isRunning { onStartSession?(session) }
  }

  /// Archive: stop these sessions and put their rows below the fold. Confirmed only while an
  /// agent is mid-turn — the same rule as Stop, since that is the same act — and never otherwise:
  /// nothing is destroyed and Unarchive is right there, which is the whole difference between
  /// this and Delete below.
  @objc private func archiveClickedSessions(_ sender: NSMenuItem) {
    guard let sessions = sender.representedObject as? [AgentSession] else { return }
    guard
      confirmBusyTeardown(
        sessions, title: "Archive",
        detail: "Archiving stops it; the next message resumes the session.")
    else { return }
    setArchived(true, sessions)
  }

  @objc private func unarchiveClickedSessions(_ sender: NSMenuItem) {
    guard let sessions = sender.representedObject as? [AgentSession] else { return }
    setArchived(false, sessions)
  }

  private func setArchived(_ archived: Bool, _ sessions: [AgentSession]) {
    guard let workspace, workspace.setArchived(archived, for: sessions) else { return }
    // The selection is left exactly where it is, even when the row it is on has just dropped into
    // a folded section. The reload simply does not find that row and the rail goes unhighlighted,
    // which is the same state as folding a worktree while reading one of its sessions — and the
    // transcript column, which is what you were actually looking at, does not move.
    reload()
    view.window?.invalidateRestorableState()
  }

  /// Delete: confirm first, always. Unlike Stop — which loses nothing, the transcript stays on
  /// disk — this unlinks that transcript, so the conversation is gone for good, and it is Claude
  /// Code's record, not hukan's. Hence a confirm even when the session is idle, and the
  /// destructive button style. One sheet for the whole batch: four confirms in a row is not four
  /// decisions, it is one decision and three reflexes.
  @objc private func deleteClickedSessions(_ sender: NSMenuItem) {
    guard let sessions = sender.representedObject as? [AgentSession], !sessions.isEmpty else {
      return
    }
    let alert = NSAlert()
    let working = sessions.filter(\.isTurnActive).count
    if sessions.count == 1 {
      alert.messageText = "Delete “\(sessions[0].title ?? "New session")”?"
    } else {
      alert.messageText = "Delete \(sessions.count) sessions?"
    }
    // How many are mid-turn, because that is the half of the warning a batch can no longer say by
    // looking at the row you right-clicked.
    let stopped =
      working == 0
      ? ""
      : (sessions.count == 1
        ? "The agent is still working, and will be stopped. "
        : "\(working) of them are still working, and will be stopped. ")
    alert.informativeText =
      stopped
      + (sessions.count == 1
        ? "Its conversation will be deleted for good — this cannot be undone."
        : "Their conversations will be deleted for good — this cannot be undone.")
    alert.addButton(withTitle: "Delete").hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    for session in sessions { onDeleteSession?(session) }
  }

  /// Confirm a Stop/Restart only while an agent is mid-turn — that is the case that loses work.
  /// An idle-but-live session loses nothing (its transcript is on disk), so it goes through
  /// silently. App-modal like the close-repository confirm; returns whether to proceed. One sheet
  /// for the batch, and it names how many are actually working: with five rows selected, "the
  /// agent is still working" is not something you can check by looking.
  private func confirmBusyTeardown(_ sessions: [AgentSession], title: String, detail: String)
    -> Bool
  {
    let working = sessions.filter(\.isTurnActive).count
    guard working > 0 else { return true }
    let alert = NSAlert()
    alert.messageText =
      sessions.count == 1 ? "\(title) this session?" : "\(title) \(sessions.count) sessions?"
    alert.informativeText =
      (working == 1 && sessions.count == 1
        ? "The agent is still working. " : "\(working) of them are still working. ") + detail
    alert.addButton(withTitle: title)
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
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

  /// A fold from the keyboard (see `RailOutlineView.onFold`): written into whichever exception
  /// set speaks for the row, then applied by a rebuild — the same path the chevrons take.
  private func setFold(_ item: Any, collapsed: Bool) {
    guard let node = item as? RailNode else { return }
    func write(_ set: inout Set<String>, _ key: String, _ present: Bool) {
      if present { set.insert(key) } else { set.remove(key) }
    }
    if isSearching {
      guard let session = node.session else { return }
      if collapsed {
        collapsedResultSessions.insert(session.id)
      } else {
        collapsedResultSessions.remove(session.id)
      }
    } else if node.isRepositoryHeading, let repositoryID = node.repositoryID {
      write(&collapsedRepositories, repositoryID, collapsed)
    } else if node.isWorktreeHeading, let worktree = node.worktree {
      write(&collapsedWorktrees, worktree.id.uuidString, collapsed)
    } else if let section = node.section, let key = node.sectionKey {
      switch section {
      // The one set written the other way round: absence means folded.
      case .archived: write(&expandedArchives, key, !collapsed)
      case .worktrees: write(&collapsedWorktreeSections, key, collapsed)
      }
    } else {
      return
    }
    reloadAfterFold()
  }

  /// A fold moved: reload — which rebuilds, the arrangement having changed — and record it.
  private func reloadAfterFold() {
    reload()
    view.window?.invalidateRestorableState()
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
    reloadAfterFold()
  }

  /// A matched session's disclosure in the result list. Folds its hit rows away, leaving the
  /// session row and its count.
  @objc private func toggleResultSession(_ sender: NSButton) {
    guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
    if collapsedResultSessions.contains(id) {
      collapsedResultSessions.remove(id)
    } else {
      collapsedResultSessions.insert(id)
    }
    reloadAfterFold()
  }

  /// A worktree heading's disclosure. One exception set against one default (worktrees stand
  /// open), so the flip is a plain membership toggle — no second set and no per-row default to
  /// carry on the button, which is what a bucket needed.
  @objc private func toggleWorktree(_ sender: NSButton) {
    guard let worktreeID = sender.identifier?.rawValue else { return }
    if collapsedWorktrees.contains(worktreeID) {
      collapsedWorktrees.remove(worktreeID)
    } else {
      collapsedWorktrees.insert(worktreeID)
    }
    reloadAfterFold()
  }

  /// A section heading's disclosure. `Archived` is the one set written the other way round — a
  /// section nobody has opened stays folded, which is the whole point of putting anything in it —
  /// while `Worktrees` stands open like the headings do. The section rides on the button's `tag`.
  @objc private func toggleSection(_ sender: NSButton) {
    guard let key = sender.identifier?.rawValue else { return }
    if sender.tag == 0 {
      if expandedArchives.contains(key) {
        expandedArchives.remove(key)
      } else {
        expandedArchives.insert(key)
      }
    } else {
      if collapsedWorktreeSections.contains(key) {
        collapsedWorktreeSections.remove(key)
      } else {
        collapsedWorktreeSections.insert(key)
      }
    }
    reloadAfterFold()
  }

  /// The repository heading's `+` — the heading is main, so this starts a session there. The
  /// repositoryID rides on the button's `identifier`, set when the row was built, so one action
  /// handles whichever heading was clicked.
  @objc private func newSessionInGroup(_ sender: NSButton) {
    guard let repositoryID = sender.identifier?.rawValue else { return }
    newSession(inRepository: repositoryID)
  }

  @objc private func newSessionInWorktree(_ sender: NSButton) {
    guard let raw = sender.identifier?.rawValue, let worktreeID = UUID(uuidString: raw) else {
      return
    }
    onNewSessionInWorktree?(worktreeID)
  }

  /// Return/Enter in the rail: dive into the session navigation is on — the anchor, not the top of
  /// a range, which is what makes Return mean the same thing whether one row is selected or five.
  /// A heading or an empty-worktree row has no composer to focus, so it is a no-op.
  private func activateSelectedSession() {
    guard let row = anchorRow, let node = outlineView.item(atRow: row) as? RailNode,
      node.session != nil
    else { return }
    onActivateSession?()
  }

  /// Double-click a row: a session dives in like Return. A heading does nothing — double-clicking
  /// it must not steal focus.
  @objc private func sessionRowDoubleClicked() {
    let row = outlineView.clickedRow
    guard row >= 0 else { return }
    guard let node = outlineView.item(atRow: row) as? RailNode, node.session != nil else { return }
    onActivateSession?()
  }

  /// Only sessions may be selected together. A rail row is one of four kinds, and a selection
  /// mixing a repository heading with two sessions is not something any act could be given — so
  /// the moment the proposal is wider than one row, everything that is not a session is dropped
  /// out of it. One row of any kind is still selectable, which is what keeps a heading a
  /// destination.
  ///
  /// Never in results mode: a hit row means "jump to this occurrence", which is a place and not a
  /// thing, so a set of them says nothing.
  func outlineView(
    _ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposed: IndexSet
  ) -> IndexSet {
    guard proposed.count > 1 else { return proposed }
    if isSearching { return anchorRow.map(IndexSet.init(integer:)) ?? IndexSet() }
    let sessions = proposed.filter {
      let node = outlineView.item(atRow: $0) as? RailNode
      return node?.session != nil
    }
    return sessions.isEmpty ? IndexSet() : IndexSet(sessions)
  }

  /// The session name leads; the worktree it sits in follows, dimmed. Leading with the
  /// worktree would bury the thing actually being supervised.
  func outlineViewSelectionDidChange(_ notification: Notification) {
    // Nothing is recorded while we are the ones driving. `reloadData()` clears the selection and
    // posts this notification, and the bookkeeping below used to run before the check — so a
    // reload wiped the anchor and the set it was itself about to put back, from a notification
    // that describes an empty outline rather than anything a person did. The reload writes both
    // itself once the rows have settled.
    guard !isUpdatingSelection else { return }
    if let expected = programmaticRow, outlineView.selectedRow == expected {
      programmaticRow = nil
      selectedRows = outlineView.selectedRowIndexes
      anchorRow = expected
      return
    }
    programmaticRow = nil
    let current = outlineView.selectedRowIndexes
    // The row that just joined is where navigation goes. Nothing joined (a row was dropped from
    // the selection instead) leaves the anchor where it was, if it is still selected — deselecting
    // one of five must not swap the transcript column out.
    let added = current.subtracting(selectedRows)
    let anchor =
      added.last ?? (anchorRow.map(current.contains) == true ? anchorRow : current.last)
    selectedRows = current
    anchorRow = anchor
    guard let anchor, let item = outlineView.item(atRow: anchor) else { return }
    guard let node = item as? RailNode else { return }
    isNotifyingSelection = true
    defer { isNotifyingSelection = false }
    if let session = node.session, let offset = node.matchOffset {
      // A search hit: open its session and jump the transcript to this occurrence.
      onSelectMatch?(session, offset, node.matchLength)
    } else if let session = node.session {
      onSelectSession?(session)
    } else if let worktree = node.worktree {
      onSelectWorktree?(worktree.id)
    }
  }

  /// A stable identity for a selectable rail row across reloads, so the reload can put the
  /// highlight back on the same row after `reloadData()` clears it, rather than re-deriving it
  /// from the session.
  private func selectionKey(of item: Any?) -> String? {
    (item as? RailNode)?.identityKey
  }
}
