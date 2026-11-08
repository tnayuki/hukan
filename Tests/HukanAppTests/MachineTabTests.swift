import XCTest

@testable import Hukan

final class MachineTabTests: XCTestCase {
  func testRestoredPaneWaitsWithoutStartingAndKeepsStoppedState() {
    for stopped in [false, true] {
      let state = MachineTabState(
        deskID: UUID(), machineID: UUID().uuidString, name: "Session machine",
        title: "Template title", stopped: stopped)
      let pane = MachinePaneViewController(restoring: state)
      XCTAssertEqual(pane.machineID, state.machineID)
      XCTAssertEqual(pane.name, state.name)
      XCTAssertEqual(pane.tabTitle, state.title)
      XCTAssertEqual(pane.isStopped, stopped)
      XCTAssertEqual(pane.stateDescription, stopped ? "stopped" : "not started")
      XCTAssertTrue(pane.isPending)
      XCTAssertFalse(pane.isRunning)
      XCTAssertNil(pane.virtualMachine)
      XCTAssertTrue(pane.agentsHeard.isEmpty)
    }
  }
}
