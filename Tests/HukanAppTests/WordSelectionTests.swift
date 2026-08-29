import AppKit
import XCTest

@testable import Hukan

/// What a double-click selects. The cases are the shapes that turn up in a transcript here, and
/// the reason the suite exists at all is that AppKit answers a Japanese line and an English line
/// differently — so the ones that showed that are stated twice, once with kana on the line and
/// once without, and the two have to agree.
final class WordSelectionTests: XCTestCase {
  /// Every word the correction produces for `line`, in the order first reached, by clicking each
  /// character in turn. Where it declines — Japanese, and any separator clicked on its own — the
  /// character contributes nothing, because AppKit's answer stands and this suite is about what
  /// changes.
  private func corrected(_ line: String) -> [String] {
    let s = line as NSString
    var seen: [String] = []
    for i in 0..<s.length {
      guard let word = word(line, clickingAt: i) else { continue }
      if !seen.contains(word) { seen.append(word) }
    }
    return seen
  }

  /// The word the correction gives for a click at `index`, or nil where it leaves the selection
  /// to AppKit. The caret stands in for AppKit's own answer, which the correction reads only to
  /// tell a click from a drag — passing it as both says "this click, not dragged".
  private func word(_ line: String, clickingAt index: Int) -> String? {
    let s = line as NSString
    let caret = NSRange(location: index, length: 1)
    return WordSelection.word(in: s, click: index, selection: caret, appkitWord: caret)
      .map { s.substring(with: $0) }
  }

  /// The same, aimed at the first character of `token`.
  private func word(_ line: String, clicking token: String) -> String? {
    word(line, clickingAt: (line as NSString).range(of: token).location)
  }

  // MARK: A hash is one word, on a Japanese line as much as an English one

  func testCommitHashIsOneWord() {
    XCTAssertEqual(corrected("756ae49 を main に取り込みました。"), ["756ae49", "main"])
    XCTAssertEqual(
      corrected("Committed as 756ae49 on main"),
      ["Committed", "as", "756ae49", "on", "main"])
    XCTAssertEqual(
      corrected("756ae49d1f2c3b4a5968778695a4b3c2d1e0f9a8 を取り込む"),
      ["756ae49d1f2c3b4a5968778695a4b3c2d1e0f9a8"])
    XCTAssertEqual(corrected("確認 a1b2c3d です"), ["a1b2c3d"])
    XCTAssertEqual(corrected("次は 756AE49 です。"), ["756AE49"])
  }

  // MARK: A hyphen between two alphanumerics does not break the word

  func testHyphenJoins() {
    XCTAssertEqual(
      corrected("f47ac10b-58cc-4372-a567-0e02b2c3d479 のセッション"),
      ["f47ac10b-58cc-4372-a567-0e02b2c3d479"])
    XCTAssertEqual(
      corrected("2026-08-29 に feature-add-history を切った"),
      ["2026-08-29", "feature-add-history"])
    XCTAssertEqual(
      corrected("kebab-case-name と foo_bar99baz"), ["kebab-case-name", "foo_bar99baz"])
    // The same line with no Japanese on it has to answer the same. It did not before: AppKit's
    // Japanese tokenizer calls `kebab-case-name` one word and its English one calls it five, and
    // a rule that deferred to whichever answer was wider is how the two lines diverged.
    XCTAssertEqual(
      corrected("kebab-case-name and foo_bar99baz"),
      ["kebab-case-name", "and", "foo_bar99baz"])
  }

  // MARK: A path and a URL are one word, and so is an option

  func testPathAndURLAreOneWord() {
    XCTAssertEqual(
      word("Sources/Hukan/Model.swift:120 を見て", clicking: "Hukan"),
      "Sources/Hukan/Model.swift:120")
    XCTAssertEqual(word("../hukan-756ae49 を remove", clicking: "hukan"), "../hukan-756ae49")
    XCTAssertEqual(
      word("~/Developer/github.com/tnayuki/hukan へ", clicking: "Developer"),
      "~/Developer/github.com/tnayuki/hukan")
    XCTAssertEqual(
      word("https://github.com/tnayuki/hukan/commit/756ae49 を開く", clicking: "commit"),
      "https://github.com/tnayuki/hukan/commit/756ae49")
    // Clicking the scheme itself has to reach the whole address too, which the two slashes
    // between `https` and the host would otherwise stop.
    XCTAssertEqual(
      word("https://github.com/tnayuki/hukan/commit/756ae49 を開く", clicking: "https"),
      "https://github.com/tnayuki/hukan/commit/756ae49")
  }

  func testOptionKeepsItsLeadingDashes() {
    XCTAssertEqual(corrected("xcodebuild --strict を実行"), ["xcodebuild", "--strict"])
    XCTAssertEqual(
      corrected("-skipPackagePluginValidation を付ける"), ["-skipPackagePluginValidation"])
    XCTAssertEqual(
      corrected("swift-format lint -p -r Sources"),
      ["swift-format", "lint", "-p", "-r", "Sources"])
  }

  // MARK: What must not be swallowed

  func testDashesThatAreNotAnOption() {
    // An infix `--` is not a prefix: the correction declines both sides, so `a` and `b` stay the
    // two words AppKit already had, and neither becomes `a--b` or `--b`.
    XCTAssertNil(word("a--b と別", clicking: "a"))
    XCTAssertNil(word("a--b と別", clicking: "b"))
    // A bullet's dash has a space in the way.
    XCTAssertEqual(corrected("- item は別"), ["item"])
  }

  func testSentencePunctuationIsNotTakenAlong() {
    XCTAssertEqual(corrected("これで終わり。次は make を実行。"), ["make"])
    XCTAssertEqual(corrected("commit (756ae49) here"), ["commit", "756ae49", "here"])
    XCTAssertEqual(corrected("v1.2.3 をタグ付け"), ["v1.2.3"])
  }

  func testJapaneseKeepsAppKitsAnswer() {
    // The correction declines anything that is not printable ASCII, so a morpheme is left to
    // AppKit — the half of the behaviour that must not change.
    let line = "形態素で切れますか"
    for i in 0..<(line as NSString).length {
      XCTAssertNil(word(line, clickingAt: i))
    }
  }

  func testSpanStopsAtWhitespaceAndNewline() {
    // A span that ran past the line end would let a path join the word below it.
    XCTAssertEqual(word("Sources/Hukan\nModel.swift", clicking: "Hukan"), "Sources/Hukan")
  }

  func testAnAbsurdlyLongRunIsLeftAlone() {
    // The minified-file guard: one line, no spaces, longer than any word worth selecting.
    let line = String(repeating: "a", count: WordSelection.maximumSpan + 10)
    XCTAssertNil(word(line, clickingAt: 5))
  }
}
