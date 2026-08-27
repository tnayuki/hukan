import XCTest

@testable import Hukan

/// Pins the slash-command list's look, the way `HistorySnapshotTests` pins the History section's.
///
/// The row is the thing worth pinning: a skill's description is a paragraph written for the model
/// to route on, not a menu label, and left to their intrinsic widths the labels made the row wider
/// than the panel — which laid it out from a leading edge off the side, so the names lost their
/// left margin on exactly the rows whose description was longest. So the case is drawn at the
/// panel's own narrow width with a description far too long for it, next to a row with an argument
/// hint and one with neither.
///
/// `TEST_RUNNER_HUKAN_RECORD=1` re-records; `TEST_RUNNER_HUKAN_PREVIEW=completions` writes
/// /tmp/hukan-preview-completions.png and leaves the reference alone.
final class CompletionSnapshotTests: XCTestCase {
  private static let reference = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Snapshots/completions.png")

  /// About what the composer is in a real window — wide enough that an argument hint has
  /// somewhere to go, narrow enough that a skill's description still has to truncate.
  private static let width: CGFloat = 440

  private static let commands = [
    ClaudeCommand(
      name: "embedded-captions",
      description:
        "Add captions to a talking-head video. ONE catalog of 32 visual identities behind two "
        + "engines: column-flow (captions composited INTO the scene) and themed constitutions. "
        + "Route by identity, never by mode.",
      argumentHint: "", aliases: []),
    ClaudeCommand(
      name: "code-review",
      description: "Review the current diff for correctness bugs and cleanups.",
      argumentHint: "[low|medium|high|xhigh|max] [--fix]", aliases: ["review"]),
    ClaudeCommand(name: "compact", description: "Compact.", argumentHint: "", aliases: []),
  ]

  @MainActor
  func testCompletionListMatchesSnapshot() throws {
    if ProcessInfo.processInfo.environment["HUKAN_PREVIEW"] == "completions" {
      let out = URL(fileURLWithPath: "/tmp/hukan-preview-completions.png")
      try render().write(to: out)
      print("preview: \(out.path)")
      return
    }

    let record = ProcessInfo.processInfo.environment["HUKAN_RECORD"] == "1"
    let actual = try render()
    if record {
      try actual.write(to: Self.reference)
      XCTFail("recorded completions snapshot — run again without HUKAN_RECORD to verify")
      return
    }
    guard let expected = try? Data(contentsOf: Self.reference) else {
      XCTFail(
        "no reference at \(Self.reference.path) — record with TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test"
      )
      return
    }
    if pixels(expected) != pixels(actual) {
      let failed = FileManager.default.temporaryDirectory
        .appendingPathComponent("hukan-snapshots/completions-actual.png")
      try? FileManager.default.createDirectory(
        at: failed.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? actual.write(to: failed)
      XCTFail(
        "completions: rendered output differs from completions.png (actual written to"
          + " \(failed.path); if the change is intended, re-record with"
          + " TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test)")
    }
  }

  /// Drawn through the panel's own `present`, so what is pinned is the layout a keystroke
  /// produces rather than a stand-in for it — the sizing is part of what went wrong.
  @MainActor
  private func render() throws -> Data {
    let appearance = NSAppearance(named: .darkAqua)!
    NSApplication.shared.appearance = appearance

    let host = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200), styleMask: .borderless,
      backing: .buffered, defer: false)
    host.appearance = appearance
    let anchor = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 64))
    host.contentView = anchor

    let panel = CommandCompletionPanel()
    panel.appearance = appearance
    panel.present(Self.commands, below: anchor)
    defer { panel.dismiss() }

    guard let content = panel.contentView else { throw XCTSkip("the panel has no content view") }
    content.layoutSubtreeIfNeeded()
    let size = content.bounds.size

    let scale: CGFloat = 2
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep)
    else { throw XCTSkip("no bitmap for the list") }
    rep.size = size
    context.cgContext.scaleBy(x: scale, y: scale)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    appearance.performAsCurrentDrawingAppearance {
      // The panel's own background is the window server's material, which does not render into a
      // bitmap of our own — so stand the menu colour behind it, as the shell does on screen.
      NSColor.windowBackgroundColor.setFill()
      NSRect(origin: .zero, size: size).fill()
      content.displayIgnoringOpacity(content.bounds, in: context)
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
      fatalError("could not encode a PNG")
    }
    return png
  }

  private func pixels(_ png: Data) -> [Data] {
    guard let rep = NSBitmapImageRep(data: png), let data = rep.tiffRepresentation else {
      return [png]
    }
    return [Data("\(rep.pixelsWide)x\(rep.pixelsHigh)".utf8), data]
  }
}
