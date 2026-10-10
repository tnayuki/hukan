import AppKit
import XCTest

@testable import Hukan

/// A group's name is typed on its heading, and in a real window something else wanted the focus
/// the moment the field appeared — the rail's own tests passed while the app kept every group at
/// its untitled name. So this one is driven through a `WorkspaceWindowController`.
final class GroupRenameTests: XCTestCase {
  private func rail(in controller: NSViewController?) -> SessionRailViewController? {
    guard let controller else { return nil }
    if let rail = controller as? SessionRailViewController { return rail }
    for child in controller.children {
      if let rail = rail(in: child) { return rail }
    }
    return nil
  }

  func testRenameFromTheMenuKeepsTheFieldFocused() throws {
    let workspace = RailPreviewTests.sampleWorkspace()
    let controller = WorkspaceWindowController(workspace: workspace)
    let window = try XCTUnwrap(controller.window)
    defer { window.close() }
    let session = try XCTUnwrap(workspace.sessions.first)
    workspace.selectedWorktreeID = session.worktreeID
    workspace.selectedSessionID = session.id
    let group = workspace.createGroup(name: "Customer")
    controller.reload()
    controller.focusComposer()
    let rail = try XCTUnwrap(rail(in: window.contentViewController))

    let item = NSMenuItem()
    item.representedObject = group
    _ = rail.perform(NSSelectorFromString("renameClickedGroup:"), with: item)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    let field = try XCTUnwrap(editor.delegate as? NSTextField)
    XCTAssertEqual(field.identifier?.rawValue, group)
    XCTAssertEqual(editor.string, "Customer")
    XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 8))

    editor.string = "Customer B"
    editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    XCTAssertEqual(workspace.groups.first?.name, "Customer B")
  }
}
