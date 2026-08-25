import XCTest

@testable import Hukan

/// Where a wheel event over a card's diff goes.
///
/// A card's diff has its own scroll view so a long line can be scrolled sideways, and that view
/// is handed the gesture first — which is how scrolling over a diff came to do nothing at all.
/// What is checked here is the routing, not the scrolling: a synthesized wheel event does not
/// drive `NSScrollView` even when it is sent straight to one (measured: the clip view does not
/// move), so AppKit's half has to be checked by hand.
final class CommitScrollTests: XCTestCase {
  /// Counts the wheel events that reach it — standing in for the tab's own scroll view.
  private final class ScrollSpy: NSView {
    var received = 0
    override func scrollWheel(with event: NSEvent) { received += 1 }
  }

  @MainActor
  func testAVerticalWheelOverADiffGoesToTheTabAndAHorizontalOneStays() throws {
    let file = Git.CommitFile(
      path: "a.swift", oldPath: nil, status: .modified, added: 3, removed: 0, isBinary: false)
    let long = String(repeating: "wide ", count: 60)
    let diff = Git.FileDiff(
      rows: (1...3).map { .line(old: $0, new: $0, kind: .context, text: "\(long)\($0)") },
      note: nil, newSource: nil, oldSource: nil)
    let body = CommitDiffBodyView(diff: CommitDiffLoader.render(diff, file: file))

    let spy = ScrollSpy(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    body.translatesAutoresizingMaskIntoConstraints = false
    spy.addSubview(body)
    NSLayoutConstraint.activate([
      body.leadingAnchor.constraint(equalTo: spy.leadingAnchor),
      body.trailingAnchor.constraint(equalTo: spy.trailingAnchor),
      body.topAnchor.constraint(equalTo: spy.topAnchor),
    ])
    let window = NSWindow(
      contentRect: spy.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = spy
    spy.layoutSubtreeIfNeeded()

    let scrollView = try XCTUnwrap(body.subviews.compactMap { $0 as? NSScrollView }.first)
    let document = try XCTUnwrap(scrollView.documentView)
    XCTAssertEqual(
      document.frame.height, scrollView.contentView.bounds.height, accuracy: 0.5,
      "the card is as tall as its rows, so there is no vertical range to spend")
    XCTAssertGreaterThan(
      document.frame.width, scrollView.contentView.bounds.width,
      "and a long line is what makes the inner view take the gesture in the first place")

    scrollView.scrollWheel(with: try wheel(deltaY: -40, deltaX: 0))
    XCTAssertEqual(spy.received, 1, "a vertical wheel is passed on to what encloses the card")

    scrollView.scrollWheel(with: try wheel(deltaY: 0, deltaX: -40))
    XCTAssertEqual(spy.received, 1, "a horizontal one is the card's own, and stays")
  }

  @MainActor
  private func wheel(deltaY: Int32, deltaX: Int32) throws -> NSEvent {
    let event = CGEvent(
      scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: deltaY, wheel2: deltaX,
      wheel3: 0)
    return try XCTUnwrap(event.flatMap { NSEvent(cgEvent: $0) })
  }
}
