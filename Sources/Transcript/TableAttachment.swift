import AppKit

/// A table drawn to fit the pane it lands in. GFM tables were laid out as tab-stopped monospace
/// rows, which line up perfectly until the table is wider than the transcript pane — then every
/// row wraps at the container edge and the columns fall apart. The width the row has to fit is
/// only known at layout time (the pane can resize, and nothing re-runs the markdown), so the
/// table is an attachment: `attachmentBounds` reads the live container width, wraps each cell
/// within its column, and reports the height that needs; the image redraws at that width, in the
/// current scale and appearance, whenever the width changes.
///
/// Drawing rather than laying out real text puts the cells outside the text view's own selection:
/// the whole table is one attachment character, so a range in the storage cannot name a cell. Two
/// things stand in for that. A selection that covers the attachment copies as the table's
/// `markdown` rather than as the `￼` an attachment character copies as (see
/// `TranscriptTextView.writeSelection`), and the table carries a selection of its own — see
/// `TableSelection` and the geometry below, which is what the view drags against.
final class TableAttachment: NSTextAttachment {
  private let header: [NSAttributedString]
  private let rows: [[NSAttributedString]]
  /// The table's own markdown, so a copied selection expands the attachment back to text rather
  /// than the `￼` an attachment character copies as. `TranscriptTextView.writeSelection` reads it.
  let markdown: String
  /// The width the current `image` was drawn for, so a relayout at the same width reuses it
  /// instead of re-rasterising (`attachmentBounds` fires more than once per width).
  private var renderedWidth: CGFloat = -1
  /// The geometry the current `image` was drawn from, which is what a click is measured against.
  private(set) var layout: TableLayout?
  /// What is selected inside this table. Held here rather than in the view because it belongs to
  /// the table the way a text selection belongs to the storage — and because a width change
  /// relays the cells out, which is where it has to be dropped.
  var selection: TableSelection?

