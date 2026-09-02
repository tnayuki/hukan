import XCTest

@testable import Hukan

/// The band behind a patch's rows, on the way from the grammar to the pane.
///
/// What a band costs is a rendering surface that reaches past the row's own text, which is what
/// the transcript's fragment does to every paragraph and what the editor was built not to. So
/// the two halves worth pinning are that a patch gets one and that every other file does not.
final class PatchBandTests: XCTestCase {
  private let patch = """
    diff --git a/a.swift b/a.swift
    index 1111111..2222222 100644
    --- a/a.swift
    +++ b/a.swift
    @@ -1,3 +1,3 @@
     func f() -> Int {
    -  let gone = "old"
    +  let added = "new"
     }
    """

  /// The rows the grammar bands are the changed ones and the two file headers — never a context
  /// row, which is in both files and is what the reader is meant to see straight through.
  func testOnlyTheRowsThatChangedAreBanded() {
    let text = patch as NSString
    let bands = SyntaxHighlighting.highlight(in: patch, forPath: "a.diff").bands
    let banded = bands.map { text.substring(with: $0.range) }
    XCTAssertTrue(banded.contains { $0.hasPrefix("+  let added") }, "the added row has no band")
    XCTAssertTrue(banded.contains { $0.hasPrefix("-  let gone") }, "the removed row has no band")
    XCTAssertTrue(banded.contains { $0.hasPrefix("+++ ") }, "the new file's header has no band")
    XCTAssertTrue(banded.contains { $0.hasPrefix("--- ") }, "the old file's header has no band")
    XCTAssertFalse(
      banded.contains { $0.contains("func f()") }, "a context row was banded")
    XCTAssertFalse(banded.contains { $0.hasPrefix("@@") }, "the hunk's location was banded")
  }

  /// The two sides in the commit tab's own colours, so one window does not read a diff two ways.
  func testTheBandsAreTheColoursACommitReadsIn() {
    let text = patch as NSString
    for band in SyntaxHighlighting.highlight(in: patch, forPath: "a.diff").bands {
      let row = text.substring(with: band.range)
      if row.hasPrefix("+") {
        XCTAssertEqual(band.color, CommitTheme.addedBand, "\(row)")
      } else if row.hasPrefix("-") {
        XCTAssertEqual(band.color, CommitTheme.removedBand, "\(row)")
      }
    }
  }

  /// A band cannot come out of the text, so it never reaches the tokens: the row keeps the
  /// colours of the language it is a patch of, which is the whole reason it is a band.
  func testABandedRowKeepsItsOwnSyntaxColours() {
    let text = patch as NSString
    let read = SyntaxHighlighting.highlight(in: patch, forPath: "a.diff")
    let added = text.range(of: "+  let added")
    let onTheAddedRow = read.spans.filter { NSIntersectionRange($0.range, added).length > 0 }
    XCTAssertTrue(
      onTheAddedRow.contains { text.substring(with: $0.range) == "let" },
      "the added row's keyword was not coloured as Swift")
    XCTAssertFalse(
      onTheAddedRow.contains { $0.color == CommitTheme.addedBand },
      "the band leaked into the row's foreground")
  }

  /// Only a file with bands pays for the reach. A patch's fragments have to widen — the band
  /// spans the view, not the row — and a source file's must stay exactly what the stock layout
  /// measured, or every editor pane pays for a case that only a patch has.
  @MainActor
  func testOnlyAPatchsFragmentsReachPastTheirText() throws {
    for (path, source, wider) in [
      ("a.diff", patch, true), ("a.swift", "let x = 1\nlet y = 2\n", false),
    ] {
      let (scrollView, textView) = makeEditorTextView()
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: .borderless,
        backing: .buffered, defer: false)
      window.contentView = scrollView
      textView.textStorage?.setAttributedString(
        NSAttributedString(string: source, attributes: [.font: monospace]))
      scrollView.layoutSubtreeIfNeeded()

      let layoutManager = try XCTUnwrap(textView.textLayoutManager)
      let table = try XCTUnwrap(layoutManager.delegate as? EmphasisTable)
      table.bands = SyntaxHighlighting.highlight(in: source, forPath: path).bands
      XCTAssertEqual(!table.bands.isEmpty, wider, "\(path): the wrong file has bands")
      layoutManager.ensureLayout(for: layoutManager.documentRange)

      // The same fragments measured twice, with the table's bands and without: the stock surface
      // is whatever the layout made of the text, so what is being asked is only whether a band
      // widens it — not how wide either answer is.
      var widened = false
      layoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) {
        fragment in
        let banded = fragment.renderingSurfaceBounds
        let bands = table.bands
        table.bands = []
        if banded.width > fragment.renderingSurfaceBounds.width { widened = true }
        table.bands = bands
        return true
      }
      XCTAssertEqual(widened, wider, "\(path): the fragments' reach is wrong for this file")
    }
  }
}
