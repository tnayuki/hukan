import XCTest

@testable import Hukan

/// The roster label contract: the engine advertises numberless names ("Opus", "Fable") with the
/// version only in `resolvedModel`, and `resolvedModel` carries a `[1m]` context-window suffix the
/// transcript's id does not. `matches` bridges that suffix gap and `numberedName` restores the
/// version — the pair that keeps "Opus 4.8" showing where a bare "Opus" or a raw id did before.
final class ClaudeModelLabelTests: XCTestCase {
  private func model(_ value: String, _ name: String, _ resolved: String) -> ClaudeModel {
    ClaudeModel(value: value, displayName: name, resolvedModel: resolved)
  }

  func testVersionParsedOffResolvedID() {
    XCTAssertEqual(ClaudeModel.version(fromResolved: "claude-opus-4-8[1m]"), "4.8")
    XCTAssertEqual(ClaudeModel.version(fromResolved: "claude-fable-5"), "5")
    XCTAssertEqual(ClaudeModel.version(fromResolved: "claude-sonnet-5"), "5")
    // A trailing 8-digit date snapshot is not a version component.
    XCTAssertEqual(ClaudeModel.version(fromResolved: "claude-haiku-4-5-20251001"), "4.5")
    XCTAssertNil(ClaudeModel.version(fromResolved: "claude-experimental"))
  }

  func testNumberedNameSplicesVersionOntoLabel() {
    XCTAssertEqual(model("opus[1m]", "Opus", "claude-opus-4-8[1m]").numberedName, "Opus 4.8")
    XCTAssertEqual(model("claude-fable-5[1m]", "Fable", "claude-fable-5").numberedName, "Fable 5")
    // No numeric version: the bare label stands.
    XCTAssertEqual(model("x", "Custom", "claude-experimental").numberedName, "Custom")
    // "Default" is the engine's own pick, not a model — no version, even though it resolves to one.
    XCTAssertEqual(
      model("default", "Default (recommended)", "claude-opus-5[1m]").numberedName,
      "Default (recommended)")
    // A label that already ends in a parenthetical takes the version before it, not after.
    XCTAssertEqual(
      model("opus[1m]", "Opus (1M context)", "claude-opus-5[1m]").numberedName,
      "Opus 5 (1M context)")
  }

  func testMatchesToleratesContextSuffix() {
    let opus = model("opus[1m]", "Opus", "claude-opus-4-8[1m]")
    // The transcript records the resolved id without the `[1m]` suffix — must still match.
    XCTAssertTrue(opus.matches("claude-opus-4-8"))
    XCTAssertTrue(opus.matches("claude-opus-4-8[1m]"))
    XCTAssertTrue(opus.matches("opus[1m]"))  // the alias value, exact
    XCTAssertFalse(opus.matches("claude-sonnet-5"))
  }
}
