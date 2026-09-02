import AppKit

extension NSColor {
  /// `withAlphaComponent` on a *catalog* colour is not the small thing it looks like: it resolves
  /// the colour against whatever appearance happens to be current and hands back a plain sRGB one.
  /// Every colour in this folder is built while an attributed string is assembled, which is not a
  /// drawing moment and promises nothing about the appearance — so
  /// `.quaternarySystemFill.withAlphaComponent(0.25)` froze to white on one machine and to black
  /// on another, and the blockquote's slab came out darker than the transcript behind it. The
  /// value was never wrong at the point of use; it was decided too early.
  ///
  /// This keeps the colour dynamic instead. The alpha is applied when the colour is *read* —
  /// inside the draw, under the appearance that is drawing it.
  func withDynamicAlpha(_ alpha: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
      var resolved = self
      appearance.performAsCurrentDrawingAppearance { resolved = self.withAlphaComponent(alpha) }
      return resolved
    }
  }
}
