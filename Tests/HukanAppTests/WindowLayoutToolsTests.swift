import AppKit
import XCTest

@testable import Hukan

/// The desktop app's `ccd_window` server, hosted under its name so a mod or an agent written
/// against that app reaches it here unchanged — and answered by the same rules: only the caller
/// and the sessions it started, only while the caller is on screen.
final class WindowLayoutToolsTests: XCTestCase {
  private var controller: WorkspaceWindowController?

  override func tearDown() {
    controller?.window?.close()
    controller = nil
  }

  /// The desktop app's four tool names, with its search hints (registered beside hukan's own
  /// server: `BrowserToolsTests`).
  func testTheServerIsOfferedUnderTheDesktopAppsName() {
    let names = WindowMCP.toolList.compactMap { $0["name"] as? String }
    XCTAssertEqual(
      names, ["open_session_in", "close_split", "set_sidebar_collapsed", "get_window_layout"])
    for tool in WindowMCP.toolList {
      let meta = tool["_meta"] as? [String: Any]
      XCTAssertNotNil(meta?["anthropic/searchHint"] as? String, "\(tool["name"] ?? "?")")
    }
  }

  /// The two servers share a session's handler, so each answers only the tools it lists: hukan's
  /// own `set_tags` sent to `ccd_window` is unknown there, and never reaches the handler.
  func testAServerRunsOnlyTheToolsItLists() {
    var reached = false
    var answer: [String: Any] = [:]
    HukanMCP.handle(
      [
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": ["name": HukanMCP.setTagsTool, "arguments": ["tags": ["x: y"]]],
      ],
      server: WindowMCP.serverName, tools: WindowMCP.toolList,
      handler: { _, done in
        reached = true
        done(.text("ran"))
      },
      reply: { answer = $0 })
    XCTAssertFalse(reached)
    let result = answer["result"] as? [String: Any]
    XCTAssertEqual(result?["isError"] as? Bool, true)
    let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String
    XCTAssertEqual(text, "Unknown tool: set_tags")
  }

  @MainActor
  func testOpenSessionInShowsOnlyWhatTheCallerStartedWhileItIsOnScreen() throws {
    let workspace = RailPreviewTests.sampleWorkspace()
    let caller = workspace.sessions[0]
    let stranger = workspace.sessions[1]
    let child = AgentSession(worktreeID: caller.worktreeID)
    child.title = "Child"
    child.origin = SessionOrigin(parentID: caller.id, detached: false)
    workspace.sessions.append(child)
    workspace.selectedWorktreeID = caller.worktreeID
    workspace.selectedSessionID = caller.id
    let controller = WorkspaceWindowController(workspace: workspace)
    self.controller = controller
    let window = try XCTUnwrap(controller.window)
    controller.reload()
    window.orderFront(nil)
    window.makeFirstResponder(nil)

    func call(_ name: String, _ arguments: [String: Any] = [:]) -> (ok: Bool, text: String) {
      let outcome = controller.performWindowTool(
        HukanMCP.Call(name: name, arguments: arguments, server: WindowMCP.serverName),
        from: caller)
      switch outcome {
      case .text(let text): return (true, text)
      case .error(let text): return (false, text)
      case .image: return (false, "image")
      }
    }
    func open(_ id: String, _ target: String) -> (ok: Bool, text: String) {
      call("open_session_in", ["session_id": id, "target": target])
    }

    XCTAssertFalse(open("self", "split").ok, "a session is not split beside itself")
    XCTAssertTrue(open("self", "window").text.hasPrefix("No change: this session is already"))
    XCTAssertFalse(open(stranger.id.uuidString, "focus").ok)
    XCTAssertTrue(open(stranger.id.uuidString, "focus").text.hasPrefix("Refused: session"))
    XCTAssertFalse(open(UUID().uuidString, "focus").ok)
    XCTAssertFalse(open(child.id.uuidString, "sideways").ok)

    let layout = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(call("get_window_layout").text.utf8))
        as? [String: Any])
    let main = try XCTUnwrap(layout["main_window"] as? [String: Any])
    let pane = try XCTUnwrap((main["panes"] as? [[String: Any]])?.first)
    XCTAssertEqual(pane["session_id"] as? String, caller.id.uuidString)
    XCTAssertEqual(pane["is_this_session"] as? Bool, true)
    XCTAssertEqual(
      (layout["this_session"] as? [String: Any])?["on_screen"] as? Bool, true)

    // The keyboard in an editable text view: the pane is not changed under it.
    let typing = NSTextView(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
    window.contentView?.addSubview(typing)
    window.makeFirstResponder(typing)
    XCTAssertFalse(open(child.id.uuidString, "split").ok)
    XCTAssertEqual(workspace.selectedSessionID, caller.id)
    typing.removeFromSuperview()
    window.makeFirstResponder(nil)

    let shown = open(child.id.uuidString, "split")
    XCTAssertTrue(shown.ok, shown.text)
    XCTAssertTrue(shown.text.contains("no split view"), shown.text)
    XCTAssertEqual(workspace.selectedSessionID, child.id)

    // The caller has left the screen, so it arranges nothing more.
    XCTAssertFalse(open("self", "focus").ok)
    XCTAssertEqual(
      (try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(call("get_window_layout").text.utf8))
          as? [String: Any])["this_session"] as? [String: Any])?["on_screen"] as? Bool, false)

    XCTAssertTrue(call("close_split").text.hasPrefix("No change:"))
    XCTAssertFalse(call("set_sidebar_collapsed").ok, "collapsed is required")

    // A maximized column is the person's mode: the rail is not the agent's to change under it.
    workspace.selectedSessionID = caller.id
    controller.reload()
    controller.focusComposer()
    controller.toggleMaximize(nil)
    window.makeFirstResponder(nil)
    XCTAssertEqual(controller.maximizedColumn, .session)
    XCTAssertFalse(call("set_sidebar_collapsed", ["collapsed": false]).ok)
    XCTAssertEqual(controller.maximizedColumn, .session, "the mode was ended")
  }
}
