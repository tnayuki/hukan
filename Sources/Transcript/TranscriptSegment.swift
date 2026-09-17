import AppKit

/// One slice of the conversation with a TextKit 2 stack of its own.
///
/// The transcript is written at its two ends and nowhere else — a reply appends, a history slice
/// is put in front — so a slice that is already laid out is never moved by what arrives later. A
/// segment is that slice: its layout manager's geometry is the truth inside it, and the only
/// thing the document adds is where the segment starts. Which is what lets the document's height
/// be a sum of a few dozen numbers rather than TextKit's estimate of a viewport's surroundings —
/// the estimate `NSTextView` writes over its own frame, and the reason the reader's line used to
/// move under them (see `TranscriptDocumentView`).
///
/// The one edit that lands inside a segment is a tool call folding, and that costs the segment a
/// re-layout of its own length and nothing else.
final class TranscriptSegment {
  let storage: NSTextStorage
  let contentStorage = NSTextContentStorage()
  let layoutManager = TranscriptLayoutManager()
  let container: NSTextContainer

  /// The segment's first character, as an offset into the whole document. Kept by the document,
  /// which is the only thing that knows what stands in front.
  var start = 0
  /// Where the segment's text begins in the document's own coordinates (the container's top,
  /// before the view's inset). Kept by the document, the same way.
  var originY: CGFloat = 0
  /// Whether this segment ends the document. Set by the document: the last paragraph of a
  /// storage is laid out with an empty line after its newline, which is right at the end of the
  /// conversation and wrong in front of the next segment (see `measureTail`).
  var isTail = false {
    didSet { if isTail != oldValue { height = isTail ? tailHeight : interiorHeight } }
  }
  /// The segment's exact height at `laidOutWidth`, as the paragraphs would measure inside one
  /// document.
  private(set) var height: CGFloat = 0
  private(set) var laidOutWidth: CGFloat = -1
  private var tailHeight: CGFloat = 0
  private var interiorHeight: CGFloat = 0

  private static let unbounded: CGFloat = 1_000_000

  var length: Int { storage.length }
  var range: NSRange { NSRange(location: start, length: storage.length) }
  /// How many paragraphs the segment holds — what decides when the tail is sealed.
  var paragraphCount: Int {
    storage.string.utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
  }

  init(_ text: NSAttributedString, width: CGFloat) {
    // An empty storage filled inside an editing transaction, never
    // `NSTextStorage(attributedString:)`: that initialiser fixes the attributes on the way in,
    // and fixing writes a fallback font over every character the system font lacks — a `☐`
    // comes out in Apple Symbols, whose line is two points taller. Filled this way the fonts
    // stay as written and CoreText falls back per glyph, which is what `NSTextView` shows and
    // what the references hold (measured).
    storage = NSTextStorage()
    container = NSTextContainer(size: CGSize(width: width, height: Self.unbounded))
    contentStorage.addTextLayoutManager(layoutManager)
    layoutManager.textContainer = container
    contentStorage.textStorage = storage
    contentStorage.performEditingTransaction { storage.setAttributedString(text) }
    layOut(width: width)
  }

  /// Lay the whole segment out at `width` and record its height. A no-op for the fragments that
  /// are still valid, so after an append only the tail costs anything.
  func layOut(width: CGFloat) {
    if container.size.width != width {
      container.size = CGSize(width: width, height: Self.unbounded)
      layoutManager.invalidateLayout(for: layoutManager.documentRange)
    }
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    laidOutWidth = width
    measureTail()
  }

  /// Replace a range of this segment's text, and lay the result out again.
  func replace(_ local: NSRange, with replacement: NSAttributedString) {
    contentStorage.performEditingTransaction {
      storage.replaceCharacters(in: local, with: replacement)
    }
    layOut(width: container.size.width)
  }

  func append(_ text: NSAttributedString) {
    replace(NSRange(location: storage.length, length: 0), with: text)
  }

  /// What the last paragraph measures inside a document, against what it measures here.
  ///
  /// A storage ending in a newline is laid out with one more, empty line after it — the line the
  /// insertion point would stand on. `NSTextView` gives that line the height of the line before
  /// it and leaves every row at its own height, which is what the conversation's end looks like
  /// and what the snapshot references hold. A bare stack, with no view to say what font an empty
  /// line is in, pads every row of that last paragraph up to the default font's line — measured:
  /// a 7pt spacer's two rows come out 14 and 14 against the view's 8 and 8, a 14pt paragraph's
  /// are untouched. So the fragment's rows are put back to their natural heights, and the empty
  /// line is kept at the end of the document and dropped in front of another segment, where the
  /// next paragraph follows the newline directly.
  private func measureTail() {
    let usage = layoutManager.usageBoundsForTextContainer.height
    tailHeight = usage
    interiorHeight = usage
    guard storage.length > 0 else { return }
    var last: NSTextLayoutFragment?
    layoutManager.enumerateTextLayoutFragments(
      from: layoutManager.documentRange.endLocation, options: [.reverse, .ensuresLayout]
    ) { fragment in
      last = fragment
      return false
    }
    guard let fragment = last, let phantom = fragment.textLineFragments.last,
      phantom.characterRange.length == 0
    else { return }
    let lines = fragment.textLineFragments
    let frame = fragment.layoutFragmentFrame.height
    let spacingAfter =
      (attributes(of: fragment)[.paragraphStyle] as? NSParagraphStyle)?.paragraphSpacing ?? 0
    // Each real row as laid out, against the line it holds; the row before the empty line has
    // the paragraph's spacing-after between the two.
    var padding: CGFloat = 0
    for index in 0..<(lines.count - 1) {
      let line = lines[index]
      let next = lines[index + 1]
      var row = next.typographicBounds.minY - line.typographicBounds.minY
      if index == lines.count - 2 { row -= spacingAfter }
      padding += max(0, row - line.typographicBounds.height)
    }
    let phantomRow = frame - phantom.typographicBounds.minY
    let natural = lines[lines.count - 2].typographicBounds.height
    tailHeight = usage - padding - max(0, phantomRow - natural)
    interiorHeight = usage - padding - phantomRow
    height = isTail ? tailHeight : interiorHeight
  }

