import XCTest

@testable import Hukan

/// The one resolution every outside hand-off shares — a Finder drop, the command line, a
/// `$EDITOR` file: the deepest open worktree containing the path claims it, and everything
/// under `.git` is the repository, not the checkout's contents.
final class PathResolutionTests: XCTestCase {
  private func workspace(roots: [String]) -> Workspace {
    let workspace = Workspace()
    for root in roots {
      let repo = Repository(id: root)
      let worktree = Worktree(url: URL(fileURLWithPath: root), repository: repo)
      repo.worktrees = [worktree]
      workspace.repositories.append(repo)
    }
    return workspace
  }

  func testTheDeepestContainingWorktreeClaimsThePath() {
    let ws = workspace(roots: ["/private/tmp/repo", "/private/tmp/repo/vendor/nested"])
    let hit = ws.worktreeContaining("/private/tmp/repo/vendor/nested/a.txt")
    XCTAssertEqual(hit?.worktree.url.path, "/private/tmp/repo/vendor/nested")
    XCTAssertEqual(hit?.relativePath, "a.txt")
  }

  func testTheRootItselfResolvesWithAnEmptyRelativePath() {
    let ws = workspace(roots: ["/private/tmp/repo"])
    XCTAssertEqual(ws.worktreeContaining("/private/tmp/repo")?.relativePath, "")
  }

  /// `/private/tmp/repo2` must not match the root `/private/tmp/repo` by prefix alone — the
  /// containment test is on the separator, the same rule `repath` follows for renames.
  func testASiblingWithASharedPrefixIsNotContained() {
    let ws = workspace(roots: ["/private/tmp/repo"])
    XCTAssertNil(ws.worktreeContaining("/private/tmp/repo2/a.txt"))
  }

  func testAPathOutsideEveryWorktreeIsNotContained() {
    let ws = workspace(roots: ["/private/tmp/repo"])
    XCTAssertNil(ws.worktreeContaining("/private/tmp/elsewhere/a.txt"))
  }

  /// `.git` and everything under it is the repository. `.github` and `.gitignore` are ordinary
  /// checkout contents — the test is on the separator here too.
  func testGitInternalPathsAreTheRepositorysNotTheCheckouts() {
    XCTAssertTrue(Workspace.isRepositoryInternal(".git"))
    XCTAssertTrue(Workspace.isRepositoryInternal(".git/COMMIT_EDITMSG"))
    XCTAssertTrue(Workspace.isRepositoryInternal(".git/worktrees/feat/COMMIT_EDITMSG"))
    XCTAssertFalse(Workspace.isRepositoryInternal("src/a.txt"))
    XCTAssertFalse(Workspace.isRepositoryInternal(".github/workflows/ci.yml"))
    XCTAssertFalse(Workspace.isRepositoryInternal(".gitignore"))
  }
}

/// Discovery against a real repository, the CLI as the fixture builder — `git_repository_open`
/// answers only at a root, and these are exactly the askings that arrive pointing elsewhere.
final class GitDiscoveryTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    Git.initialize()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-discover-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    root = tmp.resolvingSymlinksInPath()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  @discardableResult
  private func git(_ arguments: [String], in directory: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func testDiscoveryWalksUpFromASubdirectoryAndIntoLinkedWorktrees() throws {
    let main = root.appendingPathComponent("main")
    let deep = main.appendingPathComponent("src/deep")
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    git(["init", "-q", "-b", "main", main.path], in: root)
    try "hi".write(to: deep.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    git(["add", "-A"], in: main)
    git(
      ["-c", "user.email=t@e", "-c", "user.name=t", "commit", "-qm", "init"], in: main)
    git(["worktree", "add", "-q", "../feat", "-b", "feat"], in: main)

    // From a subdirectory: the repository, not the subdirectory — the bug this exists for.
    XCTAssertEqual(Git.discoverRepository(containing: deep), main.path)
    // From inside a linked worktree: the common dir's parent, the repository's one identity.
    let feat = root.appendingPathComponent("feat")
    XCTAssertEqual(Git.discoverRepository(containing: feat.appendingPathComponent(".")), main.path)
    // From inside the gitdir — where a linked worktree's COMMIT_EDITMSG lives.
    XCTAssertEqual(
      Git.discoverRepository(
        containing: main.appendingPathComponent(".git/worktrees/feat")),
      main.path)
    // Nowhere near git: no answer.
    XCTAssertNil(Git.discoverRepository(containing: root))
  }
}
