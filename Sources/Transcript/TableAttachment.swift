import AppKit

/// A table drawn to fit the pane it lands in. GFM tables were laid out as tab-stopped monospace
/// rows, which line up perfectly until the table is wider than the transcript pane — then every
/// row wraps at the container edge and the columns fall apart. The width the row has to fit is
/// only known at layout time (the pane can resize, and nothing re-runs the markdown), so the
/// table is an attachment: `attachmentBounds` reads the live container width, wraps each cell
/// within its column, and reports the height that needs; the image redraws at that width, in the
/// current scale and appearance, whenever the width changes.
///
/// The cost of drawing rather than laying out real text is that the cells are no longer selectable
/// glyph by glyph — the whole table selects as one attachment. Copying still yields the table as
/// text, though: the attachment carries its `markdown`, and `TranscriptTextView.writeSelection`
/// swaps it in for the `￼` the attachment would otherwise copy as.
final class TableAttachment: NSTextAttachment {
  private let header: [NSAttributedString]
  private let rows: [[NSAttributedString]]
  /// The table's own markdown, so a copied selection expands the attachment back to text rather
  /// than the `￼` an attachment character copies as. `TranscriptTextView.writeSelection` reads it.
  let markdown: String
  /// The width the current `image` was drawn for, so a relayout at the same width reuses it
  /// instead of re-rasterising (`attachmentBounds` fires more than once per width).
  private var renderedWidth: CGFloat = -1

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
    let layout = TableLayout(header: header, rows: rows, available: available)
    if abs(available - renderedWidth) > 0.5 || image == nil {
      renderedWidth = available
      image = NSImage(size: layout.size, flipped: true) { _ in
        layout.draw()
        return true
      }
    }
    return CGRect(x: 0, y: 0, width: layout.size.width, height: layout.size.height)
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
  private let rowHeights: [CGFloat]
  let size: CGSize

  private let indent: CGFloat = 12
  private let gap: CGFloat = 16
  private let vPad: CGFloat = 6
  private let radius: CGFloat = 6

  // Matches the former tab-stop table: a stronger header wash above two alternating body washes,
  // the row seam carried by the shade change, and one hairline weight for the header rule and the
  // outer frame.
  private let headerFill = NSColor.tertiarySystemFill
  private let rowFill = NSColor.quaternarySystemFill.withAlphaComponent(0.25)
  private let altRowFill = NSColor.quaternarySystemFill.withAlphaComponent(0.45)
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
      let fill = index == 0 ? headerFill : ((index - 1).isMultiple(of: 2) ? rowFill : altRowFill)
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
