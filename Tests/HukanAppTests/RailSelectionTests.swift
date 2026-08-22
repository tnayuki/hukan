import AppKit
import XCTest

@testable import Hukan

/// The rail's selection, driven through a real outline view — the rules here are delegate
/// callbacks and reload bookkeeping, so there is nothing to exercise without a view behind them.
/// The one worth the most is that a multi-selection survives the reload that runs per FSEvents
/// batch: a selection that evaporated there would do so exactly while a batch act is being lined
/// up.
final class RailSelectionTests: XCTestCase {
  private func rail(sessionCount: Int) -> (SessionRailViewController, Workspace, [AgentSession]) {
    let repo = Repository(id: "/repo/main")
    let main = Worktree(url: URL(fileURLWithPath: "/repo/main"), branch: "main", repository: repo)
    repo.worktrees = [main]
    let workspace = Workspace()
    workspace.repositories = [repo]
    workspace.selectedWorktreeID = main.id
    let sessions = (0..<sessionCount).map { index -> AgentSession in
      let session = AgentSession(worktreeID: main.id)
      session.title = "Session \(index)"
      session.lastInstructedAt = Date(timeIntervalSinceReferenceDate: Double(sessionCount - index))
      return session
    }
    workspace.sessions = sessions

    let rail = SessionRailViewController()
    rail.workspace = workspace
    rail.loadViewIfNeeded()
    rail.reload()
    return (rail, workspace, sessions)
  }

  /// A reload runs for every FSEvents batch, so a selection of several that came back as one would
  /// evaporate under an agent writing files — which is exactly when a batch act is being lined up.
  func testAMultiSelectionSurvivesAReload() {
    let (rail, _, sessions) = rail(sessionCount: 4)
    rail.selectSessions([sessions[0].id, sessions[2].id])
    XCTAssertEqual(Set(rail.selectedSessionIDs), [sessions[0].id, sessions[2].id])

    rail.reload()
    XCTAssertEqual(Set(rail.selectedSessionIDs), [sessions[0].id, sessions[2].id])
  }

  /// The real path, which a rail with no window behind it does not exercise: widening the
  /// selection moves the anchor, the window follows by pointing at it, and the reload that follows
  /// must not read its own anchor as a pick from elsewhere — that collapses the selection to one
  /// row the instant it is widened.
  func testWideningTheSelectionSurvivesTheWindowFollowingTheAnchor() {
    let (rail, workspace, sessions) = rail(sessionCount: 4)
    // What the window does with `onSelectSession`: record the pick, then reload the rail.
    rail.onSelectSession = { [weak rail] session in
      workspace.selectedSessionID = session.id
      rail?.reload()
    }

    rail.selectSessions([sessions[0].id])
    rail.selectSessions([sessions[0].id, sessions[2].id])
    XCTAssertEqual(Set(rail.selectedSessionIDs), [sessions[0].id, sessions[2].id])
    XCTAssertEqual(workspace.selectedSessionID, sessions[2].id)

    // A pick from elsewhere still replaces it — that is the half of the rule worth keeping.
    workspace.selectedSessionID = sessions[3].id
    rail.reload()
    XCTAssertEqual(rail.selectedSessionIDs, [sessions[3].id])
  }

  /// A shift-extension is one selection change per keypress, and each one tells the window. If
  /// that round trip rebuilt the rail, the outline would be handed a fresh selection every time —
  /// and with it a fresh range origin, which is what ⇧ extends from. The rail must therefore not
  /// rebuild itself while it is the one doing the telling.
  func testTheRailIsNotRebuiltWhileItIsReportingItsOwnSelection() {
    let (rail, workspace, sessions) = rail(sessionCount: 4)
    let outline = rail.outlineViewForTesting
    var reloads = 0
    rail.onSelectSession = { [weak rail] session in
      workspace.selectedSessionID = session.id
      reloads += 1
      rail?.reload()
    }

    rail.selectSessions([sessions[0].id])
    reloads = 0
    // What ⇧↓ amounts to: the outline widens its own selection and the delegate reports it.
    outline.selectRowIndexes(IndexSet(1...2), byExtendingSelection: false)
    XCTAssertEqual(reloads, 1, "the window was told")
    XCTAssertEqual(outline.selectedRowIndexes, IndexSet(1...2), "and the rows were left alone")

    // A reload from anywhere else still rebuilds, and still restores what was selected.
    rail.reload()
    XCTAssertEqual(outline.selectedRowIndexes, IndexSet(1...2))
  }

  /// The anchor is the row that joined last, not the lowest — `selectedRow` would send the
  /// transcript column to the top of a range the moment you shift-clicked downwards.
  func testTheAnchorIsTheRowSelectedLast() {
    let (rail, workspace, sessions) = rail(sessionCount: 4)
    var navigated: [UUID] = []
    rail.onSelectSession = { navigated.append($0.id) }

    // Selecting the *later* row second makes it the anchor, even though it is not the lowest.
    rail.selectSessions([sessions[3].id, sessions[1].id])
    XCTAssertEqual(navigated.last, sessions[1].id)
    XCTAssertEqual(workspace.selectedSessionID, nil, "the rail reports; the window decides")
  }

  /// A fold is allowed to hide the selected row. The time buckets needed the opposite rule only
  /// because their fold was automatic — "Older" collapsed itself on every reload, so a session
  /// selected inside it was folded away again by the next background refresh. Every fold left is
  /// an explicit one, so the section shuts when it is asked to, selection or no selection.
  func testTheArchivedSectionFoldsEvenWhileItHoldsTheSelection() {
    let (rail, workspace, sessions) = rail(sessionCount: 3)
    XCTAssertTrue(workspace.setArchived(true, for: [sessions[0]]))
    workspace.expandedArchives = [sessions[0].worktreeID.uuidString]
    workspace.selectedSessionID = sessions[0].id
    rail.reload()
    XCTAssertTrue(rail.selectedSessionIDs.contains(sessions[0].id))

    workspace.expandedArchives = []
    rail.reload()
    // The row is gone from the outline, so nothing is highlighted — and the window still points
    // at that session, which is what keeps the transcript column showing it.
    XCTAssertTrue(rail.selectedSessionIDs.isEmpty)
    XCTAssertEqual(workspace.selectedSessionID, sessions[0].id)
  }

  /// Only sessions may be selected together: a heading in a batch is not something any act could
  /// be given. One row of any kind is still selectable, which keeps a heading a destination.
  func testAWideProposalKeepsOnlyTheSessionRows() {
    let (rail, _, sessions) = rail(sessionCount: 2)
    let outline = rail.outlineViewForTesting
    let rows = IndexSet(0..<outline.numberOfRows)
    // Rows: 0 = the repository heading, which is main, then main's sessions straight under it.
    XCTAssertEqual(outline.numberOfRows, 1 + sessions.count)

    let narrowed = rail.outlineView(outline, selectionIndexesForProposedSelection: rows)
    XCTAssertEqual(narrowed, IndexSet(1...2))
    // A single row of any kind passes through untouched.
    XCTAssertEqual(
      rail.outlineView(outline, selectionIndexesForProposedSelection: IndexSet(integer: 0)),
      IndexSet(integer: 0))
  }
}
