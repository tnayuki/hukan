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
}
