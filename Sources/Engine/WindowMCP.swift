import Foundation

/// The desktop app's window-layout server, `ccd_window`, hosted by hukan under the same name.
///
/// A mod written for the desktop app calls these through `$.mcp.call("ccd_window", …)`, and an
/// agent that learnt the desktop app calls `mcp__ccd_window__open_session_in`. Hosting the server
/// under its own name and with its own tools and arguments is what lets that one mod, and that
/// one habit, work in both hosts without a branch on which one it is in. The server rides the
/// session's stream exactly as `HukanMCP` does; only the name and the tool list differ.
///
/// Names, schemas, search hints and the result wording are the desktop app's, read off its
/// bundle (7.37095.0). The descriptions are too, less what hukan does not have: there is no split
/// view and no pop-out window here, so every target shows the session where a sidebar click
/// would, and the description says so rather than promising a pane.
enum WindowMCP {
  static let serverName = "ccd_window"

  static let openSessionInTool = "open_session_in"
  static let closeSplitTool = "close_split"
  static let setSidebarCollapsedTool = "set_sidebar_collapsed"
  static let getWindowLayoutTool = "get_window_layout"

  /// The longest `session_id` taken, the desktop app's figure.
  static let sessionIDLength = 256

  static let tools: [HukanMCP.Tool] = [
    HukanMCP.Tool(
      name: openSessionInTool,
      description: """
        Show another Code session next to this one. Layout only: nothing is sent to that \
        session, and it keeps running either way. The typical use is right after start_session \
        returns a session_id: open that session beside this one so the user can watch it work.

        session_id must be this session ("self") or a session this session started \
        (start_session); for any other session, ask the user to open it from the sidebar.

        target:
        - "split": add it as a split-view pane in the window where this session is showing.
        - "window": open it in its own pop-out window (shown without taking keyboard focus).
        - "focus": show it in this window's main pane, like clicking its sidebar row. Refused \
        while the user's cursor is in a text field or terminal.

        This app has no split view and no pop-out windows: every target shows the session in \
        the main pane, as "focus" does, and the result says which happened.

        Acts only while this session is on screen. If the user is looking at another session or \
        tab, it changes nothing and says so; don't retry, just say where to find the session. \
        Already-visible targets are reported as no-ops. OS window focus is never changed.
        """,
      inputSchema: [
        "type": "object",
        "properties": [
          "session_id": [
            "type": "string",
            "description":
              "The session to show: a session_id from start_session or list_sessions, or \"self\".",
          ],
          "target": [
            "type": "string", "enum": ["split", "window", "focus"],
            "description": "\"split\" | \"window\" | \"focus\". See the tool description.",
          ],
        ],
        "required": ["session_id", "target"],
      ],
      searchHint:
        "split screen, split view, side by side: show another session next to this one or in its "
        + "own window"),
    HukanMCP.Tool(
      name: closeSplitTool,
      description:
        "Close a split-view pane that you opened with open_session_in (target \"split\"), never a "
        + "pane or window the user arranged. The session in it keeps running; only the pane goes "
        + "away. session_id picks which of your panes to close; omit it to close the most recent "
        + "one still open. Acts only while this session is on screen. This app has no split "
        + "view, so there is never a pane to close.",
      inputSchema: [
        "type": "object",
        "properties": [
          "session_id": [
            "type": "string",
            "description":
              "The session whose pane to close (one you opened). Omit for the most recent.",
          ]
        ],
      ],
      searchHint: "close a split view (split screen) pane you opened"),
    HukanMCP.Tool(
      name: setSidebarCollapsedTool,
      description:
        "Collapse (true) or expand (false) the main window's sidebar, e.g. collapse it before "
        + "showing something wide, and expand it again afterwards if you were the one who "
        + "collapsed it. Acts only while this session is showing in the main window; "
        + "already-in-that-state is reported as a no-op.",
      inputSchema: [
        "type": "object",
        "properties": [
          "collapsed": ["type": "boolean", "description": "true = collapse, false = expand."]
        ],
        "required": ["collapsed"],
      ],
      searchHint: "hide or show the sidebar"),
    HukanMCP.Tool(
      name: getWindowLayoutTool,
      description:
        "Describe the app's window layout right now: the main window's tab, its split-view panes "
        + "(session ids, which one is focused), sessions open in pop-out windows, whether the "
        + "sidebar is collapsed, and where this session is showing, if anywhere. Read-only. Use "
        + "it before rearranging, or to check whether the user can currently see this session.",
      inputSchema: ["type": "object", "properties": [String: Any]()],
      annotations: ["readOnlyHint": true],
      searchHint: "what is on screen: split view panes, pop-out windows, sidebar"),
  ]

  static var toolList: [[String: Any]] { HukanMCP.listing(tools) }

  /// `session_id` as the desktop app reads it: trimmed, present, not absurdly long. `self`, or the
  /// caller's own id, is the caller.
  enum Target: Equatable {
    case caller
    case session(String)
  }

  static func target(_ call: HukanMCP.Call, caller: String) -> Target? {
    let raw = (call.arguments["session_id"] as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty, raw.count <= sessionIDLength else { return nil }
    if raw == "self" || raw.caseInsensitiveCompare(caller) == .orderedSame { return .caller }
    return .session(raw)
  }

  static let badSessionID =
    "session_id is required: a session_id from start_session or list_sessions, or \"self\"."

  /// How a result names a session — `this session`, or `session <id>`.
  static func subject(_ id: String, caller: String) -> String {
    id.caseInsensitiveCompare(caller) == .orderedSame ? "this session" : "session \(id)"
  }

  /// The reasons the window gives for leaving the layout alone, in the desktop app's words.
  static let callerNotVisible =
    "this session isn't on screen right now (the user is looking at something else), so the "
    + "layout was left alone. Don't retry; if it matters, tell the user where to find the "
    + "session in the sidebar."
  static let windowHidden =
    "the window showing this session is minimized or hidden, so the user wouldn't see the "
    + "change; the layout was left alone. Don't retry until the user is back."
  static let userTyping =
    "the user's cursor is in a text field or terminal, and moving focus could redirect their "
    + "keystrokes; nothing was changed. Don't retry immediately. Mention where the session is "
    + "instead."
  static let noSplitToClose = "there is no open split pane that this session opened."
  static let sidebarLocked = "the sidebar can't be changed on the page the window is showing."
}
