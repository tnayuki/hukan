import XCTest

@testable import Hukan

/// The roster identity contract: `resolvedModel` carries a `[1m]` context-window suffix that the
/// transcript's id does not, and `matches` is what bridges that gap — it is the only reading hukan
/// does of a model id. The label is not one of them: the engine's `displayName` is shown verbatim,
/// since it is the one party that knows whether an account needs "Fable 5" to tell two Fables apart
/// or just "Fable". hukan spliced a version off `resolvedModel` onto the label once, and it doubled
/// up ("Fable 5 5") as soon as the engine started numbering a label itself.
final class ClaudeModelLabelTests: XCTestCase {
  private func model(_ value: String, _ name: String, _ resolved: String) -> ClaudeModel {
    ClaudeModel(value: value, displayName: name, resolvedModel: resolved)
  }

  func testMatchesToleratesContextSuffix() {
    let opus = model("opus[1m]", "Opus", "claude-opus-4-8[1m]")
    // The transcript records the resolved id without the `[1m]` suffix — must still match.
    XCTAssertTrue(opus.matches("claude-opus-4-8"))
    XCTAssertTrue(opus.matches("claude-opus-4-8[1m]"))
    XCTAssertTrue(opus.matches("opus[1m]"))  // the alias value, exact
    XCTAssertFalse(opus.matches("claude-sonnet-5"))
  }

  func testMatchesTellsTheTwoFablesApart() {
    let fable = model("claude-fable-5-1[1m]", "Fable", "claude-fable-5-1")
    let fable5 = model("claude-fable-5", "Fable 5", "claude-fable-5")
    XCTAssertTrue(fable.matches("claude-fable-5-1"))
    XCTAssertFalse(fable.matches("claude-fable-5"))
    XCTAssertTrue(fable5.matches("claude-fable-5"))
    XCTAssertFalse(fable5.matches("claude-fable-5-1"))
  }
}
