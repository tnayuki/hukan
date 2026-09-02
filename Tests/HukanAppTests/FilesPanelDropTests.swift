import AppKit
import XCTest

@testable import Hukan

/// Dropping files onto the panel — the way back in for the drag a row already offers. Two acts
/// share the gesture: a row of this panel moves, anything else copies. Which one a drag is, is a
/// rule with no drag session behind it (`dropOperation`, exercised directly the way the rail's
/// `dropBoundary` is, since an `NSDraggingInfo` is not something a test can make); what the drop
/// then writes goes through the same seam the menu's writes use — the act without the alert in
/// front of it, because the alert is the decision and a test cannot answer one.
final class FilesPanelDropTests: XCTestCase {
  private typealias Panel = FilesPanelViewController
  private var temporaries: [URL] = []

  override func tearDown() {
    for url in temporaries { try? FileManager.default.removeItem(at: url) }
    temporaries = []
    super.tearDown()
  }

  private func makeDirectory(_ name: String, files: [String], contents: String = "let a = 1\n")
    throws -> URL
  {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("\(name)-\(UUID().uuidString)")
    temporaries.append(root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for path in files {
      let file = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: file, atomically: true, encoding: .utf8)
    }
    return root
  }

  /// A worktree that really is on disk: a drop is FileManager calls, so unlike the tree's own
  /// tests this one cannot make do with a list of paths.
  private func makeWorktree(files: [String]) throws -> Worktree {
    let root = try makeDirectory("hukan-files-drop", files: files)
    let repository = Repository(id: root.path)
    let worktree = Worktree(url: root, repository: repository)
    worktree.trackedFiles = files
    worktree.hasLoadedFiles = true
    repository.worktrees = [worktree]
    return worktree
  }

  @MainActor
  private func panel(on worktree: Worktree) -> Panel {
    let panel = Panel()
    panel.show(worktree: worktree)
    return panel
  }

  private func read(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? "—"
  }

  // MARK: Which act a drag is

  /// The rule, in the six cases that decide it. The modifier keys are already folded into
  /// `allowed` by the time a destination sees them, so ⌥ and ⌘ are just narrower masks here.
  @MainActor
  func testTheRuleTellsAMoveFromACopy() throws {
    let worktree = try makeWorktree(files: ["src/deep/A.swift", "docs/B.md"])
    let root = worktree.url
    let file = root.appendingPathComponent("src/deep/A.swift")
    let src = root.appendingPathComponent("src")
    let deep = root.appendingPathComponent("src/deep")
    let docs = root.appendingPathComponent("docs")
    let outside = try makeDirectory("hukan-drop-outside", files: ["C.swift"])
      .appendingPathComponent("C.swift")

    XCTAssertEqual(
      Panel.dropOperation(
        sources: [file], into: docs, allowed: [.copy, .move], fromThisPanel: true), .move,
      "a row of this panel, dropped somewhere else in the tree")
    XCTAssertEqual(
      Panel.dropOperation(sources: [file], into: docs, allowed: [.copy], fromThisPanel: true),
      .copy, "⌥ over the same drag: the Finder's duplicate")
    XCTAssertEqual(
      Panel.dropOperation(
        sources: [file], into: deep, allowed: [.copy, .move], fromThisPanel: true),
      [], "it is already in that directory, so there is nowhere to move it to")
    XCTAssertEqual(
      Panel.dropOperation(
        sources: [src], into: deep, allowed: [.copy, .move], fromThisPanel: true),
      [], "a directory cannot go inside itself, which a copy would follow forever")
    XCTAssertEqual(
      Panel.dropOperation(sources: [outside], into: src, allowed: [.copy], fromThisPanel: false),
      .copy, "anything from outside arrives as a copy")
    XCTAssertEqual(
      Panel.dropOperation(sources: [outside], into: src, allowed: [.move], fromThisPanel: false),
      [], "⌘ over a Finder drag has nothing to mean here")
  }

  // MARK: What a drop writes

