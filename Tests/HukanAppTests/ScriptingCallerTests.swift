import XCTest

@testable import Hukan

/// hukan takes no Apple event from a process it started: inside is decided by the process TCC holds
/// responsible for the sender, which a process cannot walk out of by re-parenting itself.
final class ScriptingCallerTests: XCTestCase {
  func testWhatThisProcessStartedIsInside() throws {
    let me = ProcessInfo.processInfo.processIdentifier
    XCTAssertTrue(AppleEventGate.isInside(me))
    XCTAssertFalse(AppleEventGate.isInside(1), "launchd is nobody hukan started")

    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["5"]
    try child.run()
    defer { child.terminate() }
    XCTAssertTrue(AppleEventGate.isInside(child.processIdentifier))
  }

  /// A double fork re-parents the process to launchd, out of reach of a parent walk; the
  /// responsible process still says hukan.
  func testADetachedProcessIsStillInside() throws {
    let pidFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("hukan-detached-\(UUID().uuidString)")
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", "( sleep 5 & echo $! > '\(pidFile.path)' ) &"]
    try shell.run()
    shell.waitUntilExit()
    var pid: pid_t?
    for _ in 0..<50 where pid == nil {
      pid = (try? String(contentsOf: pidFile, encoding: .utf8))
        .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
      if pid == nil { usleep(20_000) }
    }
    let detached = try XCTUnwrap(pid)
    defer { kill(detached, SIGTERM) }
    XCTAssertNotNil(AppleEventGate.responsiblePID(of: detached), "the lookup is there")
    XCTAssertTrue(AppleEventGate.isInside(detached))
  }

  func testOnlyOpeningAndTheDictionaryPass() {
    func code(_ text: String) -> FourCharCode { text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }
    XCTAssertTrue(AppleEventGate.passes(eventClass: code("aevt"), id: code("odoc")))
    XCTAssertTrue(AppleEventGate.passes(eventClass: code("ascr"), id: code("gsdf")))
    XCTAssertFalse(AppleEventGate.passes(eventClass: code("aevt"), id: code("quit")))
    XCTAssertFalse(AppleEventGate.passes(eventClass: code("Hukn"), id: code("McpC")))
    XCTAssertFalse(AppleEventGate.passes(eventClass: code("core"), id: code("cnte")))
  }

  /// The gate is on the real road: an event this process sends itself is answered with the refusal.
  func testAnEventFromInsideIsRefused() throws {
    try XCTSkipIf(guardedScriptingEnabled(), "the harness lets everything through")
    func code(_ text: String) -> FourCharCode { text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }
    let event = NSAppleEventDescriptor(
      eventClass: code("core"), eventID: code("cnte"),
      targetDescriptor: NSAppleEventDescriptor(
        processIdentifier: ProcessInfo.processInfo.processIdentifier),
      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
    )
    event.setParam(NSAppleEventDescriptor(typeCode: code("cwin")), forKeyword: code("kocl"))
    let reply = try event.sendEvent(options: [.waitForReply], timeout: 10)
    XCTAssertEqual(
      reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue, AppleEventGate.refusal)
  }

  /// The terminals' editor reaches the app over its socket, through the helper as shipped: the
  /// request goes in, and the answer — here why nothing could open, as the test host has no
  /// window — comes back as the helper's own error.
  /// What the app answers depends on whether the test host has a window up — "no window" when it
  /// has none, the path opened when another test running beside this one has left one — so
  /// either answer is the helper having reached the app; only not reaching it, or hearing
  /// nothing back, fails. The path is a directory of its own, so what is opened is nobody's.
  func testTheHelperReachesTheAppOverItsSocket() throws {
    let socket = try XCTUnwrap(EditSocket.path, "the socket is up from launch")
    let helper = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("hukan"))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("helper-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let run = Process()
    run.executableURL = helper
    run.arguments = [directory.path]
    run.environment = [
      "HUKAN_EDIT_SOCKET": socket, "HUKAN_TERMINAL_ID": "none", "PATH": "/usr/bin:/bin",
    ]
    let errors = Pipe()
    run.standardError = errors
    try run.run()
    // The answer is written on the main queue, so the run loop has to turn while the helper waits.
    let deadline = Date().addingTimeInterval(10)
    while run.isRunning, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertFalse(run.isRunning)
    let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertFalse(said.contains("cannot reach hukan"), said)
    XCTAssertFalse(said.contains("did not answer"), said)
    if run.terminationStatus == 0 {
      XCTAssertEqual(said, "", "opened, and nothing said")
    } else {
      XCTAssertEqual(run.terminationStatus, 1)
      XCTAssertTrue(said.hasPrefix("hukan: "), said)
    }
  }
}
