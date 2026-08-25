import XCTest

@testable import Hukan

/// Pins the History section's look the way `EditorSnapshotTests` pins the editor's — drawn at the
/// panel's real width, with the states that have to stay legible there: an unpushed row beside a
/// pushed one, a summary long enough to truncate, the fork-point rule with log on both sides of
/// it, and the banner for a rebase this worktree is stopped in the middle of. Same recording
/// flow:
/// `TEST_RUNNER_HUKAN_RECORD=1` re-records, `TEST_RUNNER_HUKAN_PREVIEW=history` writes
/// /tmp/hukan-preview-history.png and leaves the reference alone.
final class HistorySnapshotTests: XCTestCase {
  private static let reference = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Snapshots/history.png")

  /// The panel's own width — its minimum thickness, where truncation is worst and the row still
  /// has to read.
  private static let width: CGFloat = 260

  private static let history = Git.History(
    commits: [
      Git.Commit(
        oid: "4f8a2c1d0000000000000000000000000000000a",
        summary: "Add the worktree's history, and the commit it opens", isPushed: false),
      Git.Commit(
        oid: "3bb3f1c00000000000000000000000000000000b",
        summary: "Watch a linked worktree's git directory", isPushed: false),
      Git.Commit(
        oid: "6f15f5100000000000000000000000000000000c",
        summary: "Add the editor's change-bar gutter", isPushed: true),
      Git.Commit(
        oid: "9a20b3d00000000000000000000000000000000d",
        summary: "Add syntax highlighting to the source pane", isPushed: true),
    ],
    // Two of its own, then the rule, then the history it was cut from — the section's two halves
    // on one screen.
    base: "origin/main", forkIndex: 2,
    // And the banner, pinned over the rows: a worktree stopped mid-rebase is the state the
    // section has to explain rather than merely survive.
    operation: Git.Operation(kind: .rebase, branch: "task", step: 1, total: 2))

  /// The section no longer measures itself — the panel's divider does, so it is drawn at the
  /// height a person would have dragged it to: the banner, the hairline and every row.
  private static let height: CGFloat = 1 + 18 + 5 * 20

  @MainActor
  func testHistoryMatchesSnapshot() throws {
    if ProcessInfo.processInfo.environment["HUKAN_PREVIEW"] == "history" {
      let out = URL(fileURLWithPath: "/tmp/hukan-preview-history.png")
      try render().write(to: out)
      print("preview: \(out.path)")
      return
    }

    let record = ProcessInfo.processInfo.environment["HUKAN_RECORD"] == "1"
    let actual = try render()
    if record {
      try actual.write(to: Self.reference)
      XCTFail("recorded history snapshot — run again without HUKAN_RECORD to verify")
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
        .appendingPathComponent("hukan-snapshots/history-actual.png")
      try? FileManager.default.createDirectory(
        at: failed.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? actual.write(to: failed)
      XCTFail(
        "history: rendered output differs from history.png (actual written to \(failed.path);"
          + " if the change is intended, re-record with TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test)"
      )
    }
  }

  /// Draw the section offscreen, into a context of our own — `displayIgnoringOpacity`, the way
  /// `WindowPreviewTests` draws a window. `cacheDisplay` is the obvious call and the wrong one
  /// again, for a second reason: the header's title lives in a layer-backed button subview, which
  /// it leaves out, so the section came back as rows under a blank strip.
  @MainActor
  private func render() throws -> Data {
    let appearance = NSAppearance(named: .darkAqua)!
    NSApplication.shared.appearance = appearance

    let panel = HistoryPanelViewController()
    panel.show(history: Self.history)

    let size = NSSize(width: Self.width, height: Self.height)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = panel.view
    panel.view.layoutSubtreeIfNeeded()

    let scale: CGFloat = 2
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep)
    else { throw XCTSkip("no bitmap for the section") }
    rep.size = size
    context.cgContext.scaleBy(x: scale, y: scale)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    appearance.performAsCurrentDrawingAppearance {
      // What sits behind the panel in the app: the window's background, since the panel's own is
      // the window server's material.
      NSColor.windowBackgroundColor.setFill()
      NSRect(origin: .zero, size: size).fill()
      panel.view.displayIgnoringOpacity(panel.view.bounds, in: context)
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
