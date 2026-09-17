import AppKit
import XCTest

@testable import Hukan

/// Colours handed to TextKit have to reach the screen. A TextKit 2 text view draws its text in
/// subviews of its own, one per run of fragments, and setting rendering attributes does not mark
/// those dirty — so a highlight could sit finished in the layout manager for most of a second,
/// until something unrelated happened to redraw the pane.
///
/// Asserted by counting draws, because nothing else can see it: the attributes are there either
/// way, and the view's own dirty flags are not readable on layer-backed views.
final class HighlightRedrawTests: XCTestCase {
  private let source = String(
    repeating: """
      /// A comment.
      func work(_ name: String) -> Int {
        let greeting = "hello \\(name)"
        return greeting.count
      }

      """, count: 40)

  @MainActor
  private func isColoured(_ textView: NSTextView) -> Bool {
    guard let layoutManager = textView.textLayoutManager,
      let contentManager = layoutManager.textContentManager
    else { return false }
    var found = false
    layoutManager.enumerateRenderingAttributes(
      from: contentManager.documentRange.location, reverse: false
    ) { _, attributes, _ in
      if attributes[.foregroundColor] != nil { found = true }
      return !found
    }
    return found
  }

  @MainActor
  private func spin(_ seconds: TimeInterval, until condition: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }

  @MainActor
  func testColoursAreDrawnAsSoonAsTheyLand() throws {
    let (scrollView, textView) = makeEditorTextView()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scrollView
    // On screen, since a window that is never ordered in is never displayed by the run loop —
    // which would pass the broken arrangement as readily as the working one.
    window.orderFrontRegardless()
    defer { window.close() }
    textView.textStorage?.setAttributedString(
      NSAttributedString(string: source, attributes: [.font: monospace]))
    // The plain text, drawn and settled: what the reader sees before any colour.
    spin(0.5)
    let beforeColour = EmphasisFragment.drawsPerformed

    let highlighter = try XCTUnwrap(SyntaxHighlighter(textView: textView, path: "a.swift"))
    highlighter.refresh()
    spin(10, until: { self.isColoured(textView) })
    XCTAssertTrue(isColoured(textView), "the colours landed")
    // A few frames. Before the fix nothing here redrew the pane at all, and in the app the colours
    // waited 450–750ms for something unrelated to do it.
    spin(0.15)
    XCTAssertGreaterThan(
      EmphasisFragment.drawsPerformed, beforeColour,
      "and the text was drawn again to show them")
  }
}
