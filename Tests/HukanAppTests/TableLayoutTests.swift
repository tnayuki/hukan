import AppKit
import XCTest

@testable import Hukan

/// A table is drawn into an image its own `size` wide, so a column laid out past that edge is not
/// merely wide — everything past the edge is clipped away, which is what a reader sees as a column
/// cut in half. These pin the widths against the pane rather than the look, which the snapshots
/// hold.
final class TableLayoutTests: XCTestCase {
  private func cell(_ text: String) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    return NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        .paragraphStyle: paragraph,
      ])
  }

  private func assertFits(_ layout: TableLayout, file: StaticString = #filePath, line: UInt = #line)
  {
    guard let last = layout.columns.last else {
      return XCTFail("no columns", file: file, line: line)
    }
    XCTAssertLessThanOrEqual(
      last.x + last.width, layout.size.width + 0.5, "the last column runs off the table",
      file: file, line: line)
  }

  /// The shape from the report: a column of paths beside a column holding identifiers of its own,
  /// in a pane narrower than the two together. Neither column's widest token can be kept whole, and
  /// honouring both is what used to lay the second one out past the table's own edge.
  func testColumnsWithUnbreakableTokensStayInsideThePane() {
    let layout = TableLayout(
      header: [cell("ファイル"), cell("中身")],
      rows: [
        [
          cell("Tests/HukanAppTests/TerminalSessionTests.swift"),
          cell("タブ名を Terminal.app の規則に変更。refreshForegroundCommands を追加"),
        ],
        [cell("Sources/Hukan/WorkspaceWindow.swift"), cell("そのタイマー")],
      ],
      available: 420)
    assertFits(layout)
    XCTAssertLessThanOrEqual(layout.size.width, 420)
  }

  /// A pane too narrow for even one column's token: the budget is still all there is to share.
  func testAPaneNarrowerThanASingleTokenStillFits() {
    let layout = TableLayout(
      header: [cell("path"), cell("note")],
      rows: [[cell("Sources/Hukan/WorkspaceWindow.swift"), cell("refreshForegroundCommands")]],
      available: 160)
    assertFits(layout)
  }

  /// With room to spare nothing is squeezed: each column keeps its natural width and the table is
  /// only as wide as it needs to be.
  func testTableThatFitsKeepsItsNaturalWidths() {
    let path = cell("Tests/HukanAppTests/TerminalSessionTests.swift")
    let layout = TableLayout(
      header: [cell("ファイル"), cell("中身")], rows: [[path, cell("短い")]], available: 900)
    assertFits(layout)
    XCTAssertEqual(layout.columns[0].width, ceil(path.size().width), accuracy: 0.5)
    XCTAssertLessThan(layout.size.width, 900)
  }

  /// A wide column beside a narrow one still gives the narrow one only what it needs — the fill
  /// hands back what a column does not use rather than splitting the pane down the middle.
  func testAShortColumnKeepsItsNaturalWidthBesideAWideOne() {
    let short = cell("状態")
    let layout = TableLayout(
      header: [cell("説明"), short],
      rows: [[cell(String(repeating: "long enough to wrap several times ", count: 6)), cell("済")]],
      available: 400)
    assertFits(layout)
    XCTAssertEqual(layout.columns[1].width, ceil(short.size().width), accuracy: 0.5)
  }
}
