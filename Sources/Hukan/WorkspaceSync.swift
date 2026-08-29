import AppKit
import Foundation

extension Workspace {
  /// Rebuild the session list from what is on disk: for every open worktree, ask git for its
  /// worktrees, then list the transcripts recorded against each one.
  ///
  /// Nothing is imported and nothing is stored on our side, so there is no list to corrupt
  /// and no husks to accumulate. A worktree that gets landed or discarded takes its
  /// sessions out of the rail with it. Old sessions are not dropped — they fold into the
  /// "Older" time bucket (collapsed by default), which is what keeps the rail glanceable
  /// without hiding history; a base checkout that has carried many sessions is exactly the
  /// long tail that bucket exists to hold.
  func discoverSessions() {
    let live = sessions.filter { $0.isRunning }
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
      DispatchQueue.main.async { [weak self] in
        worktree.changedFiles = changed
        worktree.history = history
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
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let history = Git.history(at: url, limit: limit)
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
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/sessions")
    sessionsRegistryWatcher = DirectoryWatcher(url: dir) { [weak self] _ in
      self?.rescanHeldSessions()
    }
  }

  /// Re-derive every session's held state from the registry. A session we run ourselves is never
  /// held (our own engine registers a pid there too, so the `isRunning` check must exclude it
  /// first). Each `markHeldElsewhere`/`clearHeldElsewhere` notifies only on an actual change, so a
  /// scan that finds nothing new reloads nothing.
  func rescanHeldSessions() {
    let owners = ClaudeSessionStore.liveProcessOwners()
    for session in sessions {
      if session.isRunning {
        session.clearHeldElsewhere()
      } else if let owner = owners[session.id] {
        session.markHeldElsewhere(by: owner)
      } else {
        session.clearHeldElsewhere()
      }
    }
  }

  func syncWatchers() {
    let live = Set(worktrees.map(\.id))
    watchers = watchers.filter { live.contains($0.key) }
    for worktree in worktrees where watchers[worktree.id] == nil {
      let id = worktree.id
      // Watch the whole worktree subtree: an edit, and — in the main checkout, whose `.git` is
      // inside it — the commit that clears those edits away, a change worth noticing just the
      // same. The re-query is where ignored churn (a build writing into `node_modules`)
      // collapses to a cheap no-op.
      let root = worktree.url.standardizedFileURL.path
      var started = [
        DirectoryWatcher(url: worktree.url) { [weak self] paths in
          let moved = Workspace.relativePaths(paths, under: root)
          // The index lists again the directories the batch touched, on its own queue, and
          // says which — before git is asked, since the tree does not wait on git and git could
          // not answer for a `mkdir` in any case. No index yet means no worktree on screen that
          // reads one.
          self?.worktree(id: id)?.index?.update(moved: moved) { directories in
            self?.onWorktreePathsMoved?(id, directories)
          }
          self?.refreshFiles(worktreeID: id, moved: moved)
        }
      ]
      // A linked worktree keeps a pointer file where the main checkout keeps a directory, so its
      // `HEAD` and `index` live under the common dir instead — outside everything above. Staging
      // and committing there write nothing inside the worktree at all, so without this second
      // watcher the diffstat, the ± scope and the gutter kept describing work that had already
      // been committed, and nothing ever corrected them: `refreshGitState` on focus re-reads the
      // branch, which a commit does not move.
      if let gitDirectory = Git.gitDirectory(at: worktree.url),
        !gitDirectory.path.hasPrefix(worktree.url.standardizedFileURL.path + "/")
      {
        // Nothing here is a file anyone has open, but HEAD and the index moving changes what
        // every open file is measured against — so this one says "everything", always.
        started.append(
          DirectoryWatcher(url: gitDirectory) { [weak self] _ in
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
  func refreshFiles(worktreeID: UUID, moved: Set<String>? = nil) {
    guard worktree(id: worktreeID) != nil else { return }
    guard !refreshInFlight.contains(worktreeID) else {
      refreshPending.insert(worktreeID)
      pendingPaths[worktreeID] = Workspace.union(pendingPaths[worktreeID] ?? .some([]), moved)
      return
    }
    guard let url = worktree(id: worktreeID)?.url else { return }
    let limit = worktree(id: worktreeID)?.historyLimit ?? Git.historyPage
    refreshInFlight.insert(worktreeID)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let changed = Git.changedFiles(at: url, since: "HEAD")
      let tracked = Git.trackedFiles(at: url)
      // The commit that clears the changed set is the one that adds a row to the History
      // section, so the two are read together and compared together — a commit moves only the
      // second, and the equality test has to see that as a change or the section would keep
      // drawing the list from before it.
      let history = Git.history(at: url, limit: limit)
      DispatchQueue.main.async {
        guard let self else { return }
        self.refreshInFlight.remove(worktreeID)
        if let worktree = self.worktree(id: worktreeID),
          worktree.changedFiles != changed || worktree.trackedFiles != tracked
            || worktree.history != history
        {
          worktree.changedFiles = changed
          worktree.trackedFiles = tracked
          worktree.history = history
          worktree.hasLoadedFiles = true
          self.onWorktreeFilesChanged?(worktreeID, moved)
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