  init(header: [NSAttributedString], rows: [[NSAttributedString]], markdown: String) {
    self.header = header
    self.rows = rows
    self.markdown = markdown
    super.init(data: nil, ofType: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func attachmentBounds(
    for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
    textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, position: CGPoint
  ) -> CGRect {
    let available = Self.availableWidth(textContainer, proposedLineFragment: lineFrag)
    if abs(available - renderedWidth) > 0.5 || image == nil || layout == nil {
      let built = TableLayout(header: header, rows: rows, available: available)
      layout = built
      renderedWidth = available
      // The cells were laid out again, so a selection made against the old ones names nothing.
      selection = nil
      image = NSImage(size: built.size, flipped: true) { _ in
        built.draw()
        return true
      }
    }
    guard let layout else { return .zero }
    return CGRect(x: 0, y: 0, width: layout.size.width, height: layout.size.height)
  }

  /// What the selection copies as: the cells as tab-separated rows, header included, or the plain
  /// substring when the selection stayed inside one cell.
  ///
  /// Tabs rather than the `markdown` a whole-attachment copy yields, because a table lifted out of
  /// a transcript on its own is going somewhere that reads tabs — Slack builds a real table out of
  /// tab-separated text and out of nothing else, and a spreadsheet takes it as cells. The text is
  /// the cells as they read on screen, not the source they were written in: `**bold**` is markup
  /// the destination has no use for.
  /// True while the selection names whole cells — a copy of it is a table, where a copy of a
  /// selection inside one cell is only a piece of text.
  var selectionSpansCells: Bool {
    if case .block = selection { return true }
    return false
  }

  func selectedText() -> String? {
    guard let selection, let layout else { return nil }
    if case .text(let span) = selection {
      guard !span.isEmpty else { return nil }
      if span.start.row == span.end.row, span.start.column == span.end.column {
        return layout.text(row: span.start.row, column: span.start.column)?
          .substring(
            NSRange(
              location: span.start.character, length: span.end.character - span.start.character))
      }
    }
    guard let block = selectedBlock() else { return nil }
    let rows = block.rows.clamped(to: 0...(layout.rowCount - 1))
    let columns = block.columns.clamped(to: 0...(layout.columnCount - 1))
    // The header names what the rows are, so it comes along even when the drag started below it.
    let indices = rows.contains(0) ? Array(rows) : [0] + Array(rows)
    return indices.map { row in
      columns.map { layout.text(row: row, column: $0)?.string ?? "" }.joined(separator: "\t")
    }
    .joined(separator: "\n")
  }

  /// The cells a selection covers, or nil when it named no whole cell. A text span that crossed a
  /// cell boundary has already been turned into a block by the drag, so the only span left here
  /// is one inside a single cell.
  private func selectedBlock() -> TableCellBlock? {
    switch selection {
    case .block(let block): return block
    case .text, nil: return nil
    }
  }

  /// The width a full-bleed block gets: the container's, less the line-fragment padding on each
  /// side. Falls back to the proposed fragment when there is no container (rare).
  private static func availableWidth(_ container: NSTextContainer?, proposedLineFragment: CGRect)
    -> CGFloat
  {
    if let container {
      let usable = container.size.width - container.lineFragmentPadding * 2
      if usable > 1 { return floor(usable) }
    }
    return max(1, proposedLineFragment.width)
  }
}

/// The measured geometry of one table at a fixed width, and the drawing that fills it. Built fresh
/// each time the width changes; holds no view state, so it can be captured by an image's drawing
/// handler and run at whatever scale and appearance the draw happens in.
final class TableLayout {
  /// Header row first, then body rows — one array so fills and heights index uniformly.
  private let cells: [[NSAttributedString]]
  /// Each column's left edge and width inside the image. Readable so a test can check that the
  /// last column's right edge lands within `size` — the overflow is invisible in a drawing.
  let columns: [(x: CGFloat, width: CGFloat)]
  /// Readable for the same reason `columns` is: the geometry a click is resolved against.
  let rowHeights: [CGFloat]
  let size: CGSize

  private let indent: CGFloat = 12
  private let gap: CGFloat = 16
  private let vPad: CGFloat = 6
  private let radius: CGFloat = 6

  // Matches the former tab-stop table: a stronger header wash above two alternating body washes,
  // the row seam carried by the shade change, and one hairline weight for the header rule and the
  // outer frame.
  private let headerFill = NSColor.tertiarySystemFill
  private static let rowFill = NSColor.quaternarySystemFill.withDynamicAlpha(0.25)
  private static let altRowFill = NSColor.quaternarySystemFill.withDynamicAlpha(0.45)
  private let ruleColor = NSColor.separatorColor

  init(header: [NSAttributedString], rows: [[NSAttributedString]], available: CGFloat) {
    var all = [header]
    all.append(contentsOf: rows)
    cells = all

    let columnCount = header.count
    var natural = [CGFloat](repeating: 0, count: columnCount)
    var floors = [CGFloat](repeating: 0, count: columnCount)
    for row in all {
      for column in 0..<columnCount where column < row.count {
        natural[column] = max(natural[column], ceil(row[column].size().width))
        floors[column] = max(floors[column], TableLayout.minContentWidth(row[column]))
      }
    }

    let gaps = gap * CGFloat(max(0, columnCount - 1))
    let budget = max(1, available - indent * 2 - gaps)
    let widths = TableLayout.fit(natural, floors: floors, budget: budget)

    var placed: [(x: CGFloat, width: CGFloat)] = []
    var x = indent
    for column in 0..<columnCount {
      placed.append((x: x, width: widths[column]))
      x += widths[column] + gap
    }
    columns = placed

    // Natural width if the table fits as-is, otherwise the full available width (cells wrapped).
    let naturalTotal = natural.reduce(0, +) + gaps + indent * 2
    let width = naturalTotal <= available ? naturalTotal : available

    var heights: [CGFloat] = []
    for row in all {
      var tallest: CGFloat = 0
      for column in 0..<columnCount where column < row.count {
        let bounds = row[column].boundingRect(
          with: CGSize(width: placed[column].width, height: .greatestFiniteMagnitude),
          options: [.usesLineFragmentOrigin, .usesFontLeading])
        tallest = max(tallest, ceil(bounds.height))
      }
      heights.append(tallest + vPad * 2)
    }
    rowHeights = heights
    size = CGSize(width: width, height: heights.reduce(0, +))
  }

  /// Water-fill the `budget` across columns: every column is guaranteed its `floor` — its widest
  /// unbreakable fragment, so a squeezed column wraps between words (or CJK glyphs) instead of
  /// mid-word — and the slack above the floors is shared out evenly, no column taking more than
  /// its natural width. So short columns stay their own width, wide multi-word columns wrap, and a
  /// lone long token like `transcript` still fits on one line. No-op when it all fits.
  ///
  /// The floors are a preference, not a promise: when they alone exceed the budget — a column of
  /// paths beside a column of identifiers, in a pane narrower than the two — they are scaled down
  /// to it in proportion, and those columns break inside a token. Overflowing instead, which is
  /// what the earlier fill did once a second column had a floor of its own, is the worse of the
  /// two by far: the table draws into an image its own `size` wide, so a column pushed past that
  /// edge is not merely wide, everything past it is clipped away. And the break costs less than
  /// the floor suggests — word wrapping breaks a long path at its slashes rather than refusing, so
  /// a floor is what keeps a token whole, not what keeps it legible.
  private static func fit(_ natural: [CGFloat], floors: [CGFloat], budget: CGFloat) -> [CGFloat] {
    if natural.reduce(0, +) <= budget { return natural }
    let floorTotal = floors.reduce(0, +)
    if floorTotal > budget {
      // Proportional, so the column holding the longest token still gets the most room to break it.
      return floors.map { $0 / floorTotal * budget }
    }
    var widths = floors
    var slack = budget - floorTotal
    var wanting = Set(natural.indices.filter { natural[$0] > floors[$0] })
    while !wanting.isEmpty, slack > 0.5 {
      let share = slack / CGFloat(wanting.count)
      // A column within its share of the slack is finished at its natural width (no wrap) and
      // hands the rest of that share back, so re-divide and look again. When none is, they all
      // take their share and wrap in it.
      if let column = wanting.first(where: { natural[$0] - floors[$0] <= share }) {
        slack -= natural[column] - floors[column]
        widths[column] = natural[column]
        wanting.remove(column)
      } else {
        for column in wanting { widths[column] += share }
        break
      }
    }
    return widths
  }

  /// The narrowest a cell can be drawn without a word breaking mid-glyph: the width of its widest
  /// unbreakable fragment. A break can fall at a space or between two CJK glyphs, so a fragment is
  /// a run of non-space, non-CJK characters (a Latin word) or a single CJK glyph — matching the
  /// `.byWordWrapping` the cells carry. Measured on the attributed substring so bold or linked runs
  /// count at their real width.
  static func minContentWidth(_ cell: NSAttributedString) -> CGFloat {
    let string = cell.string
    var widest: CGFloat = 0
    var runLocation = 0
    var runLength = 0
    var location = 0

    func measure(_ range: NSRange) {
      guard range.length > 0 else { return }
      widest = max(widest, ceil(cell.attributedSubstring(from: range).size().width))
    }
    func flushRun() {
      measure(NSRange(location: runLocation, length: runLength))
      runLength = 0
    }

    for character in string {
      let units = character.utf16.count
      if character.isWhitespace {
        flushRun()
      } else if let scalar = character.unicodeScalars.first, Self.isCJK(scalar) {
        flushRun()
        measure(NSRange(location: location, length: units))
      } else {
        if runLength == 0 { runLocation = location }
        runLength += units
      }
      location += units
    }
    flushRun()
    return widest
  }

  /// CJK and kana carry a break opportunity between every glyph, so each is its own wrap unit
  /// rather than part of a "word". The ranges that matter for a transcript: kana, CJK ideographs
  /// (including the extensions and compatibility block), Hangul, and the fullwidth/halfwidth forms.
  private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x303F, 0x3040...0x30FF,
      0x3130...0x318F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F,
      0xAC00...0xD7FF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x3FFFF:
      return true
    default:
      return false
    }
  }

