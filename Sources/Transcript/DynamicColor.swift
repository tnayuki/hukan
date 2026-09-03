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
    dynamicSRGB { $0.withAlphaComponent(alpha) }
  }

  /// The colour as it is, decided under the appearance that draws it.
  ///
  /// Which is not nothing even without an alpha to apply: a catalog colour resolves into *device*
  /// RGB, and device RGB means the attached display's profile — so the same `systemTeal` lands a
  /// couple of counts apart on two machines with different screens. sRGB is colour-managed the
  /// same way on the way out, so nothing looks different; it is only no longer ambiguous about
  /// which teal it meant.
  var dynamic: NSColor { dynamicSRGB { $0 } }

  private func dynamicSRGB(_ transform: @escaping (NSColor) -> NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      var resolved = self
      appearance.performAsCurrentDrawingAppearance {
        let flat = transform(self)
        resolved = flat.usingColorSpace(.sRGB) ?? flat
      }
      return resolved
    }
  }
}