  /// A copied file lands, the original stays where it was, and nothing opens: `created` is the
  /// case that opens a tab, and a drop may be twenty files at once.
  @MainActor
  func testACopiedFileLandsWithoutOpeningATab() throws {
    let worktree = try makeWorktree(files: ["src/A.swift"])
    let outside = try makeDirectory("hukan-drop-outside", files: ["C.swift"])
      .appendingPathComponent("C.swift")
    let panel = panel(on: worktree)
    var edits: [Panel.FileEdit] = []
    panel.onFileEdit = { edits.append($0) }

    XCTAssertEqual(
      panel.writeForScripting(
        drop: [outside.path], into: "src", moving: false, answering: .stop),
      "ok src/C.swift")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: worktree.url.appendingPathComponent("src/C.swift").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: outside.path), "a copy leaves the original")

    XCTAssertEqual(edits.count, 1, "one report, and not a `created`: \(edits)")
    guard case .copiedIn(let paths)? = edits.first else { return XCTFail("\(edits)") }
    XCTAssertEqual(paths, ["src/C.swift"])
  }

  /// A move inside the tree is the rename that carries directories, read from the other side —
  /// and it reports itself as one, which is what makes an open tab follow the file.
  @MainActor
  func testAMoveInsideTheTreeReportsItselfAsARename() throws {
    let worktree = try makeWorktree(files: ["src/A.swift", "docs/B.md"])
    let panel = panel(on: worktree)
    var edits: [Panel.FileEdit] = []
    panel.onFileEdit = { edits.append($0) }

    XCTAssertEqual(
      panel.writeForScripting(
        drop: [worktree.url.appendingPathComponent("src/A.swift").path], into: "docs", moving: true,
        answering: .stop), "ok docs/A.swift")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: worktree.url.appendingPathComponent("src/A.swift").path), "it left")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: worktree.url.appendingPathComponent("docs/A.swift").path))
    guard case .renamed(let from, let to)? = edits.first else { return XCTFail("\(edits)") }
    XCTAssertEqual([from, to], ["src/A.swift", "docs/A.swift"])

    // A path from outside has no move to make: the file is another checkout's, or nobody's.
    let outside = try makeDirectory("hukan-drop-outside", files: ["C.swift"])
      .appendingPathComponent("C.swift")
    XCTAssertTrue(
      panel.writeForScripting(drop: [outside.path], into: "docs", moving: true, answering: .stop)
        .contains("cannot land"))
  }

  /// A folder takes everything under it, which is the half a move on the row could not do at all
  /// before — and an open tab under it follows, since the rename names both ends.
  @MainActor
  func testAFolderMovesWithEverythingInIt() throws {
    let worktree = try makeWorktree(files: ["src/deep/A.swift", "docs/B.md"])
    let panel = panel(on: worktree)

    XCTAssertEqual(
      panel.writeForScripting(
        drop: [worktree.url.appendingPathComponent("src/deep").path], into: "docs", moving: true,
        answering: .stop), "ok docs/deep")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: worktree.url.appendingPathComponent("docs/deep/A.swift").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: worktree.url.appendingPathComponent("src/deep").path))
  }

  // MARK: A name already taken

  @MainActor
  func testKeepBothLandsItUnderANameOfItsOwn() throws {
    let worktree = try makeWorktree(files: ["src/A.swift"])
    let outside = try makeDirectory("hukan-drop-outside", files: ["A.swift"], contents: "dropped\n")
      .appendingPathComponent("A.swift")
    let panel = panel(on: worktree)

    XCTAssertEqual(
      panel.writeForScripting(
        drop: [outside.path], into: "src", moving: false, answering: .keepBoth),
      "ok src/A 2.swift", "the number goes before the extension, the Finder's spelling")
    XCTAssertEqual(read(worktree.url.appendingPathComponent("src/A.swift")), "let a = 1\n")
    XCTAssertEqual(read(worktree.url.appendingPathComponent("src/A 2.swift")), "dropped\n")
  }

  /// Replace writes over what was there — and says so as a `copiedIn`, because a tab may be
  /// showing the file whose contents have just changed under it.
  @MainActor
  func testReplaceWritesOverWhatWasThereAndAsksForAReRead() throws {
    let worktree = try makeWorktree(files: ["src/A.swift"])
    let outside = try makeDirectory("hukan-drop-outside", files: ["A.swift"], contents: "dropped\n")
      .appendingPathComponent("A.swift")
    let panel = panel(on: worktree)
    var edits: [Panel.FileEdit] = []
    panel.onFileEdit = { edits.append($0) }

    XCTAssertEqual(
      panel.writeForScripting(
        drop: [outside.path], into: "src", moving: false, answering: .replace),
      "ok src/A.swift")
    XCTAssertEqual(read(worktree.url.appendingPathComponent("src/A.swift")), "dropped\n")
    guard case .copiedIn(let paths)? = edits.first else { return XCTFail("\(edits)") }
    XCTAssertEqual(paths, ["src/A.swift"])
  }

  /// Stop answers the whole drop, not the one file — which is what the word means in the Finder's
  /// version of this alert.
  @MainActor
  func testStopLandsNothing() throws {
    let worktree = try makeWorktree(files: ["src/A.swift"])
    let source = try makeDirectory(
      "hukan-drop-outside", files: ["A.swift", "B.swift"],
      contents: "dropped\n")
    let panel = panel(on: worktree)

    XCTAssertEqual(
      panel.writeForScripting(
        drop: [
          source.appendingPathComponent("A.swift").path,
          source.appendingPathComponent("B.swift").path,
        ], into: "src", moving: false, answering: .stop), "stopped")
    XCTAssertEqual(read(worktree.url.appendingPathComponent("src/A.swift")), "let a = 1\n")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: worktree.url.appendingPathComponent("src/B.swift").path),
      "the file after the one that collided is not landed either")
  }

  /// A directory whose name is taken is refused outright rather than offered Replace: replacing a
  /// folder is deleting everything in it, and the one place this panel destroys a directory is
  /// behind Delete's own alert.
  @MainActor
  func testAFolderCollisionIsRefusedRatherThanReplaced() throws {
    let worktree = try makeWorktree(files: ["src/A.swift"])
    let outside = try makeDirectory("hukan-drop-outside", files: ["src/other.swift"])
      .appendingPathComponent("src")
    let panel = panel(on: worktree)

    XCTAssertTrue(
      panel.writeForScripting(drop: [outside.path], into: "", moving: false, answering: .replace)
        .contains("already exists"))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: worktree.url.appendingPathComponent("src/A.swift").path),
      "what was there is untouched")
  }
}
