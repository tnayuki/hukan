import XCTest

@testable import Hukan

/// The window the editor's highlighter aims at, and the way it stops being one. Colour arrives
/// for what is on screen first, and the rest of the file follows on its own — so a reader who
/// scrolls finds it already coloured rather than starting a query and waiting for one.
final class HighlightWindowTests: XCTestCase {
  /// Long enough to need several steps of the fill: the first window is a screenful plus 4000
  /// either side, and each step reaches 40,000 further.
  private let source = String(
    repeating: """
      /// A comment about the window.
      func work(_ name: String) -> Int {
        let greeting = "hello \\(name), how are you"
        return greeting.count  // counted
      }

      """, count: 700)

  @MainActor
  private func editor() -> (NSWindow, NSTextView) {
    let (scrollView, textView) = makeEditorTextView()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.contentView = scrollView
    textView.textStorage?.setAttributedString(
      NSAttributedString(string: source, attributes: [.font: monospace]))
    scrollView.layoutSubtreeIfNeeded()
    return (window, textView)
  }

  /// How far into the document anything has been coloured, in UTF-16 offsets.
  @MainActor
  private func colouredUpTo(_ textView: NSTextView) -> Int {
    guard let layoutManager = textView.textLayoutManager,
      let contentManager = layoutManager.textContentManager
    else { return 0 }
    let start = contentManager.documentRange.location
    var reached = 0
    layoutManager.enumerateRenderingAttributes(from: start, reverse: false) {
      _, attributes, range in
      if attributes[.foregroundColor] != nil {
        reached = max(reached, contentManager.offset(from: start, to: range.endLocation))
      }
      return true
    }
    return reached
  }

  /// Nothing here scrolls: the far end of the file is coloured because the fill walked out to
  /// it, which is the whole point — the alternative is a query that starts when the reader
  /// arrives and is not finished by the time they are looking.
  @MainActor
  func testTheFarEndIsColouredWithoutScrolling() throws {
    let (window, textView) = editor()
    _ = window
    let length = (source as NSString).length
    // Past the first window plus one step, so the fill has to come round more than once.
    XCTAssertGreaterThan(length, 100_000, "the file is not long enough to need a fill")
    let highlighter = try XCTUnwrap(SyntaxHighlighter(textView: textView, path: "a.swift"))
    highlighter.refresh()

    // A `func` near the very end of the file — nothing reads that far in one window.
    let tail = (source as NSString).range(
      of: "func", options: .backwards, range: NSRange(location: 0, length: length))
    let reached = expectation(description: "the fill reached the end of the file")
    var polls = 0
    func poll() {
      polls += 1
      if colouredUpTo(textView) > tail.location {
        reached.fulfill()
      } else if polls < 200 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
      }
    }
    poll()
    wait(for: [reached], timeout: 25)
  }
}
