import AppKit
import XCTest

@testable import Hukan

/// The desk coming back after a relaunch: the tabs that were open, in the order they stood, on the
/// one that was showing. Driven through the same two halves AppKit drives — the desk's
/// `restorable…` lists into `Workspace.encodeState`, and `decodeState` back into `restore…` — so
/// what is pinned here is the whole round trip and not either side's idea of it.
final class TabRestoreTests: XCTestCase {
  private func worktreeRoot(_ files: [String]) -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in files {
      try? "let a = 1\n".write(
        to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    return root
  }

  /// A desk in a window, since the strip measures itself and the panes want a superview.
  private func desk(_ workspace: Workspace) -> WorktreeDeskViewController {
    let desk = WorktreeDeskViewController()
    desk.workspace = workspace
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = desk.view
    return desk
  }

  private func relaunch(_ workspace: Workspace, _ desk: WorktreeDeskViewController) throws -> (
    Workspace, WorktreeDeskViewController
  ) {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    workspace.encodeState(
      to: archiver, fileTabs: desk.restorableFileTabs, commitTabs: desk.restorableCommitTabs,
      tabOrder: desk.restorableTabOrder, selectedTabIndex: desk.restorableSelectedTabIndex)
    archiver.finishEncoding()

    let restored = Workspace()
    let deck = self.desk(restored)
    restored.decodeState(from: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData))
    // The terminals come back first and reload the desk on their own, before the rest of the strip
    // is on it. Modelled here because it is the shape that broke the saved selection once: spent
    // against half a strip, it landed the window on the end of that half.
    deck.reload(worktreeID: restored.worktrees.first?.id)
    deck.restoreFileTabs(restored.takeRestoredFileTabs())
    deck.restoreCommitTabs(restored.takeRestoredCommitTabs())
    deck.restoreTabOrder(restored.takeRestoredTabOrder())
    if let selection = restored.takeRestoredTabSelection() {
      deck.restoreSelectedTab(worktreeID: selection.worktreeID, index: selection.index)
    }
    return (restored, deck)
  }

  /// The strip comes back as it stood — including what dragging made of it, which is why the
  /// order rides separately from the tabs.
  func testFileTabsComeBackInStripOrder() throws {
    let root = worktreeRoot(["a.swift", "b.swift", "c.swift"])
    let workspace = Workspace()
    let worktree = workspace.addWorktree(root)
    let desk = desk(workspace)
    desk.reload(worktreeID: worktree.id)
    for name in ["a.swift", "b.swift", "c.swift"] {
      desk.openFile(worktree: worktree, path: name, preview: false)
    }
    desk.moveTab(at: 2, to: 0)
    XCTAssertEqual(desk.openFilePaths, ["a.swift", "b.swift", "c.swift"], "the tabs themselves")

    let (restored, deck) = try relaunch(workspace, desk)
    let back = try XCTUnwrap(restored.worktrees.first)
    deck.reload(worktreeID: back.id)

    XCTAssertEqual(
      deck.restorableFileTabs.map(\.path), ["c.swift", "a.swift", "b.swift"],
      "the strip's order, not the order they were opened in")
  }

  /// A restored tab is a path, not a read: the file behind it is opened when the tab is, so a desk
  /// of a dozen tabs costs the one on screen.
  func testRestoredTabsAreNotReadUntilTheyAreShown() throws {
    let root = worktreeRoot(["a.swift", "b.swift"])
    let workspace = Workspace()
    let worktree = workspace.addWorktree(root)
    let desk = desk(workspace)
    desk.reload(worktreeID: worktree.id)
    desk.openFile(worktree: worktree, path: "a.swift", preview: false)
    desk.openFile(worktree: worktree, path: "b.swift", preview: false)

    let (restored, deck) = try relaunch(workspace, desk)
    XCTAssertEqual(deck.unreadRestoredTabCount, 2, "nothing is read by restoring it")

    let back = try XCTUnwrap(restored.worktrees.first)
    deck.reload(worktreeID: back.id)
    XCTAssertEqual(
      deck.unreadRestoredTabCount, 1, "the showing tab, and only it, has been read")
  }

  /// Where the desk was left is part of "as it was": without it a restored window lands on the end
  /// of the strip, which is rarely where anyone was reading.
  func testTheShowingTabIsTheOneThatComesBackShowing() throws {
    let root = worktreeRoot(["a.swift", "b.swift", "c.swift"])
    let workspace = Workspace()
    let worktree = workspace.addWorktree(root)
    workspace.selectedWorktreeID = worktree.id
    let desk = desk(workspace)
    desk.reload(worktreeID: worktree.id)
    for name in ["a.swift", "b.swift", "c.swift"] {
      desk.openFile(worktree: worktree, path: name, preview: false)
    }
    desk.selectTab(at: 0)

    let (restored, deck) = try relaunch(workspace, desk)
    let back = try XCTUnwrap(restored.worktrees.first)
    deck.reload(worktreeID: back.id)

    XCTAssertEqual(deck.activeFileContent?.currentPath, "a.swift")
    XCTAssertEqual(deck.unreadRestoredTabCount, 2, "the other two are still unread")
  }

  /// A file that is gone by the next launch takes its tab with it rather than restoring a tab with
  /// nothing to show — and the strip closes up over the gap, since the order names tabs by
  /// position among their kind.
  func testATabWhoseFileIsGoneDoesNotComeBack() throws {
    let root = worktreeRoot(["a.swift", "b.swift"])
    let workspace = Workspace()
    let worktree = workspace.addWorktree(root)
    let desk = desk(workspace)
    desk.reload(worktreeID: worktree.id)
    desk.openFile(worktree: worktree, path: "a.swift", preview: false)
    desk.openFile(worktree: worktree, path: "b.swift", preview: false)
    try FileManager.default.removeItem(at: root.appendingPathComponent("a.swift"))

    let (restored, deck) = try relaunch(workspace, desk)
    let back = try XCTUnwrap(restored.worktrees.first)
    deck.reload(worktreeID: back.id)

    XCTAssertEqual(deck.openFilePaths, ["b.swift"])
  }
}
