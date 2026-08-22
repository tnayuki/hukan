import XCTest

@testable import Hukan

/// The scan behind the desk's search tab: literal, case-insensitive, one hit per line, in path
/// order, binary and oversize files skipped, and the cap reported rather than silent.
final class FileSearchTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-search-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func write(_ contents: Data, to relativePath: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url)
  }

  private func write(_ contents: String, to relativePath: String) throws {
    try write(Data(contents.utf8), to: relativePath)
  }

  func testHitsAreOnePerLineInPathThenLineOrder() throws {
    try write("let alpha = 1\nlet Beta = 2\n// alpha again, ALPHA twice\n", to: "b/second.swift")
    try write("alpha\n", to: "a/first.swift")
    let result = FileSearch.scan(
      query: "Alpha", paths: ["b/second.swift", "a/first.swift"], root: root)
    XCTAssertFalse(result.truncated)
    XCTAssertEqual(
      result.hits,
      [
        FileSearch.Hit(path: "b/second.swift", line: 1, text: "let alpha = 1"),
        FileSearch.Hit(path: "b/second.swift", line: 3, text: "// alpha again, ALPHA twice"),
        FileSearch.Hit(path: "a/first.swift", line: 1, text: "alpha"),
      ],
      "case-insensitive, a line counted once however many times it matches, paths in the order given"
    )
  }

  func testIndentIsKeptAndNewlineIsNot() throws {
    try write("  \tindented needle\r\nplain needle", to: "f.txt")
    let hits = FileSearch.scan(query: "needle", paths: ["f.txt"], root: root).hits
    XCTAssertEqual(hits.map(\.text), ["  \tindented needle", "plain needle"])
    XCTAssertEqual(hits.map(\.line), [1, 2])
  }

  func testBinaryMissingAndOversizeFilesAreSkipped() throws {
    try write(Data([0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65, 0x00, 0x01]), to: "blob.bin")
    try write(String(repeating: "needle\n", count: FileSearch.maxFileSize / 7 + 2), to: "huge.txt")
    try write("needle\n", to: "ok.txt")
    let hits = FileSearch.scan(
      query: "needle", paths: ["blob.bin", "missing.txt", "huge.txt", "ok.txt"], root: root
    ).hits
    XCTAssertEqual(hits.map(\.path), ["ok.txt"])
  }

  func testEmptyQueryFindsNothing() throws {
    try write("anything\n", to: "f.txt")
    XCTAssertTrue(FileSearch.scan(query: "", paths: ["f.txt"], root: root).hits.isEmpty)
  }

  func testCapIsReportedNotSilent() throws {
    try write(String(repeating: "x\n", count: FileSearch.limit + 5), to: "many.txt")
    let result = FileSearch.scan(query: "x", paths: ["many.txt"], root: root)
    XCTAssertTrue(result.truncated)
    XCTAssertEqual(result.hits.count, FileSearch.limit)
  }

  /// The cap cuts the same hits it would have cut serially, whichever of the parallel reads
  /// happened to finish first.
  func testCapKeepsThePathOrderNotTheFinishingOrder() throws {
    for index in 0..<400 {
      try write(String(repeating: "x\n", count: 20), to: String(format: "f%03d.txt", index))
    }
    let paths = (0..<400).map { String(format: "f%03d.txt", $0) }
    let result = FileSearch.scan(query: "x", paths: paths, root: root)
    XCTAssertTrue(result.truncated)
    XCTAssertEqual(result.hits.count, FileSearch.limit)
    XCTAssertEqual(
      Array(Set(result.hits.map(\.path))).sorted(), Array(paths.prefix(FileSearch.limit / 20)),
      "the first 100 files by path, and no file from beyond the cut")
  }

  /// Case-insensitive is ASCII case folding on bytes: every ASCII letter, and nothing else. A
  /// query with no case of its own is unaffected, which is what keeps a Japanese search exact.
  func testCaseFoldingIsASCIIAndLeavesTheRestExact() throws {
    try write("MixedCase\nune café\n検索する行\nUNE CAFÉ\n", to: "f.txt")
    XCTAssertEqual(
      FileSearch.scan(query: "mIXEDcASE", paths: ["f.txt"], root: root).hits.map(\.line), [1],
      "every ASCII letter folds, in either direction")
    XCTAssertEqual(
      FileSearch.scan(query: "検索", paths: ["f.txt"], root: root).hits.map(\.line), [3],
      "a query with no case of its own is matched exactly, which is the Japanese case")
    XCTAssertEqual(
      FileSearch.scan(query: "UNE CAFÉ", paths: ["f.txt"], root: root).hits.map(\.line), [4],
      "what folding bytes gives up: the ASCII half of the query still folds onto line 2, but É "
        + "does not answer to é, so only the line spelling it the same way is found")
  }

  /// A scan reads every file of a worktree, so it has to be abandonable: the answer to a query
  /// the reader has moved on from must neither land nor hold the next one up.
  func testACancelledScanStopsEarly() throws {
    for index in 0..<1000 {
      try write("needle\n", to: String(format: "f%04d.txt", index))
    }
    let paths = (0..<1000).map { String(format: "f%04d.txt", $0) }
    var rounds = 0
    let result = FileSearch.scan(
      query: "needle", paths: paths, root: root,
      isCancelled: {
        rounds += 1
        return rounds > 1
      })
    XCTAssertFalse(result.truncated)
    XCTAssertLessThan(
      result.hits.count, paths.count, "it stopped where it was told to, not at the end")
  }
}

/// The one matching rule both of the field's gestures share.
final class FoldedTextTests: XCTestCase {
  func testFoldingIsIdempotentSoAPreparedHaystackMatchesTheSame() {
    let needle = FoldedText("Sources/Hukan")
    XCTAssertTrue(needle.occurs(in: FoldedText("sources/HUKAN/Model.swift")))
    XCTAssertTrue(needle.occurs(in: "SOURCES/hukan/Model.swift"))
    XCTAssertFalse(needle.occurs(in: FoldedText("Tests/HukanAppTests/Model.swift")))
  }

  func testAnEmptyNeedleMatchesNothing() {
    XCTAssertTrue(FoldedText("").isEmpty)
    XCTAssertFalse(FoldedText("").occurs(in: "anything"))
  }
}
