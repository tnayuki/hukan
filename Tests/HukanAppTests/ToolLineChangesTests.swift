import XCTest

@testable import Hukan

/// The lines a tool call changed, drawn on its line in the transcript: read off the patch the
/// engine attaches to the call's result, and put on a line that was drawn before the result came.
final class ToolLineChangesTests: XCTestCase {
  private var worktree: URL!

  override func setUpWithError() throws {
    worktree = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-changes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: ClaudeSessionStore.directory(for: worktree), withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: ClaudeSessionStore.directory(for: worktree))
    try? FileManager.default.removeItem(at: worktree)
  }

  // MARK: reading the result

  func testAnEditCountsItsPatch() {
    let result: [String: Any] = [
      "structuredPatch": [
        ["lines": ["   context", "-old", "+new", "+newer"]],
        ["lines": ["-gone"]],
      ]
    ]
    XCTAssertEqual(
      ClaudeSessionStore.lineChanges(inToolResult: result), LineChanges(added: 2, removed: 2))
  }

  func testAFileCreatedWholeCountsEveryLine() {
    let result: [String: Any] = ["type": "create", "content": "a\nb\nc\n", "structuredPatch": []]
    XCTAssertEqual(
      ClaudeSessionStore.lineChanges(inToolResult: result), LineChanges(added: 3, removed: 0))
    let unterminated: [String: Any] = ["type": "create", "content": "a\nb", "structuredPatch": []]
    XCTAssertEqual(
      ClaudeSessionStore.lineChanges(inToolResult: unterminated), LineChanges(added: 2, removed: 0))
  }

  /// A failed call's result is the error's text, and a call that moved nothing has nothing to say.
  func testAFailureOrANoOpSaysNothing() {
    XCTAssertNil(ClaudeSessionStore.lineChanges(inToolResult: "Error: String to replace not found"))
    XCTAssertNil(ClaudeSessionStore.lineChanges(inToolResult: ["structuredPatch": []]))
    XCTAssertNil(ClaudeSessionStore.lineChanges(inToolResult: nil))
  }

  // MARK: drawing it

  func testAShortCallCarriesItsCountAtTheEndOfItsLine() {
    let line = Transcript.toolUse(
      name: "Edit", input: ["file_path": "a.swift"], changes: LineChanges(added: 12, removed: 3))
    XCTAssertTrue(line.string.contains("Edit  a.swift  +12 −3\n"), line.string)
  }

  /// The live path draws the line when the call goes out and learns what it did from the result.
  func testAResultLandsOnTheLineDrawnBeforeIt() throws {
    let text = NSMutableAttributedString(
      attributedString: Transcript.toolUse(name: "Edit", input: ["file_path": "a.swift"], id: "t1"))
    text.append(Transcript.toolUse(name: "Edit", input: ["file_path": "b.swift"], id: "t2"))
    let (at, run) = try XCTUnwrap(
      Transcript.addingChanges(LineChanges(added: 1, removed: 0), toToolUse: "t1", in: text))
    text.insert(run, at: at)
    XCTAssertTrue(text.string.contains("Edit  a.swift  +1 −0\n"), text.string)
    XCTAssertTrue(text.string.contains("Edit  b.swift\n"), text.string)
    XCTAssertNil(
      Transcript.addingChanges(LineChanges(added: 1, removed: 0), toToolUse: "t3", in: text))
  }

  /// A folded call is rebuilt from its token whenever it is opened or closed, so the count has to
  /// ride on the token too, or folding the line would take it away again.
  func testAFoldedCallKeepsItsCountThroughAFold() throws {
    let long = "Sources/" + String(repeating: "deep/", count: 20) + "File.swift"
    let text = NSMutableAttributedString(
      attributedString: Transcript.toolUse(name: "Write", input: ["file_path": long], id: "t1"))
    let (at, run) = try XCTUnwrap(
      Transcript.addingChanges(LineChanges(added: 5, removed: 2), toToolUse: "t1", in: text))
    text.insert(run, at: at)
    XCTAssertTrue(text.string.contains("…  +5 −2\n"), text.string)

    var range = NSRange()
    let token = try XCTUnwrap(
      text.attribute(
        Transcript.toolTokenKey, at: at, longestEffectiveRange: &range, in: whole(text))
        as? ToolCallToken)
    XCTAssertEqual(
      range, (text.string as NSString).range(of: "▸ Write  " + token.summary + "  +5 −2"))
    XCTAssertTrue(Transcript.toolCallExpandedRun(token).string.hasPrefix("▾ Write  +5 −2\n"))
    XCTAssertTrue(Transcript.toolCallLinkRun(token).string.hasSuffix("  +5 −2"))
    // Said once: a second result for the same call does not add a second count.
    XCTAssertNil(
      Transcript.addingChanges(LineChanges(added: 5, removed: 2), toToolUse: "t1", in: text))
  }

  // MARK: reading a transcript back

  func testATranscriptPutsEachResultOnItsCall() throws {
    let id = UUID()
    let records: [[String: Any]] = [
      [
        "uuid": "a", "type": "assistant", "timestamp": "2026-09-01T00:00:00.000Z",
        "message": [
          "role": "assistant",
          "content": [
            ["type": "tool_use", "id": "t1", "name": "Edit", "input": ["file_path": "a.swift"]]
          ],
        ],
      ],
      [
        "uuid": "b", "parentUuid": "a", "type": "user", "timestamp": "2026-09-01T00:00:01.000Z",
        "message": [
          "role": "user",
          "content": [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]],
        ],
        "toolUseResult": ["structuredPatch": [["lines": ["+x", "+y", "-z"]]]],
      ],
    ]
    let text =
      try records.map {
        String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! + "\n"
      }.joined()
    try Data(text.utf8).write(to: ClaudeSessionStore.transcriptURL(id: id, worktree: worktree))

    let history = try XCTUnwrap(ClaudeSessionStore.history(id: id, worktree: worktree))
    XCTAssertEqual(history.records.first?.changes, LineChanges(added: 2, removed: 1))
    XCTAssertTrue(
      Transcript.render(history.records).string.contains("Edit  a.swift  +2 −1\n"))
  }

  private func whole(_ text: NSAttributedString) -> NSRange {
    NSRange(location: 0, length: text.length)
  }
}
