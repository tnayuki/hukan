import XCTest

@testable import Hukan

/// The held-elsewhere watch: a session another live process owns is marked held, and the hold
/// lifts on its own the moment that process exits — the release edge that drives the rail back
/// from greyed to startable.
final class HeldElsewhereTests: XCTestCase {
  /// Marking a session held by a live pid, then killing that process, clears the hold via the
  /// direct `.exit` watch — no polling, no directory event needed. This is the crux of the
  /// design: the release fires on the holder's death (here a SIGTERM), whether clean or a crash.
  func testHoldLiftsWhenHolderExits() throws {
    let session = AgentSession(worktreeID: UUID())

    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
    holder.arguments = ["30"]
    try holder.run()
    let pid = holder.processIdentifier

    // markHeldElsewhere notifies synchronously, so the closure is armed before the call.
    session.onHeldChange = {}
    session.markHeldElsewhere(by: pid)
    XCTAssertEqual(session.heldByPID, pid, "marking held records the owning pid")

    let lifted = expectation(description: "hold lifted on holder exit")
    session.onHeldChange = {
      if session.heldByPID == nil { lifted.fulfill() }
    }
    holder.terminate()
    wait(for: [lifted], timeout: 5)
    XCTAssertNil(session.heldByPID, "the hold lifts once the holder is gone")
  }

  /// Marking held by the same pid twice does not re-notify — a re-scan finding the same holder is
  /// a no-op, so the rail is not reloaded on every registry event.
  func testReMarkingSamePidIsIdempotent() throws {
    let session = AgentSession(worktreeID: UUID())
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
    holder.arguments = ["30"]
    try holder.run()
    defer { holder.terminate() }
    let pid = holder.processIdentifier

    var notifications = 0
    session.onHeldChange = { notifications += 1 }
    session.markHeldElsewhere(by: pid)
    session.markHeldElsewhere(by: pid)
    XCTAssertEqual(notifications, 1, "the same holder marks once")

    session.clearHeldElsewhere()
    XCTAssertNil(session.heldByPID)
    XCTAssertEqual(notifications, 2, "clearing an active hold notifies")
    session.clearHeldElsewhere()
    XCTAssertEqual(notifications, 2, "clearing an already-clear hold does not")
  }
}
