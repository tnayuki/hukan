import AppKit
import XCTest

@testable import Hukan

/// Look iteration for the rail, the way `SnapshotTests.testPreview` does it for the transcript:
/// the rail is the one column whose shape is hard to read from code — indents, the gutter line,
/// which rows sit on which edge — and launching the app to see it costs a minute per look.
///
///     HUKAN_PREVIEW_RAIL=1 xcodebuild test -project hukan.xcodeproj -scheme Hukan \
///         -only-testing:HukanAppTests/RailPreviewTests/testPreview -derivedDataPath .build/DerivedData
///
/// then look at /tmp/hukan-preview-rail.png. Off by default — it writes a file and asserts
/// nothing.
final class RailPreviewTests: XCTestCase {
  func testPreview() throws {
    guard ProcessInfo.processInfo.environment["HUKAN_PREVIEW_RAIL"] == "1" else { return }

    let rail = SessionRailViewController()
    rail.workspace = Self.sampleWorkspace()
    rail.loadViewIfNeeded()
    rail.reload()
    // The rail's own floor (`railItem.minimumThickness`), so what the preview truncates is
    // what the narrowest real window truncates — 200 made every title look worse than it is.
    let image = imageOfView(rail.view, width: 280, height: 420)
    let out = URL(fileURLWithPath: "/tmp/hukan-preview-rail.png")
    try pngData(image).write(to: out)
    print("wrote \(out.path)")
  }

  /// One repository with two linked worktrees and sessions in each — main's list long enough to
  /// overflow the cap, so the Archived section shows what it is for. Nothing here touches git or
  /// disk.
  static func sampleWorkspace() -> Workspace {
    let repo = Repository(id: "/repo/hukan")
    let main = Worktree(url: URL(fileURLWithPath: "/repo/hukan"), branch: "main", repository: repo)
    let heading = Worktree(
      url: URL(fileURLWithPath: "/repo/hukan-worktree-heading"), branch: "worktree-heading",
      repository: repo)
    let files = Worktree(
      url: URL(fileURLWithPath: "/repo/hukan-files-panel"), branch: "files-panel", repository: repo)
    repo.worktrees = [main, heading, files]

    let workspace = Workspace()
    workspace.repositories = [repo]
    let archived = session(in: main, "Try the SwiftPM fast loop", .idle, ago: 3 * 86400)
    let stale = session(in: main, "Rename the Sessions label", .idle, ago: 9 * 86400)
    workspace.sessions = [
      session(in: main, "Bump the libgit2 version", .idle, ago: 40),
      archived,
      stale,
      session(in: heading, "Name the worktree heading", .running, ago: 5 * 60),
      session(in: heading, "Drop the Worktrees section", .idle, ago: 3 * 3600),
      session(in: files, "Search the files panel", .needsAttention, ago: 26 * 3600),
    ]
    _ = workspace.setArchived(true, for: [archived, stale])
    return workspace
  }

  private static func session(
    in worktree: Worktree, _ title: String, _ state: RunState, ago: TimeInterval
  ) -> AgentSession {
    let session = AgentSession(worktreeID: worktree.id)
    session.title = title
    session.state = state
    session.lastInstructedAt = Date(timeIntervalSinceNow: -ago)
    return session
  }

  /// Host the rail in an offscreen window at a fixed size under the dark appearance and capture
  /// it — the rail scrolls, so it is given a height rather than fitting to one.
  private func imageOfView(_ view: NSView, width: CGFloat, height: CGFloat) -> NSImage {
    let appearance = NSAppearance(named: .darkAqua)!
    NSApplication.shared.appearance = appearance

    let frame = NSRect(x: 0, y: 0, width: width, height: height)
    let container = NSView(frame: frame)
    container.wantsLayer = true
    container.appearance = appearance
    view.frame = frame
    view.autoresizingMask = [.width, .height]
    container.addSubview(view)

    let window = NSWindow(
      contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = container
    appearance.performAsCurrentDrawingAppearance {
      container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    container.layoutSubtreeIfNeeded()

    guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
      fatalError("no bitmap rep for the rail")
    }
    container.cacheDisplay(in: container.bounds, to: rep)
    let image = NSImage(size: container.bounds.size)
    image.addRepresentation(rep)
    return image
  }

  private func pngData(_ image: NSImage) -> Data {
    guard let rep = image.representations.first as? NSBitmapImageRep,
      let data = rep.representation(using: .png, properties: [:])
    else { fatalError("no png for the rail") }
    return data
  }
}
