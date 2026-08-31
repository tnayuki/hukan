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

  /// The worktree's stream is asked not to carry the repository at all, so a path under it is
  /// not an answer this has to give — only a linked worktree's `.git` pointer file can still
  /// arrive, being a file where an exclusion needs a directory. Either way it is dropped, and
  /// what speaks for the repository is the repository's own stream.
  func testAGitDirectoryPathIsNotOneOfTheWorktreesFiles() {
    for path in ["/tmp/worktree/.git/HEAD", "/tmp/worktree/.git/index", "/tmp/worktree/.git"] {
      XCTAssertEqual(Workspace.relativePaths([path], under: root), [], path)
    }
    XCTAssertEqual(
      Workspace.relativePaths(
        ["/tmp/worktree/Sources/A.swift", "/tmp/worktree/.git/index"], under: root),
      ["Sources/A.swift"], "and the file beside it is still a file")
  }

  /// A path that is not under the worktree at all cannot be placed — nothing can be said about
  /// what it moved, so the whole batch is wholesale.
  func testAPathOutsideTheWorktreeIsWholesale() {
    XCTAssertNil(Workspace.relativePaths(["/somewhere/else/HEAD"], under: root))
    XCTAssertNil(
      Workspace.relativePaths(
        ["/tmp/worktree/Sources/A.swift", "/somewhere/else/HEAD"], under: root))
    // An empty batch is nothing to do, not "everything moved": nil is reserved for the paths
    // that could not be placed, since that is the only answer a later batch cannot narrow.
    XCTAssertEqual(Workspace.relativePaths([], under: root), [])
  }

  /// The repository's own stream. A read of the whole worktree is what an answer of yes costs,
  /// so git's churn must not buy one: the object database, the reflog, the lock files, the
  /// message an editor is handed, another worktree's state — which has a stream of its own. The
  /// heaviest of those never leave the stream (`syncWatchers` excludes the directories), and
  /// this answers for the rest, and for a directory a repository happens not to have.
  func testTheRepositorysBatchIsAskedPathByPath() {
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
