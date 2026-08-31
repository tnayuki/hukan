import XCTest

@testable import Hukan

/// What the rail's two copy items put on the pasteboard. The menu itself is built from
/// `clickedRow`, which only exists during a click, so what is asserted here is the pair of
/// derivations behind the items — which is where the whole of the decision lives anyway.
final class RailCopyTests: XCTestCase {
  /// A rail over one repository with `count` sessions in its main worktree, and those sessions.
  private func rail(sessions count: Int) -> (SessionRailViewController, [AgentSession]) {
    let repo = Repository(id: "/repo/hukan")
    let main = Worktree(url: URL(fileURLWithPath: "/repo/hukan"), branch: "main", repository: repo)
    repo.worktrees = [main]

    let sessions = (0..<count).map { _ in AgentSession(worktreeID: main.id) }
    let workspace = Workspace()
    workspace.repositories = [repo]
    workspace.sessions = sessions

    let rail = SessionRailViewController()
    rail.workspace = workspace
    return (rail, sessions)
  }

  /// The path is absolute and names Claude Code's store, not the worktree: there is nothing for
  /// it to be relative to, which is why this is one item where the files panel's Copy Path is two.
  func testTheTranscriptPathNamesTheStore() throws {
    let (rail, sessions) = rail(sessions: 1)
    let path = try XCTUnwrap(rail.transcriptPaths(of: sessions).first)

    XCTAssertTrue(path.hasPrefix("/"), "absolute: it goes to something standing somewhere else")
    XCTAssertTrue(path.contains("/.claude/projects/-repo-hukan/"))
    XCTAssertEqual(
      (path as NSString).lastPathComponent, "\(ClaudeSessionStore.name(sessions[0].id)).jsonl",
      "the same file transcriptURL would open — one derivation, not two")
  }

  /// A session that has never run has no file yet, and its path is still where that file will be
  /// written: the id and the worktree are what decide the name, and both are settled the moment
  /// the row exists.
  func testASessionWithNoTranscriptIsStillNamed() throws {
    let (rail, sessions) = rail(sessions: 1)
    let path = try XCTUnwrap(rail.transcriptPaths(of: sessions).first)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: path),
      "nothing was written; the point is that the path is answerable anyway")
  }

  /// A batch answers in the order it was given, one entry per row.
  func testABatchIsAnsweredRowForRow() {
    let (rail, sessions) = rail(sessions: 3)
    XCTAssertEqual(rail.sessionIDs(of: sessions), sessions.map { ClaudeSessionStore.name($0.id) })
    XCTAssertEqual(rail.transcriptPaths(of: sessions).count, 3)
  }

  /// The one session that cannot be named is one whose worktree this window no longer holds —
  /// there is no directory to name the file under. It drops out rather than answering wrongly.
  func testASessionWithNoWorktreeDropsOut() {
    let (rail, _) = rail(sessions: 1)
    let orphan = AgentSession(worktreeID: UUID())

    XCTAssertEqual(rail.transcriptPaths(of: [orphan]), [])
    XCTAssertEqual(
      rail.sessionIDs(of: [orphan]), [ClaudeSessionStore.name(orphan.id)],
      "the id needs no worktree to be true")
  }

  /// Pasted, an id has to match the store rather than merely resolve against it: Claude Code
  /// spells the ones it mints in lower case, and a grep is not a filesystem.
  func testAnIDIsCopiedInTheSpellingTheStoreUses() throws {
    let (rail, sessions) = rail(sessions: 1)
    let id = try XCTUnwrap(rail.sessionIDs(of: sessions).first)
    XCTAssertEqual(id, id.lowercased())
    XCTAssertEqual(UUID(uuidString: id), sessions[0].id)
  }
}
