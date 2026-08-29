import XCTest

@testable import Hukan

/// Which files a disk change reaches. FSEvents names what moved, and the point of carrying that
/// name all the way to the desk is that re-reading a file is a whole-file parse and a highlight —
/// and it drops the selection with it — so one agent write must not cost every open tab one.
final class ChangedPathsTests: XCTestCase {
  /// Under `/tmp`, which is a symlink to `/private/tmp` — the same shape as the temporary
  /// directories the worktree tests run in, and the one that made the prefix test fail.
  private let root = "/tmp/worktree"

  func testPathsComeBackRelativeToTheWorktree() {
    XCTAssertEqual(
      Workspace.relativePaths(
        ["/tmp/worktree/Sources/A.swift", "/tmp/worktree/README.md"], under: root),
      ["Sources/A.swift", "README.md"])
  }

  /// Anything under git's own directory is not a file anyone has open, but HEAD or the index
  /// moving changes what every open file is measured against — so it cannot be narrowed.
  func testAGitDirectoryPathIsWholesale() {
    XCTAssertNil(Workspace.relativePaths(["/tmp/worktree/.git/HEAD"], under: root))
    XCTAssertNil(Workspace.relativePaths(["/tmp/worktree/.git"], under: root))
    XCTAssertNil(
      Workspace.relativePaths(
        ["/tmp/worktree/Sources/A.swift", "/tmp/worktree/.git/index"],
        under: root),
      "one unplaceable path makes the whole batch unplaceable")
  }

  /// A path that is not under the worktree at all cannot be placed either — the linked
  /// worktree's git directory arrives that way.
  func testAPathOutsideTheWorktreeIsWholesale() {
    XCTAssertNil(Workspace.relativePaths(["/somewhere/else/HEAD"], under: root))
    XCTAssertNil(Workspace.relativePaths([], under: root))
  }

  /// FSEvents answers in the paths the filesystem calls canonical; the worktree's own URL may
  /// be spelled the other way. `/tmp` is the case in hand — it is a link to `/private/tmp`, and
  /// so is every temporary directory a test or an agent works in.
  func testACanonicalisedRootStillPlacesItsFiles() {
    XCTAssertEqual(
      Workspace.relativePaths(["/private/tmp/A.swift"], under: "/tmp"), ["A.swift"])
    // The other way round is not a case: what FSEvents hands over is already canonical, and a
    // path it never produces is not worth a branch that could only be wrong.
  }

  /// A directory named `.gitignore` is not the git directory, and its edit is a file's edit.
  func testAFileWhoseNameBeginsWithGitIsStillAFile() {
    XCTAssertEqual(
      Workspace.relativePaths(["/tmp/worktree/.gitignore"], under: root), [".gitignore"])
  }

  /// Batches fold while a query is in flight, and "everything" cannot be narrowed by whatever
  /// arrives after it.
  func testWholesaleWinsWhenBatchesFold() {
    XCTAssertEqual(Workspace.union(["a"], ["b"]), ["a", "b"])
    XCTAssertNil(Workspace.union(["a"], nil))
    XCTAssertNil(Workspace.union(nil, ["b"]))
    XCTAssertNil(Workspace.union(nil, nil))
  }

  /// The one thing an FSEvents batch can carry that git's own answer cannot report: a directory
  /// git has no path for. The panel shows one, so the refresh has to notice it — and has to keep
  /// noticing nothing when a build churns, which is the case the equality test exists for.
  func testADirectoryGitCannotSeeIsNoticedAndAnIgnoredOneIsNot() throws {
    let worktree = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-unseen-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: worktree) }
    for path in ["src/a.swift", ".gitignore"] {
      let file = worktree.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try (path == ".gitignore" ? "build/\n" : "let a = 1\n").write(
        to: file, atomically: true, encoding: .utf8)
    }
    for name in ["fresh", "build", "build/noise"] {
      try FileManager.default.createDirectory(
        at: worktree.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try "x\n".write(
      to: worktree.appendingPathComponent("build/noise/x.o"), atomically: true, encoding: .utf8)
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    git.arguments = ["-C", worktree.path, "init", "-q"]
    try git.run()
    git.waitUntilExit()
    let tracked = ["src/a.swift", ".gitignore"]

    XCTAssertTrue(
      Workspace.carriesUnseenDirectory(["fresh"], at: worktree, tracked: tracked, changed: []),
      "a directory git has no path for")
    XCTAssertFalse(
      Workspace.carriesUnseenDirectory(
        ["build", "build/noise", "build/noise/x.o"], at: worktree,
        tracked: tracked, changed: []),
      "the churning build stays free")
    XCTAssertFalse(
      Workspace.carriesUnseenDirectory(
        ["src/a.swift", "src/b.swift"], at: worktree,
        tracked: tracked, changed: []),
      "a file is not a directory, which is the stat every batch of writes fails at")
    XCTAssertFalse(
      Workspace.carriesUnseenDirectory(["src"], at: worktree, tracked: tracked, changed: []),
      "git already has paths under it")
  }

}
