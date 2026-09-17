import AppKit
import XCTest

@testable import Hukan

/// The transcript's scroll position has to mean a place in the conversation, not a number of
/// points. These pin the difference: the same width change that walks a point offset thousands
/// of points backwards leaves a reader anchor on its own line.
final class ScrollAnchorTests: XCTestCase {
  /// A transcript tall enough that a re-wrap moves the reader visibly — the "long session" the
  /// bug needed.
  private func longTranscript(width: CGFloat = 600) -> (NSScrollView, TranscriptDocumentView) {
    let (scrollView, textView) = makeTranscriptDocumentView()
    scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 400)
    scrollView.layoutSubtreeIfNeeded()
    let body = NSMutableAttributedString()
    for line in 0..<2000 {
      body.append(
        NSAttributedString(
          string: "line \(line) — a transcript line long enough to wrap in a narrower column\n",
          attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
    }
    textView.setContent(body)
    scrollView.layoutSubtreeIfNeeded()
    return (scrollView, textView)
  }

  /// The line the reader has at the top of the viewport, read back off the view.
  private func topLine(of scrollView: NSScrollView, _ textView: TranscriptDocumentView) -> String {
    let index = textView.insertionOffset(at: scrollView.documentVisibleRect.origin)
    let text = textView.string as NSString
    return text.substring(with: text.lineRange(for: NSRange(location: index, length: 0)))
      .trimmingCharacters(in: .newlines)
  }

  private func scrollToMiddle(_ scrollView: NSScrollView, _ textView: TranscriptDocumentView) {
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: textView.frame.height / 2))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    textView.display()
  }

  /// The bug: a narrower column re-wraps the document, the clip view keeps its point offset, and
  /// the reader lands far earlier in the conversation than where they were reading.
  func testPointOffsetWalksBackwardsOnAWidthChange() {
    let (scrollView, textView) = longTranscript()
    scrollToMiddle(scrollView, textView)
    let before = topLine(of: scrollView, textView)
    let offsetBefore = scrollView.documentVisibleRect.minY

    scrollView.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
    scrollView.layoutSubtreeIfNeeded()
    textView.display()

    XCTAssertEqual(
      scrollView.documentVisibleRect.minY, offsetBefore, accuracy: 1,
      "the clip view is expected to keep its point offset — that is what makes this a bug")
    XCTAssertNotEqual(
      topLine(of: scrollView, textView), before,
      "a re-wrap is expected to move the text out from under an unanchored reader")
  }

  /// The fix: the same width change, with the reader's place recorded as a character offset.
  func testAnchorHoldsTheReadersLineAcrossAWidthChange() throws {
    let (scrollView, textView) = longTranscript()
    scrollToMiddle(scrollView, textView)
    let before = topLine(of: scrollView, textView)
    let anchor = try XCTUnwrap(textView.readerAnchor())

    scrollView.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
    scrollView.layoutSubtreeIfNeeded()
    textView.display()
    textView.scroll(to: anchor)
    textView.display()

    XCTAssertEqual(topLine(of: scrollView, textView), before)
  }

  /// Widening again is the other half of a divider drag, and lands on the same line.
  func testAnchorHoldsWhenTheColumnWidens() throws {
    let (scrollView, textView) = longTranscript(width: 480)
    scrollToMiddle(scrollView, textView)
    let before = topLine(of: scrollView, textView)
    let anchor = try XCTUnwrap(textView.readerAnchor())

    scrollView.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
    scrollView.layoutSubtreeIfNeeded()
    textView.display()
    textView.scroll(to: anchor)
    textView.display()

    XCTAssertEqual(topLine(of: scrollView, textView), before)
  }

  /// The document's height is the segments' and never an estimate: laying a long transcript out
  /// and scrolling through it leaves the height exactly where it was.
  func testTheHeightIsExactAndNeverReestimated() {
    let (scrollView, textView) = longTranscript()
    let height = textView.frame.height
    XCTAssertEqual(height, textView.documentHeight)
    for y in stride(from: 0, to: height, by: 1500) {
      scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
      scrollView.reflectScrolledClipView(scrollView.contentView)
      textView.display()
      XCTAssertEqual(textView.frame.height, height, "at \(y)")
    }
  }

  /// An empty transcript has no layout to anchor to, and must not be made to invent one.
  func testEmptyTranscriptHasNoAnchor() {
    let (scrollView, textView) = makeTranscriptDocumentView()
    scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    scrollView.layoutSubtreeIfNeeded()
    XCTAssertNil(textView.readerAnchor())
  }
}
