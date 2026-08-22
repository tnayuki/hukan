import XCTest

@testable import Hukan

/// The engine's argv, read without launching it. What is pinned here is the one line hukan adds
/// to the system prompt: the window follows a session between worktrees by the results of
/// `EnterWorktree` and `ExitWorktree`, and nothing but this line steers the model toward them.
final class LaunchArgumentsTests: XCTestCase {
  private func flag(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
      return nil
    }
    return arguments[index + 1]
  }

  func testTheWorktreeInstructionIsAppendedToTheSystemPrompt() {
    let arguments = ClaudeSession.launchArguments(id: UUID())
    XCTAssertEqual(
      flag("--append-system-prompt", in: arguments), ClaudeSession.worktreeInstruction)
    XCTAssertTrue(ClaudeSession.worktreeInstruction.contains("EnterWorktree"))
    XCTAssertTrue(ClaudeSession.worktreeInstruction.contains("ExitWorktree"))
  }

  /// The engine rebuilds its system prompt on every launch and remembers nothing of this one,
  /// so a resume carries it too — unlike `--model`, which a resume leaves to the engine.
  func testTheInstructionRidesAResumeAsWell() {
    let arguments = ClaudeSession.launchArguments(id: UUID(), model: "opus", resume: true)
    XCTAssertEqual(
      flag("--append-system-prompt", in: arguments), ClaudeSession.worktreeInstruction)
    XCTAssertNil(flag("--model", in: arguments))
  }

  /// Nothing about the app itself: identity is not an instruction, and the only behaviour it
  /// could add is the agent driving the app.
  func testTheInstructionDoesNotNameTheApp() {
    XCTAssertFalse(ClaudeSession.worktreeInstruction.lowercased().contains("hukan"))
  }
}
