import AppKit
import XCTest

@testable import Hukan

/// A table is drawn rather than laid out, so its cells are outside the text view's own selection
/// and the selection made against them is the table's own. These pin what a point in the drawing
/// resolves to, and what the selection copies as.
final class TableSelectionTests: XCTestCase {
  override class func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  /// A laid-out table, reached the way the view reaches it: the attachment's geometry only exists
  /// once something has asked the attachment for its bounds.
  private func table(
    _ markdown: String, width: CGFloat = 600, file: StaticString = #filePath, line: UInt = #line
  ) throws -> (attachment: TableAttachment, layout: TableLayout) {
    let (scrollView, textView) = makeTranscriptTextView()
    scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 400)
    textView.frame = NSRect(x: 0, y: 0, width: width, height: 400)
    let storage = try XCTUnwrap(textView.textStorage, file: file, line: line)
    storage.setAttributedString(Transcript.markdown(markdown))
    let layoutManager = try XCTUnwrap(textView.textLayoutManager, file: file, line: line)
    layoutManager.ensureLayout(for: layoutManager.documentRange)

    var found: TableAttachment?
    storage.enumerateAttribute(
      .attachment, in: NSRange(location: 0, length: storage.length)
    ) { value, _, stop in
      if let table = value as? TableAttachment {
        found = table
        stop.pointee = true
      }
    }
    let attachment = try XCTUnwrap(
      found, "no table in the rendered markdown", file: file, line: line)
    let layout = try XCTUnwrap(
      attachment.layout, "the table never laid out", file: file, line: line)
    return (attachment, layout)
  }

  private let sample = """
    | ファイル | 状態 |
    |---|---|
    | Sources/Transcript/TableAttachment.swift | 継続中 |
    | Model.swift | 失敗 |
    """

  func testCellsCopyAsTabSeparatedRowsUnderTheHeader() throws {
    let (attachment, _) = try table(sample)
    attachment.selection = .block(TableCellBlock(rows: 1...1, columns: 0...1))
    XCTAssertEqual(
      attachment.selectedText(), "ファイル\t状態\nSources/Transcript/TableAttachment.swift\t継続中")
  }

  /// The header names what the rows are, so a drag that never touched it still copies it.
  func testTheHeaderComesAlongEvenWhenTheDragStartedBelowIt() throws {
    let (attachment, _) = try table(sample)
    attachment.selection = .block(TableCellBlock(rows: 2...2, columns: 1...1))
    XCTAssertEqual(attachment.selectedText(), "状態\n失敗")
  }

  func testASelectionInsideOneCellCopiesJustThatText() throws {
    let (attachment, _) = try table(sample)
    attachment.selection = .text(
      TableTextSpan(
        start: TableCellPosition(row: 2, column: 0, character: 0),
        end: TableCellPosition(row: 2, column: 0, character: 5)))
    XCTAssertEqual(attachment.selectedText(), "Model")
    XCTAssertFalse(attachment.selectionSpansCells, "a piece of one cell is not a table")
  }

  /// The double-click unit is hukan's token rule, not AppKit's — which breaks a path at every
  /// slash, and on a line with any Japanese on it at every change of character class.
  func testADoubleClickTakesAWholePath() throws {
    let (_, layout) = try table(sample)
    let cell = try XCTUnwrap(layout.text(row: 1, column: 0))
    let word = cell.wordRange(at: 12)
    XCTAssertEqual(cell.substring(word), "Sources/Transcript/TableAttachment.swift")
  }

  func testAPointResolvesToTheCellItIsDrawnIn() throws {
    let (_, layout) = try table(sample)
    for row in 0..<layout.rowCount {
      for column in 0..<layout.columnCount {
        let origin = layout.cellOrigin(row: row, column: column)
        let position = layout.position(at: CGPoint(x: origin.x + 2, y: origin.y + 2))
        XCTAssertEqual(position?.row, row)
        XCTAssertEqual(position?.column, column)
      }
    }
  }

  /// A relayout at a new width builds new cells, so a selection made against the old ones names
  /// nothing and has to go rather than land somewhere else.
  func testAWidthChangeDropsTheSelection() throws {
    let (attachment, _) = try table(sample)
    attachment.selection = .block(TableCellBlock(rows: 1...1, columns: 0...1))
    let container = NSTextContainer(
      size: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
    _ = attachment.attachmentBounds(
      for: [:], location: NSTextLocationStub(), textContainer: container,
      proposedLineFragment: CGRect(x: 0, y: 0, width: 320, height: 20), position: .zero)
    XCTAssertNil(attachment.selection)
  }
}

/// `attachmentBounds` wants a location it never reads.
private final class NSTextLocationStub: NSObject, NSTextLocation {
  func compare(_ location: any NSTextLocation) -> ComparisonResult { .orderedSame }
}
