import XCTest

@testable import Hukan

/// The walk behind the files panel: what it goes into, what it leaves out, and how it keeps up.
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

  private func built(_ index: WorktreeIndex) {
    let done = expectation(description: "walked")
    index.build { done.fulfill() }
    wait(for: [done], timeout: 5)
  }

  /// A directory git ignores is not walked — it is a hundred thousand files nobody wants filtered
  /// — but an ignored file in a plain directory is walked with its neighbours.
  func testTheWalkStopsAtAnIgnoredDirectoryAndNotAtAnIgnoredFile() throws {
    let root = try makeTree(["src/a.swift", "src/noise.log", "build/deep/x.o", "README.md"])
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
    let index = WorktreeIndex(root: root) { directories in
      Set(directories.filter { $0 == "build" })
    }
    built(index)

    XCTAssertTrue(index.isBuilt)
    XCTAssertEqual(index.filePaths, ["README.md", "src/a.swift", "src/noise.log"])
    XCTAssertNil(index.entries(of: "build"), "not walked")
    XCTAssertTrue(index.isIgnoredDirectory("build"))
    XCTAssertEqual(index.entries(of: "empty"), [], "walked, and empty")
    XCTAssertEqual(
      index.entries(of: "")?.map(\.name).sorted(), ["README.md", "build", "empty", "src"])
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
      withDestinationURL: root.appendingPathComponent(
        "elsewhere"))
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

  /// A name can change kind. A directory standing where a file stood is one the walk has never
  /// been into, so it has to be walked like any other new directory — while the names of what
  /// was there were taken regardless of kind, and it was mistaken for a directory already known,
  /// everything under it stayed out of the index and so out of the filter and the search.
  func testADirectoryStandingWhereAFileStoodIsWalked() throws {
    let root = try makeTree(["src/a.swift", "top.txt"])
    let manager = FileManager.default
    let index = WorktreeIndex(root: root) { _ in [] }
    built(index)
    XCTAssertEqual(index.filePaths, ["src/a.swift", "top.txt"])

    try manager.removeItem(at: root.appendingPathComponent("top.txt"))
    try manager.createDirectory(
      at: root.appendingPathComponent("top.txt"), withIntermediateDirectories: true)
    try "inside\n".write(
      to: root.appendingPathComponent("top.txt/now.txt"), atomically: true, encoding: .utf8)

    let done = expectation(description: "batch")
    index.update(moved: ["top.txt"]) { _ in done.fulfill() }
    wait(for: [done], timeout: 5)

    XCTAssertEqual(index.filePaths, ["src/a.swift", "top.txt/now.txt"])
    XCTAssertEqual(index.entries(of: "top.txt")?.map(\.name), ["now.txt"])
  }

  /// The flattened list is spliced rather than rebuilt, so the splice has to be indistinguishable
  /// from the rebuild — over a run of batches that between them create, delete, replace a file
  /// with a directory and a directory with a file, and take a whole subtree away. The oracle is
  /// the index's own full walk of the same disk.
  func testTheSplicedFlatteningMatchesAFullWalk() throws {
    let root = try makeTree(["src/a.swift", "src/deep/b.swift", "top.txt"])
    let manager = FileManager.default
    let index = WorktreeIndex(root: root) { directories in
      Set(directories.filter { ($0 as NSString).lastPathComponent == "ignored" })
    }
    built(index)

    func batch(_ paths: Set<String>, _ change: () throws -> Void) rethrows {
      try change()
      let done = expectation(description: "batch")
      index.update(moved: paths) { _ in done.fulfill() }
      wait(for: [done], timeout: 5)

      // The oracle: a second index over the same disk, walked from scratch.
      let fresh = WorktreeIndex(root: root) { directories in
        Set(directories.filter { ($0 as NSString).lastPathComponent == "ignored" })
      }
      built(fresh)
      XCTAssertEqual(index.filePaths, fresh.filePaths, "after \(paths.sorted())")
    }

    // A file edited: no name moves at all, which is the case the splice exists for.
    try batch(["src/a.swift"]) {
      try "changed\n".write(
        to: root.appendingPathComponent("src/a.swift"), atomically: true, encoding: .utf8)
    }
    // Made, and made in a directory that is itself new — the walk has to bring both in.
    try batch(["src/c.swift", "fresh/d.swift", "fresh"]) {
      try "c\n".write(
        to: root.appendingPathComponent("src/c.swift"), atomically: true, encoding: .utf8)
      try manager.createDirectory(
        at: root.appendingPathComponent("fresh/inner"), withIntermediateDirectories: true)
      try "d\n".write(
        to: root.appendingPathComponent("fresh/d.swift"), atomically: true, encoding: .utf8)
      try "e\n".write(
        to: root.appendingPathComponent("fresh/inner/e.swift"), atomically: true, encoding: .utf8)
    }
    // A whole subtree taken away.
    try batch(["src/deep", "src/deep/b.swift"]) {
      try manager.removeItem(at: root.appendingPathComponent("src/deep"))
    }
    // A file where a directory was, and a directory where a file was.
    try batch(["fresh/inner", "top.txt"]) {
      try manager.removeItem(at: root.appendingPathComponent("fresh/inner"))
      try "was a directory\n".write(
        to: root.appendingPathComponent("fresh/inner"), atomically: true, encoding: .utf8)
      try manager.removeItem(at: root.appendingPathComponent("top.txt"))
      try manager.createDirectory(
        at: root.appendingPathComponent("top.txt"), withIntermediateDirectories: true)
      try "inside\n".write(
        to: root.appendingPathComponent("top.txt/now.txt"), atomically: true, encoding: .utf8)
    }
    // One git has started ignoring keeps its files out of the list, the walk not going in.
    try batch(["ignored", "ignored/junk.o"]) {
      try manager.createDirectory(
        at: root.appendingPathComponent("ignored"), withIntermediateDirectories: true)
      try "junk\n".write(
        to: root.appendingPathComponent("ignored/junk.o"), atomically: true, encoding: .utf8)
    }
    XCTAssertFalse(index.filePaths.contains { $0.hasPrefix("ignored/") })
    XCTAssertTrue(index.filePaths.contains("fresh/inner"))
    XCTAssertTrue(index.filePaths.contains("top.txt/now.txt"))
  }

  /// A batch names paths; the directories they sit in are read again, a new directory is walked
  /// in, and a directory that went takes its subtree out. Each answer says which directories
  /// now read differently.
  func testABatchRelistsItsDirectoriesAndWalksWhatIsNew() throws {
    let root = try makeTree(["src/a.swift"])
    let index = WorktreeIndex(root: root) { _ in [] }
    built(index)
    let before = index.generation

    try "y\n".write(
      to: root.appendingPathComponent("src/b.swift"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("lib/inner"), withIntermediateDirectories: true)
    try "z\n".write(
      to: root.appendingPathComponent("lib/inner/c.swift"), atomically: true, encoding: .utf8)
    var answered: Set<String>??
    let updated = expectation(description: "relisted")
    index.update(moved: ["src/b.swift", "lib"]) { directories in
      answered = directories
      updated.fulfill()
    }
    wait(for: [updated], timeout: 5)

    XCTAssertEqual(answered ?? nil, ["src", ""])
    XCTAssertGreaterThan(index.generation, before)
    XCTAssertEqual(index.filePaths, ["lib/inner/c.swift", "src/a.swift", "src/b.swift"])

    try FileManager.default.removeItem(at: root.appendingPathComponent("lib"))
    let removed = expectation(description: "removed")
    index.update(moved: ["lib"]) { _ in removed.fulfill() }
    wait(for: [removed], timeout: 5)
    XCTAssertEqual(index.filePaths, ["src/a.swift", "src/b.swift"])
    XCTAssertNil(index.entries(of: "lib/inner"), "the subtree went with it")
  }

  /// The panel's own write is read in at once, on the caller's thread, so the row exists before
  /// the next line names it.
  func testRefreshNowReadsOneDirectoryOnTheSpot() throws {
    let root = try makeTree(["a.swift"])
    let index = WorktreeIndex(root: root) { _ in [] }
    built(index)
    try "y\n".write(to: root.appendingPathComponent("untitled"), atomically: true, encoding: .utf8)

    index.refreshNow("")

    XCTAssertEqual(index.filePaths, ["a.swift", "untitled"])
  }
}
