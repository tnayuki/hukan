import AppKit

/// One line of a file's diff, as the gutter and the bands read it.
///
/// A card's body is built so that every one of these is exactly one paragraph, which is what lets
/// both of them index by line number instead of tracking ranges — the same 1:1 mapping the
/// editor's no-wrap rule protects, for the same reason.
enum CommitRow: Equatable {
  /// A hunk's `@@ … @@`.
  case hunk
  case code(old: Int?, new: Int?, kind: Git.FileDiff.Kind)
}

extension NSAttributedString.Key {
  /// The full-width band behind one row: the diff's `+`/`-` column, moved out of the text.
  static let diffBand = NSAttributedString.Key("hukanDiffBand")
}

/// The colours a commit reads in. The bands are pale on purpose — they carry which side a line is
/// on, while the line's own syntax colours carry what it says, and a saturated fill would drown
/// the second under the first.
enum CommitTheme {
  static let addedBand = NSColor.systemGreen.withDynamicAlpha(0.13)
  static let removedBand = NSColor.systemRed.withDynamicAlpha(0.12)
  /// A file card's header strip, behind the path and its counts.
  static let fileBand = NSColor.quaternaryLabelColor
  static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
  static let gutterFont = NSFont.monospacedDigitSystemFont(
    ofSize: NSFont.smallSystemFontSize, weight: .regular)
  /// What a search paints behind every occurrence of what it found.
  static let match = NSColor.systemYellow.withDynamicAlpha(0.35)
  /// The card: a quiet slab the window's material shows through, with its own hairline.
  static let card = NSColor.textBackgroundColor.withDynamicAlpha(0.35)

  static func band(for kind: Git.FileDiff.Kind) -> NSColor? {
    switch kind {
    case .added: return addedBand
    case .removed: return removedBand
    case .context: return nil
    }
  }

  static func color(for status: Git.CommitFile.Status) -> NSColor {
    switch status {
    case .added: return .systemGreen
    case .deleted: return .systemRed
    case .renamed, .copied: return .systemTeal
    case .typeChanged: return .systemOrange
    case .modified: return .secondaryLabelColor
    }
  }
}

/// Paints one row's band across the whole document width.
///
/// The transcript has a fragment for this too (`BlockBackgroundFragment`) and this is not it: a
/// diff band is flat, full-bleed and per-row, where that one is an inset slab with rounded outer
/// corners spanning a run of paragraphs. The reason to keep them apart is cost, though, not
/// looks. Widening a fragment's rendering surface to the document width is what that class does
/// to *every* paragraph, and in a pane where nothing wraps the document is as wide as its
/// longest line; here only a banded row pays for it, and every other row gets a plain fragment.
final class DiffBandFragment: NSTextLayoutFragment {
  var fill: NSColor?
  /// The view the band spans. The container reports nothing usable at draw time, and the
  /// fragment's own frame is the width of its text — which is the ragged edge being avoided.
  weak var textView: NSTextView?

  override var renderingSurfaceBounds: CGRect {
    super.renderingSurfaceBounds.union(bandSurface(in: textView))
  }

  override func draw(at point: CGPoint, in context: CGContext) {
    if let fill { fillBand(fill, at: point, in: context, of: textView) }
    super.draw(at: point, in: context)
  }
}

/// The geometry of a full-width band behind one row, shared by the two fragments that draw one:
/// a commit's diff, where every row is banded and the sign has been taken out of the text, and
/// the editor's, where a patch's rows are banded and every other file's are not.
///
/// The band spans the view rather than the row, because the fragment's own frame is the width of
/// its text — which is the ragged edge being avoided — and the container reports nothing usable
/// at draw time. It reaches left of the container by the container's own inset, so the band meets
/// the gutter's half of it instead of leaving a stripe of window between two halves of one row.
extension NSTextLayoutFragment {
  func fillBand(_ fill: NSColor, at point: CGPoint, in context: CGContext, of textView: NSTextView?)
  {
    context.saveGState()
    context.setFillColor(fill.cgColor)
    context.fill(bandSurface(in: textView).offsetBy(dx: point.x, dy: point.y))
    context.restoreGState()
  }

