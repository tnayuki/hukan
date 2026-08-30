import XCTest

@testable import Hukan

/// git owns the worktree list, so the window has to follow it in both directions. Built on real
/// repositories driven by the `git` CLI, the way `GitTests` is — the case this exists for, a
/// session running `git worktree remove` once its task has landed, happens on disk and not in
/// the model.
final class WorktreeSyncTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    Git.initialize()
    // Resolve symlinks up front: temp dirs live under /var → /private/var, and libgit2 reports
    // resolved paths, so the base has to be resolved for path comparisons to line up.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-worktree-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    root = tmp.resolvingSymlinksInPath()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: helpers

  @discardableResult
  private func git(_ arguments: [String], in dir: URL) -> String {
    run(["git"] + arguments, in: dir)
  }

  @discardableResult
  private func run(_ arguments: [String], in dir: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = dir
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A repository with one commit and one linked worktree — the shape every test here starts from.
  private func makeRepositoryWithWorktree() throws -> (main: URL, linked: URL) {
    let main = root.appendingPathComponent("main")
    try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
    git(["init", "-q", "-b", "main"], in: main)
    git(["config", "user.email", "test@example.com"], in: main)
    git(["config", "user.name", "Test"], in: main)
    git(["config", "commit.gpgsign", "false"], in: main)
    try "hello\n".write(to: main.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    git(["add", "."], in: main)
    git(["commit", "-q", "-m", "Initial"], in: main)
    let linked = root.appendingPathComponent("task")
    git(["worktree", "add", "-q", "-b", "task", linked.path], in: main)
    return (main, linked)
  }

  /// Wait until the worktree's first read has landed and nothing else is in flight for it —
  /// `loadFiles` reports twice (the tree, then the measuring) and a test that starts writing
  /// after the first is racing the second.
  private func settle(_ workspace: Workspace, worktreeID: UUID) {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      let worktree = workspace.worktree(id: worktreeID)
      if worktree?.hasLoadedFiles == true, !workspace.loadInFlight.contains(worktreeID),
        !workspace.refreshInFlight.contains(worktreeID)
      {
        return
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
  }

  private func openPaths(_ workspace: Workspace) -> [String] {
    workspace.worktrees.map { $0.url.standardizedFileURL.path }.sorted()
  }

  // MARK: tests

  func testARemovedWorktreeLeavesTheWindowWithItsSessions() throws {
    let (main, linked) = try makeRepositoryWithWorktree()
    let workspace = Workspace()
    workspace.openRepository(main)
    XCTAssertEqual(openPaths(workspace), [linked.path, main.path].sorted())

    guard let task = workspace.worktree(atPath: linked.path) else {
      return XCTFail("the linked worktree never joined the window")
    }
    let session = AgentSession(worktreeID: task.id, isDetached: true)
    workspace.sessions.append(session)
    workspace.selectedWorktreeID = task.id
    workspace.selectedSessionID = session.id

    git(["worktree", "remove", linked.path], in: main)

    let refreshed = expectation(description: "refreshGitState")
    var reportedChange = false
    workspace.refreshGitState { changed in
      reportedChange = changed
      refreshed.fulfill()
    }
    waitForExpectations(timeout: 10)

    XCTAssertTrue(reportedChange, "a worktree leaving has to redraw the window")
    XCTAssertEqual(openPaths(workspace), [main.path])
    XCTAssertTrue(workspace.sessions.isEmpty, "the worktree's sessions leave with it")
    XCTAssertEqual(workspace.selectedWorktreeID, workspace.worktree(atPath: main.path)?.id)
    XCTAssertNil(workspace.selectedSessionID)
  }

  /// The case the exit is followed for at all. An `ExitWorktree` with `remove` is git ceasing to
  /// list a worktree while the session that was in it lives on, back where it started — and a
  /// worktree leaving takes its sessions with it (above). Unless the session has already gone
  /// home by the time the enumeration is re-read, the reconcile stops the one process that just
  /// finished its task. Driven through the engine's own events, since the result text is the
  /// whole of what the window learns from.
  func testASessionThatExitedItsWorktreeSurvivesItsRemoval() throws {
    let (main, linked) = try makeRepositoryWithWorktree()
    let workspace = Workspace()
    workspace.openRepository(main)
    let task = try XCTUnwrap(workspace.worktree(atPath: linked.path))
    let home = try XCTUnwrap(workspace.worktree(atPath: main.path))
    let session = AgentSession(worktreeID: task.id)
    workspace.sessions.append(session)
    session.onExitWorktree = { url in workspace.returnSession(session, to: url) }

    session.apply(
      ClaudeEvent(
        type: "assistant", subtype: nil,
        payload: [
          "message": [
            "content": [
              [
                "type": "tool_use", "id": "t1", "name": "ExitWorktree",
                "input": ["action": "remove"],
              ]
            ]
          ]
        ]))
    session.apply(
      ClaudeEvent(
        type: "user", subtype: nil,
        payload: [
          "message": [
            "content": [
              [
                "type": "tool_result", "tool_use_id": "t1",
                "content":
                  "Exited and removed worktree at \(linked.path). Session is now back in \(main.path).",
              ]
            ]
          ]
        ]))
    XCTAssertEqual(session.worktreeID, home.id, "the result moved the session home")

    git(["worktree", "remove", "--force", linked.path], in: main)
    let refreshed = expectation(description: "refreshGitState")
    workspace.refreshGitState { _ in refreshed.fulfill() }
    waitForExpectations(timeout: 10)

    XCTAssertEqual(openPaths(workspace), [main.path])
    XCTAssertTrue(
      workspace.sessions.contains { $0 === session },
      "the worktree left; the session that had already left it did not go with it")
    XCTAssertEqual(session.worktreeID, home.id)
  }

  /// The exit never registers a worktree. The engine's original directory is where the session
  /// was started — a worktree root this window holds — so a result naming anything else is not
  /// a place to make: a Worktree git does not list is what the next reconcile drops, and the
  /// session with it, which is the failure the exit is followed to prevent.
  func testAnExitToAPathThatIsNotAnOpenWorktreeChangesNothing() throws {
    let (main, linked) = try makeRepositoryWithWorktree()
    let workspace = Workspace()
    workspace.openRepository(main)
    let task = try XCTUnwrap(workspace.worktree(atPath: linked.path))
    let session = AgentSession(worktreeID: task.id)
    workspace.sessions.append(session)

    XCTAssertFalse(workspace.returnSession(session, to: root))
    XCTAssertEqual(session.worktreeID, task.id)
    XCTAssertEqual(openPaths(workspace), [linked.path, main.path].sorted())
  }

  /// The first read lands in two hops so the panel can draw a tree before the working-tree diff
  /// and the log are in: the tree only needs the index, which is the cheapest of the three.
  func testTheFileListArrivesBeforeTheDiffAndTheLog() throws {
    let (main, _) = try makeRepositoryWithWorktree()
    try "edited\n".write(
      to: main.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let workspace = Workspace()
    workspace.addWorktree(main)
    let worktree = try XCTUnwrap(workspace.worktree(atPath: main.path))

    var seen: [(tracked: Int, changed: Int, commits: Int)] = []
    let read = expectation(description: "both hops")
    read.expectedFulfillmentCount = 2
    workspace.loadFiles(worktreeID: worktree.id) {
      seen.append(
        (worktree.trackedFiles.count, worktree.changedFiles.count, worktree.history.commits.count))
      read.fulfill()
    }
    waitForExpectations(timeout: 10)

    XCTAssertEqual(seen.count, 2, "the window is told twice, so it draws what has arrived")
    XCTAssertEqual(seen[0].tracked, 1, "the file list is the first hop")
    XCTAssertEqual(seen[0].changed, 0)
    XCTAssertEqual(seen[0].commits, 0)
    XCTAssertTrue(worktree.hasLoadedFiles, "and the panel is told to stop saying it is reading")
    XCTAssertEqual(seen[1].changed, 1, "what moved is the second")
    XCTAssertEqual(seen[1].commits, 1)
  }

  /// The completion is the window's redraw, and a redraw asks the panel for its files again — so
  /// an ask that arrives while a read is in flight has to be queued rather than answered where it
  /// stands. Answering it recursed with no bottom: reload → loadFiles → completion → reload, which
  /// is the spin that left the app burning a core and never opening a window.
  func testASecondAskWhileAReadIsInFlightIsNotAnsweredWhereItStands() throws {
    let (main, _) = try makeRepositoryWithWorktree()
    let workspace = Workspace()
    workspace.addWorktree(main)
    let worktree = try XCTUnwrap(workspace.worktree(atPath: main.path))

    var calls = 0
    let read = expectation(description: "the read lands")
    read.expectedFulfillmentCount = 2
    // The ask queued below runs a second pass with this same completion, so the hops outnumber
    // the two being waited for.
    read.assertForOverFulfill = false
    var redraw: (() -> Void)!
    redraw = {
      calls += 1
      read.fulfill()
      // What the window does on every redraw. The cap is what keeps a regression here a failed
      // count rather than an overflowed stack.
      guard calls < 20, !worktree.hasLoadedFiles || worktree.needsFileReload else { return }
      workspace.loadFiles(worktreeID: worktree.id, completion: redraw)
    }

    workspace.loadFiles(worktreeID: worktree.id, completion: redraw)
    workspace.loadFiles(worktreeID: worktree.id, completion: redraw)
    XCTAssertEqual(calls, 0, "the second ask is queued behind the first, not answered on the spot")

    waitForExpectations(timeout: 10)
    XCTAssertTrue(worktree.hasLoadedFiles, "and the read itself still lands")
    XCTAssertEqual(worktree.trackedFiles.count, 1)
  }

  /// A worktree added behind the app's back still arrives — the other direction, unchanged.
  func testAWorktreeAddedBehindTheAppsBackJoinsTheWindow() throws {
    let (main, linked) = try makeRepositoryWithWorktree()
    let workspace = Workspace()
    workspace.addWorktree(main)
    XCTAssertEqual(openPaths(workspace), [main.path])

    let refreshed = expectation(description: "refreshGitState")
    var reportedChange = false
    workspace.refreshGitState { changed in
      reportedChange = changed
      refreshed.fulfill()
    }
    waitForExpectations(timeout: 10)

    XCTAssertTrue(reportedChange)
    XCTAssertEqual(openPaths(workspace), [linked.path, main.path].sorted())
  }

  /// A commit made in a *linked* worktree has to reach the window, and nothing it writes is
  /// inside that worktree: the pointer file where the main checkout has a `.git` directory sends
  /// `HEAD` and `index` under the common dir, so staging and committing there are invisible to a
  /// watcher over the worktree alone. Nothing else corrects it either — the focus-in re-read only
  /// looks at the branch, which a commit does not move — so the diffstat, the ± scope and the
  /// gutter would describe work that had already been committed until something happened to
  /// write inside the worktree again. Real FSEvents, since watching the right directory is the
  /// whole assertion.
  func testACommitInALinkedWorktreeReachesTheWindow() throws {
    let (main, linked) = try makeRepositoryWithWorktree()
    let workspace = Workspace()
    workspace.openRepository(main)
    let task = try XCTUnwrap(workspace.worktree(atPath: linked.path))

    // An edit inside the worktree — this much a watcher over the worktree already sees. Made by
    // another process, as an agent's would be: the watchers carry `IgnoreSelf`, so a write from
    // this very process raises no event at all (the reason the app refreshes its own saves by
    // hand).
    let sawTheEdit = expectation(description: "the edit shows as a change")
    // And it says *which* file: a reader with several open re-reads only the one written to.
    var editedPaths: Set<String>??
    workspace.onWorktreeFilesChanged = { id, moved in
      guard id == task.id, !task.changedFiles.isEmpty else { return }
      editedPaths = moved
      sawTheEdit.fulfill()
    }
    run(["sh", "-c", "echo edited > a.txt"], in: linked)
    wait(for: [sawTheEdit], timeout: 20)
    XCTAssertEqual(editedPaths ?? nil, ["a.txt"], "the edit named the file it touched")

    // Committing it writes only under the common dir. The change has to leave the window anyway.
    let sawTheCommit = expectation(description: "the commit clears the change")
    // What it reports is not asserted here: two watchers fire for a commit in a linked
    // worktree — the one over the worktree, and the one over the git directory outside it —
    // and which arrives first is a race. That the second cannot be narrowed to a file is the
    // rule, and `ChangedPathsTests` is where a rule belongs.
    workspace.onWorktreeFilesChanged = { id, _ in
      guard id == task.id, task.changedFiles.isEmpty else { return }
      sawTheCommit.fulfill()
    }
    git(["add", "a.txt"], in: linked)
    git(["commit", "-q", "-m", "Edit a"], in: linked)
    wait(for: [sawTheCommit], timeout: 20)
  }

  /// hukan's own write — a save, one of the files panel's edits. FSEvents carries `IgnoreSelf`,
  /// so this process writing raises no event at all and the refresh is asked for by hand: git is
  /// asked about the path written, exactly as it would be about anyone else's, and what the
  /// readers are told moved is nothing, since the buffer already holds what went to disk and a
  /// re-read would only cost them their selection.
  func testHukansOwnWriteAsksGitAboutItWithoutReReadingIt() throws {
    let (main, _) = try makeRepositoryWithWorktree()
    let workspace = Workspace()
    workspace.openRepository(main)
    let worktree = try XCTUnwrap(workspace.worktree(atPath: main.path))

    let refreshed = expectation(description: "git answers for the file written")
    var reported: Set<String>??
    workspace.onWorktreeFilesChanged = { id, moved in
      guard id == worktree.id, !worktree.changedFiles.isEmpty else { return }
      reported = moved
      refreshed.fulfill()
    }
    try "hello\nagain\n".write(
      to: main.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    workspace.refreshFiles(worktreeID: worktree.id, moved: ["a.txt"], ownWrite: true)

    wait(for: [refreshed], timeout: 10)
    XCTAssertEqual(worktree.changedFiles.map(\.path), ["a.txt"])
    XCTAssertEqual(reported ?? nil, [], "nothing to re-read: the buffer is what was written")
  }

  /// A `.gitignore` is the one file whose own change is about other files. A read narrowed to
  /// the paths that moved is asked about it and about nothing else, so a file it has just
  /// stopped hiding would be mentioned by nothing — the ± scope, the diffstat and the rail all
  /// read that one answer, and none of them would ever hear of it.
  ///
  /// The batch is handed over rather than left to FSEvents, so that what is under test is the
  /// rule about a narrow question and not whichever shape a real batch happens to take.
  func testAGitignoreChangeIsNotNarrowedToItself() throws {
    let (main, _) = try makeRepositoryWithWorktree()
    try "noise\n".write(
      to: main.appendingPathComponent("noise.log"), atomically: true, encoding: .utf8)
    try "*.log\n".write(
      to: main.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    git(["add", ".gitignore"], in: main)
    git(["commit", "-q", "-m", "Ignore logs"], in: main)

    let workspace = Workspace()
    workspace.openRepository(main)
    let worktree = try XCTUnwrap(workspace.worktree(atPath: main.path))
    settle(workspace, worktreeID: worktree.id)
    XCTAssertFalse(
      worktree.changedFiles.contains { $0.path == "noise.log" }, "hidden to begin with")

    let unmasked = expectation(description: "the file it stopped hiding shows up")
    unmasked.assertForOverFulfill = false
    workspace.onWorktreeFilesChanged = { id, _ in
      guard id == worktree.id,
        worktree.changedFiles.contains(where: { $0.path == "noise.log" })
      else { return }
      unmasked.fulfill()
    }
    try "".write(to: main.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    workspace.refreshFiles(worktreeID: worktree.id, moved: [".gitignore"])
    wait(for: [unmasked], timeout: 10)
  }

  /// The main checkout keeps its git directory inside the watched subtree, so everything git
  /// writes there arrives as an ordinary path of the worktree — and most of it is churn hukan
  /// drops. What must not be dropped with it is the commit itself: the index and the branch both
  /// move, and the change has to leave the window. Real FSEvents, and made by another process,
  /// since a write from this one raises no event at all.
  func testACommitInTheMainCheckoutStillReachesTheWindow() throws {
    let (main, _) = try makeRepositoryWithWorktree()
    let workspace = Workspace()
    workspace.openRepository(main)
    let worktree = try XCTUnwrap(workspace.worktree(atPath: main.path))

    let sawTheEdit = expectation(description: "the edit shows as a change")
    sawTheEdit.assertForOverFulfill = false
    workspace.onWorktreeFilesChanged = { id, _ in
      guard id == worktree.id, !worktree.changedFiles.isEmpty else { return }
      sawTheEdit.fulfill()
    }
    run(["sh", "-c", "echo edited >> a.txt"], in: main)
    wait(for: [sawTheEdit], timeout: 20)

    let sawTheCommit = expectation(description: "the commit clears the change")
    sawTheCommit.assertForOverFulfill = false
    workspace.onWorktreeFilesChanged = { id, _ in
      guard id == worktree.id, worktree.changedFiles.isEmpty else { return }
      sawTheCommit.fulfill()
    }
    run(["sh", "-c", "git add a.txt && git commit -q -m 'Edit a'"], in: main)
    wait(for: [sawTheCommit], timeout: 20)
  }

  /// The second watcher is only for the worktrees that need one — the main checkout keeps its
  /// git directory inside itself, where the first one already covers it.
  func testOnlyALinkedWorktreeIsWatchedTwice() throws {
    let (main, linked) = try makeRepositoryWithWorktree()
    let workspace = Workspace()
    workspace.openRepository(main)

    let mainID = try XCTUnwrap(workspace.worktree(atPath: main.path)).id
    let linkedID = try XCTUnwrap(workspace.worktree(atPath: linked.path)).id
    XCTAssertEqual(workspace.watchers[mainID]?.count, 1)
    XCTAssertEqual(workspace.watchers[linkedID]?.count, 2)
  }

  /// The guard that keeps a bad read from emptying a window: git answering nothing is a failure
  /// to read the repository, not a repository with no worktrees.
  func testAnEmptyEnumerationDropsNothing() throws {
    let (main, linked) = try makeRepositoryWithWorktree()
    let workspace = Workspace()
    workspace.openRepository(main)
    let repositoryID = try XCTUnwrap(workspace.worktree(atPath: main.path)).repositoryID

    XCTAssertFalse(workspace.reconcileWorktrees([], ofRepository: repositoryID))
    XCTAssertEqual(openPaths(workspace), [linked.path, main.path].sorted())
  }

  /// Closing a repository is a decision someone makes; a refresh never arrives at it, however
  /// odd the enumeration looks.
  func testTheMainCheckoutIsNeverDropped() throws {
    let (main, linked) = try makeRepositoryWithWorktree()
    let workspace = Workspace()
    workspace.openRepository(main)
    let repositoryID = try XCTUnwrap(workspace.worktree(atPath: main.path)).repositoryID

    XCTAssertFalse(workspace.reconcileWorktrees([linked], ofRepository: repositoryID))
    XCTAssertEqual(openPaths(workspace), [linked.path, main.path].sorted())
  }
}
