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

  /// The id hukan mints goes to the engine in the CLI's own spelling, so the transcript it
  /// creates is named like every other one in the store rather than in `uuidString`'s upper case.
  func testTheSessionIDIsPassedInLowerCase() {
    let id = UUID(uuidString: "FFF40972-FBDE-40F0-B6F8-1EA442254E7C")!
    XCTAssertEqual(
      flag("--session-id", in: ClaudeSession.launchArguments(id: id)),
      "fff40972-fbde-40f0-b6f8-1ea442254e7c")
    XCTAssertEqual(
      flag("--resume", in: ClaudeSession.launchArguments(id: id, resume: true)),
      "fff40972-fbde-40f0-b6f8-1ea442254e7c")
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
