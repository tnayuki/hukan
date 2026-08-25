import XCTest

@testable import Hukan

/// `Git.history` and `Git.commit` against real repositories, the way `GitTests` checks the rest of
/// the libgit2 reads: the CLI builds the fixture, and what the CLI itself answers is the
/// expectation. The question these have to keep answering is the section's whole premise — that a
/// worktree's history is its *task's* history, bounded by the base branch.
final class GitHistoryTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    Git.initialize()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-history-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    root = tmp.resolvingSymlinksInPath()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: helpers

  @discardableResult
  private func git(_ arguments: [String], in dir: URL? = nil) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = dir ?? root
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func commit(_ message: String, file: String = "a.txt", in dir: URL? = nil) throws {
    let base = dir ?? root!
    try (message + "\n").write(
      to: base.appendingPathComponent(file), atomically: true, encoding: .utf8)
    git(["add", file], in: base)
    git(["commit", "-q", "-m", message], in: base)
  }

  private func makeRepository() {
    git(["init", "-q", "-b", "main"])
    git(["config", "user.email", "test@example.com"])
    git(["config", "user.name", "Test"])
    git(["config", "commit.gpgsign", "false"])
  }

  /// A second repository standing in for the remote, so `origin/main` is a real ref.
  private func addOrigin() throws {
    let remote = root.appendingPathComponent("origin.git")
    git(["init", "-q", "--bare", remote.path])
    git(["remote", "add", "origin", remote.path])
    // `-u`, so main tracks origin/main the way a real checkout does — without an upstream there
    // is nothing to measure pushedness against.
    git(["push", "-q", "-u", "origin", "main"])
    git(["remote", "set-head", "origin", "main"])
  }

  // MARK: tests

  /// A page of history reads the log and nothing else. It used to go through the whole
  /// worktree read — the tracked list and the working-tree diff along with it — so scrolling a
  /// large repository paid for a full diff against HEAD per page, which is the most expensive of
  /// the three and the one with nothing to do with the log.
  @MainActor
  func testAPageOfHistoryReadsNothingButTheLog() throws {
    makeRepository()
    for i in 0..<(Git.historyPage + 10) { try commit("Commit \(i)") }

    let repository = Repository(id: root.path)
    let worktree = Worktree(url: root, repository: repository)
    worktree.history = Git.history(at: root)
    XCTAssertTrue(worktree.history.truncated, "more log than one page")
    // Sentinels: the paging read must leave both of these exactly as it found them.
    worktree.changedFiles = [ChangedFile(path: "sentinel.txt", added: 1, removed: 0)]
    worktree.trackedFiles = ["sentinel.txt"]

    let workspace = Workspace()
    workspace.repositories = [repository]
    repository.worktrees = [worktree]

    let paged = expectation(description: "the page lands")
    workspace.loadMoreHistory(worktreeID: worktree.id) { paged.fulfill() }
    wait(for: [paged], timeout: 5)

    XCTAssertEqual(worktree.history.commits.count, Git.historyPage + 10, "the rest of the log")
    XCTAssertFalse(worktree.history.truncated)
    XCTAssertEqual(worktree.changedFiles.map(\.path), ["sentinel.txt"], "not re-measured")
    XCTAssertEqual(worktree.trackedFiles, ["sentinel.txt"], "not re-listed")
  }

  /// A rebase stopped on a conflict is the case the banner exists for: HEAD is detached partway
  /// through the replay, so the branch's own commits are *gone* from the list until they are
  /// re-applied one at a time — on a checkout in sync with its remote the list empties outright.
  /// Without the operation riding along, that happens on a worktree full of conflict markers with
  /// nothing on screen saying why.
  func testARebaseInProgressIsReported() throws {
    makeRepository()
    try commit("Base")
    try addOrigin()
    git(["checkout", "-q", "-b", "task"])
    try commit("Task edit")
    try commit("Task second", file: "b.txt")
    git(["checkout", "-q", "main"])
    try commit("Upstream edit")
    git(["checkout", "-q", "task"])

    XCTAssertNil(Git.history(at: root).operation, "nothing underway yet")

    // Conflicts on the first replayed commit: both branches rewrote a.txt.
    git(["rebase", "main"])

    let history = Git.history(at: root)
    let operation = try XCTUnwrap(history.operation)
    XCTAssertEqual(operation.kind, .rebase)
    XCTAssertEqual(
      operation.branch, "task", "the branch git is putting back, not the detached HEAD")
    XCTAssertEqual(operation.step, 1)
    XCTAssertEqual(operation.total, 2)
    XCTAssertFalse(
      history.commits.contains { $0.summary == "Task edit" },
      "the branch's own work is not in the list while the replay is stopped — it is on the "
        + "detached HEAD's far side, and comes back one commit at a time")

    // And the worktree keeps its name while it runs — the rail and the top bar read this.
    XCTAssertEqual(Git.currentBranch(at: root), "task")

    git(["checkout", "--theirs", "a.txt"])
    git(["add", "a.txt"])
    git(["-c", "core.editor=true", "rebase", "--continue"])
    XCTAssertNil(Git.history(at: root).operation, "and it is gone once the rebase lands")
    XCTAssertEqual(Git.currentBranch(at: root), "task")
  }

  /// A conflicted merge is the other half: HEAD is *not* detached, so the branch name is fine,
  /// but the worktree is still stopped on something a person has to finish.
  func testAMergeInProgressIsReported() throws {
    makeRepository()
    try commit("Base")
    git(["checkout", "-q", "-b", "task"])
    try commit("Task edit")
    git(["checkout", "-q", "main"])
    try commit("Upstream edit")
    git(["merge", "task"])

    let operation = try XCTUnwrap(Git.history(at: root).operation)
    XCTAssertEqual(operation.kind, .merge)
    XCTAssertNil(operation.step, "a merge has no steps to count")
    XCTAssertEqual(Git.currentBranch(at: root), "main")
  }

  /// The premise: the branch's own commits first, then the history it was cut from, with the fork
  /// point marked where the two meet.
  func testABranchListsItsOwnCommitsAndThenWhatItWasCutFrom() throws {
    makeRepository()
    try commit("Base")
    try addOrigin()
    git(["checkout", "-q", "-b", "task"])
    try commit("First step")
    try commit("Second step")

    let history = Git.history(at: root)
    XCTAssertEqual(history.commits.map(\.summary), ["Second step", "First step", "Base"])
    XCTAssertEqual(history.base, "origin/main")
    XCTAssertFalse(history.truncated)
    // The fork index is exactly what git calls the range that used to bound this list.
    XCTAssertEqual(
      history.commits.prefix(history.forkIndex).map(\.oid),
      git(["rev-list", "origin/main..HEAD"]).split(separator: "\n").map(String.init))
  }

  /// The base branch, in sync with its remote, has nothing of its own — and still lists its log.
  /// Bounding the list at the base is what used to empty the section here, which is the one place
  /// a person looks to see what landed.
  func testTheBaseBranchInSyncStillListsItsLog() throws {
    makeRepository()
    try commit("Base")
    try commit("Second")
    try addOrigin()

    let history = Git.history(at: root)
    XCTAssertEqual(history.commits.map(\.summary), ["Second", "Base"])
    XCTAssertEqual(history.forkIndex, 0, "nothing of its own, so no rule to draw")
  }

  /// A base branch holding unpushed commits marks them, and the fork index counts them.
  func testLocalCommitsAheadOfTheRemoteAreMarked() throws {
    makeRepository()
    try commit("Base")
    try addOrigin()
    try commit("Not pushed yet")

    let history = Git.history(at: root)
    XCTAssertEqual(history.commits.map(\.summary), ["Not pushed yet", "Base"])
    XCTAssertEqual(history.commits.first?.isPushed, false)
    XCTAssertEqual(history.forkIndex, 1)
  }

  /// Pushing does not empty the list — a landed task is exactly the one being reviewed. Only the
  /// marker moves.
  func testPushingMarksCommitsWithoutHidingThem() throws {
    makeRepository()
    try commit("Base")
    try addOrigin()
    git(["checkout", "-q", "-b", "task"])
    try commit("Pushed step")
    git(["push", "-q", "-u", "origin", "task"])
    try commit("Local step")

    let history = Git.history(at: root)
    XCTAssertEqual(history.commits.map(\.summary), ["Local step", "Pushed step", "Base"])
    XCTAssertEqual(history.commits.map(\.isPushed), [false, true, true])
    XCTAssertEqual(history.forkIndex, 2)
  }

  /// Scrolling asks for the next page, and a page is a longer walk from the same tip — so what
  /// was read stays read and the rows below it arrive.
  func testAPageCarriesOnWhereTheLastOneStopped() throws {
    makeRepository()
    try commit("Base")
    try addOrigin()
    for i in 1...5 { try commit("Step \(i)") }

    let first = Git.history(at: root, limit: 2)
    XCTAssertEqual(first.commits.map(\.summary), ["Step 5", "Step 4"])
    XCTAssertTrue(first.truncated)

    let second = Git.history(at: root, limit: 4)
    XCTAssertEqual(
      second.commits.prefix(2).map(\.oid), first.commits.map(\.oid),
      "the page that was read is still the top of the list")
    XCTAssertTrue(second.truncated)

    let whole = Git.history(at: root, limit: 50)
    XCTAssertEqual(whole.commits.count, 6, "five steps and the first commit")
    XCTAssertFalse(whole.truncated, "nothing left below, so the section stops asking")
  }

  /// With no upstream there is no answer to give, so the section is told nothing rather than
  /// being told everything is unpushed.
  func testWithoutAnUpstreamPushednessIsUnknown() throws {
    makeRepository()
    try commit("Base")
    try addOrigin()
    git(["checkout", "-q", "-b", "task"])
    try commit("Step")

    XCTAssertNil(Git.history(at: root).commits.first?.isPushed)
  }

  /// A linked worktree is the case the section exists for, and it reads from its own HEAD.
  func testALinkedWorktreeReadsItsOwnHistory() throws {
    makeRepository()
    try commit("Base")
    try addOrigin()
    let linked = root.appendingPathComponent("task")
    git(["worktree", "add", "-q", "-b", "task", linked.path])
    try commit("Task step", in: linked)

    // Each worktree walks from its own HEAD: the linked one has a commit of its own on top of
    // the shared history, the main checkout does not.
    XCTAssertEqual(Git.history(at: linked).commits.map(\.summary), ["Task step", "Base"])
    XCTAssertEqual(Git.history(at: linked).forkIndex, 1)
    XCTAssertEqual(Git.history(at: root).commits.map(\.summary), ["Base"])
    XCTAssertEqual(Git.history(at: root).forkIndex, 0)
  }

  /// The cap says so rather than quietly showing a short list.
  func testTheCapReportsItself() throws {
    makeRepository()
    try commit("Base")
    try addOrigin()
    git(["checkout", "-q", "-b", "task"])
    for i in 1...5 { try commit("Step \(i)") }

    let history = Git.history(at: root, limit: 3)
    XCTAssertEqual(history.commits.count, 3)
    XCTAssertTrue(history.truncated)
    XCTAssertEqual(history.commits.first?.summary, "Step 5")
  }

  /// A repository with no base branch to measure against still reads, running back to the root.
  func testARepositoryWithNoBaseWalksToTheRoot() throws {
    makeRepository()
    git(["checkout", "-q", "-b", "solo"])
    try commit("One")
    try commit("Two")

    let history = Git.history(at: root)
    XCTAssertNil(history.base)
    XCTAssertEqual(history.commits.map(\.summary), ["Two", "One"])
  }

  /// The commit tab's read: message, author, and what it touched. Not the diff — that is
  /// `fileDiff`, one file at a time.
  func testACommitReadsWhole() throws {
    makeRepository()
    try commit("Base")
    try "one\ntwo\n".write(
      to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    git(["add", "a.txt"])
    git(["commit", "-q", "-m", "Rewrite a\n\nWith a body that explains why."])

    let oid = git(["rev-parse", "HEAD"])
    let detail = try XCTUnwrap(Git.commit(at: root, oid: oid))
    XCTAssertEqual(detail.oid, oid)
    XCTAssertEqual(detail.shortOID, String(oid.prefix(7)))
    XCTAssertEqual(detail.summary, "Rewrite a")
    XCTAssertEqual(detail.body, "With a body that explains why.")
    XCTAssertEqual(detail.author, "Test")
    XCTAssertEqual(detail.files.map(\.path), ["a.txt"])
    XCTAssertEqual(detail.files.first?.status, .modified)
    XCTAssertEqual(detail.files.first?.added, 2)
    XCTAssertEqual(detail.files.first?.removed, 1)
    XCTAssertFalse(detail.countsOmitted)
  }

  /// A file's diff arrives as rows that know their line number on each side — which is what lets
  /// the tab number both gutters and drop the `+`/`-` column.
  func testAFileDiffCarriesBothSidesLineNumbers() throws {
    makeRepository()
    try commit("Base")
    try "one\ntwo\n".write(
      to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    git(["add", "a.txt"])
    git(["commit", "-q", "-m", "Rewrite a"])

    let oid = git(["rev-parse", "HEAD"])
    let diff = try XCTUnwrap(
      Git.fileDiff(at: root, oid: oid, path: "a.txt", wantsSource: false))
    XCTAssertNil(diff.note)
    XCTAssertEqual(diff.rows.first, .hunk("@@ -1 +1,2 @@"))
    XCTAssertEqual(
      diff.rows.dropFirst().first, .line(old: 1, new: nil, kind: .removed, text: "Base"))
    XCTAssertTrue(
      diff.rows.contains(.line(old: nil, new: 1, kind: .added, text: "one")),
      "an added line has a new-side number and no old one")
  }

  /// A commit too wide to count through still lists what it touched: the delta list is free, and
  /// only the per-file counts are refused — the wall used to be the whole commit's.
  func testAWideCommitListsItsFilesWithoutCountingThem() throws {
    makeRepository()
    try commit("Base")
    for i in 0..<600 {
      try "x\n".write(
        to: root.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
    }
    git(["add", "."])
    git(["commit", "-q", "-m", "Vendor drop"])

    let detail = try XCTUnwrap(Git.commit(at: root, oid: git(["rev-parse", "HEAD"])))
    XCTAssertEqual(detail.files.count, 600)
    XCTAssertTrue(detail.countsOmitted)
    // Counting lines means diffing every file, which is the cost being refused.
    XCTAssertNil(detail.files.first?.added)
    XCTAssertEqual(detail.summary, "Vendor drop", "what it says still reads")

    // And one of them still opens, because a file is what the reader asked for.
    let diff = try XCTUnwrap(
      Git.fileDiff(at: root, oid: git(["rev-parse", "HEAD"]), path: "f7.txt", wantsSource: false))
    XCTAssertEqual(diff.rows.count, 2, "a hunk header and the one line it added")
  }

  /// A generated file is turned away by its line count — and only that file. The commit around it
  /// reads normally, which is the whole point of the file being the unit.
  func testAGeneratedFileIsTurnedAwayByItself() throws {
    makeRepository()
    try commit("Base")
    try String(repeating: "line\n", count: 30_000).write(
      to: root.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
    git(["add", "."])
    git(["commit", "-q", "-m", "Generated"])

    let oid = git(["rev-parse", "HEAD"])
    let detail = try XCTUnwrap(Git.commit(at: root, oid: oid))
    XCTAssertEqual(detail.files.first?.added, 30_000, "the commit still says how much moved")

    let diff = try XCTUnwrap(
      Git.fileDiff(at: root, oid: oid, path: "big.txt", wantsSource: false))
    guard case .tooLarge(let lines, _) = diff.note else {
      return XCTFail(
        "a 30,000-line file has to be turned away, got \(String(describing: diff.note))")
    }
    XCTAssertGreaterThan(lines, 20_000)
    XCTAssertTrue(diff.rows.isEmpty)
  }

  /// The hole no count-based cap ever saw: a minified file is two changed lines and megabytes of
  /// text, so what turns it away is its size in bytes.
  func testAMinifiedFileIsTurnedAwayByItsBytes() throws {
    makeRepository()
    try commit("Base")
    let url = root.appendingPathComponent("bundle.min.js")
    try String(repeating: "a", count: 2_000_000).write(to: url, atomically: true, encoding: .utf8)
    git(["add", "."])
    git(["commit", "-q", "-m", "Bundle"])

    let oid = git(["rev-parse", "HEAD"])
    let detail = try XCTUnwrap(Git.commit(at: root, oid: oid))
    XCTAssertEqual(detail.files.first?.added, 1, "one line, as far as any line count can tell")

    let diff = try XCTUnwrap(
      Git.fileDiff(at: root, oid: oid, path: "bundle.min.js", wantsSource: false))
    guard case .tooLarge(let lines, let bytes) = diff.note else {
      return XCTFail("two megabytes on one line has to be turned away")
    }
    XCTAssertLessThan(lines, 10, "and not by its lines, which is the point")
    XCTAssertGreaterThan(bytes, 1 << 20)
  }

  /// A rename is one file, not the delete-and-add pair a raw tree diff reports.
  func testARenameIsOneFile() throws {
    makeRepository()
    try "one\ntwo\nthree\nfour\n".write(
      to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    git(["add", "."])
    git(["commit", "-q", "-m", "Base"])
    git(["mv", "a.txt", "b.txt"])
    git(["commit", "-q", "-m", "Move a"])

    let detail = try XCTUnwrap(Git.commit(at: root, oid: git(["rev-parse", "HEAD"])))
    XCTAssertEqual(detail.files.count, 1)
    XCTAssertEqual(detail.files.first?.status, .renamed)
    XCTAssertEqual(detail.files.first?.path, "b.txt")
    XCTAssertEqual(detail.files.first?.oldPath, "a.txt")
  }

  /// An ordinary commit is unaffected — the caps are for the files nobody reads as text.
  func testAnOrdinaryCommitIsNotCapped() throws {
    makeRepository()
    try commit("Base")
    try commit("Second")

    let oid = git(["rev-parse", "HEAD"])
    let detail = try XCTUnwrap(Git.commit(at: root, oid: oid))
    XCTAssertFalse(detail.countsOmitted)
    let diff = try XCTUnwrap(
      Git.fileDiff(at: root, oid: oid, path: "a.txt", wantsSource: false))
    XCTAssertNil(diff.note)
    XCTAssertFalse(diff.rows.isEmpty)
  }

  /// A root commit has no parent to diff against, so it reads as everything it introduced.
  func testARootCommitReadsAsAllAdditions() throws {
    makeRepository()
    try commit("First")

    let oid = git(["rev-parse", "HEAD"])
    let detail = try XCTUnwrap(Git.commit(at: root, oid: oid))
    XCTAssertEqual(detail.files.map(\.path), ["a.txt"])
    XCTAssertEqual(detail.files.first?.status, .added)
    XCTAssertEqual(detail.files.first?.removed, 0)
  }
}
