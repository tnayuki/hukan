import XCTest

@testable import Hukan

/// A block's fill is chosen while the attributed string is built, and drawn much later. The two
/// moments have different appearances current, and `withAlphaComponent` on a catalog colour
/// decides at the first one — which is how the blockquote's slab came out black on a machine
/// whose system appearance was light, over a transcript that is always dark.
final class DynamicColorTests: XCTestCase {
  private func sRGB(_ color: NSColor, under name: NSAppearance.Name) throws -> NSColor {
    var resolved: NSColor?
    try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
      resolved = color.usingColorSpace(.sRGB)
    }
    return try XCTUnwrap(resolved)
  }

  /// The bug, stated as the thing that must not happen again: built under one appearance, read
  /// under the other, and still the other's colour.
  func testAnAlphaModifiedCatalogColourStaysDynamic() throws {
    var fill: NSColor?
    try XCTUnwrap(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
      fill = NSColor.quaternarySystemFill.withDynamicAlpha(0.25)
    }
    let color = try XCTUnwrap(fill)

    let dark = try sRGB(color, under: .darkAqua)
    XCTAssertEqual(dark.redComponent, 1, accuracy: 0.01, "dark's fill is a white wash")
    XCTAssertEqual(dark.alphaComponent, 0.25, accuracy: 0.01, "the alpha did not survive")

    let light = try sRGB(color, under: .aqua)
    XCTAssertEqual(light.redComponent, 0, accuracy: 0.01, "light's fill is a black wash")
    XCTAssertEqual(light.alphaComponent, 0.25, accuracy: 0.01, "the alpha did not survive")
  }

  /// And `withAlphaComponent` is what it is compared against, so the test says what changed.
  func testWithAlphaComponentFreezesTheAppearanceItWasCalledUnder() throws {
    var frozen: NSColor?
    try XCTUnwrap(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
      frozen = NSColor.quaternarySystemFill.withAlphaComponent(0.25)
    }
    let color = try XCTUnwrap(frozen)
    XCTAssertEqual(
      try sRGB(color, under: .darkAqua).redComponent, 0, accuracy: 0.01,
      "if this ever starts resolving dynamically, withDynamicAlpha has nothing left to do")
  }

  /// The colour the bug was found in, through the transcript's own markdown.
  func testABlockquoteIsWashedLightOnDark() throws {
    var text: NSAttributedString?
    try XCTUnwrap(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
      text = Transcript.markdown("> a block quote")
    }
    let built = try XCTUnwrap(text)
    var fill: NSColor?
    built.enumerateAttribute(
      .blockBackground, in: NSRange(location: 0, length: built.length)
    ) { value, _, stop in
      if let color = value as? NSColor {
        fill = color
        stop.pointee = true
      }
    }
    let wash = try sRGB(try XCTUnwrap(fill, "the blockquote carries no fill"), under: .darkAqua)
    XCTAssertGreaterThan(wash.redComponent, 0.9, "the slab would be darker than the transcript")
  }
}
