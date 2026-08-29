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
