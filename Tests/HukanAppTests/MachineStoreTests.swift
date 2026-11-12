import Darwin
import XCTest

@testable import Hukan

final class MachineStoreTests: XCTestCase {
  private var directory: URL!
  private var previousRoot: URL?

  override func setUpWithError() throws {
    previousRoot = MachineStore.rootOverride
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hukan-machine-tests-\(UUID())")
    MachineStore.rootOverride = directory
    MachineStore.prepare()
  }

  override func tearDownWithError() throws {
    MachineStore.rootOverride = previousRoot
    try FileManager.default.removeItem(at: directory)
  }

  private func template() throws -> Machine {
    let manifest = MachineManifest(
      id: UUID(), kind: .macOS, title: "macOS fixture", cpuCount: 4,
      memorySize: 4 << 30, display: .init(width: 1280, height: 800),
      macAddress: "02:00:00:00:00:01", fitsWindow: false,
      hardwareModel: "aGFyZHdhcmU=", machineIdentifier: "aWRlbnRpdHk=",
      username: "guest", password: "fixture", created: Date(timeIntervalSince1970: 1_700_000_000))
    let machine = Machine(
      url: MachineStore.templatesURL.appendingPathComponent(manifest.id.uuidString),
      manifest: manifest)
    try FileManager.default.createDirectory(at: machine.url, withIntermediateDirectories: true)
    try Data("disk fixture".utf8).write(to: machine.diskURL)
    try Data("stale state".utf8).write(to: machine.stateURL)
    try machine.save()
    return machine
  }

  /// A QEMU a hukan that died left on a machine's disk belongs to no tab, so deleting the machine
  /// is the last moment anything can stop it — it ran on over a deleted disk before.
  func testDeletingAWindowsMachineStopsTheQEMULeftOnItsDisk() throws {
    var manifest = try template().manifest
    manifest.id = UUID()
    manifest.kind = .windows
    let machine = Machine(
      url: MachineStore.sessionsURL.appendingPathComponent(manifest.id.uuidString),
      manifest: manifest)
    try FileManager.default.createDirectory(at: machine.url, withIntermediateDirectories: true)
    try machine.save()
    // Anything whose path says qemu-system is what the leftover check takes for QEMU.
    let stand = directory.appendingPathComponent("qemu-system-aarch64")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: stand)
    let process = Process()
    process.executableURL = stand
    process.arguments = ["60"]
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    try Data("\(process.processIdentifier)\n".utf8)
      .write(to: machine.url.appendingPathComponent("qemu.pid"))

    try MachineStore.delete(machine)

