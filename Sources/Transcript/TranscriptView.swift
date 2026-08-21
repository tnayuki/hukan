import AppKit

/// Paints a paragraph's background across the full column instead of only behind its glyphs.
///
/// `.backgroundColor` stops where the text stops, so a wrapped line ends in a ragged edge and
/// the result reads as a highlighter rather than a block. TextKit 2 hands the fragment its own
/// `draw`, which is the supported place to fix that.
/// Which edges of a multi-paragraph block this line sits on, so a run of paragraphs draws as
/// one rounded slab instead of a stack of rectangles.
struct BlockEdges: OptionSet {
  let rawValue: Int
  static let top = BlockEdges(rawValue: 1)
  static let bottom = BlockEdges(rawValue: 2)
}

final class BlockBackgroundFragment: NSTextLayoutFragment {
  var fill: NSColor?
  var accent: NSColor?
  var edges: BlockEdges = []
  /// The text view this fragment belongs to. The container reports nothing usable either
  /// when the fragment is built or when it draws, and falling back to the fragment's own
  /// frame collapses the fill to the width of the text — the ragged edge this class exists
  /// to remove. The view's bounds are known at draw time and are the honest number.
  weak var textView: NSTextView?

  /// Left and right breathing room, so a block is inset from the column rather than bleeding
  /// into the scroller.
  private let inset: CGFloat = 2
  private let radius: CGFloat = 6
  private let accentWidth: CGFloat = 3

  /// TextKit 2 clips a fragment's drawing to the area it declares, and the default is the
  /// extent of the text. Without widening it the fill is computed correctly and then thrown
  /// away past the last glyph, which looks exactly like the bug this class was meant to fix.
  override var renderingSurfaceBounds: CGRect {
    // Fragment-local, and the fragment starts at the paragraph's indent — so reaching the
    // column's left edge means going negative by exactly that much.
    super.renderingSurfaceBounds.union(
      CGRect(
        x: -layoutFragmentFrame.origin.x, y: 0,
        width: columnWidth, height: layoutFragmentFrame.height))
  }

  override func draw(at point: CGPoint, in context: CGContext) {
    if fill != nil || accent != nil {
      // Anchored to the column, not to the fragment: an indented paragraph's fragment
      // starts at its indent, and filling from there leaves the band starting to the
      // right of its own text.
      let left = point.x - layoutFragmentFrame.origin.x + inset
      let rect = CGRect(
        x: left, y: point.y,
        width: columnWidth - inset * 2, height: layoutFragmentFrame.height)
      context.saveGState()
      if let fill {
        context.setFillColor(fill.cgColor)
        context.addPath(path(in: rect))
        context.fillPath()
      }
      if let accent {
        context.setFillColor(accent.cgColor)
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: accentWidth, height: rect.height))
      }
      context.restoreGState()
    }
    super.draw(at: point, in: context)
  }

  private var columnWidth: CGFloat {
    guard let textView else { return layoutFragmentFrame.width }
    let padding = textView.textContainer?.lineFragmentPadding ?? 0
    return max(
      layoutFragmentFrame.width,
      textView.bounds.width - textView.textContainerInset.width * 2 - padding * 2)
  }

  /// Only the outer corners of the block are rounded; interior lines stay square so the
  /// paragraphs meet with no seam.
  private func path(in rect: CGRect) -> CGPath {
    guard !edges.isEmpty else { return CGPath(rect: rect, transform: nil) }
    var corners: [CGFloat] = [0, 0, 0, 0]
    if edges.contains(.top) {
      corners[0] = radius
      corners[1] = radius
    }
    if edges.contains(.bottom) {
      corners[2] = radius
      corners[3] = radius
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

}

final class TranscriptLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
  weak var textView: NSTextView?

  func textLayoutManager(
    _ textLayoutManager: NSTextLayoutManager,
    textLayoutFragmentFor location: any NSTextLocation,
    in textElement: NSTextElement
  ) -> NSTextLayoutFragment {
    let fragment = BlockBackgroundFragment(
      textElement: textElement, range: textElement.elementRange)
    fragment.textView = textView
    guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0
    else { return fragment }
    let attributes = paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
    fragment.fill = attributes[.blockBackground] as? NSColor
    fragment.accent = attributes[.blockAccent] as? NSColor
    fragment.edges = BlockEdges(rawValue: attributes[.blockEdges] as? Int ?? 0)
    return fragment
  }
}