  /// The band in the fragment's own coordinates, which is what a rendering surface is measured
  /// in and what a draw offsets by its origin. Deliberately not folded into
  /// `renderingSurfaceBounds` here: an override calls this and unions it with `super`'s, and
  /// reading its own property to build it would be a loop.
  func bandSurface(in textView: NSTextView?) -> CGRect {
    let inset = textView?.textContainerInset.width ?? 0
    let padding = textView?.textContainer?.lineFragmentPadding ?? 0
    let reach = inset + padding
    let width =
      textView.map { max(layoutFragmentFrame.width, $0.bounds.width - inset * 2 - padding * 2) }
      ?? layoutFragmentFrame.width
    return CGRect(
      x: -layoutFragmentFrame.origin.x - reach, y: 0, width: width + reach,
      height: layoutFragmentFrame.height)
  }
}

/// Hands a banded row the fragment that can draw it, and every other row a plain one.
final class DiffLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
  weak var textView: NSTextView?

  func textLayoutManager(
    _ textLayoutManager: NSTextLayoutManager,
    textLayoutFragmentFor location: any NSTextLocation,
    in textElement: NSTextElement
  ) -> NSTextLayoutFragment {
    guard let paragraph = textElement as? NSTextParagraph,
      paragraph.attributedString.length > 0,
      let fill = paragraph.attributedString.attribute(.diffBand, at: 0, effectiveRange: nil)
        as? NSColor
    else { return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange) }
    let fragment = DiffBandFragment(textElement: textElement, range: textElement.elementRange)
    fragment.textView = textView
    fragment.fill = fill
    return fragment
  }
}

/// The commit tab's gutter: the line's number on each side, old then new.
///
/// Two columns rather than the editor's one, because a diff line exists on one side or both, and
/// which of those it is *is* the information — so the blank column says added or deleted, and the
/// coloured band behind the row says it again in the periphery. That is the whole of what the
/// `+`/`-` column used to do, and taking it out of the text is what makes a line copy as code.
final class CommitGutter: NSRulerView {
  private weak var textView: NSTextView?
  private var lines = LineIndex()

  /// One entry per document line — `CommitRow.code` is the only one that draws.
  var rows: [CommitRow] = [] {
    didSet {
      lines.invalidate()
      updateThickness()
      needsDisplay = true
    }
  }

  private let padding: CGFloat = 5
  private let gap: CGFloat = 6
  private var oldWidth: CGFloat = 0
  private var newWidth: CGFloat = 0

  init(scrollView: NSScrollView, textView: NSTextView) {
    self.textView = textView
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    clientView = textView
    updateThickness()
  }

  required init(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  /// Nothing of the ruler's own chrome — the desk draws no backgrounds, so neither does this.
  override var isOpaque: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    drawHashMarksAndLabels(in: dirtyRect)
  }

  private func updateThickness() {
    var oldMax = 0
    var newMax = 0
    for row in rows {
      guard case .code(let old, let new, _) = row else { continue }
      oldMax = max(oldMax, old ?? 0)
      newMax = max(newMax, new ?? 0)
    }
    let digit = ("8" as NSString).size(withAttributes: [.font: CommitTheme.gutterFont]).width
    oldWidth = CGFloat(max(2, String(oldMax).count)) * digit
    newWidth = CGFloat(max(2, String(newMax).count)) * digit
    let thickness = ceil(padding + oldWidth + gap + newWidth + padding)
    if abs(thickness - ruleThickness) > 0.5 { ruleThickness = thickness }
  }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let textView,
      let layoutManager = textView.textLayoutManager,
      let contentManager = layoutManager.textContentManager
    else { return }
    lines.rebuildIfNeeded(from: textView.string as NSString)

