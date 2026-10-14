import AppKit
import XCTest

@testable import Hukan

final class SelectionHistoryTests: XCTestCase {
  private let a = SelectionHistory.Place.session(UUID())
  private let b = SelectionHistory.Place.session(UUID())
  private let c = SelectionHistory.Place.worktree(UUID())

  /// Reloads arrive far more often than the selection moves, so landing where it already is
  /// must not be a step — or Back would spend a press per redraw.
  func testTheSamePlaceTwiceIsOneStep() {
    var history = SelectionHistory()
    history.visit(a)
    history.visit(a)
    history.visit(b)
    XCTAssertEqual(history.places, [a, b])
  }

  /// A browser's rule: going back and then somewhere new drops what was ahead.
  func testAStepAfterGoingBackDropsWhatWasAhead() throws {
    var history = SelectionHistory()
    for place in [a, b, c] { history.visit(place) }
    history.move(to: try XCTUnwrap(history.target(-1) { _ in true }))
    XCTAssertEqual(history.current, b)
    XCTAssertEqual(history.target(1) { _ in true }, 2)
    history.visit(a)
    XCTAssertEqual(history.places, [a, b, a])
    XCTAssertNil(history.target(1) { _ in true })
  }

  /// A deleted session is stepped over rather than removed, so what stood around it keeps its
  /// order — and a place equal to where the reader already is is no step either.
  func testWhatIsGoneIsSteppedOver() {
    var history = SelectionHistory()
    for place in [a, b, a, c] { history.visit(place) }
    XCTAssertEqual(history.target(-1) { $0 != a }, 1)
    history.move(to: 2)
    XCTAssertEqual(history.target(-1) { $0 != b }, nil, "only the place already showing is left")
  }

  func testTheOldestPlaceGoesPastTheCapacity() {
    var history = SelectionHistory()
    for _ in 0...SelectionHistory.capacity { history.visit(.worktree(UUID())) }
    XCTAssertEqual(history.places.count, SelectionHistory.capacity)
    XCTAssertEqual(history.index, SelectionHistory.capacity - 1)
  }

  /// The window's half: every route that moves the selection ends in `reload`, so selecting
  /// through the rail's own callback and through a direct write must both be steps, and Back must
  /// put the worktree back along with the session — the desk follows the session it names.
  @MainActor
  func testBackAndForwardWalkTheRailsSelection() throws {
    let workspace = RailPreviewTests.sampleWorkspace()
    let controller = WorkspaceWindowController(workspace: workspace)
    _ = try XCTUnwrap(controller.window)
    let first = workspace.sessions[0]
    let second = workspace.sessions[3]
    let third = workspace.sessions[5]
    for session in [first, second, third] {
      workspace.selectedWorktreeID = session.worktreeID
      workspace.selectedSessionID = session.id
      controller.reload()
    }
    let back = NSMenuItem(
      title: "", action: #selector(WorkspaceWindowController.goBackInSessions(_:)),
      keyEquivalent: "")
    let forward = NSMenuItem(
      title: "", action: #selector(WorkspaceWindowController.goForwardInSessions(_:)),
      keyEquivalent: "")
    XCTAssertFalse(controller.validateMenuItem(forward))

    controller.goBackInSessions(nil)
    XCTAssertEqual(workspace.selectedSessionID, second.id)
    XCTAssertEqual(workspace.selectedWorktreeID, second.worktreeID)
    controller.goBackInSessions(nil)
    XCTAssertEqual(workspace.selectedSessionID, first.id)
    XCTAssertEqual(workspace.selectedWorktreeID, first.worktreeID)
    XCTAssertFalse(controller.validateMenuItem(back))

    // Gone from the window without the delete's unlink, which would reach for a transcript.
    workspace.sessions.removeAll { $0 === second }
    controller.reload()
    controller.goForwardInSessions(nil)
    XCTAssertEqual(
      workspace.selectedSessionID, third.id, "the deleted session was not stepped over")
    XCTAssertFalse(controller.validateMenuItem(forward))
  }
}
