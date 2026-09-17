import AppKit

/// The transcript, drawn by a view that owns its own height.
///
/// It was an `NSTextView` — one TextKit 2 stack over the whole conversation — and everything
/// that view fought was the view's and not the engine's: it sized itself to TextKit's *estimate*
/// of the text outside the viewport and wrote that estimate over a height that had just been
/// laid out exactly, it fell back to TextKit 1
/// without a word the moment a stray call touched a `layoutManager`, and its selection took no
/// hook a double-click rule could be put on. The engine itself was measured against the
/// snapshot references and matched them paragraph for paragraph, so the engine stays: the same
/// stack, in slices.
///
/// The transcript is written at its two ends — a reply appends, a history slice is put in
/// front — so a slice already laid out is never moved by what arrives later. Each slice is a
/// `TranscriptSegment` with a TextKit 2 stack of its own; inside one, TextKit's geometry is the
/// truth, and the document adds only where the segment starts. The height is then a sum of a
/// few dozen exact numbers, a slice landing above the reader costs its own layout and a shift
/// of the scroll origin by exactly what it added, and a tool call folding open re-lays out the
/// segment it is in and nothing else. What the view gives up against `NSTextView` is what a
/// text view owns and this one has to carry itself: the selection (a drag, the word rule, the
/// cells of a table), copy, the find bar's client, and the cursor.
/// Which edges of a multi-paragraph block this line sits on, so a run of paragraphs draws as
/// one rounded slab instead of a stack of rectangles.
struct BlockEdges: OptionSet {
  let rawValue: Int
  static let top = BlockEdges(rawValue: 1)
  static let bottom = BlockEdges(rawValue: 2)
}

/// Whatever mirrors a transcript view's text offset-for-offset — in the app, the attached
/// session. Fold edits route through it so both copies stay in step; held weakly by the view, so a
/// gone mirror falls back to editing the view alone.
public protocol TranscriptStorageMirror: AnyObject {
  func editTranscript(in range: NSRange, with replacement: NSAttributedString)
}

public final class TranscriptDocumentView: NSView {

  // MARK: The document

  private var segments: [TranscriptSegment] = []

  /// The same inset the text view had, so the fragments land where the references were drawn.
  public var textContainerInset = NSSize(width: 14, height: 12) {
    didSet { relayoutAll() }
  }
  /// `NSTextContainer`'s default, which every line's indent is measured from.
  private let lineFragmentPadding: CGFloat = 5

  /// Segments are cut at about this many paragraphs. The tail grows past it while a reply
  /// streams and is sealed at the next append; a history slice arrives as one segment however
  /// long it is, since it was already the unit the session read.
  static let paragraphsPerSegment = 200

  /// The whole text, as one string. Assembled on demand — the segments are the storage.
  public var string: String {
    var result = ""
    for segment in segments { result += segment.storage.string }
    return result
  }

  public var length: Int { segments.last.map { $0.start + $0.length } ?? 0 }

  /// The width the text is wrapped to: the container's, which is the frame's less the inset.
  public var wrapWidth: CGFloat {
    // A view with no frame yet lays out at a nominal width rather than at one point; the real
    // width re-lays everything out the moment it arrives.
    let width = frame.width - textContainerInset.width * 2
    return width > 1 ? width : 320
  }
  private var textWidth: CGFloat { wrapWidth - lineFragmentPadding * 2 }
  /// Where the segments' container coordinates sit in the view.
  private var containerOrigin: CGPoint {
    CGPoint(x: textContainerInset.width, y: textContainerInset.height)
  }

  /// The document's height: every segment's exact height, plus the inset at each end.
  public var documentHeight: CGFloat {
    (segments.last.map { $0.originY + $0.height } ?? 0) + textContainerInset.height * 2
  }

  /// Called after the text has been laid out at a width it had not been laid out at before —
  /// the one moment the reader's own text moves, and so the moment to put them back on it.
  public var onRewrap: (() -> Void)?

  /// Whatever mirrors this view's text offset-for-offset — in the app, the attached session. Fold
  /// edits go through it so both copies stay in step; with none, the view edits itself.
  public weak var mirror: TranscriptStorageMirror?

  /// Where a real link goes. Left unset, a click hands the URL to the default browser.
  public var onOpenURL: ((URL) -> Bool)?

  /// What the `…` at the end of a message offers. Supplied by whoever owns the view, because
  /// `Sources/Transcript` may not know what a session is: the view finds the anchor and the
  /// extent of the message, the owner decides what those mean.
  public struct MessageAction {
    public let title: String
    public let isEnabled: () -> Bool
    public let perform: (String, NSRange) -> Void

    public init(
      title: String, isEnabled: @escaping () -> Bool = { true },
      perform: @escaping (String, NSRange) -> Void
    ) {
      self.title = title
      self.isEnabled = isEnabled
      self.perform = perform
    }
  }
  public var messageActions: [MessageAction] = []

  public override init(frame: NSRect) {
    super.init(frame: frame)
    autoresizingMask = [.width]
  }

  required init?(coder: NSCoder) { fatalError() }

  public override var isFlipped: Bool { true }
  public override var acceptsFirstResponder: Bool { true }

  /// Scrolled on the main thread, the way an `NSTextView` is. A plain view is scrolled
  /// concurrently by AppKit — the gesture's deltas never reach the main thread — and a session
  /// switch landing while a fling was still running left the overlay scroller refusing to show
  /// for the gestures that followed, until a click or a focus change reset it (measured, with
  /// the private knob alpha). `NSTextView` never had this because it overrides `scrollWheel:`,
  /// which is what opts a document view out of responsive scrolling; the class property that
  /// claims to do the same was measured not to. So this override exists to exist, and forwards.
  public override func scrollWheel(with event: NSEvent) {
    super.scrollWheel(with: event)
  }

  // MARK: Editing the text

  /// Replace the whole conversation. Where the reader lands is the caller's to decide.
  public func setContent(_ text: NSAttributedString) {
    finder.noteClientStringWillChange()
    segments = Self.split(text, width: wrapWidth)
    selectedRange = NSRange(location: 0, length: 0)
    clearTableSelection()
    reindex()
  }

  /// Append to the end. Sealed segments are never reopened: past `paragraphsPerSegment` the next
  /// append starts a new one, so a reply streaming into the tail re-lays out a bounded slice.
  public func append(_ text: NSAttributedString) {
    guard text.length > 0 else { return }
    finder.noteClientStringWillChange()
    if let tail = segments.last, tail.paragraphCount < Self.paragraphsPerSegment {
      tail.append(text)
    } else {
      segments.append(TranscriptSegment(text, width: wrapWidth))
    }
    reindex()
  }

