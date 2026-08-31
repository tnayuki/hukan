import AppKit
import Foundation

extension Workspace {
  /// Rebuild the session list from what is on disk: for every open worktree, ask git for its
  /// worktrees, then list the transcripts recorded against each one.
  ///
  /// Nothing is imported and nothing is stored on our side, so there is no list to corrupt
  /// and no husks to accumulate. A worktree that gets landed or discarded takes its
  /// sessions out of the rail with it. Nothing leaves by age: a session goes below the fold when
  /// you archive it (`Workspace.isArchived`), which is a decision rather than a clock, so this
  /// rebuild lists the long tail of a checkout as readily as today's work.
  func discoverSessions() {
    // Carried across the rebuild: a session we run ourselves, and one another live process
    // holds. Neither is answered by the transcripts this rebuild lists — the first has not
    // written one yet, and the second may not have either (see `adoptRegisteredSessions`) — and
    // both are running work, which is the one thing the rail must never drop.
    let live = sessions.filter { $0.isRunning || $0.heldByPID != nil }
    var known = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var rebuilt: [AgentSession] = []
    var visited = Set<String>()

    for worktree in worktrees {
      for worktree in Git.worktrees(at: worktree.url) {
        let path = worktree.standardizedFileURL.path
        guard visited.insert(path).inserted else { continue }

        let found = ClaudeSessionStore.sessions(in: worktree)

        // git lists it, so it exists — register it even with no sessions. Hiding a
        // session-less worktree would leave a state git disagrees with, and one created
        // behind the app's back (`git worktree add` in a terminal) would never surface.
        // It contributes no rail row of its own — only its repository heading, so the
        // heading's `+` is there to start a first session — and leaves only by landing.
        // A worktree holding sessions likewise becomes a worktree of its own, which is how
        // it reappears in the rail after a restart without us recording anything.
        let owner = self.worktree(atPath: path) ?? addWorktree(worktree)
        for entry in found {
          let session: AgentSession
          if let existing = known.removeValue(forKey: entry.id) {
            // Already live/known — keep its current mode/effort (may hold a live change).
            session = existing
          } else {
            session = AgentSession(id: entry.id, worktreeID: owner.id, isDetached: true)
            applyRestoredPrefs(to: session)
            // `updatedAt` is "when this last emitted", which the transcript's mtime does
            // answer. The rail's key is not that question: a stored stamp wins outright, and
            // mtime is only the seed for a session this window has never seen — one started in
            // a terminal, or a worktree opened here for the first time.
            session.updatedAt = entry.modified
            session.lastInstructedAt = restoredInstruction(
              for: entry.id, fallback: entry.modified)
          }
          session.worktreeID = owner.id
          // Discovery has an answer for this id now, so the live archive set speaks for it from
          // here on rather than the carry-forward one (see `unresolvedArchived`).
          resolveArchivedID(entry.id)
          rebuilt.append(session)
        }
      }
    }

    // A session created moments ago has no transcript yet; keep anything still attached.
    for session in live where !rebuilt.contains(where: { $0.id == session.id }) {
      rebuilt.append(session)
    }
    sessions = rebuilt
    // The held state must show on a session nobody has attached, so wire its notify here — not in
    // the window's `attach`, which fires only on selection — for every session, exactly once.
    for session in sessions where session.onHeldChange == nil {
      session.onHeldChange = { [weak self] in self?.onSessionsChanged?() }
    }
    startSessionsRegistryWatcher()
    rescanHeldSessions()
    loadTitles()
  }