private nonisolated(unsafe) var layoutDelegateKey = 0
private nonisolated(unsafe) var clickDelegateKey = 0

/// Toggles a tool call between its two text forms when its header line is clicked: the folded
/// line (`Transcript.toolCallLinkRun`) and the opened block (`toolCallExpandedRun`). Both are
/// plain text carrying the `ToolCallToken`; only the header lines carry `.link`, so a click on
/// the opened block's body selects text instead of folding it.
///
/// The toggle goes through the attached mirror, not straight into the view's storage: in the
/// app that mirror is the session, whose transcript and the storage mirror each other by
/// offset — every later streaming replace is computed against the transcript, so an edit to
/// only one of them shifts every one of those ranges off target. Views with nothing behind
/// them (the offscreen harness, the diff pane) edit their own storage, which mirrors nothing.
public final class TranscriptClickDelegate: NSObject, NSTextViewDelegate {
  public weak var mirror: TranscriptStorageMirror?

  /// Where and when the last fold toggled. A fast second click on the same spot arrives as a
  /// double-click, which must read as another toggle, not a word selection — the text view
  /// checks this to tell the two apart (see `TranscriptTextView.retoggleFold`). The location
  /// stays valid across the toggle because the replacement lands exactly where the old run
  /// began.
  private(set) var lastFoldToggle: (location: Int, time: TimeInterval)?

  public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    // Only our fold link toggles a block; a real link inside a rendered plan (or anywhere in
    // the transcript) opens normally through the default handler.
    guard (link as? URL) == Transcript.toolCallLinkURL else { return false }
    guard let storage = textView.textStorage, charIndex < storage.length else { return false }
    let whole = NSRange(location: 0, length: storage.length)
    var range = NSRange(location: 0, length: 0)
    // longestEffectiveRange, not effectiveRange: these runs span colour changes, and
    // effectiveRange stops at the first boundary — replacing only the clicked piece would
    // leave the rest of the line behind as stray text.
    guard
      let token = storage.attribute(
        Transcript.toolTokenKey, at: charIndex,
        longestEffectiveRange: &range, in: whole) as? ToolCallToken
    else { return false }
    if storage.attribute(Transcript.toolExpandedKey, at: charIndex, effectiveRange: nil) != nil {
      // The opened block's extent is wider than the token run under the header (the body
      // carries the token too, but longestEffectiveRange was measured from the header's
      // colour run) — the expanded marker spans exactly the whole block.
      var extent = NSRange(location: 0, length: 0)
      _ = storage.attribute(
        Transcript.toolExpandedKey, at: charIndex,
        longestEffectiveRange: &extent, in: whole)
      edit(storage, range: extent, replacement: Transcript.toolCallLinkRun(token))
      lastFoldToggle = (extent.location, ProcessInfo.processInfo.systemUptime)
    } else {
      edit(storage, range: range, replacement: Transcript.toolCallExpandedRun(token))
      lastFoldToggle = (range.location, ProcessInfo.processInfo.systemUptime)
    }
    return true
  }

  private func edit(_ storage: NSTextStorage, range: NSRange, replacement: NSAttributedString) {
    if let mirror {
      mirror.editTranscript(in: range, with: replacement)
    } else {
      storage.replaceCharacters(in: range, with: replacement)
    }
  }
}

/// Whatever mirrors a transcript view's storage offset-for-offset — in the app, the attached
/// session. Fold edits route through it so both copies stay in step; held weakly by the click
/// delegate, so a gone mirror falls back to editing the storage directly.
public protocol TranscriptStorageMirror: AnyObject {
  func editTranscript(in range: NSRange, with replacement: NSAttributedString)
}

public func transcriptClickDelegate(of textView: NSTextView) -> TranscriptClickDelegate? {
  objc_getAssociatedObject(textView, &clickDelegateKey) as? TranscriptClickDelegate
}