  /// Put earlier conversation in front, without moving the reader: the segment is laid out, and
  /// the scroll origin moves down by exactly what it added. Returns that height.
  @discardableResult
  public func prepend(_ text: NSAttributedString) -> CGFloat {
    guard text.length > 0 else { return 0 }
    finder.noteClientStringWillChange()
    let segment = TranscriptSegment(text, width: wrapWidth)
    segments.insert(segment, at: 0)
    if selectedRange.length > 0 {
      selectedRange.location += segment.length
    } else {
      selectedRange = NSRange(location: 0, length: 0)
    }
    if let selected = selectedTable {
      selectedTable = (selected.table, selected.offset + segment.length)
    }
    reindex()
    if let scrollView = enclosingScrollView {
      var origin = scrollView.contentView.bounds.origin
      origin.y += segment.height
      scroll(origin)
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    return segment.height
  }

  /// Replace a range of the document. A range inside one segment costs that segment; one that
  /// crosses a boundary merges the segments it touches into one first, so a streamed reply that
  /// began before the tail was sealed still lands.
  public func replace(_ range: NSRange, with replacement: NSAttributedString) {
    guard range.location >= 0, NSMaxRange(range) <= length else { return }
    finder.noteClientStringWillChange()
    let delta = replacement.length - range.length
    if segments.isEmpty {
      segments = [TranscriptSegment(replacement, width: wrapWidth)]
    } else {
      let first = segmentIndex(containing: range.location)
      let last = range.length == 0 ? first : segmentIndex(containing: NSMaxRange(range) - 1)
      if first == last {
        let segment = segments[first]
        segment.replace(
          NSRange(location: range.location - segment.start, length: range.length),
          with: replacement)
      } else {
        let merged = NSMutableAttributedString()
        for segment in segments[first...last] {
          merged.append(segment.storage)
        }
        merged.replaceCharacters(
          in: NSRange(location: range.location - segments[first].start, length: range.length),
          with: replacement)
        segments.replaceSubrange(first...last, with: [TranscriptSegment(merged, width: wrapWidth)])
      }
    }
    selectedRange = Self.shifted(selectedRange, by: delta, at: range)
    if let selected = selectedTable {
      if selected.offset >= NSMaxRange(range) {
        selectedTable = (selected.table, selected.offset + delta)
      } else if selected.offset >= range.location {
        clearTableSelection()
      }
    }
    reindex()
  }

  /// Where a range ends up once `edited` was replaced by text `delta` longer.
  private static func shifted(_ range: NSRange, by delta: Int, at edited: NSRange) -> NSRange {
    guard range.length > 0 else { return NSRange(location: 0, length: 0) }
    if NSMaxRange(range) <= edited.location { return range }
    if range.location >= NSMaxRange(edited) {
      return NSRange(location: range.location + delta, length: range.length)
    }
    return NSRange(location: 0, length: 0)
  }

  /// Cut a whole text into segments at bare paragraphs — a margin line with none of the
  /// transcript's block attributes on it — so no block, mark or fold is ever split across two.
  private static func split(_ text: NSAttributedString, width: CGFloat) -> [TranscriptSegment] {
    guard text.length > 0 else { return [] }
    let string = text.string as NSString
    var segments: [TranscriptSegment] = []
    var location = 0
    var cut = 0
    var paragraphs = 0
    while location < string.length {
      let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
      paragraphs += 1
      location = NSMaxRange(paragraph)
      if paragraphs >= paragraphsPerSegment, isBare(text, paragraph) {
        segments.append(
          TranscriptSegment(
            text.attributedSubstring(from: NSRange(location: cut, length: location - cut)),
            width: width))
        cut = location
        paragraphs = 0
      }
    }
    if cut < string.length {
      segments.append(
        TranscriptSegment(
          text.attributedSubstring(from: NSRange(location: cut, length: string.length - cut)),
          width: width))
    }
    return segments
  }

  /// The keys that make a paragraph part of something — a block, a mark, a fold, a table.
  private static let blockKeys: [NSAttributedString.Key] = [
    .blockBackground, .blockAccent, .blockEdges, .attachment, .link,
    Transcript.forkAnchorKey, Transcript.copyableCodeKey, Transcript.toolTokenKey,
    Transcript.toolExpandedKey,
  ]

  private static func isBare(_ text: NSAttributedString, _ paragraph: NSRange) -> Bool {
    guard paragraph.length > 0 else { return true }
    let attributes = text.attributes(at: paragraph.location, effectiveRange: nil)
    return !blockKeys.contains { attributes[$0] != nil }
  }

  /// Recompute every segment's start and origin, size the view to the document, and redraw.
  private func reindex() {
    var start = 0
    var y: CGFloat = 0
    for (index, segment) in segments.enumerated() {
      segment.isTail = index == segments.count - 1
      segment.start = start
      segment.originY = y
      start += segment.length
      y += segment.height
    }
    let height = documentHeight
    if height != frame.height {
      super.setFrameSize(NSSize(width: frame.width, height: height))
    }
    needsDisplay = true
  }

  private func relayoutAll() {
    let width = wrapWidth
    for segment in segments where segment.laidOutWidth != width { segment.layOut(width: width) }
    reindex()
  }

  /// A width change re-wraps every line; the height then follows from the segments, never from
  /// the size the frame was asked for.
  public override func setFrameSize(_ newSize: NSSize) {
    let widthChanged = newSize.width != frame.width
    super.setFrameSize(newSize)
    if widthChanged {
      relayoutAll()
      onRewrap?()
    } else if newSize.height != documentHeight {
      super.setFrameSize(NSSize(width: newSize.width, height: documentHeight))
    }
  }

  // MARK: Reading the text

  /// The index of the segment holding a character offset; the last for the offset past the end.
  private func segmentIndex(containing offset: Int) -> Int {
    var low = 0
    var high = segments.count - 1
    while low < high {
      let mid = (low + high) / 2
      if offset < segments[mid].start + segments[mid].length { high = mid } else { low = mid + 1 }
    }
    return low
  }

  private func segment(containing offset: Int) -> TranscriptSegment? {
    guard !segments.isEmpty, offset >= 0 else { return nil }
    return segments[segmentIndex(containing: offset)]
  }

  /// The segment under a document y (container coordinates), or nil off the ends.
  private func segment(atY y: CGFloat) -> TranscriptSegment? {
    guard !segments.isEmpty, y >= 0 else { return nil }
    var low = 0
    var high = segments.count - 1
    while low < high {
      let mid = (low + high) / 2
      if y < segments[mid].originY + segments[mid].height { high = mid } else { low = mid + 1 }
    }
    let found = segments[low]
    return y < found.originY + found.height ? found : nil
  }

  public func attributedSubstring(_ range: NSRange) -> NSAttributedString {
    let result = NSMutableAttributedString()
    enumerateSegments(in: range) { segment, local in
      result.append(segment.storage.attributedSubstring(from: local))
    }
    return result
  }

  /// Every segment a range touches, with the part of the range inside it as a local range.
  private func enumerateSegments(
    in range: NSRange, _ body: (TranscriptSegment, NSRange) -> Void
  ) {
    guard range.length > 0, !segments.isEmpty else { return }
    var index = segmentIndex(containing: range.location)
    while index < segments.count, segments[index].start < NSMaxRange(range) {
      let segment = segments[index]
      let local = NSIntersectionRange(
        NSRange(location: range.location - segment.start, length: range.length),
        NSRange(location: 0, length: segment.length))
      if local.length > 0 { body(segment, local) }
      index += 1
    }
  }

  /// The attribute at a document offset with the longest range carrying it, in document
  /// offsets. Within one segment: the cuts never fall inside a block, so that is the whole run.
  public func attribute(
    _ key: NSAttributedString.Key, at offset: Int, longestEffectiveRange range: inout NSRange
  ) -> Any? {
    guard let segment = segment(containing: offset), offset < segment.start + segment.length
    else { return nil }
    var local = NSRange(location: 0, length: 0)
    let value = segment.storage.attribute(
      key, at: offset - segment.start, longestEffectiveRange: &local,
      in: NSRange(location: 0, length: segment.length))
    range = NSRange(location: local.location + segment.start, length: local.length)
    return value
  }

  public func attribute(_ key: NSAttributedString.Key, at offset: Int) -> Any? {
    var range = NSRange(location: 0, length: 0)
    return attribute(key, at: offset, longestEffectiveRange: &range)
  }

  /// Paint an attribute across document ranges — the search wash — and repaint. Geometry does
  /// not move for a colour, but TextKit relays the touched fragments, so each touched segment is
  /// asked to settle once, however many ranges fell in it.
  public func paint(_ key: NSAttributedString.Key, value: Any, ranges: [NSRange]) {
    var touched: [ObjectIdentifier: TranscriptSegment] = [:]
    for range in ranges {
      enumerateSegments(in: range) { segment, local in
        segment.storage.addAttribute(key, value: value, range: local)
        touched[ObjectIdentifier(segment)] = segment
      }
    }
    for segment in touched.values { segment.layOut(width: wrapWidth) }
    reindex()
  }

  /// Take an attribute off the whole document.
  public func clearAttribute(_ key: NSAttributedString.Key) {
    for segment in segments {
      segment.storage.removeAttribute(key, range: NSRange(location: 0, length: segment.length))
      segment.layOut(width: wrapWidth)
    }
    reindex()
  }

  /// Walk an attribute's runs across the whole document, in order.
  public func enumerateAttribute(
    _ key: NSAttributedString.Key,
    using body: (Any?, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {
    var stop = ObjCBool(false)
    for segment in segments {
      segment.storage.enumerateAttribute(key, in: NSRange(location: 0, length: segment.length)) {
        value, local, stopPointer in
        body(value, NSRange(location: local.location + segment.start, length: local.length), &stop)
        if stop.boolValue { stopPointer.pointee = true }
      }
      if stop.boolValue { return }
    }
  }

  // MARK: Geometry

  /// The document offset nearest a point in view coordinates, as an insertion point.
  public func insertionOffset(at point: CGPoint) -> Int {
    let y = point.y - containerOrigin.y
    guard !segments.isEmpty else { return 0 }
    if y < 0 { return 0 }
    guard let segment = segment(atY: y) else { return length }
    return segment.start
      + segment.insertionOffset(
        at: CGPoint(x: point.x - containerOrigin.x, y: y - segment.originY))
  }

  /// The character whose glyph is under a point in view coordinates, or nil off the glyphs.
  public func characterOffset(at point: CGPoint) -> Int? {
    let y = point.y - containerOrigin.y
    guard let segment = segment(atY: y),
      let local = segment.characterOffset(
        at: CGPoint(x: point.x - containerOrigin.x, y: y - segment.originY))
    else { return nil }
    return segment.start + local
  }

  /// The paragraph holding a document offset, and its frame in view coordinates.
  private func fragment(at offset: Int) -> (
    segment: TranscriptSegment, fragment: NSTextLayoutFragment
  )? {
    guard let segment = segment(containing: offset),
      let fragment = segment.fragment(at: offset - segment.start)
    else { return nil }
    return (segment, fragment)
  }

  private func viewFrame(of fragment: NSTextLayoutFragment, in segment: TranscriptSegment) -> CGRect
  {
    fragment.layoutFragmentFrame.offsetBy(
      dx: containerOrigin.x, dy: containerOrigin.y + segment.originY)
  }

  /// The top of the line holding an offset, in view coordinates.
  public func y(ofOffset offset: Int) -> CGFloat? {
    guard let (segment, fragment) = fragment(at: offset) else { return nil }
    return viewFrame(of: fragment, in: segment).minY
  }

  /// The rectangles a document range covers, in view coordinates.
  public func rects(for range: NSRange) -> [CGRect] {
    var rects: [CGRect] = []
    enumerateSegments(in: range) { segment, local in
      for rect in segment.rects(for: local) {
        rects.append(rect.offsetBy(dx: containerOrigin.x, dy: containerOrigin.y + segment.originY))
      }
    }
    return rects
  }

  // MARK: The reader's place

  /// Where the reader is: the character at the top of the viewport and how far into its line.
  public struct ReaderAnchor: Equatable {
    public let offset: Int
    public let within: CGFloat
    public init(offset: Int, within: CGFloat) {
      self.offset = offset
      self.within = within
    }
  }

  public func readerAnchor() -> ReaderAnchor? {
    guard let scrollView = enclosingScrollView else { return nil }
    let top = scrollView.documentVisibleRect.minY - containerOrigin.y
    guard let segment = segment(atY: top),
      let fragment = segment.fragment(atY: top - segment.originY)
    else { return nil }
    return ReaderAnchor(
      offset: segment.start + segment.startOffset(of: fragment),
      within: top - segment.originY - fragment.layoutFragmentFrame.minY)
  }

  /// Put the reader back on their own text. Exact: every segment's geometry is laid out, so
  /// there is nothing to lay out first and no estimate to land short in.
  public func scroll(to anchor: ReaderAnchor) {
    guard let (segment, fragment) = fragment(at: anchor.offset) else { return }
    let frame = viewFrame(of: fragment, in: segment)
    // `within` was measured in the paragraph as it was wrapped then; wrapped wider now, the
    // paragraph is shorter, and the same distance would land in the one after it.
    scrollTo(y: frame.minY + min(anchor.within, max(0, frame.height - 1)))
  }

  public func scrollToBottom() {
    guard let scrollView = enclosingScrollView else { return }
    let clip = scrollView.contentView
    scrollTo(y: frame.height + scrollView.contentInsets.bottom - clip.bounds.height)
  }

  /// Bring a document range into view, the way a text view would: no scroll if it is already
  /// visible, otherwise as little as it takes.
  public func scrollRangeToVisible(_ range: NSRange) {
    guard let scrollView = enclosingScrollView, !segments.isEmpty else { return }
    let clamped = NSRange(
      location: min(range.location, max(0, length - 1)), length: min(range.length, 1))
    guard let (segment, fragment) = fragment(at: clamped.location) else { return }
    let rect = rects(for: clamped).first ?? viewFrame(of: fragment, in: segment)
    let visible = scrollView.documentVisibleRect
    if rect.minY >= visible.minY, rect.maxY <= visible.maxY { return }
    if rect.minY < visible.minY {
      scrollTo(y: rect.minY - 8)
    } else {
      scrollTo(y: rect.maxY + 8 - visible.height)
    }
  }

  private func scrollTo(y: CGFloat) {
    guard let scrollView = enclosingScrollView else { return }
    let clip = scrollView.contentView
    let limit = frame.height + scrollView.contentInsets.bottom - clip.bounds.height
    let target = CGPoint(x: clip.bounds.origin.x, y: min(max(0, y), max(0, limit)))
    // Through the view's own scroll, not the clip view's primitive: this is the path the scroll
    // view's gesture machinery is told about, so a placement made while a fling is still running
    // ends the fling rather than fighting it (measured: the overlay scroller stopped answering
    // the next gesture when a session switch landed mid-momentum through the primitive).
    scroll(target)
    scrollView.reflectScrolledClipView(clip)
  }

  // MARK: Drawing

  public override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    render(in: context, dirtyRect: dirtyRect)
  }

  /// Everything the view draws, in view coordinates: the block washes, the selection, the text
  /// and the marks over it. Internal for the offscreen renderer, which draws into a bitmap of its
  /// own rather than through a window.
  func render(in context: CGContext, dirtyRect: NSRect) {
    // Both selections go under the glyphs, the way a text view's does: the wash is opaque and
    // the text has to read through it.
    drawTableSelection()
    drawSelection()
    let origin = containerOrigin
    let top = dirtyRect.minY - origin.y
    let bottom = dirtyRect.maxY - origin.y
    for segment in segments where segment.originY < bottom && segment.originY + segment.height > top
    {
      let localTop = max(0, top - segment.originY)
      let localBottom = bottom - segment.originY
      let from = segment.fragment(atY: localTop)?.rangeInElement.location
      segment.layoutManager.enumerateTextLayoutFragments(from: from, options: [.ensuresLayout]) {
        fragment in
        let box = fragment.layoutFragmentFrame
        if box.minY > localBottom { return false }
        let at = CGPoint(x: origin.x + box.minX, y: origin.y + segment.originY + box.minY)
        drawWash(for: fragment, in: segment, at: at, in: context)
        fragment.draw(at: at, in: context)
        return true
      }
    }
    drawMarks(in: dirtyRect)
  }

  /// The paragraph's block fill across the full column, and its accent bar. Drawn here rather
  /// than by a fragment subclass, which had to widen its rendering surface to reach the column's
  /// edge and was silently lost whenever the text view fell back to TextKit 1.
  private static let washInset: CGFloat = 2
  private static let washRadius: CGFloat = 6
  private static let accentWidth: CGFloat = 3

  private func drawWash(
    for fragment: NSTextLayoutFragment, in segment: TranscriptSegment, at point: CGPoint,
    in context: CGContext
  ) {
    let attributes = segment.attributes(of: fragment)
    let fill = attributes[.blockBackground] as? NSColor
    let accent = attributes[.blockAccent] as? NSColor
    guard fill != nil || accent != nil else { return }
    let edges = BlockEdges(rawValue: attributes[.blockEdges] as? Int ?? 0)
    let box = fragment.layoutFragmentFrame
    let columnWidth = max(box.width, textWidth)
    // Anchored to the column, not to the fragment: an indented paragraph's fragment starts at
    // its indent, and filling from there leaves the band starting to the right of its own text.
    let rect = CGRect(
      x: point.x - box.minX + Self.washInset, y: point.y,
      width: columnWidth - Self.washInset * 2, height: box.height)
    context.saveGState()
    if let fill {
      context.setFillColor(fill.cgColor)
      context.addPath(Self.washPath(in: rect, edges: edges))
      context.fillPath()
    }
    if let accent {
      context.setFillColor(accent.cgColor)
      context.fill(CGRect(x: rect.minX, y: rect.minY, width: Self.accentWidth, height: rect.height))
    }
    context.restoreGState()
  }

  /// Only the outer corners of the block are rounded; interior lines stay square so the
  /// paragraphs meet with no seam.
  private static func washPath(in rect: CGRect, edges: BlockEdges) -> CGPath {
    guard !edges.isEmpty else { return CGPath(rect: rect, transform: nil) }
    var corners: [CGFloat] = [0, 0, 0, 0]
    if edges.contains(.top) {
      corners[0] = washRadius
      corners[1] = washRadius
    }
    if edges.contains(.bottom) {
      corners[2] = washRadius
      corners[3] = washRadius
    }
    let path = CGMutablePath()
    // Flipped coordinates: y grows downward, so "top" is minY.
    path.move(to: CGPoint(x: rect.minX + corners[0], y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - corners[1], y: rect.minY))
    path.addArc(
      tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
      tangent2End: CGPoint(x: rect.maxX, y: rect.minY + corners[1]), radius: corners[1])
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - corners[2]))
    path.addArc(
      tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
      tangent2End: CGPoint(x: rect.maxX - corners[2], y: rect.maxY), radius: corners[2])
    path.addLine(to: CGPoint(x: rect.minX + corners[3], y: rect.maxY))
    path.addArc(
      tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
      tangent2End: CGPoint(x: rect.minX, y: rect.maxY - corners[3]), radius: corners[3])
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + corners[0]))
    path.addArc(
      tangent1End: CGPoint(x: rect.minX, y: rect.minY),
      tangent2End: CGPoint(x: rect.minX + corners[0], y: rect.minY), radius: corners[0])
    path.closeSubpath()
    return path
  }

  // MARK: Selecting text

  /// The selection, in document offsets. Empty means none: the view is read-only and shows no
  /// insertion point.
  public private(set) var selectedRange = NSRange(location: 0, length: 0) {
    didSet { if selectedRange != oldValue { needsDisplay = true } }
  }

  public func setSelectedRange(_ range: NSRange) {
    let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
    selectedRange = clamped.length > 0 ? clamped : NSRange(location: 0, length: 0)
    if selectedRange.length > 0 { clearTableSelection() }
  }

  private var selectionColour: NSColor {
    window?.firstResponder === self && window?.isKeyWindow == true
      ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor
  }

  private func drawSelection() {
    guard selectedRange.length > 0 else { return }
    selectionColour.setFill()
    for rect in rects(for: selectedRange) {
      NSBezierPath(rect: rect).fill()
    }
  }

  private enum Granularity { case character, word, paragraph }

  /// The word under an offset, by the transcript's own token rule.
  private func wordRange(at offset: Int) -> NSRange {
    guard let segment = segment(containing: offset), segment.length > 0 else {
      return NSRange(location: offset, length: 0)
    }
    let local = min(offset - segment.start, segment.length - 1)
    let string = segment.storage.string as NSString
    let appkit = segment.storage.doubleClick(at: local)
    let word =
      WordSelection.word(in: string, click: local, selection: appkit, appkitWord: nil) ?? appkit
    return NSRange(location: word.location + segment.start, length: word.length)
  }

  private func paragraphRange(at offset: Int) -> NSRange {
    guard let segment = segment(containing: offset), segment.length > 0 else {
      return NSRange(location: offset, length: 0)
    }
    let local = min(offset - segment.start, segment.length - 1)
    let paragraph = (segment.storage.string as NSString).paragraphRange(
      for: NSRange(location: local, length: 0))
    return NSRange(location: paragraph.location + segment.start, length: paragraph.length)
  }

  /// Run a drag selection to the mouse-up: a click drags by character, a double-click by word,
  /// a triple-click by paragraph, and ⇧ extends what is already selected. The view is scrolled
  /// along when the pointer leaves it, on the periodic events the loop asks for.
  private func trackSelection(from event: NSEvent, at point: CGPoint) {
    let pressed = insertionOffset(at: point)
    let granularity: Granularity =
      event.clickCount == 2 ? .word : (event.clickCount >= 3 ? .paragraph : .character)
    var anchor = pressed
    if event.modifierFlags.contains(.shift), selectedRange.length > 0 {
      anchor =
        pressed < NSMaxRange(selectedRange) ? NSMaxRange(selectedRange) : selectedRange.location
    }
    func unit(_ offset: Int) -> NSRange {
      switch granularity {
      case .character: return NSRange(location: offset, length: 0)
      case .word: return wordRange(at: offset)
      case .paragraph: return paragraphRange(at: offset)
      }
    }
    let anchorUnit = unit(anchor)
    func extend(to offset: Int) {
      let far = unit(offset)
      let start = min(anchorUnit.location, far.location, anchor, offset)
      let end = max(NSMaxRange(anchorUnit), NSMaxRange(far), anchor, offset)
      setSelectedRange(NSRange(location: start, length: end - start))
    }
    extend(to: pressed)
    NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
    defer { NSEvent.stopPeriodicEvents() }
    var last = event
    while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
      if next.type == .leftMouseUp { break }
      if next.type == .leftMouseDragged { last = next }
      if next.type == .periodic { autoscroll(with: last) }
      extend(to: insertionOffset(at: convert(last.locationInWindow, from: nil)))
    }
  }

  /// The text the selection copies: the runs of the transcript with every table attachment
  /// replaced by its markdown, which is what a table reads as in prose.
  public func selectedText() -> String? {
    guard selectedRange.length > 0 else { return nil }
    let attributed = attributedSubstring(selectedRange)
    let string = attributed.string as NSString
    var result = ""
    attributed.enumerateAttribute(
      .attachment, in: NSRange(location: 0, length: attributed.length)
    ) { value, range, _ in
      if let table = value as? TableAttachment {
        result += table.markdown
      } else {
        result += string.substring(with: range)
      }
    }
    return result
  }

  @objc public func copy(_ sender: Any?) {
    writeSelection(to: .general)
  }

  /// Copy: the table's cells when a table selection is up, otherwise the text selection.
  /// Tab-separated cells go on the tabular type as well — see `TableAttachment.selectedText`.
  public func writeSelection(to pasteboard: NSPasteboard) {
    if let table = selectedTable?.table, let text = table.selectedText() {
      pasteboard.clearContents()
      var types: [NSPasteboard.PasteboardType] = [.string]
      if table.selectionSpansCells { types.append(.tabularText) }
      pasteboard.declareTypes(types, owner: nil)
      pasteboard.setString(text, forType: .string)
      if table.selectionSpansCells { pasteboard.setString(text, forType: .tabularText) }
      return
    }
    guard let text = selectedText() else { return }
    pasteboard.clearContents()
    pasteboard.declareTypes([.string], owner: nil)
    pasteboard.setString(text, forType: .string)
  }

  public override func selectAll(_ sender: Any?) {
    clearTableSelection()
    setSelectedRange(NSRange(location: 0, length: length))
  }

  public override func cancelOperation(_ sender: Any?) {
    if clearTableSelection() { return }
    if selectedRange.length > 0 {
      setSelectedRange(NSRange(location: 0, length: 0))
      return
    }
    nextResponder?.cancelOperation(sender)
  }

  public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(copy(_:)) {
      return selectedTable?.table.selectedText() != nil || selectedRange.length > 0
    }
    if item.action == #selector(selectAll(_:)) { return length > 0 }
    return true
  }

  public override func menu(for event: NSEvent) -> NSMenu? {
    guard selectedRange.length > 0 || selectedTable?.table.selectedText() != nil else { return nil }
    let menu = NSMenu()
    menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
    return menu
  }

  public override func becomeFirstResponder() -> Bool {
    needsDisplay = true
    return super.becomeFirstResponder()
  }

  public override func resignFirstResponder() -> Bool {
    needsDisplay = true
    return super.resignFirstResponder()
  }

  // MARK: The pointer

  private var tracking: NSTrackingArea?

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }

  public override func cursorUpdate(with event: NSEvent) {
    cursor(for: convert(event.locationInWindow, from: nil)).set()
  }

  public override func mouseMoved(with event: NSEvent) {
    cursor(for: convert(event.locationInWindow, from: nil)).set()
  }

  /// The arrow over a mark, the hand over a link (a fold line, an address in prose, a link in a
  /// table's cell), the I-beam over everything else.
  private func cursor(for point: CGPoint) -> NSCursor {
    if copyMark(at: point) != nil || messageMark(at: point) != nil { return .arrow }
    if link(at: point) != nil || tableLink(at: point) != nil { return .pointingHand }
    return .iBeam
  }

  /// The `.link` under a point, only when the point is on its glyphs.
  private func link(at point: CGPoint) -> (url: URL, offset: Int)? {
    guard let offset = characterOffset(at: point) else { return nil }
    let value = attribute(.link, at: offset)
    guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else {
      return nil
    }
    return (url, offset)
  }

  public override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    let point = convert(event.locationInWindow, from: nil)
    if let found = messageMark(at: point) {
      showMessageMenu(anchor: found.anchor, extent: found.range, at: point)
      return
    }
    if let found = copyMark(at: point) {
      copyCode(found.code, of: found.range)
      return
    }
    if event.clickCount >= 2, retoggleFold(for: event) { return }
    if dragInTable(event, at: point) { return }
    clearTableSelection()
    let pressedLink = event.clickCount == 1 ? link(at: point) : nil
    trackSelection(from: event, at: point)
    // A click on a link follows it; a drag that started on one selected instead, and what says
    // which is that the selection never left the character it was pressed on.
    if let pressedLink, selectedRange.length == 0 {
      _ = follow(pressedLink.url, at: pressedLink.offset, event: event)
    }
  }

  /// A link was clicked: the fold link toggles its block, anything else goes to whoever asked
  /// for URLs — and to the default browser if nobody did.
  @discardableResult
  func follow(_ url: URL, at offset: Int, event: NSEvent?) -> Bool {
    if url == Transcript.toolCallLinkURL { return toggleFold(at: offset) }
    if let onOpenURL { return onOpenURL(url) }
    return NSWorkspace.shared.open(url)
  }

  // MARK: Folding tool calls

  /// Where and when the last fold toggled. A fast second click on the same spot arrives as a
  /// double-click, which must read as another toggle, not a word selection.
  private var lastFoldToggle: (location: Int, time: TimeInterval)?

  /// Toggle the tool call whose run holds `offset` between its folded line and its opened block.
  @discardableResult
  public func toggleFold(at offset: Int) -> Bool {
    var range = NSRange(location: 0, length: 0)
    // longestEffectiveRange, not effectiveRange: these runs span colour changes, and
    // effectiveRange stops at the first boundary — replacing only the clicked piece would
    // leave the rest of the line behind as stray text.
    guard
      let token = attribute(Transcript.toolTokenKey, at: offset, longestEffectiveRange: &range)
        as? ToolCallToken
    else { return false }
    if attribute(Transcript.toolExpandedKey, at: offset) != nil {
      // The opened block's extent is wider than the token run under the header (the body
      // carries the token too, but longestEffectiveRange was measured from the header's
      // colour run) — the expanded marker spans exactly the whole block.
      var extent = NSRange(location: 0, length: 0)
      _ = attribute(Transcript.toolExpandedKey, at: offset, longestEffectiveRange: &extent)
      edit(extent, with: Transcript.toolCallLinkRun(token))
      lastFoldToggle = (extent.location, ProcessInfo.processInfo.systemUptime)
    } else {
      edit(range, with: Transcript.toolCallExpandedRun(token))
      lastFoldToggle = (range.location, ProcessInfo.processInfo.systemUptime)
    }
    return true
  }

  /// True if this multi-click continued a toggle sequence and was consumed.
  public func retoggleFold(for event: NSEvent) -> Bool {
    guard let last = lastFoldToggle, event.timestamp - last.time <= NSEvent.doubleClickInterval
    else { return false }
    return toggleFold(at: last.location)
  }

  /// Every folded tool call, and whether each is open — what the scripting verb reads.
  public func foldStates() -> (folded: [Int], expanded: [Int]) {
    var folded: [Int] = []
    var expanded: [Int] = []
    enumerateAttribute(Transcript.toolTokenKey) { value, range, _ in
      guard value is ToolCallToken else { return }
      if attribute(Transcript.toolExpandedKey, at: range.location) != nil {
        expanded.append(range.location)
      } else {
        folded.append(range.location)
      }
    }
    return (folded, expanded)
  }

  /// Open every folded tool call in one pass, and report where `offset` ended up once the text
  /// above it grew. What ⌘F runs before it searches: the folded line carries only the argument's
  /// first 90 characters as text, so a search over a folded transcript would answer for the
  /// summaries rather than for the conversation.
  ///
  /// Walked from the end so the replacements never invalidate the ranges still to come.
  @discardableResult
  public func expandAllFolds(preserving offset: Int = 0) -> Int {
    var folded: [(range: NSRange, token: ToolCallToken)] = []
    enumerateAttribute(Transcript.toolTokenKey) { value, range, _ in
      guard let token = value as? ToolCallToken,
        attribute(Transcript.toolExpandedKey, at: range.location) == nil
      else { return }
      folded.append((range, token))
    }
    var moved = offset
    for fold in folded.reversed() {
      let replacement = Transcript.toolCallExpandedRun(fold.token)
      if NSMaxRange(fold.range) <= offset { moved += replacement.length - fold.range.length }
      edit(fold.range, with: replacement)
    }
    return moved
  }

  private func edit(_ range: NSRange, with replacement: NSAttributedString) {
    if let mirror {
      mirror.editTranscript(in: range, with: replacement)
    } else {
      replace(range, with: replacement)
    }
  }

  // MARK: Selecting inside a table

  /// The table showing a selection, and where its attachment sits in the document. The
  /// selection itself lives on the attachment; this is which one is wearing it.
  private var selectedTable: (table: TableAttachment, offset: Int)?

  /// The table under a point, if the point is on one.
  private func table(at point: CGPoint) -> (table: TableAttachment, offset: Int, frame: CGRect)? {
    guard length > 0 else { return nil }
    let index = insertionOffset(at: point)
    // The insertion point falls on either side of the attachment character depending on which
    // half of it was hit, so both sides are candidates.
    for offset in [index, index - 1] where offset >= 0 && offset < length {
      guard let table = attribute(.attachment, at: offset) as? TableAttachment,
        let frame = tableFrame(table, at: offset), frame.contains(point)
      else { continue }
      return (table, offset, frame)
    }
    return nil
  }

  /// Where a table's image sits in view coordinates. The attachment is alone on its line, so
  /// the layout fragment's top is the image's top.
  private func tableFrame(_ table: TableAttachment, at offset: Int) -> CGRect? {
    guard let size = table.layout?.size, let (segment, fragment) = fragment(at: offset)
    else { return nil }
    let box = viewFrame(of: fragment, in: segment)
    return CGRect(
      x: containerOrigin.x + lineFragmentPadding, y: box.minY, width: size.width,
      height: size.height)
  }

  private enum TableGranularity { case character, word, row }

  /// True when the click landed on a table and the drag was handled here. The table's cells are
  /// not text in the document, so the text selection cannot name them: this runs the tracking
  /// loop itself, and the two selections are exclusive — starting one empties the other.
  private func dragInTable(_ event: NSEvent, at point: CGPoint) -> Bool {
    guard let hit = table(at: point), let layout = hit.table.layout else { return false }
    if selectedTable?.table !== hit.table { clearTableSelection() }
    setSelectedRange(NSRange(location: 0, length: 0))
    let table = hit.table
    selectedTable = (table, hit.offset)

    func local(_ point: CGPoint) -> CGPoint {
      CGPoint(x: point.x - hit.frame.minX, y: point.y - hit.frame.minY)
    }
    guard let pressed = layout.position(at: local(point)) else { return true }
    func word(at position: TableCellPosition) -> NSRange {
      layout.text(row: position.row, column: position.column)?.wordRange(at: position.character)
        ?? NSRange(location: position.character, length: 0)
    }

    // ⇧ extends what is already selected, so the anchor becomes that selection's far end.
    var anchor = pressed
    if event.modifierFlags.contains(.shift) {
      switch table.selection {
      case .text(let span)?:
        anchor = pressed < span.end ? span.end : span.start
      case .block(let block)?:
        anchor = TableCellPosition(
          row: pressed.row <= block.rows.lowerBound ? block.rows.upperBound : block.rows.lowerBound,
          column: pressed.column <= block.columns.lowerBound
            ? block.columns.upperBound : block.columns.lowerBound,
          character: 0)
      case nil:
        break
      }
    }
    let granularity: TableGranularity =
      event.clickCount == 2 ? .word : (event.clickCount >= 3 ? .row : .character)
    let anchorWord = word(at: anchor)

    func extend(to point: CGPoint) {
      guard let current = layout.position(at: local(point)) else { return }
      let next: TableSelection
      if granularity == .row {
        next = .block(
          TableCellBlock(
            rows: min(anchor.row, current.row)...max(anchor.row, current.row),
            columns: 0...(layout.columnCount - 1)))
      } else if current.row != anchor.row || current.column != anchor.column {
        next = .block(
          TableCellBlock(
            rows: min(anchor.row, current.row)...max(anchor.row, current.row),
            columns: min(anchor.column, current.column)...max(anchor.column, current.column)))
      } else if granularity == .word {
        let currentWord = word(at: current)
        next = .text(
          TableTextSpan(
            start: TableCellPosition(
              row: anchor.row, column: anchor.column,
              character: min(anchorWord.location, currentWord.location)),
            end: TableCellPosition(
              row: anchor.row, column: anchor.column,
              character: max(NSMaxRange(anchorWord), NSMaxRange(currentWord)))))
      } else {
        next = .text(TableTextSpan(start: min(anchor, current), end: max(anchor, current)))
      }
      guard table.selection != next else { return }
      table.selection = next
      needsDisplay = true
    }

    extend(to: point)
    while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      if next.type == .leftMouseUp { break }
      extend(to: convert(next.locationInWindow, from: nil))
    }
    followTableLink(at: local(point), in: table, offset: hit.offset, event: event)
    return true
  }

  /// A click on a link inside a cell follows it, the way the same click in the prose does. Asked
  /// after the tracking loop rather than before it, so a drag that starts on a link still selects.
  func followTableLink(
    at point: CGPoint, in table: TableAttachment, offset: Int, event: NSEvent
  ) {
    guard event.clickCount == 1, !event.modifierFlags.contains(.shift),
      case .text(let span)? = table.selection, span.isEmpty,
      let url = table.layout?.link(at: point),
      follow(url, at: offset, event: event)
    else { return }
    clearTableSelection()
  }

  private func tableLink(at point: CGPoint) -> URL? {
    guard let hit = table(at: point) else { return nil }
    return hit.table.layout?.link(
      at: CGPoint(x: point.x - hit.frame.minX, y: point.y - hit.frame.minY))
  }

  @discardableResult
  private func clearTableSelection() -> Bool {
    guard let selected = selectedTable else { return false }
    selected.table.selection = nil
    selectedTable = nil
    needsDisplay = true
    return true
  }

  /// Drawn behind the image rather than over it: the table's row fills are translucent, so the
  /// standard selection colour reads through them the way it does behind text.
  private func drawTableSelection() {
    guard let selected = selectedTable, let selection = selected.table.selection,
      let layout = selected.table.layout, selected.offset < length,
      attribute(.attachment, at: selected.offset) as? TableAttachment === selected.table,
      let frame = tableFrame(selected.table, at: selected.offset)
    else { return }
    selectionColour.setFill()
    let rects: [CGRect]
    let radius: CGFloat
    switch selection {
    case .block(let block):
      rects = [layout.blockRect(block)]
      radius = 3
    case .text(let span):
      rects = layout.textRects(span)
      radius = 2
    }
    for rect in rects {
      NSBezierPath(
        roundedRect: rect.offsetBy(dx: frame.minX, dy: frame.minY), xRadius: radius,
        yRadius: radius
      ).fill()
    }
  }

  // MARK: The block marks

  /// A marked message's `…` and a code slab's copy mark, drawn over the text rather than set in
  /// it: a block's height and corner are known to nothing but the layout, and drawn rather than
  /// typed keeps both out of what a selection through the transcript copies.
  func drawMarks(in dirtyRect: NSRect) {
    enumerateMarkedBlocks(Transcript.forkAnchorKey, in: dirtyRect) { range in
      guard let frame = blockFrame(of: range) else { return }
      Self.drawMark(in: messageMarkRect(in: frame))
    }
    enumerateMarkedBlocks(Transcript.copyableCodeKey, in: dirtyRect) { range in
      guard let line = blockFirstLineFrame(of: range) else { return }
      Self.drawCopyMark(in: copyMarkRect(in: line), copied: copiedBlock == range.location)
    }
  }

  /// Every block carrying `key` that `dirtyRect` touches, whole.
  private func enumerateMarkedBlocks(
    _ key: NSAttributedString.Key, in dirtyRect: NSRect, _ body: (NSRange) -> Void
  ) {
    let top = dirtyRect.minY - containerOrigin.y
    let bottom = dirtyRect.maxY - containerOrigin.y
    var seen = Set<Int>()
    for segment in segments where segment.originY < bottom && segment.originY + segment.height > top
    {
      let localTop = max(0, top - segment.originY)
      let localBottom = min(segment.height, bottom - segment.originY)
      let start = segment.fragment(atY: localTop).map { segment.startOffset(of: $0) } ?? 0
      // One past the bottom fragment's start, so a block that begins on the last touched line is
      // still intersected; past the end of the text, everything to the end.
      let end =
        segment.fragment(atY: localBottom).map {
          min(segment.startOffset(of: $0) + 1, segment.length)
        }
        ?? segment.length
      guard end > start else { continue }
      let whole = NSRange(location: 0, length: segment.length)
      segment.storage.enumerateAttribute(key, in: NSRange(location: start, length: end - start)) {
        value, partial, _ in
        guard value != nil else { return }
        var range = NSRange(location: 0, length: 0)
        _ = segment.storage.attribute(
          key, at: partial.location, longestEffectiveRange: &range, in: whole)
        let global = NSRange(location: range.location + segment.start, length: range.length)
        guard seen.insert(global.location).inserted else { return }
        body(global)
      }
    }
  }

  /// The tinted slab of a marked message, in view coordinates: from its top pad to its bottom
  /// pad, the outer margin paragraphs on either side left out. Nil until the block is laid out.
  func blockFrame(of range: NSRange) -> CGRect? {
    guard range.length > 3, let (segment, top) = fragment(at: range.location + 1),
      let (_, bottom) = fragment(at: NSMaxRange(range) - 2)
    else { return nil }
    let width = textWidth
    return CGRect(
      x: containerOrigin.x + Self.washInset,
      y: containerOrigin.y + segment.originY + top.layoutFragmentFrame.minY,
      width: width - Self.washInset * 2,
      height: bottom.layoutFragmentFrame.maxY - top.layoutFragmentFrame.minY)
  }

  /// The first line of text in a slab, in the same coordinates `blockFrame` reports. A slab opens
  /// with two blank paragraphs — its outer margin and its top pad — so the line the copy mark
  /// belongs beside starts two characters in.
  func blockFirstLineFrame(of range: NSRange) -> CGRect? {
    guard let frame = blockFrame(of: range), range.length > 4,
      let (segment, paragraph) = fragment(at: range.location + 2)
    else { return nil }
    let box = paragraph.layoutFragmentFrame
    // Fragment-local, so the line's own offset within the paragraph is added to the paragraph's.
    let line = paragraph.textLineFragments.first?.typographicBounds
    return CGRect(
      x: frame.minX, y: containerOrigin.y + segment.originY + box.minY + (line?.minY ?? 0),
      width: frame.width, height: line?.height ?? box.height)
  }

  private func messageMarkRect(in frame: CGRect) -> CGRect {
    CGRect(
      x: frame.maxX - Transcript.messageMarkWidth, y: frame.midY - 10,
      width: Transcript.messageMarkWidth, height: 20)
  }

  /// Three dots, drawn rather than set in a font: a `…` glyph sits on its baseline with the
  /// dots at the bottom of its box, so centring the box leaves the dots low. Circles centre
  /// where they are put.
  private static func drawMark(in rect: CGRect) {
    let radius: CGFloat = 1.5
    let pitch: CGFloat = 5
    // Right-aligned to the text indent, so the dots end where a full line of text would.
    let right = rect.maxX - 14
    NSColor.tertiaryLabelColor.setFill()
    for index in 0..<3 {
      let centre = CGPoint(x: right - radius - pitch * CGFloat(2 - index), y: rect.midY)
      NSBezierPath(
        ovalIn: CGRect(
          x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
      ).fill()
    }
  }

  private func copyMarkRect(in line: CGRect) -> CGRect {
    CGRect(
      x: line.maxX - Transcript.copyMarkWidth, y: line.minY,
      width: Transcript.copyMarkWidth, height: line.height)
  }

  /// Two sheets, or a tick once the code has been taken — drawn as paths so the pass lands the
  /// same in the view and in the offscreen renderer's manually flipped context.
  private static func drawCopyMark(in rect: CGRect, copied: Bool) {
    // Right-aligned to the text indent, so the glyph ends where a full line of code would.
    let box = CGRect(x: rect.maxX - 12 - 11, y: rect.midY - 6, width: 11, height: 12)
    let stroke = copied ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
    stroke.setStroke()
    if copied {
      let tick = NSBezierPath()
      tick.lineWidth = 1.5
      tick.lineCapStyle = .round
      tick.lineJoinStyle = .round
      tick.move(to: CGPoint(x: box.minX + 1, y: box.minY + 6))
      tick.line(to: CGPoint(x: box.minX + 4, y: box.minY + 9))
      tick.line(to: CGPoint(x: box.minX + 10, y: box.minY + 2.5))
      tick.stroke()
      return
    }
    let front = CGRect(x: box.minX, y: box.minY + 2.5, width: 8, height: 9.5)
    let back = front.offsetBy(dx: 2.5, dy: -2.5)
    // The back sheet is the part of it the front does not cover, so the two read as one behind
    // the other rather than as a lattice.
    NSGraphicsContext.saveGraphicsState()
    let clip = NSBezierPath(rect: box.insetBy(dx: -2, dy: -2))
    clip.append(NSBezierPath(roundedRect: front.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2))
    clip.windingRule = .evenOdd
    clip.addClip()
    let backPath = NSBezierPath(roundedRect: back, xRadius: 1.5, yRadius: 1.5)
    backPath.lineWidth = 1
    backPath.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let frontPath = NSBezierPath(roundedRect: front, xRadius: 1.5, yRadius: 1.5)
    frontPath.lineWidth = 1
    frontPath.stroke()
  }

  /// The fork point of the message whose `…` is under `point`, or nil when the click is anywhere
  /// else. The mark is not text, so this is geometry: the message under the pointer, then the
  /// same rectangle `drawMarks` put its mark in — so what is hit is exactly what was drawn.
  public func messageMark(at point: NSPoint) -> (anchor: String, range: NSRange)? {
    guard length > 0 else { return nil }
    let index = min(insertionOffset(at: point), length - 1)
    var range = NSRange(location: 0, length: 0)
    guard
      let anchor = attribute(Transcript.forkAnchorKey, at: index, longestEffectiveRange: &range)
        as? String,
      let frame = blockFrame(of: range), messageMarkRect(in: frame).contains(point)
    else { return nil }
    return (anchor, range)
  }

  /// The code slab whose mark is showing a tick, by where it starts.
  private var copiedBlock: Int?
  private var copiedReset: Timer?

  /// The code of the slab whose copy mark is under `point`, or nil anywhere else.
  public func copyMark(at point: NSPoint) -> (code: String, range: NSRange)? {
    guard length > 0 else { return nil }
    let index = min(insertionOffset(at: point), length - 1)
    var range = NSRange(location: 0, length: 0)
    guard
      let code = attribute(Transcript.copyableCodeKey, at: index, longestEffectiveRange: &range)
        as? String,
      let line = blockFirstLineFrame(of: range), copyMarkRect(in: line).contains(point)
    else { return nil }
    return (code, range)
  }

  /// Take the block's code, and say so for a beat.
  public func copyCode(_ code: String, of range: NSRange, to pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    pasteboard.declareTypes([.string], owner: nil)
    pasteboard.setString(code, forType: .string)
    copiedBlock = range.location
    copiedReset?.invalidate()
    copiedReset = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
      self?.copiedBlock = nil
      self?.needsDisplay = true
    }
    needsDisplay = true
  }

  /// Open the message's menu under the `…` that was clicked. Nothing to offer is not an empty
  /// menu but no menu — a click that pops a blank panel reads as a fault.
  func showMessageMenu(anchor: String, extent: NSRange, at point: NSPoint) {
    guard !messageActions.isEmpty else { return }
    let menu = NSMenu()
    // Each item answers for itself; the standard auto-enabling would ask the responder chain to
    // validate a selector all of them share and turn them all on together.
    menu.autoenablesItems = false
    for action in messageActions {
      let item = NSMenuItem(
        title: action.title, action: #selector(performMessageAction(_:)), keyEquivalent: "")
      item.target = self
      item.isEnabled = action.isEnabled()
      item.representedObject = MessageActionInvocation(
        perform: action.perform, anchor: anchor, extent: extent)
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: point, in: self)
  }

  private final class MessageActionInvocation {
    let perform: (String, NSRange) -> Void
    let anchor: String
    let extent: NSRange

    init(perform: @escaping (String, NSRange) -> Void, anchor: String, extent: NSRange) {
      self.perform = perform
      self.anchor = anchor
      self.extent = extent
    }
  }

  @objc private func performMessageAction(_ sender: NSMenuItem) {
    guard let invocation = sender.representedObject as? MessageActionInvocation else { return }
    invocation.perform(invocation.anchor, invocation.extent)
  }

  // MARK: The find bar

  /// The standard bar, on this view as its client: the text is the segments joined, and a hit's
  /// rectangles are read off the segment that holds it.
  let finder = NSTextFinder()

  public func performFindPanelAction(_ sender: Any?) {
    let tag = (sender as? NSMenuItem)?.tag ?? Int(NSFindPanelAction.showFindPanel.rawValue)
    guard let action = NSTextFinder.Action(rawValue: tag) else { return }
    finder.performAction(action)
  }
}