  /// Name every session that does not have one yet.
  ///
  /// The rail is what gets scanned at a glance, so a column of identical "New session" rows
  /// defeats the point of it. Reading happens off the main thread and a session that has already
  /// been named is skipped, so repeated discovery costs nothing.
  ///
  /// The names land as they are read, in batches, rather than all at the end. Naming a session
  /// means reading its transcript, and this machine's own hukan checkout holds 174 MB of them
  /// across 90 sessions: collecting the lot before handing any of it over left the rail claiming
  /// every one of those rows was a "New session" until the last file had been read. A batch per
  /// 100 ms is what keeps that honest without paying for a full rail rebuild per name.
  private func loadTitles() {
    let requests = sessions.compactMap { session -> (UUID, URL)? in
      guard session.title == nil, let worktree = worktree(id: session.worktreeID) else {
        return nil
      }
      return (session.id, worktree.url)
    }
    guard !requests.isEmpty else { return }

    DispatchQueue.global(qos: .utility).async { [weak self] in
      var batch: [(UUID, String)] = []
      var since = DispatchTime.now().uptimeNanoseconds
      func deliver() {
        guard !batch.isEmpty else { return }
        let landing = batch
        batch = []
        since = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { self?.adopt(titles: landing) }
      }
      for (id, url) in requests {
        // The window closing is the end of this: there is nobody left to name rows for, and what
        // is left to read is the rest of a gigabyte of transcripts.
        guard self != nil else { return }
        guard let title = ClaudeSessionStore.title(id: id, worktree: url) else { continue }
        batch.append((id, title))
        if DispatchTime.now().uptimeNanoseconds - since > 100_000_000 { deliver() }
      }
      deliver()
    }
  }

  /// Adopt a batch of names, in one rail redraw.
  private func adopt(titles: [(UUID, String)]) {
    defer { syncTranscriptWatcher() }
    var changed = false
    for (id, title) in titles {
      guard let session = sessions.first(where: { $0.id == id }), session.title == nil else {
        continue
      }
      session.title = title
      changed = true
    }
    if changed { onSessionsChanged?() }
  }

  func worktree(atPath path: String) -> Worktree? {
    worktrees.first { $0.url.standardizedFileURL.path == path }
  }

  /// git queries spawn processes, so keep them off the main thread.
  /// Re-read git state that can change behind the app's back — most visibly the current branch
  /// after a `git checkout` in a terminal, which the rail and top bar show but only cached at
  /// open time. Run when the window reactivates, not on every redraw (the reason branch was
  /// cached at all), and off the main thread since each read spawns a process. A branch move
  /// also shifts what the diff is measured against, so the files are marked stale to reload.
  func refreshGitState(completion: @escaping (_ changed: Bool) -> Void) {
    let targets = worktrees
    // One representative checkout per repository. Every worktree of a repository enumerates
    // the same set, so `git worktree list` at each repository's main checkout once is enough.
    let repositories = Set(targets.map { $0.repositoryID })
    DispatchQueue.global(qos: .userInitiated).async {
      let branches = targets.map { ($0, Git.currentBranch(at: $0.url)) }
      let listed = repositories.map { ($0, Git.worktrees(at: URL(fileURLWithPath: $0))) }
      DispatchQueue.main.async {
        var changed = false
        for (worktree, branch) in branches where branch != worktree.branch {
          worktree.branch = branch
          // Mark it stale rather than unloaded: the tree keeps drawing the previous list until
          // the re-query lands, instead of emptying itself for the duration.
          worktree.needsFileReload = true
          changed = true
        }
        for (repositoryID, urls) in listed {
          changed = self.reconcileWorktrees(urls, ofRepository: repositoryID) || changed
        }
        completion(changed)
      }
    }
  }

  /// git's enumeration is the authority on which worktrees a repository has, in both directions.
  /// One it lists that we do not know joins the rail (grouped under its repository by
  /// `addWorktree`) — a `git worktree add` typed in a terminal. One it no longer lists leaves,
  /// taking its sessions with it: a worktree is a task, and the `git worktree remove` that ends
  /// the task is what the rail has to notice for its rows to stay live work rather than history.
  ///
  /// An empty list is not an answer, it is a failure to read the repository at all — a checkout
  /// deleted under us, a volume unmounted — so nothing is dropped on one; showing a worktree a
  /// moment too long beats emptying a window over a transient failure. The main checkout never
  /// leaves this way either: git will not remove it, and closing a repository is a decision
  /// someone makes, not something a refresh arrives at.
  @discardableResult
  func reconcileWorktrees(_ listed: [URL], ofRepository repositoryID: String) -> Bool {
    guard !listed.isEmpty else { return false }
    var changed = false
    for url in listed where worktree(atPath: url.standardizedFileURL.path) == nil {
      addWorktree(url)
      changed = true
    }
    let paths = Set(listed.map { $0.standardizedFileURL.path })
    let gone = worktrees.filter {
      $0.repositoryID == repositoryID && !$0.isMain
        && !paths.contains($0.url.standardizedFileURL.path)
    }
    guard !gone.isEmpty else { return changed }
    dropWorktrees(gone)
    return true
  }

