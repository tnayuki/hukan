import XCTest

@testable import Hukan

/// The bundled `rg`, which is both of the files panel's gestures: the filter's rows and the
/// content search's hits. What is asserted here is the rules those two have always had — what a
/// typed query matches, what is walked into, and that a run can be abandoned — now that rg is
/// what applies them.
final class RipgrepTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-rg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func write(_ contents: String, to relativePath: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
  }

  private func write(_ contents: Data, to relativePath: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url)
  }

  /// Walk to the end and answer with every path it handed over, sorted so the assertion is about
  /// the set rather than about rg's traversal order.
  private func walk(
    matching query: String = "", file: StaticString = #filePath, line: UInt = #line
  ) throws -> [String] {
    var found: [String] = []
    var finished = false
    let done = expectation(description: "walked")
    Ripgrep.files(
      in: root, matching: query,
      // The walk hands over the bytes it read — NUL-terminated paths — so a reader that wants
      // strings is the one that makes them.
      batch: { chunk in
        found.append(
          contentsOf: chunk.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
      },
      completion: {
        finished = $0
        done.fulfill()
      })
    wait(for: [done], timeout: 10)
    XCTAssertTrue(finished, "the walk was seen through", file: file, line: line)
    return found.sorted()
  }

  private func search(
    _ query: String, in paths: [String] = [], file: StaticString = #filePath, line: UInt = #line
  ) throws -> [Ripgrep.Hit] {
    var found: [Ripgrep.Hit] = []
    let done = expectation(description: "searched")
    Ripgrep.search(
      in: root, for: query, in: paths, batch: { found.append(contentsOf: $0) },
      completion: { _ in done.fulfill() })
    wait(for: [done], timeout: 10)
    return found.sorted { $0.path == $1.path ? $0.line < $1.line : $0.path < $1.path }
  }

  func testTheBinaryIsInTheBundle() throws {
    let binary = try XCTUnwrap(Ripgrep.binary, "Resources/rg ships with the app")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
  }

  func testIgnoreRulesApplyWhereverTheyAreFound() throws {
    // A nested repository, ignoring its own build output.
    try write("node_modules/\n", to: "repo/.gitignore")
    try write("{}\n", to: "repo/node_modules/left.json")
    try write("let a = 1\n", to: "repo/src/a.swift")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
    // A plain directory with an ignore file and no repository behind it at all: `.gitignore` is
    // a statement about the directory whether or not anyone ran `git init`, and the home
    // directory — the case this walk exists to survive — is full of them.
    try write("secret.txt\n", to: "plain/.gitignore")
    try write("shh\n", to: "plain/secret.txt")
    try write("keep\n", to: "plain/keep.txt")

    XCTAssertEqual(
      try walk(),
      ["plain/.gitignore", "plain/keep.txt", "repo/.gitignore", "repo/src/a.swift"],
      "ignored by a nested repository and by a directory that is not one; dotfiles otherwise kept")
  }

  func testAGitdirIsNeverWalkedIntoAtAnyDepth() throws {
    try write("ref: refs/heads/main\n", to: ".git/HEAD")
    try write("blob\n", to: "nested/.git/objects/ab/cdef")
    try write("let a = 1\n", to: "nested/a.swift")

    XCTAssertEqual(
      try walk(), ["nested/a.swift"],
      "`.git` is the repository, not the worktree — and `--hidden` would otherwise walk it")
  }

  /// What a typed query means: a path component that contains it, and everything under a
  /// directory whose name does — so `Tests` narrows to that directory's contents, which is what
  /// the substring match this replaces did.
  func testAQueryMatchesAComponentAndWhatIsUnderIt() throws {
    try write("a\n", to: "Tests/HukanAppTests/deep/browser.png")
    try write("b\n", to: "Tests/HukanAppTests/FilesPanelTests.swift")
    try write("c\n", to: "Sources/Hukan/FilesPanel.swift")
    try write("d\n", to: "Sources/Hukan/Model.swift")

    XCTAssertEqual(
      try walk(matching: "tests"),
      [
        "Tests/HukanAppTests/FilesPanelTests.swift", "Tests/HukanAppTests/deep/browser.png",
      ].sorted(), "case-insensitive, and the directory's contents come with it")
    XCTAssertEqual(
      try walk(matching: "panel"),
      ["Sources/Hukan/FilesPanel.swift", "Tests/HukanAppTests/FilesPanelTests.swift"].sorted(),
      "matched inside a name, not only at its edges")
  }

  /// A query may name two components at once, and then the separator has to line up with a real
  /// one — which is the one thing this rule does not do that a raw substring did.
  func testAQueryMayCrossAComponentBoundaryWhereThePathDoes() throws {
    try write("a\n", to: "Sources/Hukan/FilesPanel.swift")
    try write("b\n", to: "Sources/Transcript/FilesOfMine.swift")

    XCTAssertEqual(
      try walk(matching: "hukan/files"), ["Sources/Hukan/FilesPanel.swift"],
      "the two components in the order they were typed")
  }

  /// A query is text, not a pattern: someone filtering for `*.swift` means those characters.
  func testGlobCharactersInAQueryAreTakenLiterally() throws {
    try write("a\n", to: "star*name.txt")
    try write("b\n", to: "plain.txt")

    XCTAssertEqual(try walk(matching: "star*name"), ["star*name.txt"])
  }

  func testTheSearchReportsEveryMatchingLineOnce() throws {
    try write("let alpha = 1\nlet Beta = 2\n// alpha again, ALPHA twice\n", to: "b/second.swift")
    try write("alpha\n", to: "a/first.swift")

    XCTAssertEqual(
      try search("Alpha"),
      [
        Ripgrep.Hit(path: "a/first.swift", line: 1, text: "alpha"),
        Ripgrep.Hit(path: "b/second.swift", line: 1, text: "let alpha = 1"),
        Ripgrep.Hit(path: "b/second.swift", line: 3, text: "// alpha again, ALPHA twice"),
      ],
      "case-insensitive, a line counted once however many times it matches, its indent kept")
  }

  /// The ± scope: git has answered which files changed, so those are the files rg is given.
  func testTheSearchCanBeGivenThePathsToRead() throws {
    try write("needle\n", to: "changed.swift")
    try write("needle\n", to: "untouched.swift")

    XCTAssertEqual(try search("needle", in: ["changed.swift"]).map(\.path), ["changed.swift"])
  }

  /// A literal, never a pattern: the search field is not a regex box.
  func testTheSearchQueryIsALiteral() throws {
    try write("a.b\n", to: "a.swift")
    try write("axb\n", to: "b.swift")

    XCTAssertEqual(try search("a.b").map(\.path), ["a.swift"])
  }

  func testABinaryFileIsNotSearched() throws {
    try write(Data([0x6e, 0x65, 0x65, 0x64, 0x6c, 0x65, 0x00, 0x01]), to: "blob.bin")
    try write("needle\n", to: "text.swift")

    XCTAssertEqual(try search("needle").map(\.path), ["text.swift"])
  }

  func testACancelledWalkStopsAndSaysSo() throws {
    // Enough files that the walk cannot have finished before the cancel lands.
    for index in 0..<4000 {
      try write("x\n", to: "deep/\(index % 20)/file-\(index).txt")
    }
    var finished = true
    let done = expectation(description: "cancelled")
    let run = Ripgrep.files(
      in: root, batch: { _ in },
      completion: {
        finished = $0
        done.fulfill()
      })
    run?.cancel()
    wait(for: [done], timeout: 10)
    XCTAssertFalse(finished, "a cancelled walk reports that it was not seen through")
  }
}