  // MARK: Where a click lands

  var rowCount: Int { rowHeights.count }
  var columnCount: Int { columns.count }

  /// The row under a table-local y, or nil above the first one.
  func row(at y: CGFloat) -> Int? {
    var top: CGFloat = 0
    for (index, height) in rowHeights.enumerated() {
      if y >= top && y < top + height { return index }
      top += height
    }
    return y >= top ? rowHeights.count - 1 : nil
  }

  /// The column nearest a table-local x. Nearest rather than containing, so the gaps between the
  /// columns and the indent outside them are not dead ground in the middle of a drag.
  func column(at x: CGFloat) -> Int {
    var best = 0
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for (index, column) in columns.enumerated() {
      let distance =
        x < column.x
        ? column.x - x : (x > column.x + column.width ? x - (column.x + column.width) : 0)
      if distance < bestDistance {
        bestDistance = distance
        best = index
      }
    }
    return best
  }

  /// The top-left of a cell's text, in table-local coordinates.
  func cellOrigin(row: Int, column: Int) -> CGPoint {
    var y: CGFloat = 0
    for index in 0..<row { y += rowHeights[index] }
    return CGPoint(x: columns[column].x, y: y + vPad)
  }

  /// Laid out on demand: a table is drawn far more often than it is selected in, and a checkout's
  /// worth of transcript holds many that are never touched.
  private var cellTexts: [Int: TableCellText] = [:]

