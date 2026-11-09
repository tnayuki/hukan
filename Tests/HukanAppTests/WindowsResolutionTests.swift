import XCTest

@testable import Hukan

final class WindowsResolutionTests: XCTestCase {
  func testStoppedWindowsResolutionPersistsWithoutStartingGuest() throws {
    let previousRoot = MachineStore.rootOverride
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hukan-windows-resolution-\(UUID())")
    MachineStore.rootOverride = directory
    defer {
      MachineStore.rootOverride = previousRoot
      try? FileManager.default.removeItem(at: directory)
    }
    MachineStore.prepare()
    var machine = Machine(
      url: directory,
      manifest: .init(
        id: UUID(), kind: .windows, title: "Windows fixture", cpuCount: 3,
        memorySize: 6 << 30, display: .init(width: 1920, height: 1080),
        macAddress: "02:00:00:00:00:01", username: "guest", password: "fixture",
        created: Date(timeIntervalSince1970: 0)))
    machine = Machine(
      url: MachineStore.sessionsURL.appendingPathComponent(machine.id.uuidString),
      manifest: machine.manifest)
    try FileManager.default.createDirectory(at: machine.url, withIntermediateDirectories: true)
    try machine.save()
    let pane = MachinePaneViewController(
      restoring: .init(
        deskID: UUID(), machineID: machine.id.uuidString, name: "Fixture", title: "Windows",
        stopped: true))
    XCTAssertTrue(pane.runsOnQEMU)
    var notices = 0
    pane.onResolutionChange = { notices += 1 }
    var superseded: String?
    try pane.setResolution((1600, 900), settled: { superseded = $0 })
    XCTAssertEqual(pane.resolutionDescription, "1600x900")
    let saved = try XCTUnwrap(MachineStore.session(id: machine.id))
    XCTAssertEqual(saved.manifest.display.width, 1600)
    XCTAssertEqual(saved.manifest.display.height, 900)
    XCTAssertEqual(saved.manifest.fitsWindow, false)
    try pane.setResolution((1920, 1080))
    XCTAssertEqual(superseded, "superseded by a newer resolution")
    XCTAssertEqual(notices, 2)
    XCTAssertFalse(pane.isRunning)
    XCTAssertTrue(pane.isStopped)
    XCTAssertTrue(pane.isPending)
  }

  func testAgentUpdateStopsBothHalvesBeforeReplacingAndRestartsBoth() throws {
    let path = "C:\\Program Files\\Hukan\\hukan-guest-agent.exe"
    let script = MachinePaneViewController.windowsAgentUpdateScript(path: path)
    let lines = script.components(separatedBy: "\r\n")
    let commands = [
      "sc stop HukanGuestAgent", "taskkill /f /im hukan-guest-agent.exe",
      "move /y \"\(path).new\" \"\(path)\"", "sc start HukanGuestAgent",
      "schtasks /run /tn HukanGuestAgent", "del \"%~f0\"",
    ]
    let indices = try commands.map { try XCTUnwrap(lines.firstIndex(of: $0)) }
    XCTAssertEqual(indices, indices.sorted())
    XCTAssertEqual(Set(indices).count, commands.count)
    XCTAssertEqual(lines.first, "@echo off")
  }
}