  /// A worktree's first read, in two hops rather than one: which files there are, and then what
  /// has moved in them.
  ///
  /// The panel cannot draw anything until the first of those lands, and it is by far the cheapest
  /// — the index, already sorted. The second measures the working tree against HEAD, which stats
  /// every tracked file, and the third walks the log; bundling all three meant the tree waited on
  /// the diff, so a worktree opened to an empty panel for as long as the slowest of the three
  /// took. Each hop calls `completion`, so the window redraws with what has arrived.
  func loadFiles(worktreeID: UUID, completion: @escaping () -> Void) {
    guard let worktree = worktree(id: worktreeID) else { return completion() }
    // The same guard `refreshFiles` has, and for the same reason — one read at a time per
    // worktree, with at most one rerun queued behind it. Without it every reason to reload
    // (a branch move, a worktree opening, a page of history) started its own full read, and on a
    // large checkout those outlast the events that ask for them and pile up.
    // Nothing is called back here: the completion is the window's redraw, and a redraw asks the
    // panel for its files again — so calling it synchronously while a read is in flight re-enters
    // this guard, and the recursion has no bottom. What the caller wanted arrives anyway: the
    // rerun queued below runs with the in-flight caller's completion, so the redraw still happens
    // once git has answered.
    guard !loadInFlight.contains(worktreeID) else {
      loadPending.insert(worktreeID)
      return
    }
    loadInFlight.insert(worktreeID)
    readSequence += 1
    let stamp = readSequence
    let url = worktree.url
    let limit = worktree.historyLimit
    // The disk, walked once on its own queue and kept in step from then on (the watcher). The
    // panel draws before it is done — the tree lists a directory itself where the index has no
    // answer yet — so nothing here waits on it; when it lands, the panel is told the whole tree
    // may read differently, which is what a nil batch means.
    if worktree.index == nil {
      let index = WorktreeIndex(root: url) { directories in
        Git.ignored(at: url, directories: directories)
      }
      worktree.index = index
      index.build { [weak self] in self?.onWorktreePathsMoved?(worktreeID, nil) }
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let tracked = Git.trackedFiles(at: url)
      DispatchQueue.main.async {
        worktree.trackedFiles = tracked
        // Both flags move here, on the first hop: git has been asked, and the panel has a tree to
        // draw. Leaving `needsFileReload` set until the second would let the redraw this
        // completion triggers ask for the whole read again.
        worktree.hasLoadedFiles = true
        worktree.needsFileReload = false
        completion()
      }
      // Uncommitted work only: measured against HEAD, the same for the main checkout and a
      // linked worktree. "Changed" is what has not been committed yet, not the whole branch.
      let changed = Git.changedFiles(at: url, since: "HEAD")
      let history = Git.history(at: url, limit: limit)
      // Recorded here so the first watcher refresh has something to measure against — without
      // it that refresh cannot tell "HEAD moved" from "never looked", and reports everything.
      let base = Git.measurementBase(at: url)
      DispatchQueue.main.async { [weak self] in
        // Unless something read the disk after this did and has already landed: that answer is
        // the newer one, and this would put the worktree back the way it was before it.
        if stamp > worktree.readStamp {
          worktree.readStamp = stamp
          worktree.changedFiles = changed
          worktree.history = history
          worktree.measurementBase = base
        }
        completion()
        guard let self else { return }
        self.loadInFlight.remove(worktreeID)
        // Something asked again while this ran — its answer may already be stale, so run exactly
        // one more pass, which re-enters here with nothing in flight.
        if self.loadPending.remove(worktreeID) != nil {
          self.loadFiles(worktreeID: worktreeID, completion: completion)
        }
      }
    }
  }

