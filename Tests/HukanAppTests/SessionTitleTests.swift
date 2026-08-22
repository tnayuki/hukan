import XCTest

@testable import Hukan

/// Naming a session from its transcript. Claude Code renames itself during the opening
/// exchange and then re-appends the settled name for the rest of the run, so the mistake
/// these guard against is taking the first `ai-title` and showing a name the session has
/// already dropped.
final class SessionTitleTests: XCTestCase {
  private var worktree: URL!

  override func setUpWithError() throws {
    worktree = URL(fileURLWithPath: "/tmp/hukan-title-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: ClaudeSessionStore.directory(for: worktree), withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: ClaudeSessionStore.directory(for: worktree))
  }

  /// Writes `lines` as a transcript and returns the name it is read back under.
  private func title(_ lines: [String]) throws -> String? {
    let id = UUID()
    try lines.joined(separator: "\n").write(
      to: ClaudeSessionStore.transcriptURL(id: id, worktree: worktree),
      atomically: true, encoding: .utf8)
    return ClaudeSessionStore.title(id: id, worktree: worktree)
  }

  private func userLine(_ text: String) -> String {
    #"{"type":"user","message":{"role":"user","content":"\#(text)"}}"#
  }

  private func titleLine(_ text: String) -> String {
    #"{"type":"ai-title","aiTitle":"\#(text)"}"#
  }

  func testLastNameWins() throws {
    // The rename during the opening exchange, then the same name re-appended as it runs.
    let lines =
      [userLine("start"), titleLine("First guess"), titleLine("Settled name")]
      + (0..<50).map { _ in titleLine("Settled name") }
    XCTAssertEqual(try title(lines), "Settled name")
  }

  func testNameFarBackIsStillFound() throws {
    // Named once at the top and never again, then a long run of turns: the search from the
    // end has no window to fall short of.
    let lines =
      [userLine("start"), titleLine("Named once")]
      + (0..<400).map { userLine("turn \($0)") }
    XCTAssertEqual(try title(lines), "Named once")
  }

  func testMentioningTheMarkerIsNotAName() throws {
    // The search jumps to the last "ai-title" in the bytes, which a turn can talk about
    // without being one — that line parses to no name and the search carries on.
    let lines = [
      userLine("start"), titleLine("Settled name"),
      userLine("why is ai-title written twice?"),
    ]
    XCTAssertEqual(try title(lines), "Settled name")
  }

  func testFallsBackToTheFirstThingTheUserTyped() throws {
    let lines = [
      #"{"type":"user","isMeta":true,"message":{"role":"user","content":"boilerplate"}}"#,
      #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"subagent"}}"#,
      userLine("what the user typed"),
      userLine("a later turn"),
    ]
    XCTAssertEqual(try title(lines), "what the user typed")
  }

  func testBlankNameDoesNotCountAsOne() throws {
    XCTAssertEqual(try title([userLine("typed"), titleLine("   ")]), "typed")
  }

  func testMissingTranscriptHasNoName() {
    XCTAssertNil(ClaudeSessionStore.title(id: UUID(), worktree: worktree))
  }

  /// Writes `lines` as a transcript and returns the engine's own name for it, if any.
  private func aiTitle(_ lines: [String]) throws -> String? {
    let id = UUID()
    try lines.joined(separator: "\n").write(
      to: ClaudeSessionStore.transcriptURL(id: id, worktree: worktree),
      atomically: true, encoding: .utf8)
    return ClaudeSessionStore.aiTitle(id: id, worktree: worktree)
  }

  func testEngineNameIsTheLastOne() throws {
    let lines = [userLine("start"), titleLine("First guess"), titleLine("Settled name")]
    XCTAssertEqual(try aiTitle(lines), "Settled name")
  }

  /// The refresh path takes no fallback: a session running under hukan's own guess must keep
  /// it until the engine actually names the session, not have it replaced by the same first
  /// line untruncated.
  func testEngineNameIsNilWhenTheEngineHasNotNamedIt() throws {
    XCTAssertNil(try aiTitle([userLine("what the user typed")]))
  }

  /// A title is a rail row, and the rail typesets it on one line with `sizeToFit`. The fallback
  /// is the first message someone sent, which in a real project runs to hundreds of thousands of
  /// characters — uncapped, one such row cost 256 ms of CoreText and a switch 2.4 s. The cap is
  /// what keeps a title a title.
  func testFallbackIsCutToOneShortLine() throws {
    let long = String(repeating: "あ", count: 900_000)
    let name = try title([userLine(long)])
    XCTAssertEqual(name?.count, 61, "sixty characters plus the ellipsis")
    XCTAssertEqual(name?.last, "…")
  }

  /// Only the first line: a pasted message's second paragraph is not part of its name.
  func testFallbackTakesTheFirstLineOnly() throws {
    let name = try title([userLine("fix the gutter\\nand also the rail\\nand the browser")])
    XCTAssertEqual(name, "fix the gutter")
  }

  /// The engine's own name goes through the same shape. It comes from outside hukan, and one
  /// invariant covering every title beats trusting the writer to keep it short.
  func testEngineNameIsCappedTheSameWay() throws {
    let name = try title([titleLine(String(repeating: "x", count: 500))])
    XCTAssertEqual(name?.count, 61)
    XCTAssertEqual(name?.last, "…")
  }

  /// The live guess and the one read back off disk are the same string, so a session's row does
  /// not change form when it is restored.
  func testLiveGuessMatchesTheStoredFallback() throws {
    let message = "refactor the transcript so it loads tail-first, then check the rail"
    // As typed: padded, and with a blank first line the trim has to eat before the cut.
    let typed = "  \n  " + message + "  "
    XCTAssertEqual(ClaudeSessionStore.titleLine(from: typed), try title([userLine(message)]))
  }
}
