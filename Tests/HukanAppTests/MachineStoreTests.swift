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

  /// What another hukan is still making is left alone; what nobody holds goes. A claim is a
  /// `flock` on its own open file, so one taken here stands in for one taken by another process.
  func testOnlyWhatNoRunningHukanHoldsIsDiscarded() throws {
    let fm = FileManager.default
    let held = MachineStore.templatesURL.appendingPathComponent(".building-held")
    let abandoned = MachineStore.templatesURL.appendingPathComponent(".building-abandoned")
    let copying = MachineStore.imagesURL.appendingPathComponent("Fixture.iso.download")
    for url in [held, abandoned] {
      try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }
    fm.createFile(atPath: copying.path, contents: Data("partial".utf8))
    var claims = try [held, copying].map { try XCTUnwrap(MachineStore.Claim.take($0)) }
    // A claim file nobody holds is what a crash leaves beside nothing.
    fm.createFile(
      atPath: MachineStore.Claim.file(for: abandoned).path, contents: nil)

    MachineStore.discardUnfinished()
    try waitUntil { !fm.fileExists(atPath: abandoned.path) }
    try waitUntil { !fm.fileExists(atPath: MachineStore.Claim.file(for: abandoned).path) }
    XCTAssertTrue(fm.fileExists(atPath: held.path))
    XCTAssertTrue(fm.fileExists(atPath: copying.path))

    for claim in claims { claim.release() }
    claims = []
    XCTAssertFalse(fm.fileExists(atPath: MachineStore.Claim.file(for: held).path))
    MachineStore.discardUnfinished()
    try waitUntil { !fm.fileExists(atPath: held.path) && !fm.fileExists(atPath: copying.path) }
    let left =
      try fm.contentsOfDirectory(atPath: MachineStore.templatesURL.path)
      + fm.contentsOfDirectory(atPath: MachineStore.imagesURL.path)
    XCTAssertEqual(left.filter { $0.hasPrefix(".") && $0 != ".DS_Store" }, [])
  }

  private func waitUntil(_ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
      guard Date() < deadline else {
        struct NeverHappened: Error {}
        throw NeverHappened()
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
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

  /// A copy names every template behind it, so one deleted from the middle leaves the copy still
  /// knowing the one before.
  func testACopyNamesEveryTemplateBehindIt() throws {
    let source = try template()
    let copy = try MachineStore.copy(source, for: UUID())
    XCTAssertEqual(copy.manifest.lineage, [source.id])
    let saved = try MachineStore.saveAsTemplate(copy, title: "With tools")
    XCTAssertEqual(saved.manifest.lineage, [source.id])
    let second = try MachineStore.copy(saved, for: UUID())
    XCTAssertEqual(second.manifest.lineage, [saved.id, source.id])
    XCTAssertEqual(Machine(url: second.url)?.manifest.lineage, [saved.id, source.id])

    // One made before the lineage was written knows its parent, and a copy of it carries that on.
    var old = saved
    old.manifest.ancestors = nil
    try old.save()
    XCTAssertEqual(try MachineStore.copy(old, for: UUID()).manifest.lineage, [saved.id, source.id])
  }

  /// A copy is measured by what it holds that its template does not, and saving it as a template
  /// leaves that standing — the clone that takes a file's private blocks to nothing.
  func testACopyIsMeasuredAgainstItsTemplateWhateverElseIsCloned() throws {
    let megabyte = 1 << 20
    let source = try template()
    try Data((0..<4 * megabyte).map { _ in UInt8.random(in: 0...255) }).write(to: source.diskURL)
    let copy = try MachineStore.copy(source, for: UUID())
    // Its manifest is a file of its own, so a block or two stands beyond the template at once.
    XCTAssertLessThan(copy.size(beyond: source), 64 << 10)

    let disk = try FileHandle(forWritingTo: copy.diskURL)
    try disk.seek(toOffset: UInt64(megabyte))
    try disk.write(contentsOf: Data((0..<megabyte).map { _ in UInt8.random(in: 0...255) }))
    try disk.close()
    let written = Int64(megabyte)..<Int64(megabyte + (64 << 10))
    XCTAssertTrue(written.contains(copy.size(beyond: source)))

    let saved = try MachineStore.saveAsTemplate(copy, title: "With tools")
    XCTAssertTrue(written.contains(copy.size(beyond: source)))
    XCTAssertTrue(written.contains(saved.size(beyond: source)))
    XCTAssertLessThan(saved.size(beyond: copy), 64 << 10)
  }

  func testImagesExcludePartialAndUnrelatedFiles() throws {
    for name in ["A.ipsw", "B.ISO", "C.ipsw.download", "notes.txt"] {
      try Data([1]).write(to: MachineStore.imagesURL.appendingPathComponent(name))
    }
    XCTAssertEqual(MachineStore.images().map(\.lastPathComponent), ["B.ISO", "A.ipsw"])
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
