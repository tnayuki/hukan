import XCTest

@testable import Hukan

/// A width change has to invalidate the whole transcript view: every line re-wraps, so nothing
/// drawn at the old width may survive.
final class TranscriptRewrapTests: XCTestCase {
  /// In a real (never shown) window: AppKit drops an invalidation on a view with no window, so
  /// `needsDisplay` would read back false however it was set.
  @MainActor
  private func makeHostedTextView() -> ReadingView {
    let (scrollView, textView) = makeReadingView()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.contentView = scrollView
    scrollView.layoutSubtreeIfNeeded()
    return textView
  }

  @MainActor
  func testWidthChangeInvalidatesTheView() {
    let textView = makeHostedTextView()
    textView.setFrameSize(NSSize(width: 400, height: 300))
    textView.needsDisplay = false
    textView.setFrameSize(NSSize(width: 360, height: 300))
    XCTAssertTrue(textView.needsDisplay, "a narrower column re-wraps, so the old wrapping must go")
  }

  /// A column sliding beside the transcript moves its frame through every width between, and a
  /// re-wrap at each is a layout of everything loaded per frame. Held, the text stays wrapped
  /// where it was — the height with it, so the reader's place does not move under them — and is
  /// re-wrapped once, at the width the slide lands on. Holds nest, since two slides can overlap.
  @MainActor
  func testAHeldWrapIsReWrappedOnceWhereTheFrameLands() {
    let textView = makeHostedTextView()
    textView.setFrameSize(NSSize(width: 400, height: 300))
    // Paragraphs ending in a newline, the way every message in a transcript does.
    let paragraph = String(repeating: "word ", count: 400) + "\n"
    textView.setContent(
      NSAttributedString(
        string: paragraph + paragraph, attributes: [.font: NSFont.systemFont(ofSize: 13)]))
    let wrappedAt = textView.wrapWidth
    let height = textView.documentHeight
    var rewraps = 0
    textView.onRewrap = { rewraps += 1 }

    textView.holdWrap()
    textView.holdWrap()
    for width in stride(from: 390, through: 200, by: -10) {
      textView.setFrameSize(NSSize(width: CGFloat(width), height: 300))
    }
    XCTAssertEqual(textView.wrapWidth, wrappedAt, "held through the slide")
    XCTAssertEqual(textView.documentHeight, height)
    XCTAssertEqual(rewraps, 0)
    textView.releaseWrap()
    XCTAssertEqual(rewraps, 0, "one slide is still running")

    textView.releaseWrap()
    XCTAssertLessThan(textView.wrapWidth, wrappedAt, "wrapped to where it landed")
    XCTAssertGreaterThan(textView.documentHeight, height, "a narrower column is a taller text")
    XCTAssertEqual(rewraps, 1, "once")
  }
}
