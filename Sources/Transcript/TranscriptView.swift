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
  /// into the scroller. Shared with the view, which draws a message's mark against the same edge.
  static let inset: CGFloat = 2
  private var inset: CGFloat { Self.inset }
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

  /// Where a real link goes. Left unset, a click falls through to AppKit, which hands the URL to
  /// the default browser — and the address an agent just wrote is nearly always one hukan has a
  /// tab for. `Sources/Transcript` may not know what a desk or a worktree is, so the destination
  /// is handed in the way `TranscriptStorageMirror` is: return true once the URL has been taken,
  /// and the default handler is skipped.
  public var onOpenURL: ((URL) -> Bool)?

  public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    // Only our fold link toggles a block. A real link — in a rendered plan, or anywhere in the
    // prose — goes to whoever asked for it, and to the default browser if nobody did.
    guard (link as? URL) == Transcript.toolCallLinkURL else {
      let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
      guard let url, let onOpenURL else { return false }
      return onOpenURL(url)
    }
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
/// The transcript's text view: `WordSelectingTextView`'s double-click, and one thing more — a
/// fast second click on a fold header. That arrives as `clickCount` 2, which the standard
/// handling turns into word selection — on a line whose first click just toggled the fold under
/// the pointer. If the preceding click toggled a fold within the double-click interval, this
/// click is read as another toggle, not a selection.
public final class TranscriptTextView: WordSelectingTextView {
  /// What the `…` at the end of a message offers. Supplied by whoever owns the view, because
  /// `Sources/Transcript` may not know what a session is: the view finds the anchor and the
  /// extent of the message, the owner decides what those mean.
  public struct MessageAction {
    public let title: String
    /// Called with the fork anchor and the message's own extent — `range.location` is how much
    /// of the transcript comes before it, which is what both going back and branching keep.
    public let perform: (String, NSRange) -> Void
    /// Asked as the menu is built, not when the actions were registered, so an item that depends
    /// on what the session is doing right now answers for the session on screen.
    public let isEnabled: () -> Bool

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

  public override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if let found = messageMark(at: point) {
      showMessageMenu(anchor: found.anchor, extent: found.range, at: point)
      return
    }
    if event.clickCount >= 2, retoggleFold(for: event) { return }
    if dragInTable(event, at: point) { return }
    clearTableSelection()
    super.mouseDown(with: event)
  }

  /// The fork point of the message whose `…` is under `point`, or nil when the click is anywhere
  /// else. The mark is not text, so this is geometry: the message under the pointer, then the
  /// same rectangle `drawMessageMarks` put its mark in — so what is hit is exactly what was drawn.
  public func messageMark(at point: NSPoint) -> (anchor: String, range: NSRange)? {
    guard let storage = textStorage, storage.length > 0 else { return nil }
    let index = characterIndexForInsertion(at: point)
    guard let found = Transcript.forkAnchor(in: storage, at: min(index, storage.length - 1)),
      let frame = blockFrame(of: found.range), messageMarkRect(in: frame).contains(point)
    else { return nil }
    return found
  }

  // MARK: Selecting inside a table

  /// The table showing a selection, and where its attachment sits in the storage. The selection
  /// itself lives on the attachment; this is which one is wearing it, and the offset is kept so a
  /// redraw finds the table without walking the transcript.
  private var selectedTable: (table: TableAttachment, offset: Int)?

  /// The table under a point, if the point is on one. Found through the character under the
  /// pointer rather than by scanning the storage: a click must not cost a walk of the transcript.
  private func table(at point: CGPoint) -> (table: TableAttachment, offset: Int, frame: CGRect)? {
    guard let storage = textStorage, storage.length > 0 else { return nil }
    let index = characterIndexForInsertion(at: point)
    // The insertion point falls on either side of the attachment character depending on which
    // half of it was hit, so both sides are candidates.
    for offset in [index, index - 1] where offset >= 0 && offset < storage.length {
      guard
        let table = storage.attribute(.attachment, at: offset, effectiveRange: nil)
          as? TableAttachment,
        let frame = tableFrame(table, at: offset), frame.contains(point)
      else { continue }
      return (table, offset, frame)
    }
    return nil
  }

  /// Where a table's image sits in view coordinates. The attachment is alone on its line, so the
  /// layout fragment's top is the image's top.
  private func tableFrame(_ table: TableAttachment, at offset: Int) -> CGRect? {
    guard let size = table.layout?.size, let layout = textLayoutManager,
      let content = layout.textContentManager,
      let location = content.location(content.documentRange.location, offsetBy: offset),
      let fragment = layout.textLayoutFragment(for: location)
    else { return nil }
    let origin = textContainerOrigin
    let padding = textContainer?.lineFragmentPadding ?? 0
    return CGRect(
      x: origin.x + padding, y: origin.y + fragment.layoutFragmentFrame.minY,
      width: size.width, height: size.height)
  }

