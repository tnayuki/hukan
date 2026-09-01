import XCTest

@testable import Hukan

/// Switching the file under one text view — which is what a preview tab does all day, since the
/// slot is reused rather than respawned. The highlight of the file being left is the only trace
/// of it the view keeps, and these pin that it is taken off rather than left to be redrawn over
/// text it was never computed for.
final class HighlightSwitchTests: XCTestCase {
  /// A view standing where a preview tab's is: the previous file's colour and emphasis already
  /// on it, waiting to be replaced.
  @MainActor
  private func viewHoldingAPreviousFilesHighlight() throws -> (NSTextView, EmphasisTable, NSRange) {
    let (scrollView, textView) = makeEditorTextView()
    textView.textStorage?.setAttributedString(
      NSAttributedString(
        string: "plain **bold** here\n",
        attributes: [.font: monospace, .foregroundColor: NSColor.labelColor]))
    scrollView.layoutSubtreeIfNeeded()
    let layoutManager = try XCTUnwrap(textView.textLayoutManager)
    let table = try XCTUnwrap(layoutManager.delegate as? EmphasisTable)
    let marked = NSRange(location: 6, length: 8)
    table.spans = [(marked, .bold)]
    let contentManager = try XCTUnwrap(layoutManager.textContentManager)
    let start = contentManager.documentRange.location
    let range = try XCTUnwrap(
      NSTextRange(
        location: XCTUnwrap(contentManager.location(start, offsetBy: marked.location)),
        end: XCTUnwrap(contentManager.location(start, offsetBy: NSMaxRange(marked)))))
    layoutManager.setRenderingAttributes([.foregroundColor: NSColor.systemRed], for: range)
    return (textView, table, marked)
  }

  /// What is coloured now, as offsets — read back off the layout manager the way the draw does.
  @MainActor
  private func colouredRanges(in textView: NSTextView) -> [NSRange] {
    guard let layoutManager = textView.textLayoutManager,
      let contentManager = layoutManager.textContentManager
    else { return [] }
    var found: [NSRange] = []
    layoutManager.enumerateRenderingAttributes(
      from: contentManager.documentRange.location, reverse: false
    ) { _, attributes, range in
      guard attributes[.foregroundColor] != nil else { return true }
      let from = contentManager.offset(
        from: contentManager.documentRange.location, to: range.location)
      let to = contentManager.offset(
        from: contentManager.documentRange.location, to: range.endLocation)
      found.append(NSRange(location: from, length: to - from))
      return true
    }
    return found
  }

  /// Long enough for a parse dispatched at construction to have come back through the main
  /// queue — the whole point being that there is nothing to come back.
  @MainActor
  private func letAnyParseLand() {
    let landed = expectation(description: "a beat")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { landed.fulfill() }
    wait(for: [landed], timeout: 2)
  }

  /// A highlighter is made when the file is opened, which is before the file has been read: the
  /// buffer at that moment still holds the file being left. Parsing it there reads one file
  /// through another's grammar, and — landing after the new text does — paints that answer onto
  /// it, which is the wrong highlighting a preview switch used to show.
  @MainActor
  func testANewHighlighterDoesNotParseTheTextItInherited() throws {
    let (textView, table, marked) = try viewHoldingAPreviousFilesHighlight()
    let highlighter = SyntaxHighlighter(textView: textView, path: "b.swift")
    XCTAssertNotNil(
      highlighter, "the grammar for the new path was not found, so nothing was pinned")
    letAnyParseLand()
    XCTAssertEqual(table.spans.count, 1, "construction alone repainted the emphasis table")
    XCTAssertEqual(
      colouredRanges(in: textView), [marked], "construction alone repainted the colours")
  }

  /// The file being opened may be one no grammar covers, in which case there is no highlighter
  /// and so nothing that will ever run `apply`. Clearing has to be the text replacement's job,
  /// not the highlighter's, or the previous file's bold and colour stay on screen for good.
  @MainActor
  func testClearingTakesTheOutgoingFilesHighlightOff() throws {
    let (textView, table, _) = try viewHoldingAPreviousFilesHighlight()
    XCTAssertNil(SyntaxHighlighter(textView: textView, path: "b.txt"), "the premise moved")
    SyntaxHighlighting.clear(in: textView)
    XCTAssertTrue(table.spans.isEmpty, "the emphasis of the file that was left is still drawn")
    XCTAssertTrue(
      colouredRanges(in: textView).isEmpty, "the colours of the file that was left stayed")
  }

  /// And an explicit refresh — what the load path asks for once the text has landed — does paint,
  /// rather than waiting out the debounce that exists for typing.
  @MainActor
  func testAnExplicitRefreshPaintsTheTextThatLanded() throws {
    let (textView, table, _) = try viewHoldingAPreviousFilesHighlight()
    let highlighter = try XCTUnwrap(SyntaxHighlighter(textView: textView, path: "b.md"))
    SyntaxHighlighting.clear(in: textView)
    highlighter.refresh()
    letAnyParseLand()
    XCTAssertFalse(colouredRanges(in: textView).isEmpty, "nothing was coloured")
    XCTAssertFalse(table.spans.isEmpty, "the bold never reached the table")
  }
}
