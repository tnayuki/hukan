import XCTest

@testable import Hukan

/// The layer half of the fault `DynamicColorTests` covers for attributes: a `CALayer` holds a
/// resolved `CGColor`, so a view built under one appearance and displayed under the other has to
/// be repainted, not merely constructed correctly. hukan forces no appearance of its own, so this
/// is what a person switching Light and Dark while it runs actually gets.
final class LayerSurfaceTests: XCTestCase {
  private func fill(_ view: NSView, under name: NSAppearance.Name) throws -> NSColor {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.appearance = try XCTUnwrap(NSAppearance(named: name))
    window.contentView = view
    view.needsDisplay = true
    view.displayIfNeeded()
    let cgColor = try XCTUnwrap(view.layer?.backgroundColor, "the surface painted nothing")
    return try XCTUnwrap(
      NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB), "the fill is not a readable colour")
  }

  @MainActor
  func testASurfaceCarriesTheAppearanceItIsDisplayedIn() throws {
    let view = LayerSurface(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
    view.wantsLayer = true
    view.paintLayer = { $0.backgroundColor = NSColor.quaternarySystemFill.cgColor }

    let dark = try fill(view, under: .darkAqua)
    XCTAssertEqual(dark.redComponent, 1, accuracy: 0.01, "dark's fill is a white wash")

    // The same view, moved to a light window: the layer has to be repainted, and this is the
    // half that a colour resolved at build time can never get right.
    let light = try fill(view, under: .aqua)
    XCTAssertEqual(light.redComponent, 0, accuracy: 0.01, "light's fill is a black wash")
  }

  /// And the card that carried the bug, through its own init rather than a stand-in.
  @MainActor
  func testATaskCardIsWashedForTheAppearanceItIsDisplayedIn() throws {
    let card = TaskCard(
      tasks: [
        AgentTask(
          id: "1", subject: "a task", activeForm: "Doing a task", status: .inProgress,
          blockedBy: [])
      ],
      expanded: false, onToggle: {})
    let dark = try fill(card, under: .darkAqua)
    let light = try fill(card, under: .aqua)
    XCTAssertGreaterThan(
      dark.redComponent, light.redComponent,
      "the card's wash did not follow the appearance it was displayed in")
  }
}
