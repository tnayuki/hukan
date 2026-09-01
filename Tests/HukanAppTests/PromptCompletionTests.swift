import XCTest

@testable import Hukan

/// Completing a past prompt by its reading.
///
/// The mistake these guard against is the two halves disagreeing: the reading is written one way
/// by macOS's tokenizer and another way by the keyboard that produced the kana in the first place
/// — a macron against a spelt-out long vowel, `~tsu` against a doubled consonant, Hepburn against
/// the kunrei-style an IME takes just as happily — and a query that is folded differently from the
/// prompt it should find fails silently, which is indistinguishable from having no history at all.
final class PromptCompletionTests: XCTestCase {

  /// Everything below rests on this: the tokenizer gives a *reading*, not a transliteration, so a
  /// kanji compound comes back as the word it is pronounced as. Nothing else in hukan can do this,
  /// which is why the feature is possible at all.
  func testReadingIsMorphological() {
    XCTAssertEqual(PromptCompletion.reading(of: "検討"), "kentou")
    XCTAssertEqual(PromptCompletion.reading(of: "履歴"), "rireki")
    // ASCII inside a Japanese sentence is left as it stands, which is what keeps `commit`
    // findable as itself rather than as a reading of it.
    XCTAssertTrue(PromptCompletion.reading(of: "commit して").contains("commit"))
  }

  /// The four spellings one word is written in, each typed the way a person would type it.
  func testQueryVariantsFoldTogether() {
    // The small tsu: `u~tsuta` from the tokenizer against the doubled consonant from a keyboard.
    assertFinds("utta", in: "打った")
    assertFinds("yattoite", in: "やっといて")
    // A long vowel: the macron the tokenizer uses for katakana, and both ways it can be typed.
    for query in ["ririsu", "ririisu", "riri"] { assertFinds(query, in: "リリースして") }
    // And spelt out for a kanji reading — `kentou`, `kento` and `kentoo` are one word.
    for query in ["kentou", "kento", "kentoo"] { assertFinds(query, in: "検討して") }
    // Hepburn against kunrei: both are one keystroke apart on the same IME.
    for query in ["shashin", "syasin"] { assertFinds(query, in: "写真を貼って") }
    for query in ["tsukutte", "tukutte"] { assertFinds(query, in: "作ってみて") }
  }

  /// A reading is one of two ways in. The tokenizer reads an initialism aloud — PR becomes
  /// `pīāru` — so the letters a person would actually type survive only in the text itself.
  func testTextIsMatchedBesideItsReading() {
    assertFinds("pr", in: "PRを作って")
    assertFinds("commit", in: "commit して")
  }

  /// A doubled consonant is the small tsu that `geminate` has just put there, so the long-vowel
  /// collapse must not take it away again.
  func testGeminationSurvivesTheVowelCollapse() {
    XCTAssertEqual(PromptCompletion.fold("commit"), "commit")
    XCTAssertEqual(PromptCompletion.fold(PromptCompletion.reading(of: "打った")), "utta")
  }

  // MARK: - When a list is allowed to open

  func testSlashIsTheCommandListsAndNotThis() {
    XCTAssertNil(PromptCompletion.query(in: "/com", isComposing: false))
  }

  func testCommittedKanaOpensNothing() {
    // The input method has already produced characters; there is no reading left to bridge.
    XCTAssertNil(PromptCompletion.query(in: "検討", isComposing: false))
  }

  func testTextBeingComposedOpensNothing() {
    // The input method's own candidate window is over the field taking the same keys.
    XCTAssertNil(PromptCompletion.query(in: "ke", isComposing: true))
    XCTAssertNotNil(PromptCompletion.query(in: "ke", isComposing: false))
  }

  func testOneCharacterAndBareDigitsOpenNothing() {
    XCTAssertNil(PromptCompletion.query(in: "k", isComposing: false))
    XCTAssertNil(PromptCompletion.query(in: "12", isComposing: false))
    XCTAssertNotNil(PromptCompletion.query(in: "ok", isComposing: false))
  }

  // MARK: - Matching

  func testHeadSortsAboveTheMiddle() {
    let prompts = PromptCompletion.index(["これを検討して", "検討だけして"])
    XCTAssertEqual(PromptCompletion.matches("kentou", in: prompts).first, "検討だけして")
  }

  func testWhatIsAlreadyTypedIsNotOffered() {
    let prompts = PromptCompletion.index(["push", "push して"])
    let matches = PromptCompletion.matches("push", in: prompts)
    XCTAssertFalse(matches.contains("push"))
    XCTAssertTrue(matches.contains("push して"))
  }

