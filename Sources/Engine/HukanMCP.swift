import Foundation

/// The tools hukan hosts for the engine, served over the session's own stream.
///
/// Claude Code lets the process driving it host an MCP server *in that process*: a name in the
/// `initialize` request's `sdkMcpServers`, and from then on every JSON-RPC message for it arrives
/// as a `control_request` of subtype `mcp_message`, answered with the server's reply under
/// `mcp_response`. That is the mechanism the Agent SDK's in-process servers ride, and nothing in
/// it is JavaScript: what crosses the wire is the name and the messages, so a host that speaks
/// the control protocol — which hukan does for approvals, the model switch and Remote Control —
/// can host one too. No second process, no config file, no socket. And the call arrives on the
/// stream of the session making it, so *which* session is asking is answered by construction
/// rather than by anything a caller could spoof.
///
/// All of it is read off the shipped binary (2.1.258): `initialize.sdkMcpServers`,
/// `sdkMcpServerConfigs`, and the `mcp_message` shape in both directions. Undocumented and absent
/// from `--help`, the same footing as `--permission-prompt-tool stdio` — re-verify on upgrades.
///
/// This type is the wire half only: it parses a JSON-RPC message, answers the handshake and the
/// tool list itself, and hands a `tools/call` to whoever answers it — the session for its own
/// tags, the desk for the tabs. It knows nothing of a window or a web view, which is what keeps it
/// in `Sources/Engine`.
enum HukanMCP {
  /// The server's name on the wire, and so the prefix of every tool the model sees
  /// (`mcp__hukan__browser_read`).
  static let serverName = "hukan"

  /// The per-call wall clock the engine holds a tool open for. A call here may be waiting on a
  /// person — the grant card — and a person answers on no clock, so this is the same day the
  /// `edit … waiting` Apple event gives a commit message.
  static let toolTimeoutMilliseconds = 86_400_000

