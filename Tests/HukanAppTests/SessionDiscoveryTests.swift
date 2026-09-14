import XCTest

@testable import Hukan

/// What `Workspace.discoverSessions` finds when it rebuilds the rail.
///
/// The list is derived from the transcripts on disk rather than stored, so what a rebuild fails
/// to look up is a session that simply disappears once its process is gone — which is the one
/// thing archiving is supposed to be the only way out of. The enumeration it looks them up by is
/// git's, and a plain directory has none.
final class SessionDiscoveryTests: XCTestCase {
  private var root: URL!
  private var stores: [URL] = []

  override func setUpWithError() throws {
    Git.initialize()
    // libgit2 reports resolved paths, and so does the engine's own name for its cwd — resolve
    // the base up front so the store's slug and the rail's paths line up.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-discovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    root = tmp.resolvingSymlinksInPath()
  }

  override func tearDownWithError() throws {
    for store in stores { try? FileManager.default.removeItem(at: store) }
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: helpers

  @discardableResult
  private func git(_ arguments: [String], in dir: URL? = nil) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = dir ?? root
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A transcript recorded against `worktree`, the way a detached session's is left behind: a
  /// file in the store and nothing else — no process, nothing on our side.
  @discardableResult
  private func recordTranscript(in worktree: URL) throws -> UUID {
    let directory = ClaudeSessionStore.directory(for: worktree)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    stores.append(directory)
    let id = UUID()
    try #"{"type":"user","message":{"role":"user","content":"hello"}}"#.write(
      to: ClaudeSessionStore.transcriptURL(id: id, worktree: worktree),
      atomically: true, encoding: .utf8)
    return id
  }

  // MARK: tests

  /// No `git init`: a plain directory opens as its own repository, and `git_repository_open`
  /// fails there — so the enumeration is empty and the rebuild used to look up nothing at all.
  /// Every session of such a desk that was not still attached left the rail with its process.
  func testANonGitRootRebuildsItsSessions() throws {
    let id = try recordTranscript(in: root)

    let workspace = Workspace()
    workspace.addWorktree(root)
    workspace.discoverSessions()

    XCTAssertTrue(
      workspace.sessions.contains { $0.id == id },
      "a transcript recorded against a non-git root must survive the rebuild")
  }

  /// The other half of the same change: where git does answer, its answer is still the one used.
  /// The session here is recorded against a *linked* worktree that was never opened by hand, so
  /// only the enumeration can reach it — a fallback standing in front of git would lose it.
  func testACheckoutStillDiscoversThroughGitsEnumeration() throws {
    git(["init", "-q", "-b", "main"])
    git(["config", "user.email", "test@example.com"])
    git(["config", "user.name", "Test"])
    git(["config", "commit.gpgsign", "false"])
    try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    git(["add", "."])
    git(["commit", "-q", "-m", "first"])

    let linked = root.deletingLastPathComponent()
      .appendingPathComponent("linked-\(UUID().uuidString)")
    git(["worktree", "add", "-q", linked.path])
    defer { git(["worktree", "remove", "--force", linked.path]) }

    let id = try recordTranscript(in: linked.resolvingSymlinksInPath())

    let workspace = Workspace()
    workspace.addWorktree(root)
    workspace.discoverSessions()

    XCTAssertTrue(
      workspace.sessions.contains { $0.id == id },
      "a linked worktree's sessions arrive through git's enumeration, not the open root")
  }
}