/// Also used by the offscreen preview, so the two render through the same setup.
/// The transcript's text view: standard in everything except a fast second click on a fold
/// header. That arrives as `clickCount` 2, which the standard handling turns into word
/// selection — on a line whose first click just toggled the fold under the pointer. If the
/// preceding click toggled a fold within the double-click interval, this click is read as
/// another toggle, not a selection.
public final class TranscriptTextView: NSTextView {
  public override func mouseDown(with event: NSEvent) {
    if event.clickCount >= 2, retoggleFold(for: event) { return }
    super.mouseDown(with: event)
  }

  /// A table renders as one drawn attachment, so the plain-text rendition of a selection that
  /// covers it copies as `￼`. After the standard write, overwrite the string type with one where
  /// each table attachment is expanded back to its markdown — so selecting across a table and
  /// copying yields the cells as text. The rich-text types keep the default (the table's image).
  public override func writeSelection(
    to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
  ) -> Bool {
    let wrote = super.writeSelection(to: pboard, types: types)
    guard types.contains(.string) else { return wrote }
    let selection = selectedRange()
    guard selection.length > 0,
      let attributed = textStorage?.attributedSubstring(from: selection),
      Self.hasTable(attributed)
    else { return wrote }
    pboard.setString(Self.expanded(attributed), forType: .string)
    return true
  }

  private static func hasTable(_ attributed: NSAttributedString) -> Bool {
    var found = false
    attributed.enumerateAttribute(
      .attachment, in: NSRange(location: 0, length: attributed.length)
    ) { value, _, stop in
      if value is TableAttachment {
        found = true
        stop.pointee = true
      }
    }
    return found
  }

  /// The selection as plain text with every table attachment replaced by its markdown.
  private static func expanded(_ attributed: NSAttributedString) -> String {
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

  /// True if this multi-click continued a toggle sequence and was consumed. Split from
  /// `mouseDown` so the offscreen test can exercise the decision without the tracking loop
  /// `super.mouseDown` enters (which needs a real window and real events).
  public func retoggleFold(for event: NSEvent) -> Bool {
    guard let delegate = delegate as? TranscriptClickDelegate,
      let last = delegate.lastFoldToggle,
      event.timestamp - last.time <= NSEvent.doubleClickInterval
    else { return false }
    return delegate.textView(self, clickedOnLink: Transcript.toolCallLinkURL, at: last.location)
  }
}

public func makeTranscriptTextView() -> (NSScrollView, NSTextView) {
  // Assembled by hand because `scrollableTextView()` cannot be told to instantiate a subclass.
  // The rest of the recipe is the standard text-view-in-scroll-view wiring.
  let textView = TranscriptTextView(usingTextLayoutManager: true)
  let scrollView = NSScrollView()
  scrollView.documentView = textView
  textView.minSize = .zero
  textView.maxSize = NSSize(
    width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
  textView.isVerticallyResizable = true
  textView.isHorizontallyResizable = false
  textView.autoresizingMask = [.width]
  textView.textContainer?.widthTracksTextView = true
  textView.isEditable = false
  // Read-only, but the transcript is there to be quoted — the reply has to be copyable.
  // Selectable is the default, but a non-editable view is exactly where it gets turned off by
  // accident, so pin it.
  textView.isSelectable = true
  textView.drawsBackground = false
  textView.textContainerInset = NSSize(width: 14, height: 12)
  // A folded tool line is a `.link` run so it takes a click, but it is not a hyperlink — empty the
  // link styling so it keeps its own colours (not blue + underline); the cursor stays a hand.
  textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
  // NSTextLayoutManager holds its delegate weakly, and the delegate has to be per-view to
  // know which view's width to measure. Associating it with the view gives it that lifetime.
  let layoutDelegate = TranscriptLayoutDelegate()
  layoutDelegate.textView = textView
  objc_setAssociatedObject(textView, &layoutDelegateKey, layoutDelegate, .OBJC_ASSOCIATION_RETAIN)
  textView.textLayoutManager?.delegate = layoutDelegate
  // NSTextView also holds its delegate weakly, so associate it for the view's lifetime too. It
  // toggles a folded tool line and its expanded text block on click.
  let clickDelegate = TranscriptClickDelegate()
  objc_setAssociatedObject(textView, &clickDelegateKey, clickDelegate, .OBJC_ASSOCIATION_RETAIN)
  textView.delegate = clickDelegate
  scrollView.drawsBackground = false
  scrollView.hasVerticalScroller = true
  return (scrollView, textView)
}
