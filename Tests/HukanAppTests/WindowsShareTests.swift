import XCTest

@testable import Hukan

final class WindowsShareTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hukan-share-tests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  func testConfigurationAndGuestForwardUsePrivateShareAndStdioServer() throws {
    let executable = directory.appendingPathComponent("fixture-smbd")
    try Data().write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let qemu = QEMUMachine(
      machine: QEMUMachineTests.machine(at: directory),
      temporaryDirectory: directory, sambaExecutable: executable.path)
    let first = directory.appendingPathComponent("first")
    let second = directory.appendingPathComponent("second")
    for target in [first, second] {
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      try Data(target.lastPathComponent.utf8).write(to: target.appendingPathComponent("marker"))
    }
    qemu.sharedDirectory = first
    let forward = try XCTUnwrap(qemu.prepareShare())
    let root = qemu.shareRoot
    XCTAssertEqual(
      forward,
      "guestfwd=tcp:10.0.2.4:445-cmd:\(executable.path) -l \(root.path)/state -s \(root.path)/smb.conf"
    )
    let config = try String(contentsOf: root.appendingPathComponent("smb.conf"), encoding: .utf8)
    let lines = config.components(separatedBy: "\n")
    for line in [
      "path=\(root.path)/share", "interfaces=127.0.0.1", "bind interfaces only=yes",
      "unix extensions = no", "allow insecure wide links = yes", "follow symlinks = yes",
      "wide links = yes", "read only=no", "guest ok=yes", "force user=\(NSUserName())",
    ] {
      XCTAssertTrue(lines.contains(line), line)
    }
    let share = root.appendingPathComponent("share")
    let link = share.appendingPathComponent("worktree")
    for target in [first, second, first] {
      qemu.share(target)
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
      XCTAssertEqual(
        try String(contentsOf: link.appendingPathComponent("marker"), encoding: .utf8),
        target.lastPathComponent)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: share.path), ["worktree"])
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("worktree-next").path))
    }
  }

  func testMissingSambaOrWorktreeDoesNotPrepareShare() {
    let qemu = QEMUMachine(
      machine: QEMUMachineTests.machine(at: directory),
      temporaryDirectory: directory,
      sambaExecutable: directory.appendingPathComponent("missing").path)
    XCTAssertNil(qemu.prepareShare())
    qemu.sharedDirectory = directory
    XCTAssertNil(qemu.prepareShare())
    XCTAssertFalse(FileManager.default.fileExists(atPath: qemu.shareRoot.path))
  }
}
