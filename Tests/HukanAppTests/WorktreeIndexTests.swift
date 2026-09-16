import XCTest

@testable import Hukan

/// What the files panel's tree keeps: the listings it has actually made, and how a change on disk
/// turns into "these rows read differently". Nothing here walks a worktree — that went with the
/// index that used to hold one (see `WorktreeIndex`), and the whole path set is `Ripgrep`'s now.
final class WorktreeIndexTests: XCTestCase {
  private var temporaries: [URL] = []

  override func tearDown() {
    for url in temporaries { try? FileManager.default.removeItem(at: url) }
    temporaries = []
    super.tearDown()
  }

  private func makeTree(_ files: [String]) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-index-\(UUID().uuidString)")
    temporaries.append(root)
    for path in files {
      let file = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try "x\n".write(to: file, atomically: true, encoding: .utf8)
    }
    return root
  }

  private func update(_ index: WorktreeIndex, moved: Set<String>?) -> Set<String>? {
    var answer: Set<String>?
    let done = expectation(description: "batch")
    index.update(moved: moved) {
      answer = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    return answer
  }

  /// The listing is `readdir`, so what the entry itself says about a name has to agree with what
  /// a `stat` used to: a link is what it points at, a link pointing nowhere is not a directory,
  /// a hidden file is a file like any other, and `.git` is the one name left out — it is the
  /// repository, not the worktree, and in a linked worktree it is a file rather than a directory.
  func testTheListingReadsLinksAndHiddenNamesTheWayAStatDid() throws {
    let root = try makeTree(["src/a.swift", ".env", "elsewhere/b.swift", ".git/HEAD"])
    let manager = FileManager.default
    try manager.createSymbolicLink(
      at: root.appendingPathComponent("link"),
      withDestinationURL: root.appendingPathComponent("elsewhere"))
    try manager.createSymbolicLink(
      at: root.appendingPathComponent("dangling"),
      withDestinationURL: root.appendingPathComponent("nothing-here"))
    try manager.createSymbolicLink(
      at: root.appendingPathComponent("file-link"),
      withDestinationURL: root.appendingPathComponent("src/a.swift"))

    let listed = try XCTUnwrap(WorktreeIndex.list(root))
    let byName = Dictionary(
      listed.map { ($0.name, $0.isDirectory) }, uniquingKeysWith: { a, _ in a })
    XCTAssertEqual(byName["link"], true, "a link to a directory is a directory")
    XCTAssertEqual(byName["file-link"], false)
    XCTAssertEqual(byName["dangling"], false, "nothing there to be a directory")
    XCTAssertEqual(byName[".env"], false, "hidden names are listed")
    XCTAssertEqual(byName["src"], true)
    XCTAssertNil(byName[".git"], "the repository is not the worktree")
    XCTAssertFalse(listed.contains { $0.name == "." || $0.name == ".." })
    XCTAssertNil(WorktreeIndex.list(root.appendingPathComponent("nothing-here")))
  }

  /// A directory nobody has opened has no answer here, which is the tree's cue to list it itself
  /// — and what it lists, it says, so the next batch has something to compare against.
  func testADirectoryIsKnownOnlyOnceTheTreeHasListedIt() throws {
    let root = try makeTree(["src/a.swift"])
    let index = WorktreeIndex(root: root)

    XCTAssertNil(index.entries(of: ""), "nothing is walked because a worktree exists")
    XCTAssertNil(index.entries(of: "src"))

    index.note("", entries: try XCTUnwrap(WorktreeIndex.list(root)))
    XCTAssertEqual(index.entries(of: "")?.map(\.name), ["src"])
    XCTAssertNil(index.entries(of: "src"), "opened rows only")
  }

  /// A batch re-lists the directories it names and answers with those that now read differently
  /// — the ones the tree has listed, since a directory nobody opened has no rows to be stale.
  func testABatchRelistsWhatTheTreeHasOpenedAndNothingElse() throws {
    let root = try makeTree(["src/a.swift", "vendor/b.swift"])
    let index = WorktreeIndex(root: root)
    index.note("", entries: try XCTUnwrap(WorktreeIndex.list(root)))
    index.note(
      "src", entries: try XCTUnwrap(WorktreeIndex.list(root.appendingPathComponent("src"))))

    try "y\n".write(
      to: root.appendingPathComponent("src/new.swift"), atomically: true, encoding: .utf8)
    try "y\n".write(
      to: root.appendingPathComponent("vendor/new.swift"), atomically: true, encoding: .utf8)

    let changed = update(index, moved: ["src/new.swift", "vendor/new.swift"])
    XCTAssertEqual(changed, ["src"], "vendor was never listed, so nothing was drawn from it")
    XCTAssertEqual(index.entries(of: "src")?.map(\.name).sorted(), ["a.swift", "new.swift"])
    XCTAssertNil(index.entries(of: "vendor"))
  }

  /// A write that moves nothing in a listing is not a change: a file's contents are not its name.
  func testAFileEditedInPlaceIsNotAChangedListing() throws {
    let root = try makeTree(["src/a.swift"])
    let index = WorktreeIndex(root: root)
    index.note(
      "src", entries: try XCTUnwrap(WorktreeIndex.list(root.appendingPathComponent("src"))))

    try "changed\n".write(
      to: root.appendingPathComponent("src/a.swift"), atomically: true, encoding: .utf8)

    XCTAssertEqual(update(index, moved: ["src/a.swift"]), [], "the names in it are the same")
  }

  /// A directory that has left the disk is forgotten with everything under it, and its own path
  /// is what the panel is told about.
  func testADirectoryThatWentIsForgottenWithItsSubtree() throws {
    let root = try makeTree(["src/deep/a.swift"])
    let index = WorktreeIndex(root: root)
    index.note(
      "src", entries: try XCTUnwrap(WorktreeIndex.list(root.appendingPathComponent("src"))))
    index.note(
      "src/deep",
      entries: try XCTUnwrap(WorktreeIndex.list(root.appendingPathComponent("src/deep")))
    )

    try FileManager.default.removeItem(at: root.appendingPathComponent("src"))

    // The batch names something inside `src/deep`, so the directory asked about is its parent —
    // and that one is gone, which is what takes the whole subtree with it.
    XCTAssertEqual(update(index, moved: ["src/deep/a.swift"]), ["src/deep"])
    XCTAssertNil(index.entries(of: "src/deep"))
    XCTAssertEqual(update(index, moved: ["src/deep"]), ["src"], "and its parent in turn")
    XCTAssertNil(index.entries(of: "src"))
  }

  /// The wholesale question — a batch that could not be placed — drops the listings rather than
  /// re-reading them. The tree asks here first, so a listing that may be wrong is worse than none.
  func testAWholesaleBatchForgetsEverything() throws {
    let root = try makeTree(["src/a.swift"])
    let index = WorktreeIndex(root: root)
    index.note("", entries: try XCTUnwrap(WorktreeIndex.list(root)))
    let before = index.generation

    XCTAssertNil(update(index, moved: nil), "all of them")
    XCTAssertNil(index.entries(of: ""))
    XCTAssertGreaterThan(index.generation, before)
  }

  /// The panel's own write needs the row before the next line of code names it, so that one
  /// directory is re-listed on the spot rather than through a batch.
  func testRefreshNowReadsOneDirectoryOnTheSpot() throws {
    let root = try makeTree(["a.swift"])
    let index = WorktreeIndex(root: root)
    index.note("", entries: try XCTUnwrap(WorktreeIndex.list(root)))
    try "y\n".write(to: root.appendingPathComponent("untitled"), atomically: true, encoding: .utf8)

    index.refreshNow("")

    XCTAssertEqual(index.entries(of: "")?.map(\.name).sorted(), ["a.swift", "untitled"])
  }
}
