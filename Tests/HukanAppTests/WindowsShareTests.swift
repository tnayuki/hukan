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
      "path=\(root.path)/worktree", "interfaces=127.0.0.1", "bind interfaces only=yes",
      "unix extensions = no", "follow symlinks = yes", "wide links = no", "read only=no",
      "guest ok=yes", "force user=\(NSUserName())",
    ] {
      XCTAssertTrue(lines.contains(line), line)
    }
    // A wide link anywhere lets every link in the worktree out of it.
    XCTAssertFalse(config.contains("allow insecure wide links"))
    XCTAssertFalse(lines.contains("wide links = yes"))
    let link = root.appendingPathComponent("worktree")
    for target in [first, second, first] {
      qemu.share(target)
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
      XCTAssertEqual(
        try String(contentsOf: link.appendingPathComponent("marker"), encoding: .utf8),
        target.lastPathComponent)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("worktree-next").path))
    }
  }

  /// A move ends this machine's sambas: the processes under QEMU running the samba binary, and
  /// nothing else on the machine.
  func testTheProcessesEndedOnAMoveAreThoseUnderTheMachine() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["5"]
    try child.run()
    defer { child.terminate() }
    let me = ProcessInfo.processInfo.processIdentifier
    XCTAssertEqual(
      QEMUMachine.processes(running: "/bin/sleep", under: me), [child.processIdentifier])
    XCTAssertEqual(QEMUMachine.processes(running: "/bin/cat", under: me), [])
    XCTAssertEqual(QEMUMachine.processes(running: "/bin/sleep", under: child.processIdentifier), [])
  }

  /// A move waits while samba has a file open in the worktree it is leaving — a regular file, not
  /// the directory it holds for as long as it is connected.
  func testAnOpenFileIsSeenAndADirectoryIsNot() throws {
    let file = directory.appendingPathComponent("open.txt")
    try Data("x".utf8).write(to: file)
    let me = ProcessInfo.processInfo.processIdentifier
    let held = open(directory.path, O_RDONLY)
    defer { close(held) }
    XCTAssertFalse(QEMUMachine.hasFileOpen(me, under: directory))
    let handle = try FileHandle(forReadingFrom: file)
    XCTAssertTrue(QEMUMachine.hasFileOpen(me, under: directory))
    XCTAssertFalse(
      QEMUMachine.hasFileOpen(me, under: directory.appendingPathComponent("elsewhere")))
    try handle.close()
    XCTAssertFalse(QEMUMachine.hasFileOpen(me, under: directory))
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
