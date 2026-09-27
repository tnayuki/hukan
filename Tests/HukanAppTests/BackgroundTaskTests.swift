import XCTest

@testable import Hukan

/// A subagent sent to the background outlives the turn that launched it: the turn's `result`
/// arrives while it is still working, and the engine opens a turn of its own when it reports
/// back. Read as the end of the work, that `result` put the green check on a session whose agent
/// was still busy.
final class BackgroundTaskTests: XCTestCase {
  private func system(_ subtype: String, _ payload: [String: Any] = [:]) -> ClaudeEvent {
    ClaudeEvent(type: "system", subtype: subtype, payload: payload)
  }

  private func started(_ id: String, type: String) -> ClaudeEvent {
    system("task_started", ["task_id": id, "task_type": type, "is_backgrounded": true])
  }

  private func notified(_ id: String) -> ClaudeEvent {
    system("task_notification", ["task_id": id, "status": "completed"])
  }

  private let result = ClaudeEvent(type: "result", subtype: "success", payload: [:])

  func testATurnThatLeavesASubagentRunningIsNotDone() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(system("init"))
    session.apply(started("a1", type: "local_agent"))
    session.apply(result)
    XCTAssertEqual(session.state, .running, "the subagent is still working")
    XCTAssertTrue(session.isWorking)
    XCTAssertFalse(session.isTurnActive, "a send now goes straight to the engine")
  }

  /// The engine hands the subagent's result to the model in a turn it opens itself, and that
  /// turn's `result` is what finally ends the work.
  func testTheTurnTheEngineOpensOnReportIsWhatEndsIt() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(system("init"))
    session.apply(started("a1", type: "local_agent"))
    session.apply(result)
    session.apply(notified("a1"))
    XCTAssertEqual(session.state, .running, "no check flashed between report and turn")
    session.apply(system("init"))
    XCTAssertTrue(session.isTurnActive, "the engine's own turn is a turn in flight")
    session.apply(result)
    XCTAssertEqual(session.state, .idle)
    XCTAssertFalse(session.isWorking)
  }

  /// A backgrounded shell is often a server meant to run until someone stops it.
  func testABackgroundShellDoesNotHoldTheSessionBusy() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(system("init"))
    session.apply(started("b1", type: "local_bash"))
    session.apply(result)
    XCTAssertEqual(session.state, .idle)
    XCTAssertFalse(session.isWorking)
  }

  /// A foreground subagent reports before its turn ends, so nothing is left over.
  func testAForegroundSubagentLeavesNothingBehind() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(system("init"))
    session.apply(started("a1", type: "local_agent"))
    session.apply(notified("a1"))
    session.apply(result)
    XCTAssertEqual(session.state, .idle)
  }
}