  /// What one step of a drag selects: a click drags by character, a double-click by word, a
  /// triple-click by row — the text view's own escalation, each of which goes on extending while
  /// the mouse is down.
  private enum TableGranularity { case character, word, row }

  /// True when the click landed on a table and the drag was handled here. The table's cells are
  /// not text in the storage, so the text view's own selection cannot name them: this runs the
  /// tracking loop itself, and the two selections are exclusive — starting one empties the other.
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
    return true
  }

  /// Drops the table selection, and reports whether there was one — so a key that is only meant
  /// to dismiss it can stop there.
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
      let layout = selected.table.layout, let storage = textStorage,
      selected.offset < storage.length,
      storage.attribute(.attachment, at: selected.offset, effectiveRange: nil)
        as? TableAttachment === selected.table,
      let frame = tableFrame(selected.table, at: selected.offset)
    else { return }
    let colour =
      window?.firstResponder === self && window?.isKeyWindow == true
      ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor
    colour.setFill()
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

  /// A table selection is not a range in the storage, so the standard copy has nothing to write:
  /// this writes the cells instead. Tab-separated, and on the tabular type as well when whole
  /// cells were taken — see `TableAttachment.selectedText`.
  public override func copy(_ sender: Any?) {
    guard let table = selectedTable?.table, let text = table.selectedText() else {
      super.copy(sender)
      return
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    var types: [NSPasteboard.PasteboardType] = [.string]
    if table.selectionSpansCells { types.append(.tabularText) }
    pasteboard.declareTypes(types, owner: nil)
    pasteboard.setString(text, forType: .string)
    if table.selectionSpansCells { pasteboard.setString(text, forType: .tabularText) }
  }

  /// Copy is disabled while the text selection is empty, which is exactly the state a table
  /// selection leaves the view in.
  public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(copy(_:)), selectedTable?.table.selectedText() != nil {
      return true
    }
    return super.validateUserInterfaceItem(item)
  }

  public override func selectAll(_ sender: Any?) {
    clearTableSelection()
    super.selectAll(sender)
  }

  public override func cancelOperation(_ sender: Any?) {
    guard !clearTableSelection() else { return }
    super.cancelOperation(sender)
  }

  // MARK: The message mark

  /// A marked message's `…`, drawn at the vertical centre of the block's trailing edge — over the
  /// text, not in it, which is what lets it sit at the block's centre at all: a fragment can only
  /// draw its own line, and the message's height is known to nothing but the layout. Every marked
  /// block that reaches the viewport gets one, found through the same attribute the click reads.
  public override func draw(_ dirtyRect: NSRect) {
    drawTableSelection()
    super.draw(dirtyRect)
    drawMessageMarks(in: dirtyRect)
  }

  /// The blocks worth asking about are the ones the dirty rect touches, found by the fragments
  /// under its top and bottom edges — not the viewport controller's range, which an offscreen
  /// render (the snapshot tests) never has.
  ///
  /// Internal rather than private for the offscreen renderer, which draws the transcript fragment
  /// by fragment (a view never in a window snapshots empty) and so has to ask for this pass
  /// itself, in the same coordinates the view would use.
  func drawMessageMarks(in dirtyRect: NSRect) {
    guard let storage = textStorage, storage.length > 0, let layout = textLayoutManager,
      let content = layout.textContentManager
    else { return }
    let origin = textContainerOrigin
    func offset(atY y: CGFloat) -> Int? {
      guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: y - origin.y))
      else { return nil }
      return content.offset(
        from: content.documentRange.location, to: fragment.rangeInElement.location)
    }
    let start = offset(atY: dirtyRect.minY) ?? 0
    // One past the bottom fragment's start, so a block that begins on the last touched line is
    // still intersected; past the end of the text, everything to the end.
    let end = offset(atY: dirtyRect.maxY).map { min($0 + 1, storage.length) } ?? storage.length
    guard end > start else { return }
    let whole = NSRange(location: 0, length: storage.length)
    var drawn = Set<Int>()
    storage.enumerateAttribute(
      Transcript.forkAnchorKey, in: NSRange(location: start, length: end - start)
    ) { value, partial, _ in
      guard value != nil else { return }
      // The viewport may cut a block in two; the frame wants all of it.
      var range = NSRange(location: 0, length: 0)
      _ = storage.attribute(
        Transcript.forkAnchorKey, at: partial.location, longestEffectiveRange: &range, in: whole)
      guard drawn.insert(range.location).inserted, let frame = blockFrame(of: range) else { return }
      Self.drawMark(in: messageMarkRect(in: frame))
    }
  }

  /// The tinted slab of a marked message, in view coordinates: from its top pad to its bottom
  /// pad, the outer margin paragraphs on either side left out. Nil until the block is laid out.
  private func blockFrame(of range: NSRange) -> CGRect? {
    guard let layout = textLayoutManager, let content = layout.textContentManager,
      range.length > 3,
      let first = content.location(content.documentRange.location, offsetBy: range.location + 1),
      let last = content.location(
        content.documentRange.location, offsetBy: NSMaxRange(range) - 2),
      let span = NSTextRange(location: first, end: last)
    else { return nil }
    layout.ensureLayout(for: span)
    guard let top = layout.textLayoutFragment(for: first),
      let bottom = layout.textLayoutFragment(for: last)
    else { return nil }
    let origin = textContainerOrigin
    let width =
      bounds.width - textContainerInset.width * 2 - (textContainer?.lineFragmentPadding ?? 0) * 2
    return CGRect(
      x: origin.x + BlockBackgroundFragment.inset,
      y: origin.y + top.layoutFragmentFrame.minY,
      width: width - BlockBackgroundFragment.inset * 2,
      height: bottom.layoutFragmentFrame.maxY - top.layoutFragmentFrame.minY)
  }

  /// Where a block's mark goes: the reserved room at its trailing edge (`messageMarkWidth`),
  /// centred on the block's height. The dots are drawn in the leading part of it, held off the
  /// edge by the text indent, and the whole of it takes the click.
  private func messageMarkRect(in frame: CGRect) -> CGRect {
    CGRect(
      x: frame.maxX - Transcript.messageMarkWidth, y: frame.midY - 10,
      width: Transcript.messageMarkWidth, height: 20)
  }

  /// Three dots, drawn rather than set in a font: a `…` glyph sits on its baseline with the
  /// dots at the bottom of its box, so centring the box leaves the dots low, and how low changes
  /// with the font. Circles centre where they are put.
  private static func drawMark(in rect: CGRect) {
    let radius: CGFloat = 1.5
    let pitch: CGFloat = 5
    // Right-aligned to the text indent, so the dots end where a full line of text would.
    let right = rect.maxX - 14
    NSColor.tertiaryLabelColor.setFill()
    for index in 0..<3 {
      let centre = CGPoint(
        x: right - radius - pitch * CGFloat(2 - index), y: rect.midY)
      NSBezierPath(
        ovalIn: CGRect(
          x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
      ).fill()
    }
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

  /// Re-wrapping has to start from a cleared view, not from what was on it. The transcript
  /// paints no background of its own (`drawsBackground = false`, with the window showing
  /// through) yet it is layer-backed all the same — `wantsLayer` on a sibling in the same
  /// column propagates down the tree — so the layer keeps the last frame's bits. TextKit 2
  /// only redraws the fragments it re-laid, and with no background pass nothing erases the
  /// rest: the old wrapping stays underneath the new one, clipped to the old, wider column.
  /// Visible on every launch, because the split view is resized several times while the
  /// window is being restored and `arrangeColumnsIfNeeded` applies the stored widths after
  /// that. The guard is on width because that is the only change that re-wraps a line (AppKit
  /// invalidates on its own for plenty of others; this covers the one it does not).
  public override func setFrameSize(_ newSize: NSSize) {
    let widthChanged = newSize.width != frame.width
    super.setFrameSize(newSize)
    if widthChanged { needsDisplay = true }
  }

  /// Called after the view has laid out at a wrap width it had not laid out at before — the one
  /// moment the reader's text actually moves, and so the moment to put them back on it.
  ///
  /// Read off the container rather than the frame, and from `layout()` rather than a frame
  /// notification, because neither of those says when a re-wrap happens. `NSTextView` runs a
  /// live resize — a divider drag, a split view collapsing under an animation — with
  /// `postsFrameChangedNotifications` switched off (measured: `viewWillStartLiveResize` clears
  /// it and nothing puts it back), so an observer of the frame goes deaf at the first one and
  /// stays deaf for the life of the view. And within a live resize the frame's width runs
  /// ahead of the text's: the container keeps its old width until the resize ends, or tracks it
  /// a frame late, and the text is laid out where the container is. `layout()` is what follows
  /// every one of those container changes, and by the time it returns the view has done its own
  /// viewport shift, so a placement made here is the last word.
  public var onRewrap: (() -> Void)?

  /// The width the text is wrapped to right now — the container's, which is the one that lays
  /// the lines out; see `onRewrap` for why the frame's is not it.
  public var wrapWidth: CGFloat { textContainer?.size.width ?? 0 }

  private var laidOutWidth: CGFloat = 0

  public override func layout() {
    super.layout()
    let width = wrapWidth
    guard width != laidOutWidth else { return }
    laidOutWidth = width
    onRewrap?()
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

public func makeTranscriptTextView() -> (NSScrollView, TranscriptTextView) {
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
