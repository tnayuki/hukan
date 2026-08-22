import AppKit
import XCTest

@testable import Hukan

/// The transcript's scroll position has to mean a place in the conversation, not a number of
/// points. These pin the difference: the same width change that walks a point offset thousands
/// of points backwards leaves a character anchor on its own line.
final class ScrollAnchorTests: XCTestCase {
  /// A transcript tall enough that a re-wrap moves the reader visibly — the "long session" the
  /// bug needed. Laid out in full, the way opening a session lays it out.
  private func longTranscript(width: CGFloat = 600) -> (NSScrollView, NSTextView) {
    let (scrollView, textView) = makeTranscriptTextView()
    scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 400)
    scrollView.layoutSubtreeIfNeeded()
    let body = NSMutableAttributedString()
    for line in 0..<2000 {
      body.append(
        NSAttributedString(
          string: "line \(line) — a transcript line long enough to wrap in a narrower column\n",
          attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
    }
    textView.textStorage?.setAttributedString(body)
    textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)
    scrollView.layoutSubtreeIfNeeded()
    return (scrollView, textView)
  }

  /// The line the reader has at the top of the viewport, read back off the view.
  private func topLine(of scrollView: NSScrollView, _ textView: NSTextView) -> String {
    let index = textView.characterIndexForInsertion(at: scrollView.documentVisibleRect.origin)
    let text = textView.string as NSString
    return text.substring(with: text.lineRange(for: NSRange(location: index, length: 0)))
      .trimmingCharacters(in: .newlines)
  }

  private func scrollToMiddle(_ scrollView: NSScrollView, _ textView: NSTextView) {
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
  func testAnchorHoldsTheReadersLineAcrossAWidthChange() {
    let (scrollView, textView) = longTranscript()
    scrollToMiddle(scrollView, textView)
    let before = topLine(of: scrollView, textView)
    let anchor = TranscriptScrollAnchor.capture(in: scrollView, of: textView)
    XCTAssertNotNil(anchor)

    scrollView.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
    scrollView.layoutSubtreeIfNeeded()
    textView.display()
    anchor?.restore(in: scrollView, of: textView)
    textView.display()

    XCTAssertEqual(topLine(of: scrollView, textView), before)
  }

  /// Widening again is the other half of a divider drag, and lands on the same line.
  func testAnchorHoldsWhenTheColumnWidens() {
    let (scrollView, textView) = longTranscript(width: 480)
    scrollToMiddle(scrollView, textView)
    let before = topLine(of: scrollView, textView)
    let anchor = TranscriptScrollAnchor.capture(in: scrollView, of: textView)

    scrollView.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
    scrollView.layoutSubtreeIfNeeded()
    textView.display()
    anchor?.restore(in: scrollView, of: textView)
    textView.display()

    XCTAssertEqual(topLine(of: scrollView, textView), before)
  }

  /// An empty transcript has no layout to anchor to, and must not be made to invent one.
  func testEmptyTranscriptHasNoAnchor() {
    let (scrollView, textView) = makeTranscriptTextView()
    scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    scrollView.layoutSubtreeIfNeeded()
    XCTAssertNil(TranscriptScrollAnchor.capture(in: scrollView, of: textView))
  }
}