  /// One tool as it is advertised: the name the model calls, the description that is the whole of
  /// what it is told about the tool, and the arguments' JSON schema.
  struct Tool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    /// MCP's behaviour hints (`readOnlyHint` and the rest), which a client may use to decide which
    /// calls to ask its user about. Nil sends none.
    var annotations: [String: Any]? = nil
  }

  /// A `tools/call` as the host receives it.
  struct Call {
    let name: String
    let arguments: [String: Any]

    func string(_ key: String) -> String? {
      guard let value = arguments[key] as? String, !value.isEmpty else { return nil }
      return value
    }

    /// An array of strings, or nil when the argument is missing or anything in it is not a
    /// string — a list half of which was dropped would be a different list from the one sent.
    func strings(_ key: String) -> [String]? {
      guard let values = arguments[key] as? [Any] else { return nil }
      let strings = values.compactMap { $0 as? String }
      return strings.count == values.count ? strings : nil
    }
  }

  /// The tool that names the session itself. Answered by the session, not the desk: it touches no
  /// tab, so it needs no window to be asked in.
  static let setTagsTool = "set_tags"

  /// What a call comes back with. Text is the usual answer; an image is a screenshot; an error is
  /// reported to the model as a failed tool result rather than as a protocol error, since it is
  /// something the model can read and act on ("the user declined").
  enum Outcome {
    case text(String)
    case image(Data, mimeType: String)
    case error(String)
  }

  /// The host of the tabs: given a call, runs it and answers exactly once, on the main thread.
  typealias Handler = (Call, @escaping (Outcome) -> Void) -> Void

  static let tools: [Tool] =
    [
      Tool(
        name: setTagsTool,
        description:
          "Replace this session's tags with the given list. Tags label the session on the user's "
          + "list of sessions, so it can be found at a glance by what it is working on: write each "
          + "as `kind: value` — `JIRA: ABC-123`, `Issue: #42`, `PR: #58886`. Only the value is shown; "
          + "the kind picks the colour, so spell the same kind the same way every time. When you "
          + "know the address of what a tag names, end the tag with it in angle brackets — "
          + "`PR: #58886 <https://github.com/owner/repo/pull/58886>` — and clicking the tag opens "
          + "that page. The list "
          + "is the whole set, not a change to it: pass the tags to keep as well as the new one, "
          + "and an empty list to clear them. Answers with the tags as they now stand.",
        inputSchema: [
          "type": "object",
          "properties": [
            "tags": [
              "type": "array", "items": ["type": "string"],
              "description": "Every tag the session should carry, each `kind: value`",
            ]
          ],
          "required": ["tags"],
          "additionalProperties": false,
        ]),
      Tool(
        name: "browser_tabs",
        description:
          "List the web tabs open on this worktree's desk in hukan: each tab's id, title, address, "
          + "and whether the user has shared it with you — \"read\", \"drive\", or \"not shared\". "
          + "Reading or driving a tab that is not shared asks the user first; a tab is shared until "
          + "the user withdraws it, and \"drive\" falls back to \"read\" when the tab moves to "
          + "another site. These tabs carry the user's own logins, so a page behind a sign-in that "
          + "WebFetch cannot reach is readable here.",
        inputSchema: [
          "type": "object", "properties": [String: Any](), "additionalProperties": false,
        ]
      ),
      Tool(
        name: "browser_open",
        description:
          "Open an http(s) address in a new web tab on this worktree's desk and share the new tab "
          + "with you — the user is asked first and answers with "
          + "\"read\" or \"drive\". Reports the new tab's id, title and address once the page has "
          + "loaded. Use this when there is no tab to read yet; a tab already open at the same "
          + "address is shared instead of opened twice.",
        inputSchema: [
          "type": "object",
          "properties": ["url": ["type": "string", "description": "The http(s) address to open"]],
          "required": ["url"],
          "additionalProperties": false,
        ]),
      Tool(
        name: "browser_read",
        description:
          "Read a shared web tab's page as text (the rendered text, not the HTML). Optionally narrow "
          + "to a CSS selector. Needs the tab shared for reading; if it is not, the user is asked.",
        inputSchema: [
          "type": "object",
          "properties": [
            "tab": ["type": "string", "description": "The tab id from browser_tabs"],
            "selector": [
              "type": "string",
              "description": "A CSS selector to read instead of the whole page",
            ],
          ],
          "required": ["tab"],
          "additionalProperties": false,
        ]),
      Tool(
        name: "browser_navigate",
        description:
          "Load an address in a shared web tab and wait for the page, then report its title and "
          + "address. Needs the tab shared for reading; if it is not, the user is asked. Moving to "
          + "another site withdraws a \"drive\" share back to \"read\".",
        inputSchema: [
          "type": "object",
          "properties": [
            "tab": ["type": "string", "description": "The tab id from browser_tabs"],
            "url": ["type": "string", "description": "The http(s) address to load"],
          ],
          "required": ["tab", "url"],
          "additionalProperties": false,
        ]),
      Tool(
        name: "browser_screenshot",
        description:
          "Take a screenshot of a shared web tab as it is showing. Needs the tab shared for reading; "
          + "if it is not, the user is asked. The tab has to be the one on screen in its worktree.",
        inputSchema: [
          "type": "object",
          "properties": ["tab": ["type": "string", "description": "The tab id from browser_tabs"]],
          "required": ["tab"],
          "additionalProperties": false,
        ]),
      Tool(
        name: "browser_run",
        description:
          "Run JavaScript in a shared web tab's page and return what it evaluates to — this is how "
          + "to click, type, submit, or inspect the DOM. A bare expression is returned as-is "
          + "(`document.title`); code using `await` runs as an async function body and must "
          + "`return` its value. Needs the tab shared for driving; if it is only shared for "
          + "reading, or not at all, the user is asked.",
        inputSchema: [
          "type": "object",
          "properties": [
            "tab": ["type": "string", "description": "The tab id from browser_tabs"],
            "javascript": ["type": "string", "description": "The code to run in the page"],
          ],
          "required": ["tab", "javascript"],
          "additionalProperties": false,
        ]),
    ] + machineTools

  /// The virtual machines on the desk — macOS guests hukan runs, reached through the guest agent
  /// over vsock. One grant per machine, asked the first time a call touches it: running a command
  /// is never only reading, so there is no read-only level to offer.
  static let machineTools: [Tool] = [
    Tool(
      name: "vm_create",
      description:
        "Make a new virtual machine on this session's desk in hukan and start it: a throwaway "
        + "copy of a template, with the session's worktree mounted — as /Volumes/My Shared "
        + "Files/worktree on macOS, as W:\\ on Windows — and the next one there when you "
        + "change worktree. Each call makes another machine; to carry on with one you already "
        + "have, vm_list it and vm_start it. The user is asked first; once they allow it the "
        + "machine is yours to use, and the call returns when its guest agent answers — a first "
        + "boot takes a minute or two. Without template, the only template there is is used; "
        + "with several, the call lists them. A Mac runs two macOS machines at once, across "
        + "every app; vm_suspend one to free its place.",
      inputSchema: [
        "type": "object",
        "properties": [
          "template": [
            "type": "string", "description": "A template's id or name, when there are several",
          ]
        ],
        "additionalProperties": false,
      ]),
    Tool(
      name: "vm_start",
      description:
        "Start a machine on this session's desk that is not running — one that was suspended "
        + "carries on where it was. The call returns when its guest agent answers. If the user "
        + "has not let you use this machine yet, they are asked first.",
      inputSchema: [
        "type": "object",
        "properties": [
          "machine": ["type": "string", "description": "The machine id from vm_list"]
        ],
        "required": ["machine"],
        "additionalProperties": false,
      ]),
    Tool(
      name: "vm_suspend",
      description:
        "Suspend a virtual machine: it is saved where it is and stopped, its tab and its disk "
        + "stay, and vm_start carries on from there. A suspended macOS machine no longer counts "
        + "against the two a Mac runs at once. The user is asked first.",
      inputSchema: [
        "type": "object",
        "properties": [
          "machine": ["type": "string", "description": "The machine id from vm_list"]
        ],
        "required": ["machine"],
        "additionalProperties": false,
      ]),
    Tool(
      name: "vm_delete",
      description:
        "Delete a virtual machine, with everything done inside it, and close its tab. The user "
        + "is asked first. The template is not touched.",
      inputSchema: [
        "type": "object",
        "properties": [
          "machine": ["type": "string", "description": "The machine id from vm_list"]
        ],
        "required": ["machine"],
        "additionalProperties": false,
      ]),
    Tool(
      name: "vm_list",
      description:
        "List the virtual machines open on this session's desk in hukan: each one's id, the "
        + "template it was copied from, whether it is running, and whether the user has let you "
        + "use it. Each is the session's own throwaway machine, with the session's worktree "
        + "mounted as /Volumes/My Shared Files/worktree on macOS and as W:\\ on Windows.",
      inputSchema: ["type": "object", "properties": [String: Any](), "additionalProperties": false]
    ),
    Tool(
      name: "guest_exec",
      description:
        "Run a shell command in a virtual machine and get its exit status, stdout and stderr. "
        + "On a macOS guest it is /bin/zsh -c, on a Windows guest PowerShell. "
        + "It runs as the guest's logged-in user, in their desktop session, so `open -a` and GUI "
        + "apps work; set admin to run it as root instead (there is no sudo password to give). "
        + "The user is asked the first time you touch a machine.",
      inputSchema: [
        "type": "object",
        "properties": [
          "machine": ["type": "string", "description": "The machine id from vm_list"],
          "command": ["type": "string", "description": "A command for /bin/zsh -c"],
          "admin": ["type": "boolean", "description": "Run as root"],
          "cwd": ["type": "string", "description": "Working directory in the guest"],
          "timeout": ["type": "number", "description": "Seconds before it is stopped (600)"],
        ],
        "required": ["machine", "command"],
        "additionalProperties": false,
      ]),
    Tool(
      name: "guest_read_file",
      description: "Read a text file from a virtual machine.",
      inputSchema: [
        "type": "object",
        "properties": [
          "machine": ["type": "string", "description": "The machine id from vm_list"],
          "path": ["type": "string", "description": "Absolute path in the guest"],
          "admin": ["type": "boolean", "description": "Read as root"],
        ],
        "required": ["machine", "path"],
        "additionalProperties": false,
      ]),
    Tool(
      name: "guest_write_file",
      description: "Write a text file in a virtual machine, making its directory if needed.",
      inputSchema: [
        "type": "object",
        "properties": [
          "machine": ["type": "string", "description": "The machine id from vm_list"],
          "path": ["type": "string", "description": "Absolute path in the guest"],
          "content": ["type": "string", "description": "The file's whole new content"],
          "admin": ["type": "boolean", "description": "Write as root"],
        ],
        "required": ["machine", "path", "content"],
        "additionalProperties": false,
      ]),
    Tool(
      name: "vm_set_resolution",
      description:
        "Hold a virtual machine's screen at a fixed size in pixels, so coordinates stay the same "
        + "whatever size its tab is — the tab scales it to fit. Give no width and height to let "
        + "the guest follow its tab again. Kept with the machine. Answers the resolution now.",
      inputSchema: [
        "type": "object",
        "properties": [
          "machine": ["type": "string", "description": "The machine id from vm_list"],
          "width": ["type": "integer", "description": "Width in pixels, e.g. 1920"],
          "height": ["type": "integer", "description": "Height in pixels, e.g. 1200"],
        ],
        "required": ["machine"],
        "additionalProperties": false,
      ]),
    Tool(
      name: "guest_screenshot",
      description:
        "Take a screenshot of a virtual machine's screen, or of one window, as a PNG at the pixels "
        + "the guest is drawing — with a resolution set by vm_set_resolution, exactly those. A "
        + "window comes out whole even when something covers it or it runs off the screen.",
      inputSchema: [
        "type": "object",
        "properties": [
          "machine": ["type": "string", "description": "The machine id from vm_list"],
          "window": ["type": "integer", "description": "A window id from guest_list_windows"],
        ],
        "required": ["machine"],
        "additionalProperties": false,
      ]),
    Tool(
      name: "guest_list_windows",
      description:
        "List the windows on a virtual machine's screen, front to back: id, application, title "
        + "and frame in the pixels of a screenshot of the screen.",
      inputSchema: [
        "type": "object",
        "properties": [
          "machine": ["type": "string", "description": "The machine id from vm_list"]
        ],
        "required": ["machine"],
        "additionalProperties": false,
      ]),
    Tool(
      name: "guest_ui_tree",
      description:
        "Read the interface of an application in a virtual machine through Accessibility, one "
        + "element a line, indented: its id, role, title, value, frame and the actions it takes. "
        + "Frames are in the pixels of a screenshot — of that window's own, given a window. Prefer "
        + "this and guest_ui_press to clicking at coordinates. Ids are positions in the tree, so read "
        + "it again after anything changes.",
      inputSchema: [
        "type": "object",
        "properties": [
          "machine": ["type": "string", "description": "The machine id from vm_list"],
          "app": [
            "type": "string",
            "description": "An application's name or bundle id; the frontmost one if left out",
          ],
          "menus": ["type": "boolean", "description": "Include the menu bar"],
          "window": [
            "type": "integer", "description": "Just this window, from guest_list_windows",
          ],
        ],
        "required": ["machine"],
        "additionalProperties": false,
      ]),
    Tool(
      name: "guest_ui_press",
      description:
        "Perform an action on an element from guest_ui_tree — Press by default, or another the "
        + "tree lists for it, such as ShowMenu.",
      inputSchema: [
        "type": "object",
        "properties": [
          "machine": ["type": "string", "description": "The machine id from vm_list"],
          "id": ["type": "string", "description": "The element's id from guest_ui_tree"],
          "action": ["type": "string", "description": "The action's name (Press)"],
        ],
        "required": ["machine", "id"],
        "additionalProperties": false,
      ]),
    Tool(
      name: "guest_ui_set_value",
      description: "Set the value of an element from guest_ui_tree, such as a text field's text.",
      inputSchema: [
        "type": "object",
        "properties": [
          "machine": ["type": "string", "description": "The machine id from vm_list"],
          "id": ["type": "string", "description": "The element's id from guest_ui_tree"],
          "value": ["type": "string", "description": "The new value"],
        ],
        "required": ["machine", "id", "value"],
        "additionalProperties": false,
      ]),
    Tool(
      name: "guest_click",
      description:
        "Click in a virtual machine, at a position in the pixels of a screenshot — of that "
        + "window's own, given a window, wherever it has moved to since. Given a window, it is "
        + "refused if something else is on top at that point. For what guest_ui_tree cannot reach.",
      inputSchema: [
        "type": "object",
        "properties": [
          "machine": ["type": "string", "description": "The machine id from vm_list"],
          "x": ["type": "number", "description": "Pixels from the left of a screenshot"],
          "y": ["type": "number", "description": "Pixels from the top of a screenshot"],
          "count": ["type": "integer", "description": "2 for a double-click"],
          "right": ["type": "boolean", "description": "Use the right button"],
          "window": ["type": "integer", "description": "A window id from guest_list_windows"],
        ],
        "required": ["machine", "x", "y"],
        "additionalProperties": false,
      ]),
    Tool(
      name: "guest_type",
      description:
        "Type text in a virtual machine, into whatever has the keyboard focus. On a macOS guest "
        + "the system's own corrections apply, as they would to anyone typing, so read it back "
        + "when the exact text matters — or use guest_ui_set_value.",
      inputSchema: [
        "type": "object",
        "properties": [
          "machine": ["type": "string", "description": "The machine id from vm_list"],
          "text": ["type": "string", "description": "The text"],
        ],
        "required": ["machine", "text"],
        "additionalProperties": false,
      ]),
    Tool(
      name: "guest_key",
      description: "Press a key in a virtual machine, with modifiers if any.",
      inputSchema: [
        "type": "object",
        "properties": [
          "machine": ["type": "string", "description": "The machine id from vm_list"],
          "key": [
            "type": "string",
            "description": "A letter or digit, or return, tab, space, delete, escape, an arrow "
              + "(left, right, up, down), f1…f12",
          ],
          "modifiers": [
            "type": "array", "items": ["type": "string"],
            "description": "Any of command, shift, option, control. On Windows, command is the "
              + "Windows key and option is Alt.",
          ],
        ],
        "required": ["machine", "key"],
        "additionalProperties": false,
      ]),
    Tool(
      name: "vm_save_template",
      description:
        "Save a virtual machine as a new template, for vm_create to copy later. The user is asked "
        + "first. The machine shuts down, is copied and starts again, and the call returns once "
        + "its guest agent answers; anything running in it is lost, so finish first.",
      inputSchema: [
        "type": "object",
        "properties": [
          "machine": ["type": "string", "description": "The machine id from vm_list"],
          "name": ["type": "string", "description": "What to call the template"],
        ],
        "required": ["machine", "name"],
        "additionalProperties": false,
      ]),
  ]

  /// What a `tools/list` answers with.
  static var toolList: [[String: Any]] { listing(tools) }

  /// Any set of tools as a `tools/list` carries them.
  static func listing(_ tools: [Tool]) -> [[String: Any]] {
    tools.map { tool in
      var entry: [String: Any] = [
        "name": tool.name, "description": tool.description, "inputSchema": tool.inputSchema,
      ]
      if let annotations = tool.annotations { entry["annotations"] = annotations }
      return entry
    }
  }

  /// One JSON-RPC message in, one reply out — through `reply`, which is called exactly once, on
  /// the main thread. The handshake (`initialize`, `ping`, the `initialized` notification) and
  /// `tools/list` are answered here; a `tools/call` goes to the handler.
  ///
  /// A notification carries no id and expects no reply, but the control request that delivered
  /// it does: the SDK answers one with an empty result under id 0, and so does this.
  ///
  /// `tools` and `instructions` are what the outside server (`ExternalMCP`) swaps in: the wire is
  /// the same JSON-RPC whichever end of hukan it is spoken from, and only what is offered differs.
  static func handle(
    _ message: [String: Any], tools: [[String: Any]] = toolList, instructions: String? = nil,
    handler: Handler, reply: @escaping ([String: Any]) -> Void
  ) {
    let id = message["id"]
    guard let method = message["method"] as? String else {
      reply(response(id: id, error: -32600, "not a request"))
      return
    }
    guard id != nil, !(id is NSNull) else {
      reply(["jsonrpc": "2.0", "id": 0, "result": [String: Any]()])
      return
    }
    let params = message["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
      var result: [String: Any] = [
        "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
        "capabilities": ["tools": [String: Any]()],
        "serverInfo": ["name": serverName, "version": "1"],
      ]
      if let instructions { result["instructions"] = instructions }
      reply(response(id: id, result: result))
    case "ping":
      reply(response(id: id, result: [:]))
    case "tools/list":
      reply(response(id: id, result: ["tools": tools]))
    case "tools/call":
      guard let name = params["name"] as? String else {
        reply(response(id: id, error: -32602, "tools/call names no tool"))
        return
      }
      let call = Call(name: name, arguments: params["arguments"] as? [String: Any] ?? [:])
      handler(call) { outcome in reply(response(id: id, result: content(for: outcome))) }
    default:
      reply(response(id: id, error: -32601, "method not found: \(method)"))
    }
  }

  /// A tool's outcome as the MCP result the model reads.
  static func content(for outcome: Outcome) -> [String: Any] {
    switch outcome {
    case .text(let text):
      return ["content": [["type": "text", "text": text]], "isError": false]
    case .image(let data, let mimeType):
      return [
        "content": [["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType]],
        "isError": false,
      ]
    case .error(let message):
      return ["content": [["type": "text", "text": message]], "isError": true]
    }
  }

  private static func response(id: Any?, result: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
  }

  private static func response(id: Any?, error code: Int, _ message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
  }
}