  func testTheListIsBounded() {
    let prompts = PromptCompletion.index((0..<200).map { "テスト\($0)を実行" })
    XCTAssertLessThanOrEqual(PromptCompletion.matches("tesuto", in: prompts).count, 50)
  }

  /// A prompt written over several lines is one candidate, and the whole of it reads on the row:
  /// the breaks are spaces, and what does not fit is the row's truncation to say.
  func testMultiLinePromptIsOneRow() {
    XCTAssertEqual(
      CommandCompletionPanel.line(of: "まず直して\nそれからテスト"), "まず直して それからテスト")
    XCTAssertEqual(CommandCompletionPanel.line(of: " 直して "), "直して")
    XCTAssertEqual(
      CommandCompletionPanel.line(of: "直して\n\n    それから\tテスト"), "直して それから テスト",
      "a blank line and an indented paste are not spacing anyone chose to see here")
  }

  private func assertFinds(
    _ query: String, in prompt: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let matches = PromptCompletion.matches(query, in: PromptCompletion.index([prompt]))
    XCTAssertEqual(
      matches, [prompt], "\(query) should find \(prompt)", file: file, line: line)
  }
}

/// Reading the prompts back out of the transcripts. There is no store of hukan's own, so what
/// this pins is the one thing that can go wrong: telling what the person typed apart from
/// everything else Claude Code writes into the same `user` records.
final class PromptHistoryTests: XCTestCase {
  private var worktree: URL!

  override func setUpWithError() throws {
    worktree = URL(fileURLWithPath: "/tmp/hukan-prompt-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: ClaudeSessionStore.directory(for: worktree), withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: ClaudeSessionStore.directory(for: worktree))
  }

  private func write(_ lines: [String]) throws {
    try lines.joined(separator: "\n").write(
      to: ClaudeSessionStore.transcriptURL(id: UUID(), worktree: worktree),
      atomically: true, encoding: .utf8)
  }

  private func user(_ text: String, at: String, extra: String = "") -> String {
    #"{"type":"user","timestamp":"\#(at)"\#(extra),"message":{"role":"user","content":"\#(text)"}}"#
  }

  func testOnlyWhatWasTyped() throws {
    try write([
      user("直して", at: "2026-08-01T00:00:00.000Z"),
      // A tool result rides in a `user` record too, and is the bulk of a transcript.
      #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
      // The wrappers the CLI injects, and the two preambles it writes as prose.
      user("<command-name>/usage</command-name>", at: "2026-08-01T00:00:01.000Z"),
      user("Caveat: The messages below were generated", at: "2026-08-01T00:00:02.000Z"),
      user("This session is being continued from", at: "2026-08-01T00:00:03.000Z"),
      // A record hukan does not show: a sidechain is a subagent's, a meta is the CLI's own.
      user("sub", at: "2026-08-01T00:00:04.000Z", extra: #","isSidechain":true"#),
      user("meta", at: "2026-08-01T00:00:05.000Z", extra: #","isMeta":true"#),
      // The person's text arrives as a block just as often as it does as a string.
      #"{"type":"user","timestamp":"2026-08-01T00:00:06.000Z","message":{"role":"user","content":[{"type":"text","text":"テストして"}]}}"#,
      // An assistant record with the same shape of content must not be read as a prompt.
      #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"わかりました"}]}}"#,
    ])
    XCTAssertEqual(PromptHistory.read(worktrees: [worktree]), ["テストして", "直して"])
  }

  func testNewestFirstAndOnlyOnce() throws {
    try write([
      user("古い", at: "2026-08-01T00:00:00.000Z"),
      user("繰り返し", at: "2026-08-01T00:00:01.000Z"),
      user("新しい", at: "2026-08-02T00:00:00.000Z"),
      user("繰り返し", at: "2026-08-03T00:00:00.000Z"),
    ])
    XCTAssertEqual(PromptHistory.read(worktrees: [worktree]), ["繰り返し", "新しい", "古い"])
  }

  /// A paste is not an instruction. Crash logs and files dropped in as text arrive as `user`
  /// records like everything else, and no one summons one back by typing two letters at it.
  func testAPasteIsNotACandidate() throws {
    let paste = String(repeating: "a", count: PromptHistory.lengthLimit + 1)
    try write([
      user(paste, at: "2026-08-01T00:00:00.000Z"),
      user("直して", at: "2026-08-01T00:00:01.000Z"),
    ])
    XCTAssertEqual(PromptHistory.read(worktrees: [worktree]), ["直して"])
  }
}
