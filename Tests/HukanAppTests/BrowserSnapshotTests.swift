import WebKit
import XCTest

@testable import Hukan

/// Pins the web tab's chrome the way `HistorySnapshotTests` pins the History section — the one
/// pane that had no reference at all. What is drawn is the bar and nothing under it: the page is
/// WebKit's, and a snapshot of a rendered page would be pinning a browser engine rather than
/// hukan. The three rows are the states the bar is ever in — a fresh tab with nothing to go back
/// to, a load under way (Stop in place of Reload, the progress line along the foot, an address
/// long enough to truncate), and the find field ⌘F opens beside it.
///
/// Same recording flow as the others: `TEST_RUNNER_HUKAN_RECORD=1` re-records, and
/// `TEST_RUNNER_HUKAN_PREVIEW=browser` writes /tmp/hukan-preview-browser.png and leaves the
/// reference alone.
final class BrowserSnapshotTests: XCTestCase {
  private static let reference = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Snapshots/browser.png")

  /// Narrow enough that the address in the middle row runs out of room, which is where the field's
  /// truncation has to read.
  private static let width: CGFloat = 420
  /// The bar and no page: the field, its insets, and the hairline the progress line draws on.
  private static let barHeight: CGFloat = 31
  private static let spacing: CGFloat = 8

  /// Long enough to truncate at this width, and shaped like the address a session actually hands
  /// you — a pull request, which is what this browser is for.
  private static let address = URL(
    string: "https://github.com/tnayuki/hukan/pull/1234/files#diff-a1b2c3d4e5f6")!

  @MainActor
  func testTheChromeMatchesSnapshot() throws {
    if ProcessInfo.processInfo.environment["HUKAN_PREVIEW"] == "browser" {
      let out = URL(fileURLWithPath: "/tmp/hukan-preview-browser.png")
      try render().write(to: out)
      print("preview: \(out.path)")
      return
    }

    let record = ProcessInfo.processInfo.environment["HUKAN_RECORD"] == "1"
    let actual = try render()
    if record {
      try actual.write(to: Self.reference)
      XCTFail("recorded browser snapshot — run again without HUKAN_RECORD to verify")
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
        .appendingPathComponent("hukan-snapshots/browser-actual.png")
      try? FileManager.default.createDirectory(
        at: failed.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? actual.write(to: failed)
      XCTFail(
        "browser: rendered output differs from browser.png (actual written to \(failed.path);"
          + " if the change is intended, re-record with TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test)"
      )
    }
  }

  /// The three bars, stacked with the window's background between them. Each pane is laid out at
  /// its final width *before* it is posed, because the progress line is measured against the
  /// view's bounds at the moment the load starts: posed first, it would be drawn for a bar of no
  /// width. Nothing here waits on the network — the load is put in and the bar is drawn in the
  /// same turn, which is the whole of what makes a page in flight a fixed picture.
  @MainActor
  private func render() throws -> Data {
    let appearance = NSAppearance(named: .darkAqua)!
    NSApplication.shared.appearance = appearance

    let panes = (0..<3).map { _ in BrowserPaneViewController() }
    let stack = NSStackView(views: panes.map(\.view))
    stack.orientation = .vertical
    stack.spacing = Self.spacing
    stack.alignment = .leading
    for pane in panes {
      pane.view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        pane.view.widthAnchor.constraint(equalToConstant: Self.width),
        pane.view.heightAnchor.constraint(equalToConstant: Self.barHeight),
      ])
    }

    let height = Self.barHeight * 3 + Self.spacing * 2
    let size = NSSize(width: Self.width, height: height)
    let window = SnapshotSurface.window(size: size, appearance: appearance)
    window.contentView = stack
    stack.layoutSubtreeIfNeeded()

    // The first is left as it opens. The second is put on an address and drawn while it is still
    // going out; the third has been asked to find, which is the field appearing rather than
    // anything found.
    panes[1].load(Self.address)
    panes[2].load(Self.address)
    panes[2].performFind(nil)
    stack.layoutSubtreeIfNeeded()

    return SnapshotSurface.png(size: size, appearance: appearance) { context in
      NSColor.windowBackgroundColor.setFill()
      NSRect(origin: .zero, size: size).fill()
      stack.displayIgnoringOpacity(stack.bounds, in: context)
    }
  }

  private func pixels(_ png: Data) -> [Data] {
    guard let rep = NSBitmapImageRep(data: png), let data = rep.tiffRepresentation else {
      return [png]
    }
    return [Data("\(rep.pixelsWide)x\(rep.pixelsHigh)".utf8), data]
  }
}
