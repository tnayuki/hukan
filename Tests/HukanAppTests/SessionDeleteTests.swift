import XCTest

@testable import Hukan

/// Deleting a session. The list is derived from the transcripts on disk, so a delete that did not
/// remove the file would be undone by the next scan — these pin that it is the file that goes, and
/// that the enumerator stops offering it.
final class SessionDeleteTests: XCTestCase {
  private var worktree: URL!

  override func setUpWithError() throws {
    worktree = URL(fileURLWithPath: "/tmp/hukan-delete-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: ClaudeSessionStore.directory(for: worktree), withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: ClaudeSessionStore.directory(for: worktree))
  }

  @discardableResult
  private func writeTranscript() throws -> UUID {
    let id = UUID()
    try #"{"type":"user","message":{"role":"user","content":"hi"}}"#.write(
      to: ClaudeSessionStore.transcriptURL(id: id, worktree: worktree),
      atomically: true, encoding: .utf8)
    return id
  }

  func testDeleteRemovesTheTranscript() throws {
    let id = try writeTranscript()
    XCTAssertTrue(ClaudeSessionStore.isResumable(id: id, worktree: worktree))

    XCTAssertTrue(ClaudeSessionStore.delete(id: id, worktree: worktree))

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: ClaudeSessionStore.transcriptURL(id: id, worktree: worktree).path))
    // The list is the files, so the deleted session is gone from it too — not merely hidden.
    XCTAssertFalse(ClaudeSessionStore.sessions(in: worktree).contains { $0.id == id })
    XCTAssertFalse(ClaudeSessionStore.isResumable(id: id, worktree: worktree))
  }

  func testDeleteLeavesTheOtherSessionsAlone() throws {
    let doomed = try writeTranscript()
    let kept = try writeTranscript()

    ClaudeSessionStore.delete(id: doomed, worktree: worktree)

    let remaining = ClaudeSessionStore.sessions(in: worktree).map(\.id)
    XCTAssertEqual(remaining, [kept])
  }

  /// Deleting through the workspace takes the row, the archive flag and the file. With no engine
  /// there is nothing to wait for, so all three land in the same breath — the case a restored
  /// session that was only ever looked at is in.
  func testDeleteTakesTheRowTheFlagAndTheFile() throws {
    let repository = Repository(id: worktree.path)
    let main = Worktree(url: worktree, branch: "main", repository: repository)
    repository.worktrees = [main]
    let workspace = Workspace()
    workspace.repositories = [repository]
    let id = try writeTranscript()
    let session = AgentSession(id: id, worktreeID: main.id)
    workspace.sessions = [session]
    workspace.archivedSessionIDs = [id]
    workspace.selectedSessionID = id

    XCTAssertTrue(workspace.deleteSession(session))

    XCTAssertTrue(workspace.sessions.isEmpty)
    XCTAssertTrue(workspace.closingSessions.isEmpty, "nothing is left waiting on an exit")
    XCTAssertFalse(workspace.archivedSessionIDs.contains(id))
    XCTAssertNil(workspace.selectedSessionID)
    XCTAssertFalse(ClaudeSessionStore.isResumable(id: id, worktree: worktree))
  }

  /// A session another live process holds is refused outright: that engine is still writing the
  /// transcript, and the row must survive the refusal rather than half-leave.
  func testDeleteRefusesASessionHeldElsewhere() throws {
    let repository = Repository(id: worktree.path)
    let main = Worktree(url: worktree, branch: "main", repository: repository)
    repository.worktrees = [main]
    let workspace = Workspace()
    workspace.repositories = [repository]
    let id = try writeTranscript()
    let session = AgentSession(id: id, worktreeID: main.id)
    workspace.sessions = [session]
    // Ourselves: a pid that is certainly alive, which is the whole of what the hold reads.
    session.markHeldElsewhere(by: getpid())

    XCTAssertFalse(workspace.deleteSession(session))

    XCTAssertEqual(workspace.sessions.count, 1)
    XCTAssertTrue(ClaudeSessionStore.isResumable(id: id, worktree: worktree))
  }

  /// Deleting what is already gone is not a failure — the caller wanted it absent, and it is.
  func testDeleteIsIdempotent() throws {
    let id = try writeTranscript()
    XCTAssertTrue(ClaudeSessionStore.delete(id: id, worktree: worktree))
    XCTAssertTrue(ClaudeSessionStore.delete(id: id, worktree: worktree))
  }
}
