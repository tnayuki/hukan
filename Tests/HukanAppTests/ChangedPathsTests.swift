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

  /// The batch on the *other* watcher — a linked worktree's git directory, which lives outside
  /// the worktree. A read of the whole worktree is what an answer of yes costs, so git's own
  /// churn must not buy one: the object database, the reflog, the lock file every operation
  /// takes and drops, the message an editor is handed, and another worktree's state.
  func testTheGitDirectorysOwnBatchIsAskedPathByPath() {
    let directory = "/tmp/repo/.git/worktrees/task"
    XCTAssertTrue(Workspace.gitDirectoryMoved(["\(directory)/index"], under: directory))
    XCTAssertTrue(Workspace.gitDirectoryMoved(["\(directory)/HEAD"], under: directory))
    XCTAssertTrue(
      Workspace.gitDirectoryMoved(["\(directory)/refs/heads/main"], under: directory))
    XCTAssertTrue(
      Workspace.gitDirectoryMoved(
        ["\(directory)/logs/HEAD", "\(directory)/HEAD"], under: directory),
      "one that matters carries the batch")

    XCTAssertFalse(
      Workspace.gitDirectoryMoved(
        [
          "\(directory)/logs/HEAD", "\(directory)/index.lock",
          "\(directory)/COMMIT_EDITMSG", "\(directory)/ORIG_HEAD",
          "\(directory)/objects/ab/cdef", "\(directory)/worktrees/other/index",
        ], under: directory))
    XCTAssertTrue(
      Workspace.gitDirectoryMoved(["/somewhere/else"], under: directory),
      "a batch nobody can place is not one to dismiss")
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

}
