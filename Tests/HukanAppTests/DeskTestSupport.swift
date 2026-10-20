import Foundation
import XCTest

@testable import Hukan

extension XCTestCase {
  /// A session standing in `worktree`, for a test to put a desk's tabs on — a desk is a session's,
  /// so a tab needs one to stand on. The session has a transcript on disk, empty, because the
  /// session list is rebuilt from the transcripts on every discovery and a relaunch is one: without
  /// it a round trip through the restorable state would come back with nobody to hand the tabs
  /// to. The worktree's session already there is the one returned, so a test can ask twice.
  @discardableResult
  func deskSession(in worktree: Worktree, of workspace: Workspace) -> AgentSession {
    if let existing = workspace.latestSession(inWorktree: worktree.id) { return existing }
    let session = AgentSession(worktreeID: worktree.id, isDetached: true)
    let store = ClaudeSessionStore.directory(for: worktree.url)
    try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: ClaudeSessionStore.transcriptURL(id: session.id, worktree: worktree.url).path,
      contents: Data())
    addTeardownBlock { try? FileManager.default.removeItem(at: store) }
    workspace.sessions.append(session)
    return session
  }
}
