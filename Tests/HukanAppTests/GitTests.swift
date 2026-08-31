import XCTest

@testable import Hukan

/// The libgit2-backed `Git` reads must answer exactly what the `git` CLI used to, since the rest
/// of the app was written against that output. Each test builds a real repository with the CLI,
/// then checks `Git` against the CLI's own answer — parity, not a hand-written expectation.
final class GitTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    Git.initialize()
    // Resolve symlinks up front: temp dirs live under /var → /private/var, and libgit2 reports
    // resolved paths, so the base has to be resolved for path comparisons to line up.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-git-\(UUID().uuidString)")
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

  private func write(_ contents: String, to relativePath: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }

  private func makeRepository() {
    git(["init", "-q", "-b", "main"])
    git(["config", "user.email", "test@example.com"])
    git(["config", "user.name", "Test"])
    git(["config", "commit.gpgsign", "false"])
  }

  // MARK: tests

  func testRepositoryIdentityAndBranch() throws {
    makeRepository()
    try write("a.txt", to: "a.txt")
    git(["add", "."])
    git(["commit", "-q", "-m", "first"])

    XCTAssertEqual(Git.repository(at: root), root.path)
    XCTAssertEqual(Git.currentBranch(at: root), "main")
  }

  func testTrackedFilesMatchesLsFiles() throws {
    makeRepository()
    try write("a\n", to: "a.txt")
    try write("b\n", to: "src/b.txt")
    try write("c\n", to: "src/deep/c.txt")
    git(["add", "."])
    git(["commit", "-q", "-m", "first"])

    let expected = git(["ls-files"]).split(separator: "\n").map(String.init).sorted()
    XCTAssertEqual(Git.trackedFiles(at: root).sorted(), expected)
    XCTAssertFalse(expected.isEmpty)
  }

  /// `git diff --numstat HEAD` for everything git already knows about — staged and unstaged
  /// alike — **plus** the untracked files, counted as added. numstat leaves those out and
  /// `git status` does not, and hukan reads the second one: a file nobody has run `git add` on is
  /// the whole of what a brand-new file is, and while it was excluded, the file an agent had just
  /// written was invisible in every reading hukan takes of a change.
  func testChangedFilesIsNumstatPlusTheUntrackedFiles() throws {
    makeRepository()
    try write("one\ntwo\n", to: "a.txt")
    try write("keep\n", to: "b.txt")
    git(["add", "."])
    git(["commit", "-q", "-m", "first"])

    // One unstaged edit (add a line), one staged edit — `git diff HEAD` sees both.
    try write("one\ntwo\nthree\n", to: "a.txt")
    try write("keep\nmore\n", to: "b.txt")
    git(["add", "b.txt"])
    // Untracked, and untracked inside a directory that is itself untracked — the second is what
    // needs the walk, or the directory reports itself instead of the file in it.
    try write("scratch\n", to: "c.txt")
    try write("deep\n", to: "fresh/d.txt")
    // Ignored stays out: that half is libgit2's default and nobody wants it moved.
    try write("noise.log\n", to: ".gitignore")
    try write("noise\n", to: "noise.log")
    git(["add", ".gitignore"])

    var expected: [ChangedFile] = []
    for line in git(["diff", "--numstat", "HEAD"]).split(separator: "\n") {
      let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count == 3 else { continue }
      expected.append(
        ChangedFile(path: String(parts[2]), added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0))
    }
    expected.append(ChangedFile(path: "c.txt", added: 1, removed: 0))
    expected.append(ChangedFile(path: "fresh/d.txt", added: 1, removed: 0))

    let byPath: (ChangedFile, ChangedFile) -> Bool = { $0.path < $1.path }
    let changed = Git.changedFiles(at: root, since: "HEAD")
    XCTAssertEqual(changed.sorted(by: byPath), expected.sorted(by: byPath))
    XCTAssertTrue(expected.contains(ChangedFile(path: "a.txt", added: 1, removed: 0)))
    XCTAssertFalse(changed.contains { $0.path == "noise.log" }, "ignored files stay out")
  }

  /// The narrowed read an FSEvents batch takes: `git diff HEAD -- <paths>`. It has to answer for
  /// those paths exactly as the whole read does — including for an untracked file inside a
  /// directory that is itself untracked, which needs the walk to go in, and for a name carrying
  /// glob characters, which a pathspec would otherwise read as a pattern and never match.
  func testChangedFilesNarrowedToPathsAnswersForThoseOnly() throws {
    makeRepository()
    try write("one\ntwo\n", to: "a.txt")
    try write("keep\n", to: "b.txt")
    try write("gone\n", to: "src/gone.txt")
    git(["add", "."])
    git(["commit", "-q", "-m", "first"])

    try write("one\ntwo\nthree\n", to: "a.txt")
    try write("scratch\n", to: "c.txt")
    try write("deep\n", to: "fresh/d.txt")
    try write("glob\n", to: "g[a].txt")
    try FileManager.default.removeItem(at: root.appendingPathComponent("src/gone.txt"))

    let whole = Git.changedFiles(at: root, since: "HEAD")
    for path in ["a.txt", "c.txt", "fresh/d.txt", "g[a].txt", "src/gone.txt"] {
      XCTAssertEqual(
        Git.changedFiles(at: root, since: "HEAD", paths: [path]), whole.filter { $0.path == path },
        path)
    }
    // A path that has not moved is answered for too — with nothing, which is what takes a file
    // edited back to what HEAD holds out of the set.
    XCTAssertEqual(Git.changedFiles(at: root, since: "HEAD", paths: ["b.txt"]), [])
    // And the batch is asked as one question.
    XCTAssertEqual(
      Git.changedFiles(at: root, since: "HEAD", paths: ["a.txt", "fresh/d.txt"]),
      whole.filter { $0.path == "a.txt" || $0.path == "fresh/d.txt" })
  }

  /// The wholesale read's question, collapsed: when HEAD or the index moved and nothing in the
  /// working tree was written, the answer can only have moved where HEAD went, where the index
  /// stands off it, or where it already differed. The candidates plus the changed set, asked by
  /// pathspec, must reproduce the whole read exactly — the collapse has to be invisible.
  func testWholesaleCandidatesReproduceTheWholeRead() throws {
    makeRepository()
    for path in ["a.txt", "b.txt", "c.txt"] { try write("one\n", to: path) }
    git(["add", "."])
    git(["commit", "-q", "-m", "first"])
    let oldHead = git(["rev-parse", "HEAD"])

    // The state the last read left behind: one modified file, one untracked.
    try write("one\ntwo\n", to: "b.txt")
    try write("new\n", to: "e.txt")
    let before = Git.changedFiles(at: root, since: "HEAD")
    XCTAssertEqual(before.map(\.path), ["b.txt", "e.txt"])

    // Then git moves under it and the working tree stays put: b's edit is committed away
    // beside a change to a, and c gains a staged edit.
    try write("one\ntwo\n", to: "a.txt")
    git(["add", "a.txt", "b.txt"])
    git(["commit", "-q", "-m", "second"])
    try write("one\nstaged\n", to: "c.txt")
    git(["add", "c.txt"])

    let candidates = try XCTUnwrap(Git.wholesaleCandidates(at: root, sinceHead: oldHead))
    XCTAssertTrue(candidates.contains("a.txt"), "HEAD moved it")
    XCTAssertTrue(candidates.contains("b.txt"), "committed away, so its entry must go")
    XCTAssertTrue(candidates.contains("c.txt"), "staged")

    let asked = candidates.union(before.map(\.path))
    let narrowed = Git.merged(
      Git.changedFiles(at: root, since: "HEAD", paths: Array(asked)), into: before, for: asked)
    XCTAssertEqual(narrowed, Git.changedFiles(at: root, since: "HEAD"))

    // Nothing to measure from is not an empty answer but no answer: the whole read is honest.
    XCTAssertNil(Git.wholesaleCandidates(at: root, sinceHead: nil))
    XCTAssertNil(Git.wholesaleCandidates(at: root, sinceHead: "not-a-commit"))
  }

  /// Folding a narrowed read back in has to leave the set indistinguishable from a whole read's
  /// — the two are compared to decide whether anything needs redrawing, so a set that merely
  /// re-sorted itself would redraw the window on every write.
  func testMergedIsWhatTheWholeReadWouldHaveSaid() throws {
    makeRepository()
    // `a.txt`, `a/b.txt` and `a-b.txt` are the ordering case: libgit2 hands its deltas over in
    // byte order, where `-` precedes `.` precedes `/`.
    for path in ["a.txt", "a/b.txt", "a-b.txt", "z.txt"] { try write("one\n", to: path) }
    git(["add", "."])
    git(["commit", "-q", "-m", "first"])
    for path in ["a.txt", "a/b.txt", "a-b.txt", "z.txt"] { try write("one\ntwo\n", to: path) }

    let whole = Git.changedFiles(at: root, since: "HEAD")
    XCTAssertEqual(whole.map(\.path), ["a-b.txt", "a.txt", "a/b.txt", "z.txt"])

    // What the worktree held before `a/b.txt` was written: the file not in the set at all, and
    // `z.txt` carrying a stale count the narrowed read was never asked about.
    let before = whole.filter { $0.path != "a/b.txt" }
      .map { $0.path == "z.txt" ? ChangedFile(path: "z.txt", added: 99, removed: 99) : $0 }
    let answered = Git.changedFiles(at: root, since: "HEAD", paths: ["a/b.txt"])
    XCTAssertEqual(
      Git.merged(answered, into: before, for: ["a/b.txt"]).map(\.path), whole.map(\.path))
    XCTAssertEqual(Git.merged(answered, into: whole, for: ["a/b.txt"]), whole)

    // A file edited back to what HEAD holds: asked about, answered for with nothing, and gone.
    try write("one\n", to: "z.txt")
    let none = Git.changedFiles(at: root, since: "HEAD", paths: ["z.txt"])
    XCTAssertEqual(
      Git.merged(none, into: whole, for: ["z.txt"]).map(\.path), ["a-b.txt", "a.txt", "a/b.txt"])
  }

  /// The files panel asks this about the directories git produced no path for, so that a
  /// checkout's build directory — which holds nothing git can see, and would otherwise be the one
  /// row nobody wants — stays out of the tree.
  func testIgnoredAnswersForDirectories() throws {
    makeRepository()
    try write("build/\n", to: ".gitignore")
    try write("a\n", to: "src/a.txt")
    git(["add", "."])
    git(["commit", "-q", "-m", "first"])
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("build"), withIntermediateDirectories: true)

    XCTAssertEqual(Git.ignored(at: root, directories: ["build", "src"]), ["build"])
    XCTAssertEqual(Git.ignored(at: root, directories: []), [])
  }

  func testDiffCarriesTheHunk() throws {
    makeRepository()
    try write("one\ntwo\n", to: "a.txt")
    try write("keep\n", to: "b.txt")
    git(["add", "."])
    git(["commit", "-q", "-m", "first"])
    try write("one\ntwo\nthree\n", to: "a.txt")

    let diff = try XCTUnwrap(Git.diff(at: root, path: "a.txt", since: "HEAD"))
    XCTAssertTrue(diff.contains("+three"), "diff should carry the added line")
    // An unchanged file has no patch.
    XCTAssertNil(Git.diff(at: root, path: "b.txt", since: "HEAD"))
  }

  func testWorktreesIncludeMainAndLinked() throws {
    makeRepository()
    try write("a.txt", to: "a.txt")
    git(["add", "."])
    git(["commit", "-q", "-m", "first"])

    let linked = root.deletingLastPathComponent()
      .appendingPathComponent("linked-\(UUID().uuidString)").resolvingSymlinksInPath()
    git(["worktree", "add", "-q", linked.path])
    defer { git(["worktree", "remove", "--force", linked.path]) }

    let paths = Set(Git.worktrees(at: root).map { $0.resolvingSymlinksInPath().path })
    XCTAssertTrue(paths.contains(root.path), "main worktree must be present")
    XCTAssertTrue(paths.contains(linked.path), "linked worktree must be present")
    // Enumerated from the linked worktree, git still leads with main — so must Git.
    XCTAssertEqual(Git.worktrees(at: linked).first?.resolvingSymlinksInPath().path, root.path)
  }

  /// No `git init`: a Worktree may be a plain directory. git has no tracked list to give for it,
  /// and none is invented — the files panel's tree, filter and search read the disk through
  /// `WorktreeIndex`, which lists a plain directory the same way it lists a checkout.
  func testANonGitDirectoryHasNoTrackedListAndIsListedByTheIndex() throws {
    try write("a.txt", to: "a.txt")
    try write("b.txt", to: "sub/b.txt")
    XCTAssertEqual(Git.trackedFiles(at: root), [])
    XCTAssertEqual(Git.ignored(at: root, directories: ["sub"]), [], "nothing to ignore by")

    let index = WorktreeIndex(root: root) { [root] in Git.ignored(at: root!, directories: $0) }
    let built = expectation(description: "walked")
    index.build { built.fulfill() }
    wait(for: [built], timeout: 5)
    XCTAssertEqual(index.filePaths, ["a.txt", "sub/b.txt"])
  }
}
