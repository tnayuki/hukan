import AppKit

/// The scroll view the gutter needs under it.
///
/// AppKit reserves the ruler's strip already — it subtracts `ruleThickness` from `contentSize`
/// and seeds the clip view's bounds the same distance to the left, so a document line at x=0
/// lands just right of the numbers. Reserving it a *second* time by moving the clip view's frame
/// is what put a gutter's width of nothing between the numbers and the text: the text view then
/// sizes itself to a content width that has the strip taken out twice, and a document narrower
/// than the pane makes AppKit pin the bounds to hold that too-narrow document in place. So the
/// layout is AppKit's, untouched.
///
/// What AppKit's layout does not do is stop the text at the strip: the clip view keeps the full
/// width and overlaps the ruler, so scrolling sideways slides the line under it. An opaque ruler
/// covers that, which is why the behaviour is rarely seen — and why this one paints, alone among
/// the desk's views, in the colour that would otherwise show through it.
final class EditorScrollView: NSScrollView {
  /// A wheel this view cannot act on belongs to whatever encloses it.
  ///
  /// The commit tab puts one of these inside every card, where the scrolling that matters is the
  /// tab's: a card's diff is exactly as tall as its own rows, so it has no vertical range to
  /// spend — and an inner scroll view that can move horizontally is handed the gesture first and,
  /// with elasticity off, clamps it and swallows it rather than passing it on. Over a diff,
  /// nothing scrolled at all. Horizontal scrolling stays here, which is what a long line needs.
  ///
  /// The source pane is unaffected: a file long enough to scroll never takes this branch, and one
  /// short enough to take it has nothing enclosing it to scroll either.
  ///
  /// What is handed on has to be a wheel with vertical intent and nothing else — not merely one
  /// whose vertical delta is the larger of the two. A trackpad gesture opens and closes with
  /// events carrying no delta at all, and `0 >= 0` handed those away too: the scroll view saw the
  /// middle of a sideways gesture but never its end, so the rubber band it had stretched was
  /// never let go and the text stayed parked off the side of its own content.
  override func scrollWheel(with event: NSEvent) {
    let canScrollVertically = (documentView?.frame.height ?? 0) > contentView.bounds.height + 0.5
    let verticalOnly = event.scrollingDeltaX == 0 && event.scrollingDeltaY != 0
    if !canScrollVertically, verticalOnly {
      nextResponder?.scrollWheel(with: event)
      return
    }
    super.scrollWheel(with: event)
  }
}

extension NSScrollView {
  /// Scroll to the document's leading edge, at `y`. Not to x = 0: under AppKit's ruler layout
  /// the leftmost position is `-ruleThickness` — that is the seed the clip view's bounds carry
  /// so the strip has somewhere to be — and 0 is a gutter's width to the *right* of it, with the
  /// first characters of every line under the numbers. Asked of the clip view's own constraint,
  /// so it is whatever the leftmost is, with or without a ruler.
  func scrollToLeadingEdge(y: CGFloat) {
    contentView.scroll(to: NSPoint(x: leadingEdgeX, y: y))
    reflectScrolledClipView(contentView)
  }

  /// The leftmost the clip view will go, asked of its own constraint.
  var leadingEdgeX: CGFloat {
    contentView.constrainBoundsRect(
      NSRect(
        origin: NSPoint(x: -1_000_000, y: contentView.bounds.origin.y),
        size: contentView.bounds.size)
    ).origin.x
  }

  /// Whether the document's leading edge is the leftmost thing on screen.
  var isAtLeadingEdge: Bool { abs(contentView.bounds.origin.x - leadingEdgeX) < 0.5 }
}

/// The source pane's gutter: line numbers, with the file's uncommitted changes beside them.
/// A bar marks an added (green) or rewritten (blue) line and a red wedge sits on the boundary
/// where lines were deleted; a change already in the index draws hollow. The bars measure the
/// *buffer* against HEAD, so an edit is marked as it is typed and stays marked until it is
/// committed — staging only hollows it. Hovering one opens the block it belongs to: what those
/// lines read as before, and what replaced them.
final class EditorGutter: NSRulerView {
  private weak var textView: NSTextView?

  var lineChanges = Git.LineChanges() {
    didSet {
      needsDisplay = true
      if peeked != nil { closePeek() }
    }
  }