  func text(row: Int, column: Int) -> TableCellText? {
    guard row >= 0, row < cells.count, column >= 0, column < columns.count,
      column < cells[row].count
    else { return nil }
    let key = row * columns.count + column
    if let found = cellTexts[key] { return found }
    let built = TableCellText(cells[row][column], width: columns[column].width)
    cellTexts[key] = built
    return built
  }

  /// The position a table-local point names.
  func position(at point: CGPoint) -> TableCellPosition? {
    guard let row = row(at: point.y) else { return nil }
    let column = self.column(at: point.x)
    guard let text = text(row: row, column: column) else { return nil }
    let origin = cellOrigin(row: row, column: column)
    return TableCellPosition(
      row: row, column: column,
      character: text.characterIndex(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y)))
  }

  /// The highlight for a block of cells, in table-local coordinates. Half the gap on each side,
  /// so two selected columns read as one band rather than as two stripes with a channel between.
  func blockRect(_ block: TableCellBlock) -> CGRect {
    let rows = block.rows.clamped(to: 0...(rowCount - 1))
    let cols = block.columns.clamped(to: 0...(columnCount - 1))
    var y: CGFloat = 0
    for index in 0..<rows.lowerBound { y += rowHeights[index] }
    var height: CGFloat = 0
    for index in rows { height += rowHeights[index] }
    let left = max(0, columns[cols.lowerBound].x - gap / 2)
    let right = min(
      size.width, columns[cols.upperBound].x + columns[cols.upperBound].width + gap / 2)
    return CGRect(x: left, y: y, width: right - left, height: height)
  }

  /// The rectangles a run of characters occupies — one per line the run wraps onto.
  func textRects(_ span: TableTextSpan) -> [CGRect] {
    guard !span.isEmpty, span.start.row == span.end.row, span.start.column == span.end.column,
      let text = text(row: span.start.row, column: span.start.column)
    else { return [] }
    let origin = cellOrigin(row: span.start.row, column: span.start.column)
    let range = NSRange(
      location: span.start.character, length: span.end.character - span.start.character)
    return text.rects(for: range).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
  }

  func draw() {
    let full = CGRect(origin: .zero, size: size)
    let hairline = 1 / (NSScreen.main?.backingScaleFactor ?? 2)
    let frame = NSBezierPath(
      roundedRect: full.insetBy(dx: hairline / 2, dy: hairline / 2), xRadius: radius,
      yRadius: radius
    )

    NSGraphicsContext.saveGraphicsState()
    frame.addClip()
    var y: CGFloat = 0
    for (index, height) in rowHeights.enumerated() {
      let body = (index - 1).isMultiple(of: 2) ? Self.rowFill : Self.altRowFill
      let fill = index == 0 ? headerFill : body
      fill.setFill()
      NSBezierPath(rect: CGRect(x: 0, y: y, width: size.width, height: height)).fill()
      y += height
    }
    // The rule sits on the seam between the header and the first body row.
    if let headerHeight = rowHeights.first {
      ruleColor.setFill()
      NSBezierPath(
        rect: CGRect(x: 0, y: headerHeight - hairline, width: size.width, height: hairline)
      )
      .fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    ruleColor.setStroke()
    frame.lineWidth = hairline
    frame.stroke()

    y = 0
    for (index, row) in cells.enumerated() {
      let height = rowHeights[index]
      for column in 0..<columns.count where column < row.count {
        let rect = CGRect(
          x: columns[column].x, y: y + vPad,
          width: columns[column].width, height: height - vPad * 2)
        row[column].draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
      }
      y += height
    }
  }
}

