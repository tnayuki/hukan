import AppKit
import Foundation

/// One window is one Workspace, holding several worktrees.
final class Workspace {
  /// The open repositories, each owning the worktrees git enumerates for it. This is the one
  /// list; `worktrees` is a flattening of it, so the two can never fall out of step.
  var repositories: [Repository] = []
  var worktrees: [Worktree] { repositories.flatMap(\.worktrees) }
  var sessions: [AgentSession] = []
  /// This window's terminals, keyed to their worktree like `sessions`. A worktree's desk shows
  /// `terminals(inWorktree:)`; the array is the one store, so a terminal outlives tab switches.
  var terminals: [TerminalSession] = []

  /// Something arrived that the rail is showing — a session title read in the background,
  /// for instance. Set by the window that owns this workspace.
  var onSessionsChanged: (() -> Void)?

  /// A worktree's files moved on disk (an agent edit, a terminal command, an external editor)
  /// and the working set actually changed. Carries the worktree id so the window can refresh
  /// just that one's rail badge, and the file column too when it is the one on screen. Set by
  /// the window that owns this workspace.
  /// The worktree-relative paths that moved, or nil when what moved could not be placed — a
  /// commit, a staging, anything under git's own directory — and everything a reader has open
  /// has to be re-read.
  var onWorktreeFilesChanged: ((UUID, Set<String>?) -> Void)?
  /// A directory git cannot see arrived under a watched worktree — the one change git's own
  /// answer never reports. Narrower than the hook above on purpose: nothing has moved that a tab,
  /// the rail or a diffstat could be measured against, so only the tree is redrawn.
  var onWorktreeDirectoriesChanged: ((UUID) -> Void)?

  // The four properties below are the class's own bookkeeping, but `private` is
  // file-scoped and their only other user is `WorkspaceSync.swift` — the extension that
  // does the watching and refreshing. Internal is the cost of that split, not an
  // invitation: nothing outside those two files should touch them.
  /// The filesystem watchers of one open worktree, keyed by worktree id — usually one over the
  /// worktree itself, and for a linked worktree a second over its git directory, which lives
  /// outside it (see `syncWatchers()`). Reconciled against the worktree list by `syncWatchers()`
  /// rather than started at each call site, so however a worktree arrives — opened, restored, or
  /// enumerated on focus — it ends up watched exactly once, the same way `worktrees` is just a
  /// flattening of `repositories`.
  var watchers: [UUID: [DirectoryWatcher]] = [:]

  /// The one watcher over Claude Code's own per-process registry (`~/.claude/sessions/`, a
  /// `<pid>.json` per live engine). A file appearing there for one of our session ids means
  /// another process took it — the acquire edge the per-holder exit watch cannot see, because we
  /// do not yet know the pid. The matching release edge is that pid's own `.exit`, watched by the
  /// session (see `AgentSession.markHeldElsewhere`): a crash leaves the file behind and fires no
  /// delete here, so the directory watch cannot be trusted for release.
  var sessionsRegistryWatcher: DirectoryWatcher?

  /// Worktrees with a `refreshFiles` git query in flight, and those that changed again while one
  /// was running. Together they collapse a storm of FSEvents into at most one query plus one
  /// queued rerun per worktree — see `refreshFiles`. Touched only on the main thread.
  var refreshInFlight: Set<UUID> = []
  var refreshPending: Set<UUID> = []
  /// The same pair for `loadFiles`, which had none — see the note there. And a third for the
  /// history's own paging, which reads nothing else and so needs no queued rerun: a page asked
  /// for while one is in flight is simply the next scroll's page.
  var loadInFlight: Set<UUID> = []
  var loadPending: Set<UUID> = []
  var historyInFlight: Set<UUID> = []
  /// What moved while a query was in flight, so the rerun reports the union rather than only
  /// the batch that happened to arrive last. nil for a worktree whose changes could not be
  /// placed — the wholesale case, which cannot be narrowed by anything arriving after it.
  var pendingPaths: [UUID: Set<String>?] = [:]

  /// The paths FSEvents named, as paths within the worktree — and nil when any of them is not
  /// one. Anything under git's own directory is the case that matters: `.git/HEAD` moving is
  /// not a file anyone has open, but it changes what every open file is measured against.
  static func relativePaths(_ paths: [String], under root: String) -> Set<String>? {
    // Both spellings of the worktree: the one we were handed, and the one the filesystem calls
    // canonical. FSEvents answers in canonical paths — `/private/var/…` where a URL built from
    // the worktree says `/var/…` — so a test against the given form alone matches nothing under
    // a temporary directory, and every event there reads as "could not be placed".
    let roots = Set([root, canonicalPath(root)].compactMap { $0 })
    var relative: Set<String> = []
    for path in paths {
      let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
      guard let root = roots.first(where: { standardized.hasPrefix($0 + "/") }) else { return nil }
      let suffix = String(standardized.dropFirst(root.count + 1))
      guard !suffix.hasPrefix(".git/"), suffix != ".git" else { return nil }
      relative.insert(suffix)
    }
    return relative.isEmpty ? nil : relative
  }

