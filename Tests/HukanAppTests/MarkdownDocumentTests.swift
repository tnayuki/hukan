import AppKit
import XCTest

@testable import Hukan

/// A Markdown file read as a document rather than as a message: the line breaks inside a
/// paragraph are the writer's editor, so they close up — and a message keeps every one of them,
/// since the transcript's look must not move because files are now read too.
final class MarkdownDocumentTests: XCTestCase {
  /// The rendered text's paragraphs, with the trailing newline each block ends in dropped.
  private func paragraphs(_ source: String, document: Bool = true) -> [String] {
    Transcript.markdown(source, document: document).string
      .components(separatedBy: "\n").filter { !$0.isEmpty }
  }

  func testAWrappedParagraphIsOneParagraph() {
    XCTAssertEqual(
      paragraphs("The editor never wraps\na line, so a file\nis hard-wrapped.\n\nNext.\n"),
      ["The editor never wraps a line, so a file is hard-wrapped.", "Next."])
  }

  func testJapaneseClosesUpAcrossTheBreak() {
    XCTAssertEqual(paragraphs("人類が滅ぶまでの道筋は\n七つの段階に分かれていた。\n"), ["人類が滅ぶまでの道筋は七つの段階に分かれていた。"])
    // Either side being CJK is enough: an English word wrapped onto a Japanese line opens no gap.
    XCTAssertEqual(paragraphs("NAGI-4\nというモデル\n"), ["NAGI-4というモデル"])
  }

  func testTwoTrailingSpacesKeepTheBreak() {
    XCTAssertEqual(paragraphs("one  \ntwo\\\nthree\n"), ["one\u{2028}two\u{2028}three"])
  }

  func testAListItemCarriesOnOverTheLinesUnderIt() {
    XCTAssertEqual(
      paragraphs("- first item\n  wraps here\n- second\n"),
      ["•  first item wraps here", "•  second"])
  }

  func testABlockEndsTheParagraphAboveIt() {
    XCTAssertEqual(
      paragraphs("prose\n# Heading\nprose\n- item\n"), ["prose", "Heading", "prose", "•  item"])
  }

  func testAQuoteReadsAsParagraphs() {
    let rendered = paragraphs("> first line\n> carries on\n>\n> second\n")
    XCTAssertEqual(rendered, ["first line carries on", "second"])
  }

  func testAMessageKeepsEveryLine() {
    XCTAssertEqual(
      paragraphs("Files changed:\nfoo.swift\nbar.swift\n", document: false),
      ["Files changed:", "foo.swift", "bar.swift"])
    XCTAssertNil(
      Transcript.markdown("text\n").attribute(.markdownSourceLine, at: 0, effectiveRange: nil))
  }

  func testEveryBlockSaysWhichLineItBeganOn() {
    let rendered = Transcript.markdown(
      "# Title\n\nfirst\nwrapped\n\n```\ncode\n```\n- item\n", document: true)
    func line(of text: String) -> Int? {
      let location = (rendered.string as NSString).range(of: text).location
      return rendered.attribute(.markdownSourceLine, at: location, effectiveRange: nil) as? Int
    }
    XCTAssertEqual(line(of: "Title"), 1)
    XCTAssertEqual(line(of: "first wrapped"), 3)
    XCTAssertEqual(line(of: "code"), 6)
    XCTAssertEqual(line(of: "item"), 9)
  }
}
