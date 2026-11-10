import XCTest

@testable import Hukan

/// Which row a change lights: the deepest one on screen that stands for it, and never the parent
/// of a row that is merely scrolled away.
final class TreeFlashTests: XCTestCase {
  private func rows(_ spec: [(String, Bool)]) -> [TreeFlash.VisibleRow] {
    spec.map { .init(path: $0.0, isOpenDirectory: $0.1) }
  }

  func testAFileOnScreenLightsItself() {
    let visible = rows([("Sources", true), ("Sources/a.swift", false)])
    XCTAssertEqual(
      TreeFlash.rowsToLight(changed: ["Sources/a.swift"], visible: visible) { _ in true },
      ["Sources/a.swift"])
  }

  func testAFileInAFoldedDirectoryLightsTheDirectory() {
    let visible = rows([("Sources", true), ("Sources/Hukan", false), ("README.md", false)])
    XCTAssertEqual(
      TreeFlash.rowsToLight(changed: ["Sources/Hukan/Model.swift"], visible: visible) { _ in true },
      ["Sources/Hukan"])
  }

  func testAFoldedTopLevelDirectoryLights() {
    let visible = rows([("Sources", false), ("Tests", false)])
    XCTAssertEqual(
      TreeFlash.rowsToLight(
        changed: ["Tests/A/b.swift", "Sources/x.swift"], visible: visible
      ) { _ in true },
      ["Tests", "Sources"])
  }

  /// The file's row exists below the open directory but is scrolled away: lighting the directory
  /// would point at the wrong row.
  func testAnOpenDirectoryDoesNotLightForARowScrolledAway() {
    let visible = rows([("Sources", true)])
    XCTAssertEqual(
      TreeFlash.rowsToLight(changed: ["Sources/z.swift"], visible: visible) { _ in true },
      [])
  }

  /// The file's row has gone — it was deleted — so the open directory it was in is what is left
  /// on screen to stand for it.
  func testAnOpenDirectoryLightsForARowThatHasGone() {
    let visible = rows([("Sources", true), ("Sources/a.swift", false)])
    XCTAssertEqual(
      TreeFlash.rowsToLight(changed: ["Sources/gone.swift"], visible: visible) { _ in false },
      ["Sources"])
  }

  /// A deeper folded directory scrolled out of view under an open one: the row that stands for
  /// the change exists, so nothing on screen lights.
  func testAFoldedDirectoryScrolledAwayLightsNothing() {
    let visible = rows([("Sources", true)])
    let lit = TreeFlash.rowsToLight(changed: ["Sources/Hukan/Model.swift"], visible: visible) {
      $0 == "Sources/Hukan"
    }
    XCTAssertEqual(lit, [])
  }

  func testAChangeOutsideEveryVisibleRowLightsNothing() {
    let visible = rows([("Sources", false)])
    XCTAssertEqual(
      TreeFlash.rowsToLight(changed: ["Tests/a.swift"], visible: visible) { _ in true }, [])
  }
}