  /// Where each line was drawn last, so a hover can find the line under the pointer without
  /// walking the layout again. Filled by the draw, which has the fragment frames anyway.
  private var rows: [(line: Int, top: CGFloat, height: CGFloat)] = []
  private var peek: DiffPeekView?
  /// The block the open card is showing, so moving within the same one does not rebuild it.
  private var peeked: Int?

  private let numberFont = NSFont.monospacedDigitSystemFont(
    ofSize: NSFont.smallSystemFontSize, weight: .regular)
  private var lines = LineIndex()

  private let barWidth: CGFloat = 3
  private let padding: CGFloat = 4

  init(scrollView: NSScrollView, textView: NSTextView) {
    self.textView = textView
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    clientView = textView
    // The storage notification, not the storage delegate (a slot better left free), and not
    // NSText.didChange (which skips programmatic replacement, and a file opening is one).
    NotificationCenter.default.addObserver(
      self, selector: #selector(textStorageDidChange),
      name: NSTextStorage.didProcessEditingNotification, object: textView.textStorage)
    updateThickness()
  }

  required init(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  /// What shows through the strip, painted rather than left to show through.
  ///
  /// The source pane needs it: AppKit's clip view keeps the scroll view's full width and slides
  /// the line underneath, so a transparent strip lets a long line read straight through the
  /// numbers. It is the colour that would have shown through anyway, so nothing about the look
  /// changes. The commit tab wants the transparency instead — a diff line's side is a band that
  /// runs the full width, and painting over it would cut the band off at the numbers.
  var backgroundColor: NSColor? {
    didSet { needsDisplay = true }
  }

  /// Two things this must not do, both of which blank the pane outright.
  ///
  /// It must not claim `isOpaque`: AppKit's own ruler layout has the clip view keep the scroll
  /// view's full width and *overlap* this strip, and an opaque ruler over an overlapping clip
  /// view is taken to cover it, so the text stops being drawn at all. And the fill has to be
  /// clipped to `bounds` by hand — a ruler is handed a `dirtyRect` reaching past its own strip
  /// and is not clipped to it, so filling the rect it was given paints over the whole pane.
  override func draw(_ dirtyRect: NSRect) {
    if let backgroundColor {
      backgroundColor.setFill()
      bounds.intersection(dirtyRect).fill()
    }
    // NSRulerView's own chrome is a different grey with an edge line, so this replaces the
    // default draw rather than adding to it.
    drawHashMarksAndLabels(in: dirtyRect)
  }

  @objc private func textStorageDidChange() {
    lines.invalidate()
    // The storage is mid-edit here; thickness and redraw wait for the pass to end.
    DispatchQueue.main.async { [weak self] in
      self?.updateThickness()
      self?.needsDisplay = true
    }
  }

  private func rebuildLineStartsIfNeeded() {
    guard let text = textView?.string else { return }
    lines.rebuildIfNeeded(from: text as NSString)
  }

  private func updateThickness() {
    rebuildLineStartsIfNeeded()
    let digits = max(2, String(lines.count).count)
    let digitWidth = ("8" as NSString).size(withAttributes: [.font: numberFont]).width
    let thickness = ceil(padding + CGFloat(digits) * digitWidth + 6 + barWidth + padding)
    guard abs(thickness - ruleThickness) > 0.5 else { return }
    // The strip's width is the leading edge: widen it and the edge moves left with it. A view
    // sitting at that edge has to come along, or it is left a digit's width to the right of it
    // with the first character of every line under the numbers — which is what a file crossing
    // a hundred lines did, its gutter growing after the text had already landed and been
    // scrolled to what was the edge at the time.
    let followEdge = scrollView?.isAtLeadingEdge ?? false
    ruleThickness = thickness
    if followEdge, let scrollView {
      scrollView.scrollToLeadingEdge(y: scrollView.contentView.bounds.origin.y)
    }
  }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let textView,
      let layoutManager = textView.textLayoutManager,
      let contentManager = layoutManager.textContentManager
    else { return }
    rebuildLineStartsIfNeeded()
    rows.removeAll(keepingCapacity: true)

    let visible = textView.visibleRect
    let inset = textView.textContainerInset
    // Fragment frames live in container space; the container sits `inset` into the text view.
    let from = layoutManager.textLayoutFragment(
      for: CGPoint(x: 0, y: visible.minY - inset.height))
    layoutManager.enumerateTextLayoutFragments(
      from: from?.rangeInElement.location, options: [.ensuresLayout]
    ) { fragment in
      let frame = fragment.layoutFragmentFrame
      let top = convert(NSPoint(x: 0, y: frame.minY + inset.height), from: textView).y
      if frame.minY + inset.height > visible.maxY { return false }
      let offset = contentManager.offset(
        from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
      let line = lines.line(at: offset)
      let firstLineHeight = fragment.textLineFragments.first?.typographicBounds.height
      self.rows.append((line, top, frame.height))
      draw(
        line: line, top: top, height: frame.height,
        firstLineHeight: firstLineHeight ?? frame.height)
      return true
    }
  }

  private func draw(line: Int, top: CGFloat, height: CGFloat, firstLineHeight: CGFloat) {
    let text = "\(line)" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
      .font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor,
    ]
    let size = text.size(withAttributes: attributes)
    let barX = bounds.maxX - padding - barWidth
    text.draw(
      at: NSPoint(x: barX - 6 - size.width, y: top + (firstLineHeight - size.height) / 2),
      withAttributes: attributes)

    if let bar = lineChanges.bars[line] {
      // Each line's bar overhangs its row by the corner radius, so two changed lines in a row
      // overlap into one continuous mark and a lone one still reads as a rounded stub.
      let radius = barWidth / 2
      let rect = NSRect(
        x: barX, y: top - radius, width: barWidth, height: height + radius * 2)
      (bar.kind == .added ? NSColor.systemGreen : NSColor.systemBlue).set()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      if bar.staged {
        // Hollow by cutting the middle back to the strip's own colour rather than by stroking:
        // a stroke would draw the two long edges of every row, ruling lines across a run of
        // connected bars. The cut is per row for the same reason it has to be — a staged line
        // next to an unstaged one still reads apart.
        let inset: CGFloat = 1
        (backgroundColor ?? .windowBackgroundColor).set()
        NSBezierPath(
          roundedRect: rect.insetBy(dx: inset, dy: inset),
          xRadius: max(0, radius - inset), yRadius: max(0, radius - inset)
        ).fill()
      }
    }
    // A wedge on the boundary carrying a deletion: below this line — or above the first,
    // where the boundary "line 0" has no row of its own to sit under.
    drawDeletionWedge(at: top + height, ifBoundary: line)
    if line == 1 { drawDeletionWedge(at: top, ifBoundary: 0) }
  }