    let visible = textView.visibleRect
    let inset = textView.textContainerInset
    let from = layoutManager.textLayoutFragment(
      for: CGPoint(x: 0, y: visible.minY - inset.height))
    layoutManager.enumerateTextLayoutFragments(
      from: from?.rangeInElement.location, options: [.ensuresLayout]
    ) { fragment in
      let frame = fragment.layoutFragmentFrame
      if frame.minY + inset.height > visible.maxY { return false }
      let offset = contentManager.offset(
        from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
      let index = lines.line(at: offset) - 1
      guard rows.indices.contains(index) else { return true }
      let top = convert(NSPoint(x: 0, y: frame.minY + inset.height), from: textView).y
      // The band runs under the numbers too: the fragment can only paint from the text
      // container's edge, and a row that stops at the gutter reads as two things, not one.
      // Every row's strip is painted, banded or not. The band has to run under the numbers or a
      // row reads as two things rather than one — and an unpainted strip is worse than plain:
      // AppKit's clip view keeps the scroll view's full width and slides the line underneath, so
      // a long line scrolled sideways reads straight through the numbers.
      switch rows[index] {
      case .code(let old, let new, let kind):
        fill(CommitTheme.band(for: kind), top: top, height: frame.height)
        let height = fragment.textLineFragments.first?.typographicBounds.height ?? frame.height
        draw(old, right: padding + oldWidth, top: top, height: height)
        draw(new, right: padding + oldWidth + gap + newWidth, top: top, height: height)
      case .hunk:
        fill(nil, top: top, height: frame.height)
      }
      return true
    }
  }

  /// One row's strip, opaque from the window up. The card and the bands are both translucent —
  /// pale is the point of them — so painting a band alone would tint the line scrolled underneath
  /// rather than cover it. Laying the window's colour and the card's down first is what the strip
  /// shows anyway, so the pixels are the same and the text below is gone.
  private func fill(_ band: NSColor?, top: CGFloat, height: CGFloat) {
    let rect = NSRect(x: 0, y: top, width: bounds.width, height: height)
    for color in [NSColor.windowBackgroundColor, CommitTheme.card] + (band.map { [$0] } ?? []) {
      color.setFill()
      rect.fill()
    }
  }

  private func draw(_ number: Int?, right: CGFloat, top: CGFloat, height: CGFloat) {
    guard let number else { return }
    let text = "\(number)" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
      .font: CommitTheme.gutterFont, .foregroundColor: NSColor.tertiaryLabelColor,
    ]
    let size = text.size(withAttributes: attributes)
    text.draw(
      at: NSPoint(x: right - size.width, y: top + (height - size.height) / 2),
      withAttributes: attributes)
  }
}

/// One file's diff, drawn inside its card: the coloured rows, the two-column gutter beside them,
/// and horizontal scrolling for the lines that do not fit.
///
/// It is a text view because a diff has to be selected and copied, and because nothing else lays
/// out coloured monospace as cheaply — but it is not an *editor pane*: it never scrolls
/// vertically, it is exactly as tall as its own rows, and the card above it does the framing. The
/// commit tab used to be one text view holding the whole commit, headers and message and all;
/// that is what a patch file looks like, not what a change looks like.
final class CommitDiffBodyView: NSView {
  private let scrollView: NSScrollView
  private let textView: NSTextView
  private let gutter: CommitGutter
  private let layoutDelegate = DiffLayoutDelegate()
  private var heightConstraint: NSLayoutConstraint?

  /// The rows behind the text, so a search can map a match back to what it is looking at.
  private(set) var rows: [CommitRow] = []

