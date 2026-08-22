import XCTest

@testable import Hukan

/// A width change has to invalidate the whole transcript view. It draws no background of its own
/// but is layer-backed anyway, so TextKit 2's fragment-by-fragment redraw leaves the previous
/// wrapping on the layer underneath the new one unless the view is marked dirty outright.
final class TranscriptRewrapTests: XCTestCase {
  /// In a real (never shown) window: AppKit drops an invalidation on a view with no window, so
  /// `needsDisplay` would read back false however it was set.
  @MainActor
  private func makeHostedTextView() -> NSTextView {
    let (scrollView, textView) = makeTranscriptTextView()
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
}
