import XCTest

@testable import Hukan

/// The pure `[String: Any]` → summary/full logic behind every tool-call line and approval card.
/// `toolArgument` picks the one argument worth showing and clips it; `summarize` is its one-line
/// face. No AppKit, no rendering — just the key-priority, first-line, and 90-char-clip rules.
final class TranscriptSummaryTests: XCTestCase {
  func testPicksFirstMatchingKeyInPriorityOrder() {
    // file_path outranks command even when both are present.
    let result = Transcript.toolArgument(
      tool: "Edit",
      input: ["command": "rm -rf /", "file_path": "/src/a.swift"])
    XCTAssertEqual(result?.summary, "/src/a.swift")
    XCTAssertEqual(result?.full, "/src/a.swift")
  }

  func testKeyPriorityFallsThrough() {
    // No file_path/path/pattern, so command is the first key that hits.
    XCTAssertEqual(Transcript.toolArgument(tool: "Bash", input: ["command": "ls"])?.summary, "ls")
    // pattern outranks command.
    XCTAssertEqual(
      Transcript.toolArgument(
        tool: "Grep",
        input: ["command": "x", "pattern": "TODO"])?.summary, "TODO")
  }

  func testSummaryIsFirstLineButFullIsWhole() {
    let multiline = "echo one\necho two\necho three"
    let result = Transcript.toolArgument(tool: "Bash", input: ["command": multiline])
    XCTAssertEqual(result?.summary, "echo one")
    XCTAssertEqual(result?.full, multiline)
  }

  func testClipsSummaryAtNinetyChars() {
    let ninety = String(repeating: "a", count: 90)
    XCTAssertEqual(
      Transcript.toolArgument(tool: "Bash", input: ["command": ninety])?.summary, ninety,
      "exactly 90 chars is left untouched")

    let overLong = String(repeating: "a", count: 91)
    let clipped = Transcript.toolArgument(tool: "Bash", input: ["command": overLong])?.summary
    XCTAssertEqual(clipped, String(repeating: "a", count: 90) + "…")
    XCTAssertEqual(clipped?.count, 91, "90 chars plus the single ellipsis glyph")
  }

  func testSkillCallNamesItsSkill() {
    // The Skill tool's input is the skill's name and its arguments; without `skill` in the key
    // list the line read a bare `Skill` and never said which one ran.
    let result = Transcript.toolArgument(
      tool: "Skill", input: ["skill": "code-review", "args": "--fix"])
    XCTAssertEqual(result?.summary, "code-review")
    XCTAssertEqual(result?.full, "code-review")
  }

  func testReturnsNilWhenNoKnownKey() {
    XCTAssertNil(Transcript.toolArgument(tool: "Mystery", input: ["unknown": "value"]))
    XCTAssertNil(Transcript.toolArgument(tool: "Mystery", input: [:]))
    // A known key whose value is not a String does not count.
    XCTAssertNil(Transcript.toolArgument(tool: "Bash", input: ["command": 42]))
  }

  func testSummarizeMirrorsToolArgumentSummary() {
    XCTAssertEqual(
      Transcript.summarize(tool: "Bash", input: ["command": "make build"]), "make build")
    XCTAssertEqual(
      Transcript.summarize(tool: "Mystery", input: [:]), "",
      "empty string, not a crash, when there is nothing to show")
  }
}