  init(diff: LoadedFileDiff) {
    (scrollView, textView) = makeEditorTextView()
    gutter = CommitGutter(scrollView: scrollView, textView: textView)
    super.init(frame: .zero)

    scrollView.hasVerticalScroller = false
    // Overlay scrollers so a long line costs no height: the card is exactly as tall as its rows.
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.verticalScrollElasticity = .none
    layoutDelegate.textView = textView
    textView.textLayoutManager?.delegate = layoutDelegate
    textView.textContainerInset = NSSize(width: 6, height: 6)
    textView.usesFindBar = false
    textView.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(stretchToCard), name: NSView.frameDidChangeNotification,
      object: textView)

    scrollView.verticalRulerView = gutter
    scrollView.hasVerticalRuler = true
    scrollView.rulersVisible = true

    textView.textStorage?.setAttributedString(diff.text)
    rows = diff.rows
    gutter.rows = diff.rows

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    let height = heightAnchor.constraint(equalToConstant: 0)
    height.isActive = true
    heightConstraint = height
    updateHeight()
  }

  required init?(coder: NSCoder) { fatalError() }

  /// The card is as tall as the rows, so the height is measured rather than scrolled to.
  private func updateHeight() {
    guard let layoutManager = textView.textLayoutManager else { return }
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    let inset = textView.textContainerInset.height * 2
    heightConstraint?.constant = ceil(layoutManager.usageBoundsForTextContainer.height + inset)
  }

  /// A band spans the row, and the text is only as wide as its longest line — so a narrow diff
  /// stretches to the card rather than leaving its bands stopping short of the edge. It only ever
  /// grows, so the frame change this makes re-enters once and finds nothing to do.
  @objc private func stretchToCard() {
    let minimum = scrollView.contentView.bounds.width
    if textView.frame.width < minimum { textView.frame.size.width = minimum }
  }

  override func layout() {
    super.layout()
    stretchToCard()
  }

  /// Every occurrence of `term`, marked so all of them read at once — the search's own colour,
  /// applied as a rendering attribute so the text itself is untouched.
  func mark(_ term: String) -> [NSRange] {
    guard let layoutManager = textView.textLayoutManager,
      let contentManager = layoutManager.textContentManager,
      let documentRange = range(contentManager, NSRange(location: 0, length: length))
    else { return [] }
    layoutManager.setRenderingAttributes([:], for: documentRange)
    guard !term.isEmpty else { return [] }

    var found: [NSRange] = []
    let text = textView.string as NSString
    var searched = NSRange(location: 0, length: text.length)
    while searched.length > 0 {
      let match = text.range(of: term, options: [.caseInsensitive], range: searched)
      guard match.location != NSNotFound else { break }
      found.append(match)
      if let range = range(contentManager, match) {
        layoutManager.setRenderingAttributes(
          [.backgroundColor: CommitTheme.match], for: range)
      }
      let next = NSMaxRange(match)
      searched = NSRange(location: next, length: text.length - next)
    }
    return found
  }

  /// Where a match sits in this view's own coordinates, so the tab can scroll it into sight.
  func rect(of match: NSRange) -> NSRect? {
    guard let layoutManager = textView.textLayoutManager,
      let contentManager = layoutManager.textContentManager,
      let range = range(contentManager, match)
    else { return nil }
    var result: NSRect?
    layoutManager.enumerateTextSegments(in: range, type: .standard) { _, frame, _, _ in
      result = frame
      return false
    }
    guard let result else { return nil }
    let inset = textView.textContainerInset
    return convert(
      result.offsetBy(dx: inset.width + gutter.ruleThickness, dy: inset.height), from: nil)
  }

  /// The rows as one string — what a test reads back, and what a search runs over.
  var text: String { textView.string }

  private var length: Int { (textView.string as NSString).length }

  private func range(_ contentManager: NSTextContentManager, _ range: NSRange) -> NSTextRange? {
    let start = contentManager.documentRange.location
    guard let from = contentManager.location(start, offsetBy: range.location),
      let to = contentManager.location(start, offsetBy: NSMaxRange(range))
    else { return nil }
    return NSTextRange(location: from, end: to)
  }
}
