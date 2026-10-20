import AppKit
import XCTest

@testable import Hukan

/// A Markdown file's preview is a second tab on the same buffer: beside the source rather than in
/// place of it, back as a preview after a relaunch, and not the editor exiting when it closes.
final class MarkdownPreviewTabTests: XCTestCase {
  private func worktreeRoot() -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try? "# Title\n\nA paragraph\nwrapped.\n".write(
      to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    return root
  }

  private func desk(_ workspace: Workspace) -> WorktreeDeskViewController {
    let desk = WorktreeDeskViewController()
    desk.workspace = workspace
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = desk.view
    return desk
  }

  func testThePreviewStandsBesideTheSource() {
    let workspace = Workspace()
    let worktree = workspace.addWorktree(worktreeRoot())
    let desk = desk(workspace)
    desk.reload(deskID: deskSession(in: worktree, of: workspace).id)
    desk.openFile(worktree: worktree, path: "README.md", preview: false)
    desk.openFile(worktree: worktree, path: "README.md", preview: false, rendered: true)
    // Asked for twice, it is still one preview: the pair is the tab's identity.
    desk.openFile(worktree: worktree, path: "README.md", preview: false, rendered: true)

    XCTAssertEqual(
      desk.tabStripReport, "1   file      README.md\n2 ● preview   README.md")
    XCTAssertEqual(desk.openFilePaths, ["README.md"], "only the source is a file being edited")
  }

  func testAPreviewComesBackAsAPreview() throws {
    let workspace = Workspace()
    let worktree = workspace.addWorktree(worktreeRoot())
    let desk = desk(workspace)
    desk.reload(deskID: deskSession(in: worktree, of: workspace).id)
    desk.openFile(worktree: worktree, path: "README.md", preview: false, rendered: true)

    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    workspace.encodeState(
      to: archiver, fileTabs: desk.restorableFileTabs, tabOrder: desk.restorableTabOrder)
    archiver.finishEncoding()
    let restored = Workspace()
    restored.decodeState(from: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData))

    XCTAssertEqual(
      restored.takeRestoredFileTabs().map { [$0.path, $0.rendered ? "preview" : "source"] },
      [["README.md", "preview"]])
  }

  func testClosingThePreviewIsNotTheEditorExiting() {
    let workspace = Workspace()
    let worktree = workspace.addWorktree(worktreeRoot())
    let desk = desk(workspace)
    var closed: [String] = []
    desk.onFileTabClosed = { _, path in closed.append(path) }
    desk.reload(deskID: deskSession(in: worktree, of: workspace).id)
    desk.openFile(worktree: worktree, path: "README.md", preview: false)
    desk.openFile(worktree: worktree, path: "README.md", preview: false, rendered: true)

    XCTAssertTrue(desk.closeActiveTab())
    XCTAssertEqual(closed, [], "an `edit … waiting` is waiting on the source")
    XCTAssertTrue(desk.closeActiveTab())
    XCTAssertEqual(closed, ["README.md"])
  }
}
