import XCTest

@testable import Hukan

/// `Git.fileBase` against a real repository — the libgit2 reads that stand behind the gutter,
/// where `LineChangesTests` pins what is done with them.
final class GitLineChangesTests: XCTestCase {
  private var repo: URL!

  override func setUpWithError() throws {
    repo = FileManager.default.temporaryDirectory
      .appendingPathComponent("hukan-linechanges-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try git("init", "-q")
    try write("one\ntwo\nthree\nfour\n")
    try git("add", "file.txt")
    try git("commit", "-q", "-m", "base")
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: repo)
  }

  func testBaseReadsHeadAndIndex() throws {
    try write("one\nTWO\nthree\nfour\n")
    try git("add", "file.txt")
    // Unstaged on top of the staged rewrite.
    try write("one\nTWO\nthree\nFOUR\n")

    let base = Git.fileBase(at: repo, path: "file.txt")
    XCTAssertEqual(base.head, "one\ntwo\nthree\nfour\n")
    XCTAssertEqual(base.index, "one\nTWO\nthree\nfour\n")

    // End to end: the staged block hollow, the working-tree one solid.
    let changes = Git.lineChanges(base: base, current: try contents())
    XCTAssertEqual(changes.bars[2], Git.LineChanges.Bar(kind: .modified, staged: true))
    XCTAssertEqual(changes.bars[4], Git.LineChanges.Bar(kind: .modified, staged: false))
  }

  func testUntouchedFileHasNoChanges() throws {
    let base = Git.fileBase(at: repo, path: "file.txt")
    XCTAssertTrue(Git.lineChanges(base: base, current: try contents()).bars.isEmpty)
  }

  /// A repository that stores LF and checks out CRLF — a Windows batch file under
  /// `*.bat text eol=crlf` — must read as unchanged: the base is the file as the checkout wrote
  /// it, or every line of it is a bar while git's own diff says nothing moved.
  func testCheckoutFiltersApplyToTheBase() throws {
    try write("*.bat text eol=crlf\n", to: ".gitattributes")
    try write("@echo off\r\necho hello\r\n", to: "run.bat")
    try git("add", ".gitattributes", "run.bat")
    try git("commit", "-q", "-m", "batch")

    let base = Git.fileBase(at: repo, path: "run.bat")
    XCTAssertEqual(base.head, "@echo off\r\necho hello\r\n")
    XCTAssertEqual(base.index, "@echo off\r\necho hello\r\n")
    let current = try String(contentsOf: repo.appendingPathComponent("run.bat"), encoding: .utf8)
    XCTAssertTrue(Git.lineChanges(base: base, current: current).bars.isEmpty)
  }

  func testUntrackedFileHasNoBase() throws {
    try "new\n".write(
      to: repo.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
    let base = Git.fileBase(at: repo, path: "other.txt")
    XCTAssertNil(base.head)
    XCTAssertNil(base.index)
  }

  private func write(_ text: String) throws {
    try write(text, to: "file.txt")
  }

  private func write(_ text: String, to name: String) throws {
    try text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  private func contents() throws -> String {
    try String(contentsOf: repo.appendingPathComponent("file.txt"), encoding: .utf8)
  }

  private func git(_ arguments: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = repo
    process.arguments =
      ["-c", "user.name=test", "-c", "user.email=test@example.com"] + arguments
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
  }
}
