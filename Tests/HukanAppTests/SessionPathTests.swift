import XCTest

@testable import Hukan

/// The two charter "traps" that are pure string logic: the transcript directory slug (which
/// flattens dots as well as slashes) and pulling a worktree path out of a tool result.
final class SessionPathTests: XCTestCase {
  // MARK: transcript directory slug

  func testDirectoryFlattensSlashesAndDots() {
    // github.com must become github-com — dots are encoded too, not just slashes.
    let dir = ClaudeSessionStore.directory(
      for: URL(fileURLWithPath: "/Users/x/src/github.com/y/main"))
    XCTAssertEqual(dir.lastPathComponent, "-Users-x-src-github-com-y-main")
    XCTAssertTrue(
      dir.deletingLastPathComponent().path.hasSuffix(".claude/projects"),
      "the slug sits under ~/.claude/projects")
  }

  func testDirectoryEncodesEveryDot() {
    let dir = ClaudeSessionStore.directory(for: URL(fileURLWithPath: "/tmp/a.b.c/d"))
    XCTAssertEqual(dir.lastPathComponent, "-tmp-a-b-c-d")
  }

  // MARK: worktree path extraction

  func testWorktreePathBeforeBranchClause() {
    let text = "Created worktree at /Users/x/wt/feature on branch feature-x. Ready."
    XCTAssertEqual(
      AgentSession.worktreePath(fromToolResult: text),
      URL(fileURLWithPath: "/Users/x/wt/feature"))
  }

  func testWorktreePathFallsBackToSentenceEnd() {
    // No " on branch " — the ". " delimiter closes the path instead.
    let text = "Created worktree at /Users/x/wt/plain. Next step follows."
    XCTAssertEqual(
      AgentSession.worktreePath(fromToolResult: text),
      URL(fileURLWithPath: "/Users/x/wt/plain"))
  }

  func testWorktreePathRejectsRelativePath() {
    // The wording matched, but a non-absolute path is not trustworthy — give up.
    XCTAssertNil(
      AgentSession.worktreePath(fromToolResult: "worktree at relative/dir on branch x. "))
  }

  func testWorktreePathNilWhenWordingAbsent() {
    XCTAssertNil(
      AgentSession.worktreePath(fromToolResult: "Entered the existing worktree /Users/x/wt."))
    XCTAssertNil(AgentSession.worktreePath(fromToolResult: ""))
  }

  // MARK: the way back out — ExitWorktree's result, as the engine words it (2.1.246)

  func testExitedCwdAfterAKeep() {
    let text =
      "Exited worktree. Your work is preserved at /Users/x/wt/feature on branch feature-x. "
      + "Session is now back in /Users/x/main."
    XCTAssertEqual(
      AgentSession.exitedCwd(fromToolResult: text), URL(fileURLWithPath: "/Users/x/main"))
  }

  /// A remove's result also says `worktree at <path>` — the Enter parser would read that and
  /// move the session *into* the worktree it just left. The exit parser must read the other end.
  func testExitedCwdAfterARemoveIsNotTheRemovedWorktree() {
    let text =
      "Exited and removed worktree at /Users/x/wt/feature. Discarded 2 commits and 1 "
      + "uncommitted file. Session is now back in /Users/x/main."
    XCTAssertEqual(
      AgentSession.exitedCwd(fromToolResult: text), URL(fileURLWithPath: "/Users/x/main"))
    XCTAssertEqual(
      AgentSession.worktreePath(fromToolResult: text),
      URL(fileURLWithPath: "/Users/x/wt/feature"),
      "which is exactly why the two results are read by two parsers")
  }

  /// The original directory was gone, so the engine went somewhere else and says so — and that
  /// is where the session is, so that is what is read.
  func testExitedCwdWhenTheOriginalDirectoryWasGone() {
    let text =
      "Exited worktree. Your work is preserved at /Users/x/wt/feature. The original directory "
      + "/Users/x/gone no longer exists, so the session is now in /Users/x/wt/feature. "
      + "Consider restarting Claude from an existing directory."
    XCTAssertEqual(
      AgentSession.exitedCwd(fromToolResult: text), URL(fileURLWithPath: "/Users/x/wt/feature"))
  }

  func testExitedCwdRejectsWhatIsNotAPath() {
    XCTAssertNil(AgentSession.exitedCwd(fromToolResult: "Session is now back in main."))
    XCTAssertNil(
      AgentSession.exitedCwd(
        fromToolResult: "No-op: there is no active EnterWorktree session to exit."))
    XCTAssertNil(AgentSession.exitedCwd(fromToolResult: ""))
  }
}
