import XCTest

@testable import Hukan

/// Where the editor's first column lands, and what keeps it there.
///
/// AppKit reserves the ruler's strip on its own — `contentSize` loses `ruleThickness` and the
/// clip view's bounds are seeded that far left — so the arithmetic that matters is one sum:
/// `clip.frame.minX - clip.bounds.origin.x`, where the document's x=0 shows up. Reserving the
/// strip a second time by moving the clip view's frame made that sum come to twice the gutter's
/// width, which read as a gap between the numbers and the line they belong to.
final class EditorGutterLayoutTests: XCTestCase {
  /// The editor stack in a real (never shown) window, built the way a file tab builds it: the
  /// pane first, the gutter next, the file's text last.
  @MainActor
  private func makeStack(_ source: String) -> (NSScrollView, NSTextView, EditorGutter) {
    let (scrollView, textView) = makeEditorTextView()
    let gutter = EditorGutter(scrollView: scrollView, textView: textView)
    gutter.backgroundColor = .windowBackgroundColor
    scrollView.verticalRulerView = gutter
    scrollView.hasVerticalRuler = true
    scrollView.rulersVisible = true

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView()
    container.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: container.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.contentView = container
    container.layoutSubtreeIfNeeded()

    textView.textStorage?.setAttributedString(
      NSAttributedString(
        string: source,
        attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
    // The gutter re-measures itself a turn of the run loop after the text lands, so the digit
    // count (and with it the strip's width) is only right once that has run.
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    container.layoutSubtreeIfNeeded()
    return (scrollView, textView, gutter)
  }

  /// Where the document's leading edge lands within the scroll view.
  @MainActor
  private func firstColumn(_ scrollView: NSScrollView) -> CGFloat {
    scrollView.contentView.frame.minX - scrollView.contentView.bounds.origin.x
  }

  private static let short = "one\ntwo\nthree\n"
  private static let long = String(repeating: "abcdefghij", count: 40)

  /// The text begins exactly where the gutter ends — once, not twice.
  @MainActor
  func testTextStartsAtTheGutterEdge() {
    let (scrollView, _, gutter) = makeStack(Self.long)
    XCTAssertGreaterThan(gutter.ruleThickness, 0)
    XCTAssertEqual(firstColumn(scrollView), gutter.ruleThickness, accuracy: 0.5)
  }

  /// The regression: a file with no line long enough to fill the pane. Taking the strip out of
  /// the content width twice left the document narrower than the clip view, and AppKit pinned
  /// the bounds to hold that too-narrow document — pushing the text a whole gutter to the right.
  @MainActor
  func testAFileNarrowerThanThePaneStartsThereToo() {
    let (scrollView, _, gutter) = makeStack(Self.short)
    XCTAssertLessThan(
      scrollView.documentView!.frame.width, scrollView.contentView.bounds.width + 0.5,
      "the fixture has to be narrower than the pane for this to be the case it is")
    XCTAssertEqual(firstColumn(scrollView), gutter.ruleThickness, accuracy: 0.5)
  }

  /// Scrolled sideways, the line runs under the strip — AppKit's clip view keeps the full width —
  /// so the gutter is the one view on the desk that paints, and paints over it.
  @MainActor
  func testTheGutterPaintsSoScrolledTextCannotShowThroughIt() {
    let (scrollView, _, gutter) = makeStack(Self.long)
    scrollView.contentView.scroll(to: NSPoint(x: 200, y: 0))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    XCTAssertEqual(scrollView.contentView.bounds.origin.x, 200, accuracy: 0.5)
    XCTAssertNotNil(gutter.backgroundColor)
  }

  /// Opening a file scrolls to its leading edge, and under a ruler that edge is not x = 0 —
  /// that is a gutter's width to the right, with the first characters of every line hidden under
  /// the numbers. The helper asks the clip view where its leftmost actually is.
  @MainActor
  func testScrollingToTheLeadingEdgeIsNotScrollingToZero() {
    let (scrollView, _, gutter) = makeStack(Self.long)
    // What the open path used to do, and what it hides.
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    XCTAssertEqual(firstColumn(scrollView), 0, accuracy: 0.5, "x = 0 puts the text under the strip")

    scrollView.scrollToLeadingEdge(y: 0)
    XCTAssertEqual(firstColumn(scrollView), gutter.ruleThickness, accuracy: 0.5)
  }

  /// The gutter grows a digit *after* the text has landed — a file of a hundred lines and more
  /// only needs three once it is read — and the leading edge moves left with it. A view already
  /// sitting at that edge has to follow, or it is left a digit's width to the right of it with
  /// the first character of every line under the numbers.
  @MainActor
  func testTheLeadingEdgeFollowsAGutterThatGrowsAfterTheFileLands() {
    let (scrollView, textView) = makeEditorTextView()
    let gutter = EditorGutter(scrollView: scrollView, textView: textView)
    gutter.backgroundColor = .windowBackgroundColor
    scrollView.verticalRulerView = gutter
    scrollView.hasVerticalRuler = true
    scrollView.rulersVisible = true
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.contentView = scrollView
    scrollView.layoutSubtreeIfNeeded()
    let narrow = gutter.ruleThickness

    // Two digits' worth of gutter while the pane is empty, then a file that needs three.
    textView.textStorage?.setAttributedString(
      NSAttributedString(
        string: (1...220).map { "line \($0) " + Self.long }.joined(separator: "\n"),
        attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
    scrollView.layoutSubtreeIfNeeded()
    scrollView.scrollToLeadingEdge(y: 0)
    XCTAssertEqual(firstColumn(scrollView), narrow, accuracy: 0.5)

    // The gutter re-measures a turn of the loop later, which is where the edge moves.
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertGreaterThan(gutter.ruleThickness, narrow, "the fixture never grew a digit")
    XCTAssertEqual(
      firstColumn(scrollView), gutter.ruleThickness, accuracy: 0.5,
      "the text stayed at the old edge, under the numbers")
  }

  /// A file whose line count needs another digit widens the gutter after the pane is already
  /// laid out, and the text has to move over with it.
  @MainActor
  func testTheFirstColumnFollowsAGutterThatWidensOnLoad() {
    let (scrollView, _, gutter) = makeStack(Self.short)
    let narrow = gutter.ruleThickness
    let (wideScroll, _, wideGutter) = makeStack(
      (1...220).map { "line \($0)" }.joined(separator: "\n"))
    XCTAssertGreaterThan(wideGutter.ruleThickness, narrow)
    XCTAssertEqual(firstColumn(wideScroll), wideGutter.ruleThickness, accuracy: 0.5)
    _ = scrollView
  }
}
