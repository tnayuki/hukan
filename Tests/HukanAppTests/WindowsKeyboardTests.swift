import XCTest

@testable import Hukan

final class WindowsKeyboardTests: XCTestCase {
  func testPhysicalPositionsIncludeExtendedAndJapaneseKeys() {
    let expected: [UInt16: UInt32] = [
      0: 0x1E, 24: 0x0D, 93: 0x7D, 94: 0x73,
      102: 0x7B, 104: 0x70, 55: 0xDB, 54: 0xDC, 123: 0xCB, 76: 0x9C,
    ]
    for (mac, scan) in expected { XCTAssertEqual(QEMUScreenView.qemuKeys[mac], scan) }
    XCTAssertNil(QEMUScreenView.qemuKeys[UInt16.max])
    let jis = WindowsKeyboard.commands(jis: true)
    XCTAssertEqual(jis.count, 4)
    XCTAssertTrue(
      jis.contains([
        "reg.exe", "add", WindowsKeyboard.key, "/v",
        "OverrideKeyboardIdentifier", "/t", "REG_SZ", "/d", "PCAT_106KEY", "/f",
      ]))
    XCTAssertTrue(jis.contains { $0.contains("kbd106.dll") })
    let ansi = WindowsKeyboard.commands(jis: false)
    XCTAssertEqual(ansi.count, 4)
    XCTAssertEqual(
      Set(ansi.map { $0[4] }),
      Set([
        "LayerDriver JPN", "OverrideKeyboardIdentifier", "OverrideKeyboardType",
        "OverrideKeyboardSubtype",
      ]))
    XCTAssertTrue(
      ansi.allSatisfy {
        $0.prefix(4) == ["reg.exe", "delete", WindowsKeyboard.key, "/v"] && $0.last == "/f"
      })
  }
}