  /// One more page of the log, and *only* that: the section's paging used to go through
  /// `loadFiles`, which re-read the tracked files and re-measured the working tree against HEAD
  /// every time — the most expensive read of the three, and the one with nothing to do with the
  /// history. Scrolling a large repository therefore cost a full working-tree diff per page.
  func loadMoreHistory(worktreeID: UUID, completion: @escaping () -> Void) {
    guard let worktree = worktree(id: worktreeID), worktree.history.truncated else {
      return completion()
    }
    guard !historyInFlight.contains(worktreeID) else { return completion() }
    historyInFlight.insert(worktreeID)
    let url = worktree.url
    worktree.historyLimit += Git.historyPage
    let limit = worktree.historyLimit
    // The tag map covers the whole repository, so a page reaching further back is already
    // answered by the one the section holds — paging re-reads the log, never the refs.
    let tags = worktree.history.tags
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let history = Git.history(at: url, limit: limit, tags: tags)
      DispatchQueue.main.async {
        self?.historyInFlight.remove(worktreeID)
        guard let worktree = self?.worktree(id: worktreeID), worktree.history != history else {
          return completion()
        }
        worktree.history = history
        completion()
      }
    }
  }

  /// Start a watcher for every open worktree and drop watchers whose worktree has left.
  /// Idempotent: a worktree already watched keeps its watcher, so calling this after any path
  /// that adds or removes worktrees is cheap and cannot double-watch. Dropping a watcher
  /// releases it, and its deinit stops the FSEvents stream.
  /// Begin watching Claude Code's session registry for the held-elsewhere acquire edge. Idempotent
  /// — safe to call from every `discoverSessions`; the watcher is created once and lives for the
  /// workspace's lifetime, since the watched directory never changes.
  func startSessionsRegistryWatcher() {
    guard sessionsRegistryWatcher == nil else { return }
    sessionsRegistryWatcher = DirectoryWatcher(url: ClaudeSessionStore.registryDirectory) {
      [weak self] _ in
      self?.rescanHeldSessions()
    }
  }

  /// Re-derive every session's held state from the registry. A session we run ourselves is never
  /// held (our own engine registers a pid there too, so the `isRunning` check must exclude it
  /// first). Each `markHeldElsewhere`/`clearHeldElsewhere` notifies only on an actual change, so a
  /// scan that finds nothing new reloads nothing.
  func rescanHeldSessions() {
    let owners = ClaudeSessionStore.liveProcessOwners()
    var vanished: Set<UUID> = []
    for session in sessions {
      if session.isRunning {
        session.clearHeldElsewhere()
      } else if let owner = owners[session.id] {
        session.markHeldElsewhere(by: owner.pid)
      } else {
        // Nobody holds it, so "is there anything to resume" can have changed: a session adopted
        // below joined the rail before it had written a transcript, and the process that has
        // gone is what wrote one. Asked of the hold's edge, and of a registry-born row whether
        // or not the edge is this pass's — the release usually arrives on the holder's own
        // `.exit` watch, which cleared the pid before any rescan could run. One stat either way,
        // and a rescan is a claude starting or stopping, not a redraw.
        if session.heldByPID != nil || session.isRegistryBorn,
          let worktree = worktree(id: session.worktreeID)
        {
          session.isDetached = ClaudeSessionStore.isResumable(
            id: session.id, worktree: worktree.url)
          // Nothing was written, so there was no conversation: the row stood for a process, and
          // the process is gone. Undoing the adoption is the honest end of it — leaving it would
          // grow a "New session" per `claude` that was started and quit before a word was typed,
          // which is a rail of rows standing for nothing.
          if session.isRegistryBorn && !session.isDetached { vanished.insert(session.id) }
        }
        session.clearHeldElsewhere()
      }
    }
    if !vanished.isEmpty {
      sessions.removeAll { vanished.contains($0.id) }
      if let selected = selectedSessionID, vanished.contains(selected) { selectedSessionID = nil }
    }
    adoptRegisteredSessions(owners)
    // A hold taken or lifted is also a conversation becoming worth following, or ceasing to be.
    syncTranscriptWatcher()
    if !vanished.isEmpty { onSessionsChanged?() }
  }

  /// Put on the rail the sessions the registry names that this window has never seen — a `claude`
  /// started in a terminal, or by another app, in a worktree that is open here.
  ///
  /// Discovery cannot answer for these. It lists transcripts, and the record is written when the
  /// process starts, seconds before the first message creates the transcript — measured at 11s on
  /// a session started here, which is simply how long it took to type — and it is written once,
  /// so there is no second event to re-read on. Waiting for the transcript therefore means
  /// waiting until the next `discoverSessions`, which is a repository being opened or a relaunch:
  /// a session working away in the background with no row on the rail, which is the one thing the
  /// rail exists to prevent. The record is the answer instead — it carries the id and the
  /// directory, which is the whole of what a row needs. The name arrives when the transcript does.
  ///
  /// Only the worktree *root* counts, never a directory inside it: Claude Code keys its transcript
  /// directory off the cwd, so a session started one level down writes where
  /// `ClaudeSessionStore.sessions(in:)` will never look, and adopting it would put up a row the
  /// next discovery drops.
  func adoptRegisteredSessions(_ owners: [UUID: ClaudeSessionStore.SessionOwner]) {
    let known = Set(sessions.map(\.id))
    var adopted: [(session: AgentSession, pid: pid_t)] = []
    for (id, owner) in owners where !known.contains(id) {
      guard let cwd = owner.cwd, let home = worktree(atRoot: cwd) else { continue }
      // Detached is "there is something to resume", and at this moment there usually is not.
      // Asked rather than assumed, for the session that has been going a while before this
      // window opened its worktree.
      let session = AgentSession(
        id: id, worktreeID: home.id,
        isDetached: ClaudeSessionStore.isResumable(id: id, worktree: home.url))
      session.isRegistryBorn = true
      applyRestoredPrefs(to: session)
      // It started just now, which is the honest answer for both — and the stored stamp still
      // wins for a session this window has instructed before, exactly as in discovery.
      session.updatedAt = Date()
      session.lastInstructedAt = restoredInstruction(for: id, fallback: session.updatedAt)
      resolveArchivedID(id)
      adopted.append((session, owner.pid))
    }
    guard !adopted.isEmpty else { return }
    // Listed before they are marked: marking notifies, and a notification is the rail reading
    // `sessions` back.
    sessions.append(contentsOf: adopted.map(\.session))
    for (session, pid) in adopted {
      session.onHeldChange = { [weak self] in self?.onSessionsChanged?() }
      session.markHeldElsewhere(by: pid)
    }
    loadTitles()
    syncTranscriptWatcher()
    onSessionsChanged?()
  }

  /// Keep the transcript watcher matched to whether anything is still waiting for a name.
  ///
  /// An adopted row is the one row nothing else will ever name. Its transcript does not exist
  /// when the row goes up — that is the whole reason the row came off the registry — and the
  /// file appearing later is an event in a directory hukan watches for no other reason. So the
  /// stream is up exactly while one of these rows is nameless: `~/.claude/projects`, the parent,
  /// since the worktree's own directory under it may not exist until the first message creates
  /// it. Every claude on the machine writes into that subtree, which is why the question asked
  /// of a batch is a set lookup on the file name, and why the stream is not up the rest of the
  /// time.
  func syncTranscriptWatcher() {
    guard !watchedTranscripts().isEmpty else {
      transcriptsWatcher = nil
      return
    }
    guard transcriptsWatcher == nil else { return }
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/projects")
    transcriptsWatcher = DirectoryWatcher(url: directory) { [weak self] paths in
      guard let self else { return }
      // Read again rather than captured: what is being watched for changes under this closure,
      // and a set fixed when the stream started would go on answering for rows that have since
      // been named and panes that have since been let go.
      let watched = self.watchedTranscripts()
      let moved = Set(paths.map { ($0 as NSString).lastPathComponent }).compactMap { watched[$0] }
      guard !moved.isEmpty else { return }
      var wantsNames = false
      for id in moved {
        guard let session = self.sessions.first(where: { $0.id == id }) else { continue }
        if session.title == nil { wantsNames = true }
        if session.isFollowable, let worktree = self.worktree(id: session.worktreeID) {
          session.follow(at: worktree.url)
        }
      }
      if wantsNames { self.loadTitles() }
    }
  }

  /// The transcript files worth reacting to, by file name, and the session each belongs to.
  ///
  /// Two reasons a file is on this list, and both end on their own. A row adopted from the
  /// registry has no name until its transcript exists, and reading titles is discovery's job,
  /// which has already run. And a conversation another live process is writing, opened here, is
  /// on screen at whatever it said when it was opened unless the file is followed — the process
  /// is not ours, so there is no stream to hear it on. Nothing else qualifies: a session hukan
  /// runs speaks over its own pipes, and one nobody has opened is read whole when it is.
  private func watchedTranscripts() -> [String: UUID] {
    var watched: [String: UUID] = [:]
    for session in sessions
    where (session.isRegistryBorn && session.title == nil) || session.isFollowable {
      watched["\(session.id.uuidString).jsonl"] = session.id
    }
    return watched
  }

  /// The open worktree whose root is exactly this directory. Resolved on both sides, because
  /// /tmp is a symlink and an engine reports its directory through `realpath` — the lesson
  /// `returnSession` learned first.
  func worktree(atRoot url: URL) -> Worktree? {
    let target = url.standardizedFileURL.resolvingSymlinksInPath().path
    return worktrees.first {
      $0.url.standardizedFileURL.resolvingSymlinksInPath().path == target
    }
  }

  func syncWatchers() {
    let live = Set(worktrees.map(\.id))
    watchers = watchers.filter { live.contains($0.key) }
    for worktree in worktrees where watchers[worktree.id] == nil {
      let id = worktree.id
      // Observation begins when the watcher does, so the baseline is recorded here: where HEAD
      // and the index stand at this moment. Without one, a refresh cannot tell "moved under me"
      // from "never looked" and its first report claims everything moved. Anything that moved
      // *before* this moment needs no report — nothing was watching, so nothing was shown that
      // could have gone stale.
      worktree.measurementBase = Git.measurementBase(at: worktree.url)
      // Two streams, and the split is the point. A worktree's files and its repository are
      // different questions with different answers — one narrows to what moved, the other cannot
      // be narrowed at all — and FSEvents coalesces per stream, so carrying both on one meant a
      // `git status` an agent ran arrived in the same batch as the file it had just written, and
      // the batch was answered by the worse half: the file's name was dropped and the whole
      // worktree read again. A linked worktree always had the two, its repository being outside
      // it; the main checkout keeps its `.git` inside the subtree and so had to be told to leave
      // it out. Now every worktree is watched the same way.
      let root = worktree.url.standardizedFileURL.path
      var started = [
        DirectoryWatcher(
          url: worktree.url, excluding: [worktree.url.appendingPathComponent(".git")]
        ) { [weak self] paths in
          guard let moved = Workspace.relativePaths(paths, under: root) else {
            // Placed nowhere, so nothing about it can be narrowed: the index walks again and
            // everything open is measured against git afresh.
            self?.worktree(id: id)?.index?.update(moved: nil) { directories in
              self?.onWorktreePathsMoved?(id, directories)
            }
            self?.refreshFiles(worktreeID: id, moved: nil)
            return
          }
          guard !moved.isEmpty else { return }
          // The index lists again the directories the batch touched, on its own queue, and says
          // which — before git is asked, since the tree does not wait on git and git could not
          // answer for a `mkdir` in any case. No index yet means no worktree on screen that
          // reads one.
          self?.worktree(id: id)?.index?.update(moved: moved) { directories in
            self?.onWorktreePathsMoved?(id, directories)
          }
          self?.refreshFiles(worktreeID: id, moved: moved)
        }
      ]
      // Nothing in there is a file anyone has open, but HEAD and the index moving changes what
      // every open file is measured against — so what this one reports, it reports as
      // "everything". What it reports at all is the narrower question: most of a batch in there
      // is git's own churn, and a `git add` writing a dozen blobs must not read the worktree a
      // dozen times. The heaviest of it never leaves the stream (`Git.movesTheWorkingSet` still
      // answers for the rest, and for a directory this repository happens not to have).
      if let gitDirectory = Git.gitDirectory(at: worktree.url) {
        let directory = gitDirectory.standardizedFileURL.path
        started.append(
          DirectoryWatcher(
            url: gitDirectory,
            excluding: ["objects", "logs", "worktrees"].map(gitDirectory.appendingPathComponent)
          ) { [weak self] paths in
            guard Workspace.gitDirectoryMoved(paths, under: directory) else { return }
            self?.refreshFiles(worktreeID: id, moved: nil)
          })
      }
      watchers[id] = started
    }
  }

  /// A file moved under a watched worktree — re-query git and, only if the working set
  /// actually shifted, adopt it and tell the window. Unlike `loadFiles` this ignores
  /// `hasLoadedFiles`: its whole point is to refresh a worktree that was already loaded. The
  /// equality check is what keeps a churning build — whose ignored files never reach git —
  /// from reloading the UI at all, so watching broadly costs nothing when nothing git-visible
  /// changed.
  ///
  /// The FSEvents 0.3s window coalesces write bursts, but only while the last query has already
  /// returned; on a large repository a query can outlast the window, and a plain dispatch would
  /// then stack a fresh one per batch until the machine is buried in overlapping work (in the
  /// subprocess days, git processes). So a worktree with a query in flight does not start
  /// another — it records that it changed again in `refreshPending`, and the query, on finishing,
  /// runs exactly one more pass. At most one query plus one queued rerun per worktree, whatever
  /// the event rate.
  ///
  /// `ownWrite` is hukan having done the writing — a save, one of the panel's own edits. git is
  /// asked about those paths exactly as it is about anyone else's, but they are subtracted from
  /// the report: the buffer already holds what went to disk, and a re-read would only cost the
  /// reader its selection.
  ///
  /// What the report *says* moved is what the read observed, never the scope it was asked with.
  /// `moved` decides the question put to git; the answer is reported as the paths whose entries
  /// actually differ — and as "everything" only when HEAD or the index moved between this read
  /// and the last (`Git.MeasurementBase`), which is the one case where files the diff never
  /// names are measured against something new. The two used to be the same value, and that was
  /// a race: a read asked for wholesale observes whatever lands while it runs, so an edit made
  /// during one was reported as "everything moved" and cost every open file a re-read.
  func refreshFiles(worktreeID: UUID, moved: Set<String>? = nil, ownWrite: Bool = false) {
    guard worktree(id: worktreeID) != nil else { return }
    guard !refreshInFlight.contains(worktreeID) else {
      refreshPending.insert(worktreeID)
      // The rerun folds the batches and re-reads what they name — `ownWrite` is not carried
      // through it, so a save landing while a read is in flight costs that one file a re-read.
      // It is a race of milliseconds now that a read is narrowed, and the direction that errs is
      // the one that cannot leave anything stale.
      pendingPaths[worktreeID] = Workspace.union(pendingPaths[worktreeID] ?? .some([]), moved)
      return
    }
    guard let url = worktree(id: worktreeID)?.url else { return }
    let limit = worktree(id: worktreeID)?.historyLimit ?? Git.historyPage
    // What git is asked about — nil for the whole worktree. An empty set is a question with no
    // answer rather than a narrow one, and it must not be folded in as if it were narrow: that
    // would keep every entry the whole read has just dropped. Neither can a batch carrying a
    // `.gitignore`, which is the one file whose own content decides what *other* files are: ask
    // only about the paths that moved and a file it has just stopped hiding is mentioned by
    // nothing, while one it has started hiding stays listed.
    let asked = moved.flatMap { paths -> Set<String>? in
      if paths.isEmpty { return nil }
      if paths.contains(where: { ($0 as NSString).lastPathComponent == ".gitignore" }) {
        return nil
      }
      return paths
    }
    // What a wholesale question can collapse to. Nothing in the working tree was written — a
    // write raises its own batch and is asked about by name — so the answer can only have
    // moved where HEAD went since the last landed read, where the index stands off HEAD, or
    // where it already differed. Captured on this side of the hop, so the background block
    // measures from what the last landed read actually recorded.
    let recordedHead = worktree(id: worktreeID)?.measurementBase?.head
    // A ref lives in git's own directory, so a batch narrowed to paths in the working tree
    // cannot have moved a tag — the same reasoning that keeps the index out of a narrowed read,
    // and what keeps a repository with thousands of tags from paying for the scan on every file
    // an agent writes.
    let knownTags = asked == nil ? nil : worktree(id: worktreeID)?.history.tags
    let alreadyChanged = Set(worktree(id: worktreeID)?.changedFiles.map(\.path) ?? [])
    refreshInFlight.insert(worktreeID)
    readSequence += 1
    let stamp = readSequence
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      // The collapse — see `Git.wholesaleCandidates`. nil (a first read, an unborn branch, a
      // head that no longer resolves) falls back to the whole diff, the honest cost then.
      let scope =
        asked
        ?? Git.wholesaleCandidates(at: url, sinceHead: recordedHead).map {
          $0.union(alreadyChanged)
        }
      let changed = Git.changedFiles(at: url, since: "HEAD", paths: scope.map(Array.init))
      // The index is a file inside git's own directory, so nothing that moved in the worktree
      // can have moved it: a narrowed batch is by construction one git never saw. Reading it
      // anyway is what a 400,000-entry index costs on every write an agent makes.
      let tracked = asked == nil ? Git.trackedFiles(at: url) : nil
      // The commit that clears the changed set is the one that adds a row to the History
      // section, so the two are read together and compared together — a commit moves only the
      // second, and the equality test has to see that as a change or the section would keep
      // drawing the list from before it.
      let history = Git.history(at: url, limit: limit, tags: knownTags)
      let base = Git.measurementBase(at: url)
      DispatchQueue.main.async {
        guard let self else { return }
        self.refreshInFlight.remove(worktreeID)
        // The same rule `loadFiles` keeps: a read that started earlier read the disk earlier,
        // so it has nothing to say once a later one has landed — and a narrowed read folds into
        // the changed set, which makes writing an older answer into it worse than useless.
        if let worktree = self.worktree(id: worktreeID), stamp > worktree.readStamp {
          worktree.readStamp = stamp
          // A narrowed read answers for the paths it was given and for nothing else, so it is
          // folded into what the worktree already holds rather than replacing it — the
          // collapsed wholesale included, whose scope is its candidates.
          let files =
            scope.map { Git.merged(changed, into: worktree.changedFiles, for: $0) }
            ?? changed
          let trackedFiles = tracked ?? worktree.trackedFiles
          // The report: everything, if what files are measured against moved under this read
          // (or nothing has ever been read); otherwise exactly what was seen to move — the
          // entries that differ, plus the paths git was asked about, less the ones hukan wrote
          // itself. `moved` is not consulted: the scope of the question is not an observation.
          let reported: Set<String>?
          if let recorded = worktree.measurementBase, recorded == base {
            var observed = Git.differingPaths(worktree.changedFiles, files)
            if let asked { observed.formUnion(asked) }
            if ownWrite { observed.subtract(asked ?? []) }
            reported = observed
          } else {
            reported = nil
          }
          worktree.measurementBase = base
          // Adopting and reporting are two questions. git's answer moving is one reason to
          // report; a file whose content moved without moving the answer is the other, and it
          // was missing — one line replaced by another leaves the same `+1 −1`, so the second
          // such edit to a file was adopted by nobody and the tab showing it went on showing
          // what was there before. The report is gated on git *knowing* the path rather than on
          // its answer changing, which is what still keeps a build churning inside its own
          // output directory from reloading the window: those paths git has never heard of.
          let answerMoved =
            worktree.changedFiles != files || worktree.trackedFiles != trackedFiles
            || worktree.history != history
          if answerMoved {
            worktree.changedFiles = files
            worktree.trackedFiles = trackedFiles
            worktree.history = history
            worktree.hasLoadedFiles = true
          }
          if answerMoved || reported?.contains(where: worktree.isKnownToGit) == true {
            self.onWorktreeFilesChanged?(worktreeID, reported)
          }
        }
        // Whatever the result, git has just been asked — a branch move's re-read is satisfied.
        self.worktree(id: worktreeID)?.needsFileReload = false
        // A change landed while the query ran, so its result may already be stale — catch up
        // with one more pass (which re-enters here with nothing in flight).
        if self.refreshPending.remove(worktreeID) != nil {
          let queued = self.pendingPaths.removeValue(forKey: worktreeID) ?? .some([])
          self.refreshFiles(worktreeID: worktreeID, moved: queued ?? nil)
        }
      }
    }
  }
}
