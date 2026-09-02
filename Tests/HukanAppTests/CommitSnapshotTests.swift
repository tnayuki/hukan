import XCTest

@testable import Hukan

/// Pins the commit tab's look the way `EditorSnapshotTests` pins the editor's: the message, a
/// file's header row open over its diff, the two-column gutter, the bands that replaced the
/// `+`/`-` column, and a second file folded beside a third that is too large to show. The colours
/// inside the diff come from the real grammar, through `CommitDiffLoader.render` — the same call
/// the tab makes once git has handed the rows over. Same recording flow:
/// `TEST_RUNNER_HUKAN_RECORD=1` re-records, `TEST_RUNNER_HUKAN_PREVIEW=commit` writes
/// /tmp/hukan-preview-commit.png and leaves the reference alone.
final class CommitSnapshotTests: XCTestCase {
  private static let reference = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Snapshots/commit.png")

  /// The file as the commit left it — what the added and context rows are coloured from.
  private static let newSource = """
    import AppKit

    struct Renderer {
      let name = "commit"
      var count: Int = 42

      func render(scale: Double) -> Bool {
        guard count > 0 else { return false }
        return true
      }
    }
    """

  /// The same file as its parent had it: one line shorter, and `name` spelled differently.
  private static let oldSource = """
    import AppKit

    struct Renderer {
      let name = "old"

      func render(scale: Double) -> Bool {
        return true
      }
    }
    """

  private static let detail = Git.CommitDetail(
    oid: "4f8a2c1d0000000000000000000000000000000a",
    summary: "Add the worktree's history, and the commit it opens",
    body: "The reading of a change belongs next to the code it changed,\nnot to a wall of patch.",
    author: "Toru Nayuki", date: Date(timeIntervalSince1970: 1_756_000_000),
    files: [
      Git.CommitFile(
        path: "Sources/Hukan/Renderer.swift", oldPath: nil, status: .modified, added: 3,
        removed: 1, isBinary: false),
      Git.CommitFile(
        path: "Sources/CommitTab.swift", oldPath: "Sources/CommitPane.swift",
        status: .renamed, added: 40, removed: 12, isBinary: false),
      Git.CommitFile(
        path: "Resources/hukan.icns", oldPath: nil, status: .added, added: nil, removed: nil,
        isBinary: true),
    ],
    countsOmitted: false)

  private static let fileDiff = Git.FileDiff(
    rows: [
      .hunk("@@ -1,8 +1,10 @@ struct Renderer {"),
      .line(old: 3, new: 3, kind: .context, text: "struct Renderer {"),
      .line(old: 4, new: nil, kind: .removed, text: "  let name = \"old\""),
      .line(old: nil, new: 4, kind: .added, text: "  let name = \"commit\""),
      .line(old: nil, new: 5, kind: .added, text: "  var count: Int = 42"),
      .line(old: 5, new: 6, kind: .context, text: ""),
      .line(old: 6, new: 7, kind: .context, text: "  func render(scale: Double) -> Bool {"),
      .line(old: nil, new: 8, kind: .added, text: "    guard count > 0 else { return false }"),
      .line(old: 7, new: 9, kind: .context, text: "    return true"),
    ],
    note: nil, newSource: newSource, oldSource: oldSource)

  @MainActor
  func testCommitMatchesSnapshot() throws {
    if ProcessInfo.processInfo.environment["HUKAN_PREVIEW"] == "commit" {
      let out = URL(fileURLWithPath: "/tmp/hukan-preview-commit.png")
      try render().write(to: out)
      print("preview: \(out.path)")
      return
    }

    let record = ProcessInfo.processInfo.environment["HUKAN_RECORD"] == "1"
    let actual = try render()
    if record {
      try actual.write(to: Self.reference)
      XCTFail("recorded commit snapshot — run again without HUKAN_RECORD to verify")
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
        .appendingPathComponent("hukan-snapshots/commit-actual.png")
      try? FileManager.default.createDirectory(
        at: failed.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? actual.write(to: failed)
      XCTFail(
        "commit: rendered output differs from commit.png (actual written to \(failed.path);"
          + " if the change is intended, re-record with TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test)"
      )
    }
  }

  /// Draw the tab offscreen, into a context of our own — `displayIgnoringOpacity`, the way
  /// `HistorySnapshotTests` draws the section. `cacheDisplay` is the obvious call and the wrong
  /// one: it fills an opaque background and drops layer-backed subviews, which here is every card
  /// there is.
  @MainActor
  private func render() throws -> Data {
    let appearance = NSAppearance(named: .darkAqua)!
    NSApplication.shared.appearance = appearance

    let sections = Self.detail.files.map { CommitSection(file: $0) }
    sections[0].isOpen = true
    sections[0].diff = CommitDiffLoader.render(Self.fileDiff, file: Self.detail.files[0])
    sections[1].isOpen = true
    sections[1].diff = LoadedFileDiff(note: .tooLarge(lines: 41200, bytes: 3_400_000))
    sections[2].isOpen = true
    sections[2].diff = LoadedFileDiff(note: .binary)

    let controller = CommitContentViewController()
    controller.present(Self.detail, sections: sections)

    let size = NSSize(width: 620, height: 470)
    let window = SnapshotSurface.window(size: size, appearance: appearance)
    window.contentView = controller.view
    controller.view.frame = NSRect(origin: .zero, size: size)
    controller.view.layoutSubtreeIfNeeded()
    // A second pass: the diff bodies measure their own height once they have a width, and the
    // cards above them only learn theirs from that.
    controller.view.layoutSubtreeIfNeeded()

    return SnapshotSurface.png(size: size, appearance: appearance) { context in
      NSColor.windowBackgroundColor.setFill()
      NSRect(origin: .zero, size: size).fill()
      controller.view.displayIgnoringOpacity(controller.view.bounds, in: context)
    }
  }

  private func pixels(_ png: Data) -> [Data] {
    guard let rep = NSBitmapImageRep(data: png), let data = rep.tiffRepresentation else {
      return [png]
    }
    return [Data("\(rep.pixelsWide)x\(rep.pixelsHigh)".utf8), data]
  }
}
