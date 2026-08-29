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