    let deadline = Date().addingTimeInterval(5)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    XCTAssertFalse(process.isRunning)
    XCTAssertFalse(FileManager.default.fileExists(atPath: machine.url.path))
  }

  func testManifestRoundTripAndPrivatePermissions() throws {
    let machine = try template()
    XCTAssertEqual(Machine(url: machine.url), machine)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: machine.url.appendingPathComponent(Machine.manifestFileName).path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertEqual(machine.diskSize, 12)
  }

  func testCopyHasItsOwnIdentityAndNoSavedState() throws {
    let source = try template()
    let session = UUID()
    let copy = try MachineStore.copy(source, for: session)
    XCTAssertNotEqual(copy.id, source.id)
    XCTAssertNotEqual(copy.manifest.macAddress, source.manifest.macAddress)
    let firstByte = try XCTUnwrap(UInt8(copy.manifest.macAddress.prefix(2), radix: 16))
    XCTAssertEqual(firstByte & 3, 2)
    XCTAssertEqual(copy.manifest.parent, source.id)
    XCTAssertEqual(copy.manifest.session, session)
    XCTAssertFalse(FileManager.default.fileExists(atPath: copy.stateURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.stateURL.path))
    XCTAssertEqual(try Data(contentsOf: copy.diskURL), try Data(contentsOf: source.diskURL))
    XCTAssertEqual(MachineStore.session(id: copy.id)?.id, copy.id)
    XCTAssertEqual(MachineStore.sessions().map(\.id), [copy.id])
  }

  /// What deleting a session takes with it: its own copies, and no other session's.
  func testSessionsOfNamesOnlyThatSessionsCopies() throws {
    let source = try template()
    let session = UUID()
    let first = try MachineStore.copy(source, for: session)
    let second = try MachineStore.copy(source, for: session)
    _ = try MachineStore.copy(source, for: UUID())
    XCTAssertEqual(
      Set(MachineStore.sessions(of: session).map(\.id)), [first.id, second.id])
    XCTAssertEqual(MachineStore.sessions(of: UUID()).count, 0)
  }

  func testSaveAsTemplateClearsSessionAndDisplayPolicy() throws {
    let source = try template()
    let copy = try MachineStore.copy(source, for: UUID())
    try Data([1]).write(to: copy.stateURL)
    let saved = try MachineStore.saveAsTemplate(copy, title: "With tools")
    XCTAssertNotEqual(saved.id, copy.id)
    XCTAssertNotEqual(saved.manifest.macAddress, copy.manifest.macAddress)
    XCTAssertEqual(saved.manifest.parent, source.id)
    XCTAssertNil(saved.manifest.session)
    XCTAssertNil(saved.manifest.fitsWindow)
    XCTAssertEqual(saved.manifest.title, "With tools")
    XCTAssertFalse(FileManager.default.fileExists(atPath: saved.stateURL.path))
    XCTAssertEqual(MachineStore.template(id: saved.id)?.id, saved.id)
    XCTAssertEqual(Set(MachineStore.templates().map(\.id)), [source.id, saved.id])
    try MachineStore.delete(copy)
    XCTAssertNil(MachineStore.session(id: copy.id))
    XCTAssertNotNil(MachineStore.template(id: saved.id))
  }

  func testImagesExcludePartialAndUnrelatedFiles() throws {
    for name in ["A.ipsw", "B.ISO", "C.ipsw.download", "notes.txt"] {
      try Data([1]).write(to: MachineStore.imagesURL.appendingPathComponent(name))
    }
    XCTAssertEqual(MachineStore.images().map(\.lastPathComponent), ["B.ISO", "A.ipsw"])
  }

  func testFileImageArrivesWholeInImages() throws {
    let source = directory.appendingPathComponent("installer.ipsw")
    let contents = Data("installer fixture".utf8)
    try contents.write(to: source)
    let download = RestoreImageDownload(.file(source))
    let finished = expectation(description: "file copied")
    download.onChange = {
      if case .done = download.state { finished.fulfill() }
      if case .failed(let message) = download.state {
        XCTFail(message)
        finished.fulfill()
      }
    }
    download.start()
    wait(for: [finished], timeout: 5)
    let destination = MachineStore.imagesURL.appendingPathComponent(source.lastPathComponent)
    XCTAssertEqual(download.state, .done(destination))
    XCTAssertEqual(try Data(contentsOf: destination), contents)
    // Compared as real paths: the temporary directory is reached through a link.
    XCTAssertEqual(
      MachineStore.images().map { $0.resolvingSymlinksInPath() },
      [destination.resolvingSymlinksInPath()])
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: destination.appendingPathExtension("download").path))
  }

  func testReplyLimitRejectsAnUnterminatedReply() throws {
    var sockets: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
      XCTFail("Could not create socket pair")
      return
    }
    defer {
      close(sockets[0])
      close(sockets[1])
    }
    let bytes = Array(repeating: UInt8(65), count: 128)
    XCTAssertEqual(
      bytes.withUnsafeBytes { Darwin.write(sockets[1], $0.baseAddress, $0.count) }, 128)
    let result = GuestAgent.exchange(sockets[0], ["op": "ping"], replyLimit: 64)
    XCTAssertThrowsError(try result.get()) { error in
      XCTAssertEqual(error.localizedDescription, "The guest agent's reply was too large.")
    }
  }
}
