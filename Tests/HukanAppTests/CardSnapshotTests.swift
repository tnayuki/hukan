import AppKit
import XCTest

@testable import Hukan

/// Pixel snapshots of app *views* — the ones the transcript's PNG harness can't reach because
/// they are real AppKit views, not styled text. A view is captured by hosting it in an
/// offscreen window (a view never in a window gives an empty `cacheDisplay`) under the dark
/// appearance it is designed for.
///
/// Record with `TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test …`, then eyeball the PNGs before
/// committing them. References live next to this file, found via `#filePath`.
final class CardSnapshotTests: XCTestCase {
  private static let snapshotsDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Snapshots")

  /// The approval card for an ExitPlanMode with a plan long enough to scroll: the plan reads in
  /// the card's own scroll box, so the plan — not a bare tool name — is what you decide on.
  func testExitPlanApprovalCard() throws {
    let plan = """
      ## Cache rendered thumbnails

      - **Source**: render once per `(path, size)`, keyed by content hash in an LRU.
      - **Eviction**: cap at 256 entries; drop the oldest on overflow.
      - **Invalidation**: a file save clears its own entries, nothing else.
      - **Warmup**: prefill from the visible rows on scroll, never the whole tree.
      - **検証**: scroll a 1,000-file tree twice and compare the timings.

      | Item | Value |
      |---|---|
      | Store | new `ThumbnailCache.swift` |
      | Cap | 256 entries |

      The cap is a guess, tuned against the profiler once wired up.
      """
    let approval = PendingApproval(
      requestID: "r1", toolName: "ExitPlanMode",
      title: "Would you like to proceed?",
      detail: "Cache rendered thumbnails",
      input: ["plan": plan])
    let card = ApprovalCard(approval: approval, onDecision: { _ in })

    try compare(imageOfView(card, width: 380), named: "exit-plan-card")
  }

  // MARK: harness

  /// Host `view` in an offscreen window at `width`, on the app's own dark backdrop with `padding`
  /// around it (the card is a translucent orange over that background, so it washes out captured
  /// against nothing), laid out under the dark appearance, and capture it at its fitted height.
  private func imageOfView(_ view: NSView, width: CGFloat, padding: CGFloat = 16) -> NSImage {
    let appearance = NSAppearance(named: .darkAqua)!
    NSApplication.shared.appearance = appearance

    view.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width + padding * 2, height: 2000))
    container.wantsLayer = true
    container.appearance = appearance
    container.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
      view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
      view.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
    ])
    let window = NSWindow(
      contentRect: container.frame, styleMask: .borderless,
      backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = container
    // PlanBox sizes itself in layout(), so settle the width, then read the card's height.
    container.layoutSubtreeIfNeeded()
    container.layoutSubtreeIfNeeded()
    window.setContentSize(
      NSSize(width: width + padding * 2, height: view.frame.height + padding * 2))
    appearance.performAsCurrentDrawingAppearance {
      container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    container.layoutSubtreeIfNeeded()

    let bounds = container.bounds
    guard let rep = container.bitmapImageRepForCachingDisplay(in: bounds) else {
      fatalError("no bitmap rep for the card")
    }
    container.cacheDisplay(in: bounds, to: rep)
    let image = NSImage(size: bounds.size)
    image.addRepresentation(rep)
    return image
  }

  private func compare(_ image: NSImage, named name: String) throws {
    let reference = Self.snapshotsDir.appendingPathComponent("\(name).png")
    let actual = pngData(image)
    if ProcessInfo.processInfo.environment["HUKAN_RECORD"] == "1" {
      try FileManager.default.createDirectory(
        at: Self.snapshotsDir, withIntermediateDirectories: true)
      try actual.write(to: reference)
      XCTFail("recorded \(name) — run again without HUKAN_RECORD to verify")
      return
    }
    guard let expected = try? Data(contentsOf: reference) else {
      XCTFail("\(name): no reference — record with TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test")
      return
    }
    if pixels(expected) != pixels(actual) {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hukan-snapshots")
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let failed = dir.appendingPathComponent("\(name)-actual.png")
      try? actual.write(to: failed)
      XCTFail("\(name): differs from the reference (actual at \(failed.path))")
    }
  }

  private func pngData(_ image: NSImage) -> Data {
    guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else {
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
