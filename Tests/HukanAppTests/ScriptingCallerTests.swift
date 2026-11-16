import XCTest

@testable import Hukan

/// Whether a script came from a process this hukan started is decided by walking the sender's
/// parents up to this process: it names the sender in the transcript's note, and refuses a stop or
/// the like landing on a session waiting on the person.
final class ScriptingCallerTests: XCTestCase {
  func testAChildIsInsideAndAParentIsNot() throws {
    let me = ProcessInfo.processInfo.processIdentifier
    XCTAssertTrue(isDescendant(me, of: me))
    XCTAssertTrue(isDescendant(me, of: getppid()), "this process descends from its parent")
    XCTAssertFalse(isDescendant(getppid(), of: me), "a parent is not something it started")
    XCTAssertFalse(isDescendant(1, of: me))

    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["5"]
    try child.run()
    defer { child.terminate() }
    XCTAssertTrue(isDescendant(child.processIdentifier, of: me))
  }

  func testAProcessNoAgentStartedIsATerminal() throws {
    XCTAssertNil(originInside(of: getppid(), among: []), "a process outside is the person's")

    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["5"]
    try child.run()
    defer { child.terminate() }
    XCTAssertEqual(originInside(of: child.processIdentifier, among: []), "a terminal in hukan")
  }
}