// MARK: - Selecting inside a table

/// A place in a table's text. Reading order is (row, column, character), so two of these bound a
/// selection the way two offsets bound one in a text view. Row 0 is the header.
struct TableCellPosition: Comparable {
  var row: Int
  var column: Int
  var character: Int

  static func < (a: Self, b: Self) -> Bool {
    (a.row, a.column, a.character) < (b.row, b.column, b.character)
  }
}

/// A run of characters inside one cell.
struct TableTextSpan: Equatable {
  var start: TableCellPosition
  var end: TableCellPosition

  var isEmpty: Bool { start == end }
}

/// A rectangular block of cells.
struct TableCellBlock: Equatable {
  var rows: ClosedRange<Int>
  var columns: ClosedRange<Int>
}

/// What is selected inside a table.
///
/// A drag selects characters while it stays in the cell it started in, and snaps to whole cells
/// the moment it leaves. The switch is what keeps the highlight honest: a run that ends halfway
/// through a cell two rows down is a shape no table can be copied as, so the selection that spans
/// cells is the one a copy can actually produce — which also makes taking a column, or a row, the
/// same gesture rather than a mode.
enum TableSelection: Equatable {
  case text(TableTextSpan)
  case block(TableCellBlock)
}

/// One cell's text, laid out the way the drawing lays it out, so a click can be turned into a
/// character index and a character range back into the rectangles the glyphs occupy.
///
/// `NSAttributedString.draw(with:options:)` lays a cell out through TextKit with no line-fragment
/// padding and the cell's own word wrapping; this is that same layout, kept rather than thrown
/// away, which is what makes the caret land where the glyph is.
final class TableCellText {
  private let storage: NSTextStorage
  private let layoutManager: NSLayoutManager
  private let container: NSTextContainer

  init(_ cell: NSAttributedString, width: CGFloat) {
    storage = NSTextStorage(attributedString: cell)
    layoutManager = NSLayoutManager()
    container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    storage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(container)
    layoutManager.ensureLayout(for: container)
  }

  var length: Int { storage.length }
  var string: String { storage.string }

  /// The insertion point nearest a cell-local point (origin at the cell's top-left, y down).
  func characterIndex(at point: CGPoint) -> Int {
    guard storage.length > 0 else { return 0 }
    var fraction: CGFloat = 0
    let glyph = layoutManager.glyphIndex(
      for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
    var index = layoutManager.characterIndexForGlyph(at: glyph)
    if fraction > 0.5 { index += 1 }
    return min(max(0, index), storage.length)
  }

  func rects(for range: NSRange) -> [CGRect] {
    let clamped = clamp(range)
    guard clamped.length > 0 else { return [] }
    let glyphs = layoutManager.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
    var found: [CGRect] = []
    layoutManager.enumerateEnclosingRects(
      forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
      in: container
    ) { rect, _ in found.append(rect) }
    return found
  }

  /// What a double-click takes: hukan's token rule, not AppKit's — a cell is full of the paths,
  /// hashes and hyphenated names `WordSelection` exists to keep whole.
  func wordRange(at index: Int) -> NSRange {
    let string = storage.string as NSString
    guard string.length > 0 else { return NSRange(location: 0, length: 0) }
    let click = min(index, string.length - 1)
    let appkit = storage.doubleClick(at: click)
    return WordSelection.word(in: string, click: click, selection: appkit, appkitWord: nil)
      ?? appkit
  }

  func substring(_ range: NSRange) -> String {
    (storage.string as NSString).substring(with: clamp(range))
  }

  private func clamp(_ range: NSRange) -> NSRange {
    let location = min(max(0, range.location), storage.length)
    return NSRange(location: location, length: min(range.length, storage.length - location))
  }
}