  /// What the filesystem calls this path, or nil if there is nothing there to ask about.
  ///
  /// `realpath` rather than `resolvingSymlinksInPath`, which answers a different question: it
  /// *strips* `/private` rather than following the link, so it hands back the very spelling that
  /// does not match what FSEvents said. Only ever asked of a worktree's own directory, which
  /// exists — a path whose leaf has just been deleted has no canonical form to give.
  private static func canonicalPath(_ path: String) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(path, &buffer) != nil else { return nil }
    return String(cString: buffer)
  }

  /// Two batches of changes, folded. Either being the wholesale case makes the pair wholesale:
  /// nothing arriving later can narrow "everything moved".
  static func union(_ first: Set<String>?, _ second: Set<String>?) -> Set<String>? {
    guard let first, let second else { return nil }
    return first.union(second)
  }

  var selectedWorktreeID: UUID?
  var selectedSessionID: UUID?

  /// The rail's disclosure state, held here (not on the rail view) so it survives a restart the
  /// same way the column widths and selection do — it is display state a reload rebuilds, so the
  /// choices have to outlive both the reload and the process. Each set is an exception to one
  /// default, which is what a single default buys: a repository, a worktree and a Worktrees
  /// section stand open unless listed, an Archived section stays folded unless listed. Keyed by
  /// repository id, worktree id, worktree id and repository id respectively.
  var collapsedRepositories: Set<String> = []
  var collapsedWorktrees: Set<String> = []
  var expandedArchives: Set<String> = []
  var collapsedWorktreeSections: Set<String> = []

  /// The sessions you archived — put below the fold because you are done with them. Held here
  /// rather than on `AgentSession` for the reason the rail's order is: sessions are rebuilt from
  /// disk on every discovery, and this is a decision of yours that nothing on disk records.
  ///
  /// Archiving is not deleting: the transcript stays exactly where Claude Code wrote it, and the
  /// session comes back the moment you unarchive it. Compare `deleteSession`, which unlinks the
  /// file and cannot be undone.
  var archivedSessionIDs: Set<UUID> = []
  /// Archived ids restored from disk that no discovery has claimed yet. They belong to
  /// repositories this window has not opened, so they ride through untouched instead of being
  /// pruned as gone — an id discovery *has* resolved once is governed by `archivedSessionIDs`
  /// alone, which is what keeps a session that has genuinely vanished (its worktree removed, its
  /// transcript deleted) from lingering in the stored set for good.
  private var unresolvedArchived: Set<String> = []

  /// Take an id out of the carry-forward set: discovery has resolved it, so from here on the
  /// live set is the only thing that speaks for it. Called for every session discovery builds.
  func resolveArchivedID(_ id: UUID) {
    unresolvedArchived.remove(id.uuidString)
  }

  /// Whether this session sits below the fold *right now*. Being archived is your decision and it
  /// sticks; being *shown* archived is that decision minus one rule — a session that is working or
  /// waiting on you comes back out. The rail's whole job is to find what is waiting on you, so a
  /// pulsing row must never be behind a fold, and an archive that could hide one would be the same
  /// mistake the time buckets made when "Older" swallowed a session that was still running.
  func isArchived(_ session: AgentSession) -> Bool {
    guard canArchive(session), archivedSessionIDs.contains(session.id) else { return false }
    return !session.isTurnActive && session.state != .needsAttention
  }

  /// Only main's sessions can be archived. A linked worktree *is* the task: when it lands, the
  /// `git worktree remove` that ends it takes the worktree off the rail and its sessions with it,
  /// so nothing accumulates there to need putting away. The long tail is main's alone — the
  /// one-shot questions and the attempts that went nowhere, asked where you happened to be
  /// standing — which is the only place the fold earns its keep.
  ///
  /// A flag on a session that has since moved into a worktree (`EnterWorktree`) goes inert rather
  /// than being cleared: it is still true that you archived it, and coming home is what makes it
  /// mean something again.
  func canArchive(_ session: AgentSession) -> Bool {
    worktree(id: session.worktreeID)?.isMain == true
  }

  /// Archive or unarchive, and say whether anything moved. Unarchiving a session that only *looks*
  /// unarchived because it is awake still clears the flag, which is why this reads the set rather
  /// than `isArchived`.
  ///
  /// Archiving stops the engine. Archived means done with, and a process kept alive for a row
  /// below the fold is a process nobody is watching; what a stop costs is nothing, since the
  /// transcript stays and the next send resumes it — the same act as Stop Session, which is why
  /// the two differ only in where the row goes. It is also what makes the act definite: without
  /// it a working session took the flag and stayed on the rail until its turn ended, so archiving
  /// it looked like nothing had happened. The rail confirms first when a turn is under way (see
  /// `confirmBusyTeardown`); the scripted verb does not, the way `roll back` does not.
  func setArchived(_ archived: Bool, for sessions: [AgentSession]) -> Bool {
    var moved = false
    for session in sessions {
      if archived {
        guard canArchive(session) else { continue }
        session.stop()
        moved = archivedSessionIDs.insert(session.id).inserted || moved
      } else {
        moved = archivedSessionIDs.remove(session.id) != nil || moved
      }
    }
    return moved
  }

  /// How wide each column was left: rail, running agent, and the file column's own sidebar.
  /// Empty until the layout has been arranged once.
  ///
  /// This rides in the window's restorable state rather than a split view `autosaveName`,
  /// for the same reason the open repositories do: an autosave name is one global setting,
  /// so a second window could not hold a different arrangement, and the widths would drift
  /// away from the frame and Space that AppKit restores alongside them.
  var columnWidths: [Double] = []

  /// How tall the files panel's History section was left. Stored beside the widths, and for the
  /// same reason: it is the arrangement of one window, not a global setting.
  var historyHeight: Double = 0

  /// Per-session composer choices: the permission mode and reasoning effort the engine does not
  /// remember across --resume, plus the model — which the engine does remember, so it is kept
  /// for display continuity only, never forced (see `applyRestoredPrefs`).
  /// Restored from disk keyed by session id string and applied as discovery rebuilds the
  /// sessions, so a session set to Bypass comes back as Bypass. This is a preference map, never
  /// the session list — sessions stay disk-derived — so it cannot corrupt what git and Claude
  /// Code own, and a stale entry for a gone session is simply ignored.
  private var restoredPrefs: [String: (mode: PermissionMode, effort: String, model: String)] = [:]
  /// Type-ahead restored from disk, keyed by session id, applied as discovery rebuilds the
  /// sessions. Same disposable, disk-derived-list philosophy as the prefs map.
  private var restoredQueues: [String: [String]] = [:]
  /// Unsent composer drafts restored from disk, keyed by session id. Same philosophy again.
  private var restoredDrafts: [String: String] = [:]
  /// The model roster each session last saw the engine advertise, keyed by session id. Held per
  /// session, not shared — so a restored session that has not connected yet shows the list it
  /// itself saw, and seeds its own picker with it (see `applyRestoredPrefs`) rather than borrowing
  /// another session's. A New Session eager-starts and learns its own; a session's live reply wins
  /// the moment it arrives (`seedModels` never overwrites it).
  private var restoredRosters: [String: [ClaudeModel]] = [:]
  /// When you last instructed each session, keyed by session id — the rail's sort key, restored
  /// rather than re-derived. It is view state: nothing outside the rail's order reads it, and
  /// nobody else records it (Claude Code's transcript knows its own user turns, not
  /// which of them you delegated from this window). Without it, discovery fell back to the
  /// transcript's mtime, which moves for reasons that are not instructions — the agent's own
  /// output, and the `last-prompt` line a quitting engine appends, which re-stamps every attached
  /// session within the same second and so reshuffled the day's rows on every restart.
  private var restoredInstructedAt: [String: Date] = [:]

  /// Terminals decoded from restoration state, waiting for the window controller to turn them into
  /// live `TerminalSession`s (it owns the callback wiring). Each carries the worktree to reopen on
  /// and the scrollback to replay. Unlike sessions, a terminal has no disk source to rediscover —
  /// the model is the state — so it is rebuilt from here, then this is emptied by `takeRestoredTerminals`.
  private var pendingRestoredTerminals:
    [(worktreeID: UUID, directory: String, sessionID: String, scrollback: String)] = []

  func takeRestoredTerminals()
    -> [(worktreeID: UUID, directory: String, sessionID: String, scrollback: String)]
  {
    defer { pendingRestoredTerminals = [] }
    return pendingRestoredTerminals
  }

  /// Web tabs decoded from restoration state, waiting for the desk to put them back on their
  /// worktrees — the terminals' arrangement, for the same reason: the tabs are the desk's and it
  /// wires them, so the model only carries them across.
  private var pendingRestoredBrowserTabs: [BrowserTabState] = []

  func takeRestoredBrowserTabs() -> [BrowserTabState] {
    defer { pendingRestoredBrowserTabs = [] }
    return pendingRestoredBrowserTabs
  }

  /// The kinds of tab that outlive the window, and so the only ones whose order on the strip is
  /// worth carrying across. A tab of either kind is named by its position among its kind in the
  /// saved lists, so an order is one row per tab: which worktree, which kind — nothing else.
  struct RestoredTabOrder: Hashable {
    enum Kind: String {
      case browser, terminal
    }
    let worktreeID: UUID
    let kind: Kind
  }

  /// The strip order decoded from restoration state, waiting for the desk to lay its restored
  /// tabs out in it once both kinds are back.
  private var pendingRestoredTabOrder: [RestoredTabOrder] = []

  func takeRestoredTabOrder() -> [RestoredTabOrder] {
    defer { pendingRestoredTabOrder = [] }
    return pendingRestoredTabOrder
  }

  /// Set a freshly-discovered session's mode/effort/model from what was restored, if anything
  /// was. The model is display continuity only — it is shown until the engine confirms the real
  /// one on resume; it is never forced onto the engine (the engine remembers the model itself).
  /// Restored type-ahead rides along here too: put back as drafts, never re-sent on its own.
  /// The rail's sort key for a session discovery just rebuilt: what this window stored for it,
  /// or `fallback` (the transcript's mtime) for one it has never seen. Kept here, beside the map,
  /// so the precedence — stored always wins over mtime — is stated in one place. Not folded into
  /// `applyRestoredPrefs`, which knows nothing about the transcript the caller is looking at.
  func restoredInstruction(for id: UUID, fallback: Date) -> Date {
    restoredInstructedAt[id.uuidString] ?? fallback
  }

  func applyRestoredPrefs(to session: AgentSession) {
    if let prefs = restoredPrefs[session.id.uuidString] {
      session.permissionMode = prefs.mode
      session.effort = prefs.effort
      if !prefs.model.isEmpty { session.model = prefs.model }
    }
    if let queue = restoredQueues[session.id.uuidString] {
      session.restoreQueue(queue)
    }
    if let draft = restoredDrafts[session.id.uuidString] {
      session.draft = draft
    }
    // Show this session's own last-seen roster until it connects and reports a fresh one (a
    // restored session stays lazy, so without this its picker would flash the fallback until the
    // first send).
    if let roster = restoredRosters[session.id.uuidString] {
      session.seedModels(roster)
    }
  }

  init() {}

  func worktree(id: UUID) -> Worktree? { worktrees.first { $0.id == id } }
  func sessions(inWorktree worktreeID: UUID) -> [AgentSession] {
    sessions.filter { $0.worktreeID == worktreeID }
  }

  /// A worktree can carry several sessions, including restored detached ones. With no explicit
  /// selection (the restored one may be gone), fall back to the most recently active — after a
  /// restart the array runs newest-to-oldest, so `.last` here would resurrect the worktree's
  /// oldest husk. Explicit selection still wins: creating a session sets `selectedSessionID`
  /// before its first activity, so a just-created session never loses to an older one.
  var selectedSession: AgentSession? {
    guard let worktreeID = selectedWorktreeID else { return nil }
    let candidates = sessions(inWorktree: worktreeID)
    if let id = selectedSessionID, let session = candidates.first(where: { $0.id == id }) {
      return session
    }
    return candidates.max { $0.updatedAt < $1.updatedAt }
  }

  func terminals(inWorktree worktreeID: UUID) -> [TerminalSession] {
    terminals.filter { $0.worktreeID == worktreeID }
  }

  /// Drop a terminal, killing its shell first so closing a tab never orphans a running process.
  func removeTerminal(id: UUID) {
    guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
    terminals[index].terminate()
    terminals.remove(at: index)
  }

  /// One session row. It carries the worktree it sits in as well as the session, so a row can
  /// read that worktree's own state — its name, its diffstat — without a second lookup. The
  /// worktree is the level above (see `RailWorktree`), not a key to resolve.
  struct RailEntry {
    let session: AgentSession
    let worktree: Worktree
  }

  /// One worktree for the worktree-first rail: the sessions standing plainly, and the ones you
  /// archived. A worktree with no session at all is kept (both lists empty) — it is a selectable
  /// container, so its file tree stays reachable — which is why this is worktree-first, not
  /// one-row-per-session.
  struct RailWorktree {
    let worktree: Worktree
    /// Newest instruction first.
    let sessions: [RailEntry]
    /// Behind the fold, and only ever because you put it there. A count-based backstop was built
    /// and taken out: the fold is a place for what you are *done with*, and a rule that puts the
    /// ninth session there is guessing at that from a number — it would bury a session you are
    /// still using the moment you started one more, which is the same "the clock decided" mistake
    /// the time buckets made, one variable further along.
    let archived: [RailEntry]
  }

  /// A repository for the rail: its main worktree folded into the heading itself (the default,
  /// the common dir's parent) plus its linked worktrees, each a heading of its own — and each a
  /// *child* of the repository rather than a top-level row beside it, which is what lets the
  /// outline own the fold, the indent and the drag, and what leaves nothing for the gutter's
  /// hairline to say.
  struct RailRepository {
    let repositoryID: String
    let repositoryName: String
    let main: RailWorktree?
    let linked: [RailWorktree]
    /// Main first, then the linked ones — for the readers that want the worktrees without caring
    /// which is which (`hukan status`, and anything counting).
    var worktrees: [RailWorktree] { (main.map { [$0] } ?? []) + linked }
  }

  var railRepositories: [RailRepository] {
    func railWorktree(_ worktree: Worktree) -> RailWorktree {
      let entries =
        sessions(inWorktree: worktree.id)
        .sorted { lhs, rhs in
          if lhs.lastInstructedAt != rhs.lastInstructedAt {
            return lhs.lastInstructedAt > rhs.lastInstructedAt
          }
          return lhs.id.uuidString < rhs.id.uuidString
        }
        .map { RailEntry(session: $0, worktree: worktree) }
      let archived = entries.filter { isArchived($0.session) }
      let plain = entries.filter { !isArchived($0.session) }
      return RailWorktree(worktree: worktree, sessions: plain, archived: archived)
    }

    var order: [String] = []
    var byRepository: [String: [Worktree]] = [:]
    for worktree in worktrees {
      let key = worktree.repositoryID
      if byRepository[key] == nil { order.append(key) }
      byRepository[key, default: []].append(worktree)
    }
    return order.map { key in
      let group = byRepository[key] ?? []
      return RailRepository(
        repositoryID: key,
        repositoryName: group.first?.repositoryName ?? key,
        main: group.first { $0.isMain }.map(railWorktree),
        linked: group.filter { !$0.isMain }.map(railWorktree))
    }
  }

  /// Close a repository: drop it and every worktree of it from the window, stopping any
  /// agent still attached. Nothing on disk is touched — the worktrees stay in git and the
  /// transcripts stay where Claude Code put them, so reopening brings it all back.
  func closeRepository(_ repositoryID: String) {
    guard let repo = repositories.first(where: { $0.id == repositoryID }) else { return }
    dropWorktrees(repo.worktrees)
    repositories.removeAll { $0.id == repositoryID }
  }

  /// Move a repository in the rail's order, landing it before `otherID` — or last, when that is
  /// nil. The worktrees come with it without anything having to carry them: the repository owns
  /// them (`Repository.worktrees`) and `worktrees` is a flattening of this list, so moving the
  /// element moves the whole block.
  ///
  /// Nothing new is stored for this. `encodeState` writes the worktree paths in flattening order
  /// and `decodeState` interns repositories in the order they first appear, so the order rides a
  /// list that is already saved. The worktrees' own order is left alone for the opposite reason —
  /// it is git's enumeration, and hukan holding an opinion about it would be a second copy of
  /// something git already answers.
  @discardableResult
  func moveRepository(_ repositoryID: String, before otherID: String?) -> Bool {
    guard repositoryID != otherID,
      let from = repositories.firstIndex(where: { $0.id == repositoryID })
    else { return false }
    let destination: Int
    if let otherID {
      // A destination that is no longer open is not "the end", it is a stale drop — nothing moves.
      guard let index = repositories.firstIndex(where: { $0.id == otherID }) else { return false }
      destination = index
    } else {
      destination = repositories.count
    }
    // Where it lands once it is out of the list: a destination past it shifts down by one. Equal
    // to where it already is means the drop asked for the order it already has.
    let to = destination > from ? destination - 1 : destination
    guard to != from else { return false }
    repositories.insert(repositories.remove(at: from), at: to)
    return true
  }

  /// Drop worktrees from the window, stopping whatever was running in them: the teardown closing
  /// a repository does, minus the repository itself — which is what lets a single worktree leave
  /// on its own once git stops listing it (see `reconcileWorktrees`). Nothing on disk is touched;
  /// the transcripts stay where Claude Code put them, so a path that comes back brings them back.
  func dropWorktrees(_ leaving: [Worktree]) {
    let doomed = Set(leaving.map(\.id))
    for session in sessions where doomed.contains(session.worktreeID) { session.stop() }
    sessions.removeAll { doomed.contains($0.worktreeID) }
    for terminal in terminals where doomed.contains(terminal.worktreeID) { terminal.terminate() }
    terminals.removeAll { doomed.contains($0.worktreeID) }
    for repository in repositories { repository.worktrees.removeAll { doomed.contains($0.id) } }
    syncWatchers()
    if let selected = selectedWorktreeID, doomed.contains(selected) {
      selectedWorktreeID = worktrees.first?.id
      selectedSessionID = nil
    }
  }

  /// Put a session back on the worktree it left by `ExitWorktree`. Only a worktree already open
  /// qualifies — never `addWorktree`: the engine's original directory is where `start(at:)` put
  /// it, a worktree root this window holds, and registering anything else would make a Worktree
  /// git does not list, which the next reconcile would drop — taking this session, the one that
  /// just came home, with it. False when nothing matched, and the session stays where it was.
  /// Paths are compared resolved, because the engine reports its directory through `realpath`.
  @discardableResult
  func returnSession(_ session: AgentSession, to url: URL) -> Bool {
    let target = url.standardizedFileURL.resolvingSymlinksInPath().path
    guard
      let home = worktrees.first(where: {
        $0.url.standardizedFileURL.resolvingSymlinksInPath().path == target
      })
    else { return false }
    session.worktreeID = home.id
    return true
  }

  /// Delete a session for good: stop its engine, drop it from the list, and unlink its
  /// transcript. The list is derived from the transcripts on disk, so nothing less than removing
  /// the file would stick — a forgotten session reappears on the next scan. Irreversible, and it
  /// is Claude Code's data, not ours: the caller asks first (see the rail's Delete Session).
  /// Refuses a session held by another process — that engine is still writing the transcript we
  /// would be deleting, and we do not act on what we do not own.
  @discardableResult
  func deleteSession(_ session: AgentSession) -> Bool {
    guard session.heldByPID == nil else { return false }
    guard let worktree = worktree(id: session.worktreeID) else { return false }
    session.stop()
    let removed = ClaudeSessionStore.delete(id: session.id, worktree: worktree.url)
    guard removed else { return false }
    sessions.removeAll { $0 === session }
    // The archive flag goes with it. Nothing would read a flag for an id that no longer resolves,
    // but leaving it would keep the id in the stored set for as long as the window lives.
    archivedSessionIDs.remove(session.id)
    // Leave the worktree selected — only the session goes. The rail lands on the worktree
    // heading, which is where a deleted session's row was hanging.
    if selectedSessionID == session.id { selectedSessionID = nil }
    onSessionsChanged?()
    return true
  }

  /// The repository with this id, created and registered if it is the first worktree of it to
  /// arrive. Worktrees intern their repository through here, so every worktree of one
  /// repository shares a single object and the id/name are computed in exactly one place.
  private func repository(forID id: String) -> Repository {
    if let existing = repositories.first(where: { $0.id == id }) { return existing }
    let repository = Repository(id: id)
    repositories.append(repository)
    return repository
  }

  /// Open a repository: register its checkout and pull in whatever git and Claude Code
  /// already know about it. Adding is the only moment worth paying for the git queries —
  /// doing it on every redraw would spawn processes constantly.
  @discardableResult
  func openRepository(_ url: URL) -> Worktree {
    let worktree = addWorktree(url)
    discoverSessions()
    return worktree
  }

  /// Never add the same path twice. Appending command-line worktrees to restored ones grew the
  /// list on every launch (which is exactly what happened). Also covers picking the same
  /// folder twice from the open panel.
  @discardableResult
  func addWorktree(_ url: URL) -> Worktree {
    // However the return is reached — a fresh worktree or one already open — leave the watcher
    // set matching the worktree set. Idempotent, so the already-open branch is a no-op.
    defer { syncWatchers() }
    let path = url.standardizedFileURL.path
    if let existing = worktrees.first(where: { $0.url.standardizedFileURL.path == path }) {
      if selectedWorktreeID == nil { selectedWorktreeID = existing.id }
      return existing
    }
    let repo = repository(forID: Git.repository(at: url) ?? path)
    let worktree = Worktree(url: url, branch: Git.currentBranch(at: url), repository: repo)
    repo.worktrees.append(worktree)
    if selectedWorktreeID == nil { selectedWorktreeID = worktree.id }
    return worktree
  }

  // MARK: - Restoration

  /// Only "which worktrees are open" and a little UI state are ours to keep. Worktrees belong
  /// to git and sessions belong to Claude Code; storing either here would create a second
  /// copy that can disagree with the real one — and storing sessions is exactly what let a
  /// failed restore write an empty list back over the good one.
  ///
  /// What is left is paths and strings, which is what AppKit's restorable state handles
  /// well. Keeping it here rather than in our own file means window geometry, Space
  /// assignment and contents all restore together, and a second window can hold a
  /// different set of worktrees without any of them fighting over one global file.
  private enum Key {
    static let worktreePaths = "worktrees.paths"
    static let worktreeIDs = "worktrees.ids"
    static let selectedWorktreeID = "selectedWorktreeID"
    static let selectedSessionID = "selectedSessionID"
    static let columnWidths = "columnWidths"
    static let historyHeight = "historyHeight"
    static let collapsedRepositories = "rail.collapsedRepositories"
    static let collapsedWorktrees = "rail.collapsedWorktrees"
    static let expandedArchives = "rail.expandedArchives"
    static let collapsedWorktreeSections = "rail.collapsedWorktreeSections"
    // The sessions you put below the fold, by session id — the one piece of the rail's state
    // that is a decision rather than a disclosure. Strings like every other per-session map
    // here: secure restorable state keeps strings, numbers and arrays, and at a UUID apiece a
    // few hundred of these is a few kilobytes against the tens the web tabs' interaction state
    // already costs.
    static let archivedSessionIDs = "rail.archivedSessions"
    // Per-session composer choices: mode and effort the engine forgets across --resume, plus
    // the model for display continuity. Parallel arrays because secure restorable state only
    // keeps strings, numbers and arrays.
    static let prefSessionIDs = "sessionPrefs.ids"
    static let prefModes = "sessionPrefs.modes"
    static let prefEfforts = "sessionPrefs.efforts"
    static let prefModels = "sessionPrefs.models"
    static let queueSessionIDs = "queue.ids"
    static let queueMessages = "queue.messages"
    static let draftSessionIDs = "draft.ids"
    static let draftTexts = "draft.texts"
    // The rail's order: when you last instructed each session, as seconds since the reference
    // date. Keyed by session id like the choices above.
    static let instructedSessionIDs = "instructed.ids"
    static let instructedDates = "instructed.dates"
    // Each session's last-seen model roster, keyed by session id like the choices above — not one
    // shared list. `ids` names the sessions; the three field arrays are nested (one inner array per
    // session), the same shape `queue.messages` uses (secure restorable state keeps only strings,
    // numbers and arrays).
    static let rosterSessionIDs = "roster.ids"
    static let rosterValues = "roster.values"
    static let rosterNames = "roster.names"
    static let rosterResolved = "roster.resolved"
    // Terminals: the shell process is volatile, but enough rides restoration to bring one back on
    // the same desk (keyed by its worktree, whose id is itself restored), in the same directory,
    // with its scrollback replayed and its history session picked up. The label is derived from
    // the directory, not stored. Bounded scrollback; the fresh shell starts below it on display.
    static let terminalWorktreeIDs = "terminals.worktreeIDs"
    static let terminalDirectories = "terminals.directories"
    static let terminalSessionIDs = "terminals.sessionIDs"
    static let terminalScrollbacks = "terminals.scrollbacks"
    // Web tabs: keyed by worktree like the terminals, the address and title so the tab can be
    // named and found before it loads, and WebKit's own interaction state — the back/forward
    // list and scroll — carried opaque, base64 so it rides as a string like everything else.
    static let browserWorktreeIDs = "browsers.worktreeIDs"
    static let browserURLs = "browsers.urls"
    static let browserTitles = "browsers.titles"
    static let browserStates = "browsers.states"
    // The strip's order across both kinds, so a dragged tab does not spring back on relaunch:
    // one row per restorable tab, in strip order — the terminal and web tab lists above are saved
    // in that same order, which is what makes a row's kind enough to name its tab.
    static let tabOrderWorktreeIDs = "tabs.orderWorktreeIDs"
    static let tabOrderKinds = "tabs.orderKinds"
  }

  /// `browserTabs` come from the desk, which owns them; they are passed in rather than read off
  /// the model because the model has no view to read them from. `terminals` too, when given:
  /// the model's list is in the order they were opened, and the desk's is the order they stand
  /// in, which is the one to come back in. `tabOrder` is the strip order the two lists are in.
  func encodeState(
    to coder: NSCoder, browserTabs: [BrowserTabState] = [], terminals: [TerminalSession]? = nil,
    tabOrder: [RestoredTabOrder] = []
  ) {
    let terminals = terminals ?? self.terminals
    coder.encode(worktrees.map(\.url.path) as NSArray, forKey: Key.worktreePaths)
    coder.encode(worktrees.map(\.id.uuidString) as NSArray, forKey: Key.worktreeIDs)
    coder.encode(selectedWorktreeID?.uuidString ?? "", forKey: Key.selectedWorktreeID)
    // The session being looked at is as much "where you were" as the worktree it sits in.
    // The session itself stays disk-derived; only the pointer is stored, and one that no
    // longer resolves after a restart falls back to the most recently active session.
    coder.encode(selectedSessionID?.uuidString ?? "", forKey: Key.selectedSessionID)
    coder.encode(columnWidths.map(NSNumber.init(value:)) as NSArray, forKey: Key.columnWidths)
    coder.encode(historyHeight, forKey: Key.historyHeight)
    coder.encode(Array(collapsedRepositories) as NSArray, forKey: Key.collapsedRepositories)
    coder.encode(Array(collapsedWorktrees) as NSArray, forKey: Key.collapsedWorktrees)
    coder.encode(Array(expandedArchives) as NSArray, forKey: Key.expandedArchives)
    coder.encode(
      Array(collapsedWorktreeSections) as NSArray, forKey: Key.collapsedWorktreeSections)
    // Archived ids worth keeping: the live sessions that carry the flag, plus the ids no
    // discovery has claimed — those belong to repositories this window has not opened, and
    // dropping them would silently unarchive a whole repository the next time it is opened.
    // What that leaves out is exactly the sessions this window watched disappear, which is
    // what keeps the set bounded by what is on disk rather than by how long hukan has run.
    let archivedLive = sessions.filter { archivedSessionIDs.contains($0.id) }
      .map(\.id.uuidString)
    coder.encode(
      Array(Set(archivedLive).union(unresolvedArchived)) as NSArray,
      forKey: Key.archivedSessionIDs)

    // Sessions worth storing: a non-default mode/effort, or one that has run (so its model is
    // known and can be shown instantly next launch instead of flashing the default). This is a
    // preference map, not the session list — sessions stay disk-derived — so a stale entry for
    // a session that is gone is simply ignored.
    let customised = sessions.filter {
      $0.permissionMode != AgentSession.defaultPermissionMode || $0.effort != "default"
        || $0.reportedModel != nil
    }
    coder.encode(customised.map(\.id.uuidString) as NSArray, forKey: Key.prefSessionIDs)
    coder.encode(customised.map(\.permissionMode.rawValue) as NSArray, forKey: Key.prefModes)
    coder.encode(customised.map(\.effort) as NSArray, forKey: Key.prefEfforts)
    coder.encode(customised.map(\.model) as NSArray, forKey: Key.prefModels)

    // Type-ahead the agent has not consumed yet: kept per session so a restart does not throw
    // away lines you queued while it was working. Restored as drafts, not re-sent (see
    // applyRestoredPrefs) — nested arrays because a queued line can itself contain newlines.
    // This is where a queued line flattens: restorable state holds strings, so its attachments
    // ride as paths rather than being dropped (see `QueuedMessage.flattened`).
    let withQueue = sessions.filter { !$0.queuedMessages.isEmpty }
    coder.encode(withQueue.map(\.id.uuidString) as NSArray, forKey: Key.queueSessionIDs)
    coder.encode(
      withQueue.map { $0.queuedMessages.map(\.flattened) as NSArray } as NSArray,
      forKey: Key.queueMessages)

    // The composer draft you were part-way through typing, kept per session so a restart does
    // not lose it. Parallel string arrays, same map-not-list rule as everything above.
    let withDraft = sessions.filter { !$0.draft.isEmpty }
    coder.encode(withDraft.map(\.id.uuidString) as NSArray, forKey: Key.draftSessionIDs)
    coder.encode(withDraft.map(\.draft) as NSArray, forKey: Key.draftTexts)

    // When you last instructed each session — the rail's sort key. Stored because it is view
    // state with no owner elsewhere; the mtime it used to be re-derived from answers a different
    // question and so reordered the rail on every restart. Only an instructed session is worth a
    // slot; the rest seed from mtime the first time they are seen.
    let instructed = sessions.filter { $0.lastInstructedAt != .distantPast }
    coder.encode(instructed.map(\.id.uuidString) as NSArray, forKey: Key.instructedSessionIDs)
    coder.encode(
      instructed.map { NSNumber(value: $0.lastInstructedAt.timeIntervalSinceReferenceDate) }
        as NSArray, forKey: Key.instructedDates)

    // Each session's own last-seen roster, so next launch its picker shows the real list before it
    // reconnects. Kept per session (not one shared list), nested arrays keyed by session id — a
    // stale entry for a session that is gone is simply ignored on restore.
    let withRoster = sessions.filter { !$0.availableModels.isEmpty }
    coder.encode(withRoster.map(\.id.uuidString) as NSArray, forKey: Key.rosterSessionIDs)
    coder.encode(
      withRoster.map { $0.availableModels.map(\.value) as NSArray } as NSArray,
      forKey: Key.rosterValues)
    coder.encode(
      withRoster.map { $0.availableModels.map(\.displayName) as NSArray } as NSArray,
      forKey: Key.rosterNames)
    coder.encode(
      withRoster.map { $0.availableModels.map(\.resolvedModel) as NSArray } as NSArray,
      forKey: Key.rosterResolved)

    coder.encode(terminals.map(\.worktreeID.uuidString) as NSArray, forKey: Key.terminalWorktreeIDs)
    coder.encode(terminals.map(\.currentDirectoryPath) as NSArray, forKey: Key.terminalDirectories)
    coder.encode(terminals.map(\.sessionID) as NSArray, forKey: Key.terminalSessionIDs)
    coder.encode(terminals.map { $0.scrollbackText() } as NSArray, forKey: Key.terminalScrollbacks)

    coder.encode(
      browserTabs.map(\.worktreeID.uuidString) as NSArray, forKey: Key.browserWorktreeIDs)
    coder.encode(browserTabs.map(\.url) as NSArray, forKey: Key.browserURLs)
    coder.encode(browserTabs.map(\.title) as NSArray, forKey: Key.browserTitles)
    coder.encode(
      browserTabs.map { $0.interactionState?.base64EncodedString() ?? "" } as NSArray,
      forKey: Key.browserStates)

    coder.encode(
      tabOrder.map(\.worktreeID.uuidString) as NSArray, forKey: Key.tabOrderWorktreeIDs)
    coder.encode(tabOrder.map(\.kind.rawValue) as NSArray, forKey: Key.tabOrderKinds)
  }

  func decodeState(from coder: NSCoder) {
    let paths = strings(coder, Key.worktreePaths)
    let ids = strings(coder, Key.worktreeIDs)
    var seen = Set<String>()
    repositories = []
    for (path, idString) in zip(paths, ids) {
      guard let id = UUID(uuidString: idString) else { continue }
      let url = URL(fileURLWithPath: path)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        isDirectory.boolValue,
        seen.insert(url.standardizedFileURL.path).inserted
      else { continue }
      let repo = repository(forID: Git.repository(at: url) ?? url.standardizedFileURL.path)
      repo.worktrees.append(
        Worktree(id: id, url: url, branch: Git.currentBranch(at: url), repository: repo))
    }

    // Restored worktrees are built inline above rather than through addWorktree, so reconcile
    // watchers here too — otherwise the set opened last session would come back unwatched.
    syncWatchers()

    if let selected = coder.decodeObject(of: NSString.self, forKey: Key.selectedWorktreeID)
      as String?,
      let id = UUID(uuidString: selected)
    {
      selectedWorktreeID = id
    }
    // Sessions do not exist yet at this point — discovery builds them later. The pointer is
    // held anyway; `selectedSession` matches it once the session list is rebuilt.
    if let selected = coder.decodeObject(of: NSString.self, forKey: Key.selectedSessionID)
      as String?,
      let id = UUID(uuidString: selected)
    {
      selectedSessionID = id
    }
    historyHeight = coder.decodeDouble(forKey: Key.historyHeight)
    columnWidths =
      (coder.decodeArrayOfObjects(ofClass: NSNumber.self, forKey: Key.columnWidths) ?? [])
      .map(\.doubleValue)
    collapsedRepositories = Set(strings(coder, Key.collapsedRepositories))
    collapsedWorktrees = Set(strings(coder, Key.collapsedWorktrees))
    expandedArchives = Set(strings(coder, Key.expandedArchives))
    collapsedWorktreeSections = Set(strings(coder, Key.collapsedWorktreeSections))
    // Both forms: the parsed set is what the rail reads, the raw strings are the
    // carry-forward for ids no session has claimed yet (see `unresolvedArchived`).
    let archived = strings(coder, Key.archivedSessionIDs)
    unresolvedArchived = Set(archived)
    archivedSessionIDs = Set(archived.compactMap(UUID.init(uuidString:)))

    // Hold the per-session preferences until discoverSessions builds the sessions to apply them
    // to (via applyRestoredPrefs). Kept as a map so it survives repeated discovery.
    let prefIDs = strings(coder, Key.prefSessionIDs)
    let prefModes = strings(coder, Key.prefModes)
    let prefEfforts = strings(coder, Key.prefEfforts)
    let prefModels = strings(coder, Key.prefModels)
    restoredPrefs = [:]
    for (index, idString) in prefIDs.enumerated() {
      let mode =
        index < prefModes.count ? PermissionMode(rawValue: prefModes[index]) ?? .default : .default
      let effort = index < prefEfforts.count ? prefEfforts[index] : "default"
      let model = index < prefModels.count ? prefModels[index] : ""
      restoredPrefs[idString] = (mode, effort, model)
    }

    let queueIDs = strings(coder, Key.queueSessionIDs)
    let queueBlocks =
      (coder.decodeObject(of: [NSArray.self, NSString.self], forKey: Key.queueMessages)
        as? [[String]]) ?? []
    restoredQueues = [:]
    for (index, idString) in queueIDs.enumerated() where index < queueBlocks.count {
      restoredQueues[idString] = queueBlocks[index]
    }

    let draftIDs = strings(coder, Key.draftSessionIDs)
    let draftTexts = strings(coder, Key.draftTexts)
    restoredDrafts = [:]
    for (index, idString) in draftIDs.enumerated() where index < draftTexts.count {
      restoredDrafts[idString] = draftTexts[index]
    }

    let instructedIDs = strings(coder, Key.instructedSessionIDs)
    let instructedDates =
      (coder.decodeArrayOfObjects(ofClass: NSNumber.self, forKey: Key.instructedDates) ?? [])
      .map(\.doubleValue)
    restoredInstructedAt = [:]
    for (index, idString) in instructedIDs.enumerated() where index < instructedDates.count {
      restoredInstructedAt[idString] = Date(timeIntervalSinceReferenceDate: instructedDates[index])
    }

    // Rebuild each session's roster before discovery, so `applyRestoredPrefs` can seed it into that
    // session's own picker. Nested arrays keyed by session id; a short field going missing falls
    // back to the value string.
    let rosterIDs = strings(coder, Key.rosterSessionIDs)
    let rosterValues = nestedStrings(coder, Key.rosterValues)
    let rosterNames = nestedStrings(coder, Key.rosterNames)
    let rosterResolved = nestedStrings(coder, Key.rosterResolved)
    restoredRosters = [:]
    for (index, idString) in rosterIDs.enumerated() where index < rosterValues.count {
      let values = rosterValues[index]
      let names = index < rosterNames.count ? rosterNames[index] : []
      let resolved = index < rosterResolved.count ? rosterResolved[index] : []
      restoredRosters[idString] = values.enumerated().map { i, value in
        ClaudeModel(
          value: value,
          displayName: i < names.count ? names[i] : value,
          resolvedModel: i < resolved.count ? resolved[i] : value)
      }
    }

    // Terminals: rebuild the pending list keyed by worktree. The worktrees exist by now (built at
    // the top of this method with their restored ids), but the live TerminalSessions are made by
    // the controller (it wires the callbacks) once this returns — see materializeRestoredTerminals.
    let terminalWorktrees = strings(coder, Key.terminalWorktreeIDs)
    let terminalDirectories = strings(coder, Key.terminalDirectories)
    let terminalSessionIDs = strings(coder, Key.terminalSessionIDs)
    let terminalScrollbacks = strings(coder, Key.terminalScrollbacks)
    pendingRestoredTerminals = []
    for (index, idString) in terminalWorktrees.enumerated() {
      guard let worktreeID = UUID(uuidString: idString) else { continue }
      let directory = index < terminalDirectories.count ? terminalDirectories[index] : ""
      let sessionID = index < terminalSessionIDs.count ? terminalSessionIDs[index] : ""
      let scrollback = index < terminalScrollbacks.count ? terminalScrollbacks[index] : ""
      pendingRestoredTerminals.append((worktreeID, directory, sessionID, scrollback))
    }

    let browserWorktrees = strings(coder, Key.browserWorktreeIDs)
    let browserURLs = strings(coder, Key.browserURLs)
    let browserTitles = strings(coder, Key.browserTitles)
    let browserStates = strings(coder, Key.browserStates)
    pendingRestoredBrowserTabs = []
    for (index, idString) in browserWorktrees.enumerated() {
      guard let worktreeID = UUID(uuidString: idString), index < browserURLs.count else { continue }
      let state = index < browserStates.count ? browserStates[index] : ""
      pendingRestoredBrowserTabs.append(
        BrowserTabState(
          worktreeID: worktreeID, url: browserURLs[index],
          title: index < browserTitles.count ? browserTitles[index] : "",
          interactionState: state.isEmpty ? nil : Data(base64Encoded: state)))
    }

    let orderWorktrees = strings(coder, Key.tabOrderWorktreeIDs)
    let orderKinds = strings(coder, Key.tabOrderKinds)
    pendingRestoredTabOrder = []
    for (index, idString) in orderWorktrees.enumerated() where index < orderKinds.count {
      guard let worktreeID = UUID(uuidString: idString),
        let kind = RestoredTabOrder.Kind(rawValue: orderKinds[index])
      else { continue }
      pendingRestoredTabOrder.append(RestoredTabOrder(worktreeID: worktreeID, kind: kind))
    }

    // The session list is never stored — it is read back off disk every time.
    discoverSessions()
  }

  private func strings(_ coder: NSCoder, _ key: String) -> [String] {
    (coder.decodeArrayOfObjects(ofClass: NSString.self, forKey: key) ?? []).map { $0 as String }
  }

  /// An array of string arrays — the shape used for per-session nested values (queued lines, each
  /// session's roster fields). Decoding the outer and inner `NSArray`/`NSString` in one call.
  private func nestedStrings(_ coder: NSCoder, _ key: String) -> [[String]] {
    (coder.decodeObject(of: [NSArray.self, NSString.self], forKey: key) as? [[String]]) ?? []
  }
}
