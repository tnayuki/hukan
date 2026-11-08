import AppKit
import XCTest

@testable import Hukan

/// An underscore opens or closes emphasis only at a word's edge. Agents write identifiers in
/// prose without backticks, and `snake_case_name` came back as `case` in italics.
final class UnderscoreEmphasisTests: XCTestCase {
  /// The runs of `rendered` set in an italic font, in order.
  private func italics(_ rendered: NSAttributedString) -> [String] {
    var found: [String] = []
    rendered.enumerateAttribute(
      .font, in: NSRange(location: 0, length: rendered.length), options: []
    ) { value, range, _ in
      guard let font = value as? NSFont,
        font.fontDescriptor.symbolicTraits.contains(.italic)
      else { return }
      found.append(rendered.attributedSubstring(from: range).string)
    }
    return found
  }

  func testAnUnderscoreInsideAWordIsText() {
    for line in [
      "Rename snake_case_name first",
      "Set HUKAN_SCRIPTING_GUARDED=1 and run",
      "Both file_name and dir_name moved",
      "x_1 and y_2",
    ] {
      let rendered = Transcript.markdown(line + "\n")
      XCTAssertEqual(italics(rendered), [], "in: \(line)")
      XCTAssertTrue(rendered.string.contains(line), "an underscore was eaten in: \(line)")
    }
  }

  func testAnUnderscoreAtAWordsEdgeIsEmphasis() {
    XCTAssertEqual(italics(Transcript.markdown("this is _important_ now\n")), ["important"])
    XCTAssertEqual(italics(Transcript.markdown("_whole line_\n")), ["whole line"])
    // A closer inside a word is passed over for the one at the word's edge.
    XCTAssertEqual(
      italics(Transcript.markdown("_see file_name here_ ok\n")), ["see file_name here"])
  }

  /// Kana and kanji are not word characters here, or Japanese emphasis would stop working.
  func testJapaneseAroundAnUnderscoreStillEmphasizes() {
    XCTAssertEqual(italics(Transcript.markdown("これは_重要_です\n")), ["重要"])
  }

  /// A star is not an underscore: CommonMark lets it emphasize inside a word too.
  func testAStarInsideAWordStillEmphasizes() {
    XCTAssertEqual(italics(Transcript.markdown("un*frigging*believable\n")), ["frigging"])
  }
}