  // MARK: Geometry, all in the container's coordinates (origin at the segment's top-left)

  func location(at offset: Int) -> NSTextLocation? {
    contentStorage.location(contentStorage.documentRange.location, offsetBy: offset)
  }

  func offset(of location: NSTextLocation) -> Int {
    contentStorage.offset(from: contentStorage.documentRange.location, to: location)
  }

  /// The paragraph under a segment-local y, or nil above the first and below the last.
  func fragment(atY y: CGFloat) -> NSTextLayoutFragment? {
    guard y >= 0, y < height + 1 else { return nil }
    return layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: y))
  }

  func fragment(at offset: Int) -> NSTextLayoutFragment? {
    guard let location = location(at: min(max(0, offset), max(0, storage.length - 1)))
    else { return nil }
    return layoutManager.textLayoutFragment(for: location)
  }

  /// Where the fragment's element begins, as a segment-local offset.
  func startOffset(of fragment: NSTextLayoutFragment) -> Int {
    offset(of: fragment.rangeInElement.location)
  }

  /// The insertion point nearest a segment-local point: on the line under it, rounded to the
  /// nearer edge of the character under it; past the end of a line, the end of that line.
  func insertionOffset(at point: CGPoint) -> Int {
    guard storage.length > 0 else { return 0 }
    if point.y < 0 { return 0 }
    guard let fragment = fragment(atY: point.y) else { return storage.length }
    let local = CGPoint(
      x: point.x - fragment.layoutFragmentFrame.minX, y: point.y - fragment.layoutFragmentFrame.minY
    )
    let base = startOffset(of: fragment)
    let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
    guard
      let line = lines.first(where: { local.y < $0.typographicBounds.maxY }) ?? lines.last
    else { return base }
    let bounds = line.typographicBounds
    let end = NSMaxRange(line.characterRange)
    if local.x >= bounds.maxX {
      // Past the line's end: before its terminator, the way a click there lands in a text view.
      let last = end - 1
      let terminated =
        last >= 0 && last < storage.length
        && (storage.string as NSString).character(at: min(base + last, storage.length - 1)) == 10
      return base + (terminated ? last : end)
    }
    var index = line.characterIndex(for: local)
    if line.fractionOfDistanceThroughGlyph(for: local) > 0.5 { index += 1 }
    return base + min(max(line.characterRange.location, index), end)
  }

  /// The character whose glyph is under a segment-local point, or nil off the glyphs — the
  /// question a link asks, which an insertion point answers wrongly by never missing.
  func characterOffset(at point: CGPoint) -> Int? {
    guard storage.length > 0, let fragment = fragment(atY: point.y) else { return nil }
    let local = CGPoint(
      x: point.x - fragment.layoutFragmentFrame.minX, y: point.y - fragment.layoutFragmentFrame.minY
    )
    for line in fragment.textLineFragments where line.characterRange.length > 0 {
      let bounds = line.typographicBounds
      guard bounds.contains(local) else { continue }
      let index = line.characterIndex(for: local)
      guard index < NSMaxRange(line.characterRange) else { return nil }
      // Only when the point sits on the glyph itself: `characterIndex` rounds to the nearer
      // edge, so a click to the right of a line's last glyph would answer for it.
      let glyphStart = line.locationForCharacter(at: index).x
      let glyphEnd = line.locationForCharacter(at: index + 1).x
      guard local.x >= min(glyphStart, glyphEnd) - 0.5, local.x <= max(glyphStart, glyphEnd) + 0.5
      else { return nil }
      return startOffset(of: fragment) + index
    }
    return nil
  }

  /// The rectangles a segment-local range covers, in container coordinates.
  func rects(for local: NSRange) -> [CGRect] {
    guard local.length > 0, let startLocation = location(at: local.location),
      let endLocation = location(at: NSMaxRange(local)),
      let textRange = NSTextRange(location: startLocation, end: endLocation)
    else { return [] }
    var rects: [CGRect] = []
    layoutManager.enumerateTextSegments(
      in: textRange, type: .selection, options: [.rangeNotRequired]
    ) {
      _, frame, _, _ in
      rects.append(frame)
      return true
    }
    return rects
  }

  /// The attributes the paragraph carries at its first character — where the block styling
  /// (`.blockBackground`, `.blockAccent`, `.blockEdges`) is read from.
  func attributes(of fragment: NSTextLayoutFragment) -> [NSAttributedString.Key: Any] {
    let start = startOffset(of: fragment)
    guard start < storage.length else { return [:] }
    return storage.attributes(at: start, effectiveRange: nil)
  }
}

/// The layout manager with the link styling taken off. A `.link` run is drawn in the colour and
/// decoration the transcript gave it — a folded tool line is a link so it takes a click, and it
/// is not blue and underlined — which `NSTextView` did by emptying `linkTextAttributes`; a bare
/// stack asks this instead.
final class TranscriptLayoutManager: NSTextLayoutManager {
  override func renderingAttributes(forLink link: Any, at location: any NSTextLocation)
    -> [NSAttributedString.Key: Any]
  {
    [:]
  }
}
