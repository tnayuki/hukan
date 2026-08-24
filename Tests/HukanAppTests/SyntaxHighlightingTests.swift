import XCTest

@testable import Hukan

/// The spans a file's highlighting is built from. The cases that matter are the ones that
/// silently go wrong: offsets around multi-byte characters, and files no grammar covers.
final class SyntaxHighlightingTests: XCTestCase {
  /// Every span has to land on the text it was computed for. An em dash is one UTF-16 unit
  /// but three UTF-8 bytes, so a byte offset mistaken for a character offset drifts from here
  /// on — and drifts further with each one, which is exactly how it looked in the app: colors
  /// sliding into the middle of words further down the file.
  func testSpansStayAlignedAcrossMultibyteCharacters() {
    let source = """
      /// Usage — the plan's rolling window.
      let label = "session"
      /// Another — comment.
      func fetch() -> Bool { return true }
      """
    let text = source as NSString
    let spans = SyntaxHighlighting.spans(in: source, forPath: "usage.swift")
    let words = spans.map { text.substring(with: $0.range) }
    // The keywords past both em dashes, spelled whole.
    XCTAssertTrue(words.contains("let"), "spans: \(words)")
    XCTAssertTrue(words.contains("func"), "spans: \(words)")
    XCTAssertTrue(words.contains("return"), "spans: \(words)")
    XCTAssertTrue(words.contains("Bool"), "spans: \(words)")
    // And nothing ran off the end of the document.
    for span in spans {
      XCTAssertLessThanOrEqual(NSMaxRange(span.range), text.length)
    }
  }

  func testCommentsAreOneSpanNotWords() {
    // The symptom in the app was words *inside* a comment picking up keyword colors.
    let source = "/// return the window and the plan\nlet x = 1\n"
    let text = source as NSString
    let commentEnd = (source as NSString).range(of: "\n").location
    for span in SyntaxHighlighting.spans(in: source, forPath: "x.swift")
    where span.range.location < commentEnd {
      XCTAssertEqual(
        text.substring(with: span.range), "/// return the window and the plan",
        "a comment must colour as one span")
    }
  }

  func testUnknownExtensionRendersPlain() {
    XCTAssertFalse(SyntaxHighlighting.canHighlight(path: "notes.txt"))
    XCTAssertTrue(SyntaxHighlighting.spans(in: "let x = 1", forPath: "notes.txt").isEmpty)
  }

  func testHugeFileIsLeftPlain() {
    let huge = String(repeating: "let x = 1\n", count: 120_000)
    XCTAssertGreaterThan(huge.utf16.count, SyntaxHighlighting.sizeLimit)
    XCTAssertTrue(SyntaxHighlighting.spans(in: huge, forPath: "huge.swift").isEmpty)
  }
}