  private func drawDeletionWedge(at y: CGFloat, ifBoundary boundary: Int) {
    guard let staged = lineChanges.deletions[boundary] else { return }
    let barX = bounds.maxX - padding - barWidth
    let path = NSBezierPath()
    path.move(to: NSPoint(x: barX - 4, y: y - 3.5))
    path.line(to: NSPoint(x: barX + barWidth, y: y))
    path.line(to: NSPoint(x: barX - 4, y: y + 3.5))
    path.close()
    NSColor.systemRed.set()
    path.fill()
    if staged {
      let cut = NSBezierPath()
      cut.move(to: NSPoint(x: barX - 2.5, y: y - 2))
      cut.line(to: NSPoint(x: barX + barWidth - 1.5, y: y))
      cut.line(to: NSPoint(x: barX - 2.5, y: y + 2))
      cut.close()
      (backgroundColor ?? .windowBackgroundColor).set()
      cut.fill()
    }
  }

  // MARK: - Peeking a block

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self))
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let row = rows.first(where: { point.y >= $0.top && point.y < $0.top + $0.height }),
      let index = hunkIndex(forLine: row.line)
    else {
      closePeek()
      return
    }
    guard peeked != index else { return }
    openPeek(lineChanges.hunks[index], index: index, at: row.top)
  }

  override func mouseExited(with event: NSEvent) {
    closePeek()
  }

  /// The block a hover on `line` should open: the one whose changed span covers it, or whose
  /// deletion sits on one of its two boundaries. A block with nothing removed is skipped — the
  /// lines it added are already on screen, so a card would only repeat them.
  private func hunkIndex(forLine line: Int) -> Int? {
    lineChanges.hunks.firstIndex {
      guard $0.oldLen > 0 else { return false }
      if $0.newLen == 0 { return $0.newStart == line || $0.newStart == line - 1 }
      return line > $0.newStart && line <= $0.newStart + $0.newLen
    }
  }

  private func openPeek(_ hunk: Git.Hunk, index: Int, at top: CGFloat) {
    guard let host = enclosingScrollView?.superview else { return }
    closePeek()
    let card = DiffPeekView(hunk: hunk)
    card.frame.origin = host.convert(
      NSPoint(x: bounds.maxX + 4, y: top), from: self)
    if !host.isFlipped { card.frame.origin.y -= card.frame.height }
    card.frame.origin.x = min(card.frame.origin.x, host.bounds.maxX - card.frame.width - 8)
    host.addSubview(card)
    peek = card
    peeked = index
  }

  private func closePeek() {
    peek?.removeFromSuperview()
    peek = nil
    peeked = nil
  }
}

