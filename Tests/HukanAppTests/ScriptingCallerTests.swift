import XCTest

@testable import Hukan

/// The steering verbs are refused to a process this hukan started, which is decided by walking the
/// sender's parents up to this process.
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
}
