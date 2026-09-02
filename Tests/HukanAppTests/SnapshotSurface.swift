import AppKit

/// The surface every pixel-pinned test draws on, and the whole of what keeps a reference from
/// being a photograph of the machine that recorded it.
///
/// Three ways the screen used to reach the image, each measured against a CI runner in 2026-09:
///
/// - A window's `backingScaleFactor` is the grid AppKit aligns layout to — 0.5pt where it is 2,
///   1.0pt where it is 1 — so the same view laid out on a 1x display puts its text a device pixel
///   off, per element. That was 13% of the History section's pixels.
/// - `NSImage.lockFocus` and `bitmapImageRepForCachingDisplay` take their scale from the display,
///   so a reference recorded on a 2x machine came back half size on a 1x one.
/// - A `.deviceRGB` bitmap is *device* RGB. Greys survive the conversion untouched and saturated
///   colours do not, so a commit's diff bands moved by one to five counts under another display
///   profile while everything around them matched.
///
/// So the window pins the scale, the bitmap pins the scale and sRGB, and nothing here asks the
/// screen anything. What a snapshot then pins is hukan's drawing, which is what it is for.
enum SnapshotSurface {
  /// The scale every reference is recorded at. Not the display's — this machine's happens to
  /// agree, which is exactly what made the dependency invisible.
  static let scale: CGFloat = 2

  /// A host window that reports `scale` wherever it runs. Views read the backing scale off their
  /// window, so pinning it here is what pins their layout.
  final class Window: NSWindow {
    override var backingScaleFactor: CGFloat { SnapshotSurface.scale }
  }

  static func window(contentRect: NSRect, appearance: NSAppearance) -> Window {
    let window = Window(
      contentRect: contentRect, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance
    return window
  }

  static func window(size: NSSize, appearance: NSAppearance) -> Window {
    window(contentRect: NSRect(origin: .zero, size: size), appearance: appearance)
  }

  /// Draw into a `scale`x sRGB bitmap. The block is called with the context current and, when
  /// one is given, the appearance in force.
  static func bitmap(
    size: NSSize, appearance: NSAppearance?, _ draw: (NSGraphicsContext) -> Void
  ) -> NSBitmapImageRep {
    let width = Int((size.width * scale).rounded(.up))
    let height = Int((size.height * scale).rounded(.up))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let cgContext = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("no sRGB bitmap for a snapshot") }
    let context = NSGraphicsContext(cgContext: cgContext, flipped: false)
    cgContext.scaleBy(x: scale, y: scale)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    if let appearance {
      appearance.performAsCurrentDrawingAppearance { draw(context) }
    } else {
      draw(context)
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let image = cgContext.makeImage() else { fatalError("no image from a snapshot bitmap") }
    return NSBitmapImageRep(cgImage: image)
  }

  /// The same, encoded — what a reference holds.
  static func png(
    size: NSSize, appearance: NSAppearance, _ draw: (NSGraphicsContext) -> Void
  ) -> Data {
    guard
      let png = bitmap(size: size, appearance: appearance, draw)
        .representation(using: .png, properties: [:])
    else { fatalError("could not encode a snapshot PNG") }
    return png
  }
}
