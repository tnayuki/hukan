import AppKit

/// The images a kind of machine is shown with. SF Symbols where they say it; where they have
/// nothing — Linux — a glyph of hukan's own, drawn here as a template so it takes the color and
/// weight of the symbols beside it.
///
/// No company's logo is drawn or bundled. Windows is SF Symbols' four panes, which reads as Windows
/// without being Microsoft's mark; Linux is a plain penguin of hukan's own, not anyone's mascot.
enum MachineGlyphs {
  /// The name `penguin` stands for in place of an SF Symbol's.
  static let penguin = "hukan.penguin"

  /// The SF Symbol named, or hukan's own glyph for `penguin`, `side` points square — a symbol's
  /// own size follows the view's symbol configuration, which a drawn image does not.
  static func image(_ name: String, side: CGFloat) -> NSImage? {
    name == penguin
      ? penguinImage(side: side) : NSImage(systemSymbolName: name, accessibilityDescription: nil)
  }

  /// One even-odd path on a 100-point square: a silhouette, with the belly, the eyes and the beak
  /// cut out of it, and the feet apart below it.
  private static func penguinImage(side: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
      let scale = rect.width / 100
      let path = NSBezierPath()
      path.windingRule = .evenOdd
      func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: y * scale) }
      func curve(_ points: [CGFloat]) {
        path.curve(
          to: point(points[4], points[5]), controlPoint1: point(points[0], points[1]),
          controlPoint2: point(points[2], points[3]))
      }
      path.move(to: point(50, 8))
      for segment: [CGFloat] in [
        [61, 8, 68, 16, 68, 27], [68, 31, 67, 35, 66, 38], [72, 44, 78, 52, 82, 61],
        [86, 69, 87, 75, 85, 78], [81, 77, 79, 74, 78, 71], [79, 76, 78, 81, 76, 84],
        [71, 89, 61, 91, 50, 91], [39, 91, 29, 89, 24, 84], [22, 81, 21, 76, 22, 71],
        [21, 74, 19, 77, 15, 78], [13, 75, 14, 69, 18, 61], [22, 52, 28, 44, 34, 38],
        [33, 35, 32, 31, 32, 27], [32, 16, 39, 8, 50, 8],
      ] {
        curve(segment)
      }
      path.close()
      func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) {
        path.append(
          NSBezierPath(
            ovalIn: NSRect(
              x: (x - rx) * scale, y: (y - ry) * scale, width: 2 * rx * scale,
              height: 2 * ry * scale)))
      }
      oval(50, 64, 16, 22)  // belly
      oval(43.5, 23, 3.6, 3.6)  // eyes
      oval(56.5, 23, 3.6, 3.6)
      path.move(to: point(43, 30))  // beak
      path.line(to: point(57, 30))
      path.line(to: point(50, 38))
      path.close()
      oval(38, 96, 11, 3.5)  // feet
      oval(62, 96, 11, 3.5)
      NSColor.black.setFill()
      path.fill()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Linux"
    return image
  }
}
