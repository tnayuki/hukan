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

  /// A send reports itself as your instruction, and does so before the engine is brought up — the
  /// archive flag hangs off it (`Workspace.noteInstruction`), so a row must leave the fold whether
  /// or not the process that answers the line ever starts.
  func testASendReportsTheInstructionEvenWhenNoEngineStarts() {
    let session = AgentSession(worktreeID: UUID())
    var instructions = 0
    session.onInstructed = { instructions += 1 }
    // The deferred start is a trampoline the window owns; with nothing behind it the send bails
    // after the stamp, which is exactly the moment being pinned here.
    session.onNeedsStart = {}
    session.send("hello")
    XCTAssertEqual(instructions, 1)
  }

  /// `/login` is handed to a terminal rather than to the engine, and a signed-out session drops
  /// the line outright. Neither is an instruction, so neither may unarchive anything — the same
  /// rule that keeps them from reordering the rail.
  func testLoginAndASignedOutDropAreNotInstructions() {
    let session = AgentSession(worktreeID: UUID())
    var instructions = 0
    session.onInstructed = { instructions += 1 }
    session.onNeedsStart = {}
    var login: String?
    session.onLoginRequested = { login = $0 }
    session.send("/login")
    XCTAssertEqual(login, "login")

    session.state = .signedOut
    session.send("hello")
    XCTAssertEqual(instructions, 0)
  }
}