/// The card a hover over a change bar opens: the block's base lines, then what replaced them —
/// removed above added, so the two read apart rather than as one interleaved patch. It floats
/// over the editor and never takes a click; it is there to be read, and the file itself is
/// where the change is made.
final class DiffPeekView: NSView {
  /// Rows past this are dropped: the card is a glance at a block, and a hundred-line one is
  /// read in the file, not in a tooltip.
  private static let maximumRows = 24
  private static let maximumWidth: CGFloat = 620

  private let rows: [(added: Bool, text: String)]
  private let dropped: Int
  private let rowHeight: CGFloat
  private let padding: CGFloat = 6

  init(hunk: Git.Hunk) {
    let all =
      hunk.oldLines.map { (false, $0) } + hunk.newLines.map { (true, $0) }
    rows = Array(all.prefix(Self.maximumRows))
    dropped = all.count - rows.count
    rowHeight = ceil(monospace.ascender - monospace.descender + monospace.leading) + 2

    let width = rows.reduce(CGFloat(120)) { widest, row in
      max(widest, (row.text as NSString).size(withAttributes: [.font: monospace]).width)
    }
    let height = rowHeight * CGFloat(rows.count + (dropped > 0 ? 1 : 0))
    super.init(
      frame: NSRect(
        x: 0, y: 0, width: min(width + padding * 2, Self.maximumWidth),
        height: height + padding * 2))
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  /// Never in the way: a card that swallowed clicks would make the lines under it unselectable.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    // Drawn rather than layered so the card renders through the same path the snapshot walks,
    // and so the rows' tints can sit inside its rounded edge without a mask.
    let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
    NSColor.windowBackgroundColor.setFill()
    card.fill()
    card.setClip()
    for (i, row) in rows.enumerated() {
      let rect = NSRect(
        x: 0, y: padding + CGFloat(i) * rowHeight, width: bounds.width, height: rowHeight)
      (row.added ? NSColor.systemGreen : NSColor.systemRed).withAlphaComponent(0.16).setFill()
      rect.fill()
      (row.text as NSString).draw(
        at: NSPoint(x: padding, y: rect.minY + 1),
        withAttributes: [.font: monospace, .foregroundColor: NSColor.labelColor])
    }
    if dropped > 0 {
      ("… \(dropped) more" as NSString).draw(
        at: NSPoint(x: padding, y: padding + CGFloat(rows.count) * rowHeight + 1),
        withAttributes: [.font: monospace, .foregroundColor: NSColor.tertiaryLabelColor])
    }
    NSColor.separatorColor.setStroke()
    card.stroke()
  }
}

/// A text view's line starts: the map from a layout fragment's offset back to the line number it
/// begins on. Both of the desk's rulers need it — the editor's, whose rows are the file's lines,
/// and the commit tab's, whose rows are the diff's — and both rebuild it lazily, after the text
/// has changed and before the next draw.
struct LineIndex {
  private var starts: [Int] = [0]
  private var isStale = true

  /// How many lines the text has.
  var count: Int { starts.count }

  mutating func invalidate() { isStale = true }

  mutating func rebuildIfNeeded(from string: NSString) {
    guard isStale else { return }
    isStale = false
    var result = [0]
    var location = 0
    while location < string.length {
      location = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
      if location < string.length { result.append(location) }
    }
    starts = result
  }

  /// Where a 1-based line begins.
  func start(of line: Int) -> Int { starts[max(0, min(starts.count - 1, line - 1))] }

  /// The 1-based line an offset falls on — the rightmost start at or before it, by binary search.
  func line(at offset: Int) -> Int {
    var low = 0
    var high = starts.count - 1
    while low < high {
      let mid = (low + high + 1) / 2
      if starts[mid] <= offset { low = mid } else { high = mid - 1 }
    }
    return low + 1
  }
}
