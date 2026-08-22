import XCTest

@testable import Hukan

/// The session lifecycle verbs' model-side behavior, away from the window that wires them.
final class SessionLifecycleTests: XCTestCase {
  /// Restarting a session that has no live engine has nothing to cycle, so it falls through to a
  /// plain start (the deferred-start trampoline) rather than doing nothing.
  func testRestartWithoutEngineStartsIt() {
    let session = AgentSession(worktreeID: UUID())
    var started = false
    session.onNeedsStart = { started = true }
    session.restart()
    XCTAssertTrue(started, "restart with no engine brings it up via onNeedsStart")
  }
}
