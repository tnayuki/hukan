import AppKit
import XCTest

@testable import Hukan

/// The rail's keys, driven through an outline in a real window — without one, NSOutlineView
/// neither extends a selection nor folds, so nothing here can be exercised headless. Two things
/// are pinned: that ← and → fold and unfold (AppKit's own arrow handling hangs off the disclosure
/// cell the rail hides, so the keys are the rail's), and that a ⇧-range keeps growing across the
/// reloads that run underneath it, which is only true while a reload leaves AppKit's selection
/// alone.
final class RailKeyboardTests: XCTestCase {
  private var window: NSWindow?

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
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentViewController = rail
    self.window = window
    rail.loadViewIfNeeded()
    rail.reload()
    window.makeFirstResponder(rail.outlineViewForTesting)
    rail.view.layoutSubtreeIfNeeded()
    return (rail, workspace, sessions)
  }

  private func press(_ outline: NSOutlineView, _ key: Key, shift: Bool = false) {
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0,
      windowNumber: 0, context: nil, characters: key.characters,
      charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code)!
    outline.keyDown(with: event)
  }

  private enum Key {
    case up, down, left, right
    var code: UInt16 {
      switch self {
      case .up: return 126
      case .down: return 125
      case .left: return 123
      case .right: return 124
      }
    }
    var characters: String {
      switch self {
      case .up: return "\u{F700}"
      case .down: return "\u{F701}"
      case .left: return "\u{F702}"
      case .right: return "\u{F703}"
      }
    }
  }

  func testLeftAndRightFoldTheRepositoryAndTheFoldSurvivesAReload() {
    let (rail, workspace, _) = rail(sessionCount: 3)
    let outline = rail.outlineViewForTesting
    outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    XCTAssertEqual(outline.numberOfRows, 4)

    press(outline, .left)
    XCTAssertEqual(outline.numberOfRows, 1, "← folds the heading")
    XCTAssertEqual(workspace.collapsedRepositories, ["/repo/main"], "and it is written down")
    rail.reload()
    XCTAssertEqual(outline.numberOfRows, 1, "so a background reload leaves it folded")

    press(outline, .right)
    XCTAssertEqual(outline.numberOfRows, 4, "→ unfolds it")
    XCTAssertTrue(workspace.collapsedRepositories.isEmpty)
    // → on an open heading steps into it; ← on a session steps back out.
    press(outline, .right)
    XCTAssertEqual(outline.selectedRow, 1)
    press(outline, .left)
    XCTAssertEqual(outline.selectedRow, 0)
  }

  func testLeftAndRightFoldAGroupAndPreserveItsRepositoryFold() {
    let (rail, workspace, _) = rail(sessionCount: 2)
    let group = workspace.createGroup(name: "Customer")
    workspace.moveRailRepository("/repo/main", to: group, at: 0)
    workspace.collapsedRepositories = ["/repo/main"]
    rail.reload()
    let outline = rail.outlineViewForTesting
    outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    XCTAssertEqual(outline.numberOfRows, 2)
    press(outline, .left)
    XCTAssertEqual(workspace.collapsedGroups, [group])
    XCTAssertEqual(outline.numberOfRows, 1)
    rail.reload()
    press(outline, .right)
    XCTAssertTrue(workspace.collapsedGroups.isEmpty)
    XCTAssertEqual(outline.numberOfRows, 2)
    XCTAssertEqual(workspace.collapsedRepositories, ["/repo/main"])
    press(outline, .right)
    XCTAssertEqual(outline.selectedRow, 1)
  }

  func testEmptyGroupsFoldWithTheKeyboard() {
    let (rail, workspace, _) = rail(sessionCount: 0)
    let group = workspace.createGroup()
    rail.reload()
    let outline = rail.outlineViewForTesting
    outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    press(outline, .left)
    XCTAssertEqual(workspace.collapsedGroups, [group])
    press(outline, .right)
    XCTAssertTrue(workspace.collapsedGroups.isEmpty)
  }

  func testNewGroupInlineNamingCommitsAndCancels() {
    let (rail, workspace, _) = rail(sessionCount: 0)
    let outline = rail.outlineViewForTesting
    func create() -> NSTextField {
      let menu = NSMenu()
      rail.menuNeedsUpdate(menu)
      let item = menu.items.first { $0.title == "New Group" }!
      _ = rail.perform(item.action!, with: item)
      let row = outline.numberOfRows - 1
      let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true)!
      return cell.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable }!
    }
    let cancelled = create()
    cancelled.stringValue = "Discard this"
    XCTAssertTrue(
      rail.control(
        cancelled, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    XCTAssertEqual(workspace.groups[0].name, "Untitled Group")
    let committed = create()
    committed.stringValue = "  Customer  "
    XCTAssertTrue(
      rail.control(
        committed, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
    XCTAssertEqual(workspace.groups[1].name, "Customer")
  }

  func testAShiftRangeKeepsGrowingAcrossReloads() {
    let (rail, workspace, _) = rail(sessionCount: 6)
    let outline = rail.outlineViewForTesting
    // What the window does with a selection: point at it, and reload.
    rail.onSelectSession = { [weak rail] session in
      workspace.selectedSessionID = session.id
      rail?.reload()
    }
    // Rows: 0 = the heading, 1...6 = the sessions.
    outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
    press(outline, .down, shift: true)
    press(outline, .down, shift: true)
    XCTAssertEqual(outline.selectedRowIndexes, IndexSet(2...4))
    // A reload from elsewhere — a title arriving, a diffstat tick — in the middle of it.
    rail.reload()
    press(outline, .down, shift: true)
    XCTAssertEqual(outline.selectedRowIndexes, IndexSet(2...5), "the range still extends downward")

    outline.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
    press(outline, .up, shift: true)
    rail.reload()
    press(outline, .up, shift: true)
    XCTAssertEqual(outline.selectedRowIndexes, IndexSet(3...5), "and upward")
  }

  /// The rows are redrawn in place when the tree's shape is unchanged, so what a row shows still
  /// follows the model — the redraw must not be skipped along with the rebuild.
  /// The linked worktrees sit under a `Worktrees` section of their own, which folds like the
  /// other headings and is remembered.
  func testLinkedWorktreesSitUnderAWorktreesSectionThatFolds() {
    let (rail, workspace, _) = rail(sessionCount: 1)
    let repo = workspace.repositories[0]
    let linked = Worktree(
      url: URL(fileURLWithPath: "/repo/feature"), branch: "feature", repository: repo)
    repo.worktrees.append(linked)
    rail.reload()
    let outline = rail.outlineViewForTesting
    // Rows: heading, main's session, Worktrees, the linked worktree.
    XCTAssertEqual(outline.numberOfRows, 4)
    let section = outline.item(atRow: 2) as? RailNode
    XCTAssertEqual(section?.section, .worktrees)
    XCTAssertEqual((outline.item(atRow: 3) as? RailNode)?.worktree?.id, linked.id)

    // A label, not a destination: → from main's session steps past nothing selectable, so the
    // fold is driven from the section row selected programmatically.
    workspace.collapsedWorktreeSections = [repo.id]
    rail.reload()
    XCTAssertEqual(outline.numberOfRows, 3, "folded, the linked worktree is gone from the rows")
    XCTAssertEqual(rail.outlineViewForTesting.isItemExpanded(outline.item(atRow: 2)!), false)
  }

  func testAnInPlaceReloadStillRedrawsWhatARowShows() {
    let (rail, _, sessions) = rail(sessionCount: 2)
    let outline = rail.outlineViewForTesting
    func labels(in view: NSView) -> [NSTextField] {
      view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? labels(in: $0) }
    }
    // The session's name is the one label set at the row's own size (see `viewFor`).
    func title(row: Int) -> String? {
      guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) else {
        return nil
      }
      return labels(in: cell).first { $0.font?.pointSize == 13 }?.stringValue
    }
    XCTAssertEqual(title(row: 1), "Session 0")
    sessions[0].title = "Renamed"
    rail.reload()
    XCTAssertEqual(title(row: 1), "Renamed")
    XCTAssertEqual((outline.item(atRow: 1) as? RailNode)?.title, "Renamed")
  }
}
