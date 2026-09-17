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
    let placed = try placedTable(markdown, width: width, file: file, line: line)
    return (placed.attachment, placed.layout)
  }

  /// The same table with the view it is in and the attachment's place in the storage — what a
  /// click has to be handed.
  private func placedTable(
    _ markdown: String, width: CGFloat = 600, file: StaticString = #filePath, line: UInt = #line
  ) throws -> (
    textView: TranscriptDocumentView, attachment: TableAttachment, layout: TableLayout,
    offset: Int
  ) {
    let (scrollView, textView) = makeTranscriptDocumentView()
    scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 400)
    textView.frame = NSRect(x: 0, y: 0, width: width, height: 400)
    textView.setContent(Transcript.markdown(markdown))

    var found: (table: TableAttachment, offset: Int)?
    textView.enumerateAttribute(.attachment) { value, range, stop in
      if let table = value as? TableAttachment {
        found = (table, range.location)
        stop.pointee = true
      }
    }
    let hit = try XCTUnwrap(found, "no table in the rendered markdown", file: file, line: line)
    let layout = try XCTUnwrap(
      hit.table.layout, "the table never laid out", file: file, line: line)
    return (textView, hit.table, layout, hit.offset)
  }

  private let sample = """
    | ファイル | 状態 |
    |---|---|
    | Sources/Transcript/TableAttachment.swift | 継続中 |
    | Model.swift | 失敗 |
    """

  /// A cell full of URLs, in a column wide enough that there is empty space beside the short one.
  private let linked = """
    | a header wide enough to leave room | 状態 |
    |---|---|
    | https://example.com/a | 継続中 |
    """

  /// Where those clicks land in the cell: the character the press resolved to.
  private let pressed = TableCellPosition(row: 1, column: 0, character: 3)

  /// The table-local point at the middle of a cell's glyphs.
  private func middleOfCell(_ layout: TableLayout, row: Int, column: Int) throws -> CGPoint {
    let cell = try XCTUnwrap(layout.text(row: row, column: column))
    let rect = try XCTUnwrap(cell.rects(for: NSRange(location: 0, length: cell.length)).first)
    let origin = layout.cellOrigin(row: row, column: column)
    return CGPoint(x: origin.x + rect.midX, y: origin.y + rect.midY)
  }

  /// A link in a cell is a link: the cells are built by the same `Transcript.styled` the prose is,
  /// and the drawing is the only thing standing between the click and the `.link` run.
  func testALinkInACellIsFoundUnderThePoint() throws {
    let (_, layout) = try table(linked)
    XCTAssertEqual(
      layout.link(at: try middleOfCell(layout, row: 1, column: 0)),
      URL(string: "https://example.com/a"))
  }

  func testTextThatIsNotALinkAnswersNothing() throws {
    let (_, layout) = try table(linked)
    XCTAssertNil(layout.link(at: try middleOfCell(layout, row: 1, column: 1)))
  }

  /// The empty half of a wide cell is not the link beside it. `column(at:)` answers with the
  /// nearest column rather than the containing one — dead ground in the middle of a drag is worse
  /// than a slightly generous cell — so it is the glyph hit that has to be exact.
  func testThePointMustBeOnTheGlyphs() throws {
    let (_, layout) = try table(linked)
    let cell = try XCTUnwrap(layout.text(row: 1, column: 0))
    let rect = try XCTUnwrap(cell.rects(for: NSRange(location: 0, length: cell.length)).first)
    let origin = layout.cellOrigin(row: 1, column: 0)
    let column = layout.columns[0]
    XCTAssertGreaterThan(
      column.width, rect.maxX + 4, "the fixture needs room to the right of the link")
    XCTAssertNil(layout.link(at: CGPoint(x: column.x + column.width - 2, y: origin.y + rect.midY)))
  }

  /// A press on `point`, in the view's coordinates, with the modifiers a real one would carry.
  private func click(at point: CGPoint, clickCount: Int = 1, shift: Bool = false) throws -> NSEvent
  {
    try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: point, modifierFlags: shift ? [.shift] : [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
        eventNumber: 0, clickCount: clickCount, pressure: 1))
  }

  /// The click that follows a link in a cell, posed as the drag leaves it: an empty span on the
  /// character that was pressed. The URL leaves through the delegate every other link leaves
  /// through, so a web tab or Safari under ⌘ is one decision made in one place.
  func testAClickOnALinkInACellFollowsIt() throws {
    let placed = try placedTable(linked)
    var opened: [URL] = []
    placed.textView.onOpenURL = {
      opened.append($0)
      return true
    }
    let point = try middleOfCell(placed.layout, row: 1, column: 0)
    placed.attachment.selection = .text(TableTextSpan(start: pressed, end: pressed))
    placed.textView.followTableLink(
      at: point, in: placed.attachment, offset: placed.offset, event: try click(at: point))
    XCTAssertEqual(opened, [try XCTUnwrap(URL(string: "https://example.com/a"))])
  }

  /// A drag that started on a link selects it rather than following it — which is why the
  /// question is asked after the tracking loop and not on the way in.
  func testADragThatStartedOnALinkSelectsInstead() throws {
    let placed = try placedTable(linked)
    var opened: [URL] = []
    placed.textView.onOpenURL = {
      opened.append($0)
      return true
    }
    let point = try middleOfCell(placed.layout, row: 1, column: 0)
    placed.attachment.selection = .text(
      TableTextSpan(start: pressed, end: TableCellPosition(row: 1, column: 0, character: 8)))
    placed.textView.followTableLink(
      at: point, in: placed.attachment, offset: placed.offset, event: try click(at: point))
    XCTAssertEqual(opened, [], "a selection is not a click")
  }

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