extension TranscriptDocumentView: NSUserInterfaceValidations {}

extension TranscriptDocumentView: NSTextFinderClient {
  public var isSelectable: Bool { true }
  public var allowsMultipleSelection: Bool { false }
  public var isEditable: Bool { false }
  public var stringLength: Int { length }
  public var firstSelectedRange: NSRange { selectedRange }

  public var selectedRanges: [NSValue] {
    get { selectedRange.length > 0 ? [NSValue(range: selectedRange)] : [] }
    set { setSelectedRange(newValue.first?.rangeValue ?? NSRange(location: 0, length: 0)) }
  }

  public var visibleCharacterRanges: [NSValue] {
    guard let visible = enclosingScrollView?.documentVisibleRect, length > 0 else { return [] }
    let start = insertionOffset(at: CGPoint(x: 0, y: visible.minY))
    let end = insertionOffset(at: CGPoint(x: bounds.maxX, y: visible.maxY))
    return [NSValue(range: NSRange(location: start, length: max(0, end - start)))]
  }

  public func rects(forCharacterRange range: NSRange) -> [NSValue]? {
    rects(for: range).map { NSValue(rect: $0) }
  }

  public func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView
  {
    outRange.pointee = NSRange(location: 0, length: length)
    return self
  }

  public func drawCharacters(in range: NSRange, forContentView view: NSView) {
    // The bar's overlay draws a hit's characters in its own context, which is this view's
    // coordinate space already (the content view is this one): draw the fragments holding the
    // range, clipped to the range's rectangles.
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let clip = rects(for: range)
    guard !clip.isEmpty else { return }
    context.saveGState()
    context.clip(to: clip)
    render(in: context, dirtyRect: clip.reduce(clip[0]) { $0.union($1) })
    context.restoreGState()
  }
}

/// The scroll view and the transcript view inside it — the standard wiring, assembled by hand.
public func makeTranscriptDocumentView() -> (NSScrollView, TranscriptDocumentView) {
  let view = TranscriptDocumentView(frame: .zero)
  let scrollView = NSScrollView()
  scrollView.documentView = view
  scrollView.drawsBackground = false
  scrollView.hasVerticalScroller = true
  view.finder.client = view
  view.finder.findBarContainer = scrollView
  view.finder.isIncrementalSearchingEnabled = true
  view.finder.incrementalSearchingShouldDimContentView = false
  return (scrollView, view)
}
