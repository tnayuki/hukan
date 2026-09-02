import AppKit

/// Where a reader is in the transcript, expressed as a character offset rather than a point
/// offset — the one form that survives the document being laid out again.
///
/// `NSClipView` remembers only `bounds.origin`, and TextKit 2 recomputes the whole document's
/// height whenever the column's width changes. The two together move the text out from under
/// the reader: a long transcript that stands tens of thousands of points tall can double in
/// height when a line's worth of width goes away, and a clip view whose origin never moved
/// lands thousands of points *earlier* in the conversation. Anchoring to a character instead
/// makes the position mean something the relayout cannot alter.
public struct TranscriptScrollAnchor: Equatable {
  /// The character at the top of the viewport, as an offset from the start of the document.
  public let offset: Int
  /// How far the viewport has scrolled into that character's own line fragment, so anchoring
  /// inside a tall paragraph does not snap back to its first line.
  public let within: CGFloat

  /// Read the reader's position off a laid-out view. Nil when the view has no layout to read —
  /// an empty transcript, or one whose storage was just replaced.
  public static func capture(in scrollView: NSScrollView, of textView: NSTextView) -> Self? {
    guard let layout = textView.textLayoutManager, let content = layout.textContentManager
    else { return nil }
    // The viewport's top edge, moved into the text container's coordinates — the space layout
    // fragments are measured in.
    let top = scrollView.documentVisibleRect.minY - textView.textContainerOrigin.y
    guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: top)) else { return nil }
    return Self(
      offset: content.offset(
        from: content.documentRange.location, to: fragment.rangeInElement.location),
      within: top - fragment.layoutFragmentFrame.minY)
  }

  /// Put the reader back on their own text — after a re-wrap, and after earlier conversation was
  /// inserted *above* them, where the anchor's offset has already moved by the insertion's length.
  ///
  /// The whole document is laid out first, not just the part above the anchor: a narrower column
  /// makes the transcript taller, and a clip view clamps a scroll to the height the document view
  /// currently claims — so anchoring to the second half of a re-wrapped transcript lands short
  /// unless the new height is already known. That full pass is why this belongs on a width change
  /// and on a prefix landing, not on every append.
  ///
  /// **The prefix case had a bounded version of its own, and the bound is what made it wrong.**
  /// It laid out only from the document's start through the anchor, on the grounds that
  /// everything above the anchor is exactly what was inserted and the reader's own y is small.
  /// It did the work — 25ms of it on a 900-record conversation — and then reported the geometry
  /// the document had *before* the insert: `textLayoutFragment(for:)` handed back the anchor's
  /// old frame and `usageBoundsForTextContainer` the old height, so the y it computed was the y
  /// the reader was already at, and the scroll that followed was a no-op. They stayed exactly
  /// where they stood, which was now a whole slice earlier in the conversation — the jump this
  /// anchor exists to prevent, arriving from the one direction it was not being read for.
  /// Invalidating that range first did not move it either. Only the pass over the whole document
  /// does, and on the same conversation it cost 28ms against the 25 the bounded one spent to be
  /// wrong.
  public func restore(in scrollView: NSScrollView, of textView: NSTextView) {
    guard let layout = textView.textLayoutManager, let content = layout.textContentManager,
      let location = content.location(content.documentRange.location, offsetBy: offset)
    else { return }
    Self.layOutWholeDocument(of: textView)
    scroll(to: location, in: scrollView, of: textView)
  }

  /// Lay the whole document out at the view's current width, and make the view as tall as it.
  ///
  /// Laying out is not enough on its own: TextKit 2 knows the new height the moment the pass
  /// ends, but the view's frame is only brought up to it on the view's next layout turn, and a
  /// scroll made before then is clamped to the height the frame still claims — the old one, or
  /// an estimate. So the frame is set here, to what the view will set it to anyway, and the
  /// scroll that follows lands where it was aimed. The height is the one `NSTextView` computes
  /// for a vertically resizable view: the text's, plus the inset at each end.
  public static func layOutWholeDocument(of textView: NSTextView) {
    guard let layout = textView.textLayoutManager else { return }
    layout.ensureLayout(for: layout.documentRange)
    let inset = textView.textContainerInset
    let height = ceil(layout.usageBoundsForTextContainer.height + inset.height * 2)
    if height != textView.frame.height {
      textView.setFrameSize(NSSize(width: textView.frame.width, height: height))
    }
  }

  private func scroll(
    to location: NSTextLocation, in scrollView: NSScrollView, of textView: NSTextView
  ) {
    guard let fragment = textView.textLayoutManager?.textLayoutFragment(for: location) else {
      return
    }
    let y = fragment.layoutFragmentFrame.minY + within + textView.textContainerOrigin.y
    scrollView.contentView.scroll(to: CGPoint(x: scrollView.documentVisibleRect.minX, y: y))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }
}
