import AppKit
import XCTest

@testable import Hukan

/// The chips above the composer. An image is its own thumbnail; anything else has to be named,
/// since a document glyph is the same glyph for every file — and dragging a row off the files
/// panel makes several attachments at once the ordinary case rather than the rare one.
final class AttachmentChipTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-chip-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func write(_ name: String) throws -> String {
    let url = directory.appendingPathComponent(name)
    try "x\n".write(to: url, atomically: true, encoding: .utf8)
    return url.path
  }

  private func writeImage(_ name: String) throws -> String {
    let image = NSImage(size: NSSize(width: 8, height: 8))
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    image.unlockFocus()
    let png = try XCTUnwrap(
      NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
        .representation(using: .png, properties: [:]))
    let url = directory.appendingPathComponent(name)
    try png.write(to: url)
    return url.path
  }

  @MainActor
  private func labels(in view: NSView) -> [String] {
    var found: [String] = []
    if let field = view as? NSTextField, !field.stringValue.isEmpty {
      found.append(field.stringValue)
    }
    for subview in view.subviews { found.append(contentsOf: labels(in: subview)) }
    return found
  }

  @MainActor
  func testANonImageChipIsNamedAndAnImageChipIsItself() throws {
    let composer = ComposerInput(frame: NSRect(x: 0, y: 0, width: 520, height: 130))
    let file = try write("Model.swift")
    let picture = try writeImage("shot.png")

    composer.attach([file, picture])

    XCTAssertEqual(
      composer.attachments.map(\.isImage), [false, true], "the png is read as an image")
    let shown = labels(in: composer)
    XCTAssertEqual(shown, ["Model.swift"], "the file is named; the image is its own thumbnail")
  }

  /// The last component, not the path — a chip is 160pt at most, and what tells two of them apart
  /// is the name. The whole path stays reachable as the tooltip.
  @MainActor
  func testTheChipShowsTheNameAndKeepsThePathAsItsTooltip() throws {
    let composer = ComposerInput(frame: NSRect(x: 0, y: 0, width: 520, height: 130))
    let nested = directory.appendingPathComponent("Sources/Hukan")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let path = nested.appendingPathComponent("Model.swift").path
    try "x\n".write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)

    composer.attach([path])

    XCTAssertEqual(labels(in: composer), ["Model.swift"])
    let chip = try XCTUnwrap(
      composer.subviews.flatMap(\.subviews).first { $0.toolTip == path },
      "the full path is the tooltip")
    XCTAssertLessThanOrEqual(chip.fittingSize.width, 160, "capped, so a handful still fit the row")
  }
}
