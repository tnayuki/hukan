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
/// tool list itself, and hands a `tools/call` to whoever hosts the tabs. It knows nothing of a
/// window or a web view, which is what keeps it in `Sources/Engine`.
enum BrowserMCP {
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
  }

  /// A `tools/call` as the host receives it.
  struct Call {
    let name: String
    let arguments: [String: Any]

    func string(_ key: String) -> String? {
      guard let value = arguments[key] as? String, !value.isEmpty else { return nil }
      return value
    }
  }

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

  static let tools: [Tool] = [
    Tool(
      name: "browser_tabs",
      description:
        "List the web tabs open on this worktree's desk in hukan: each tab's id, title, address, "
        + "and whether the user has shared it with you — \"read\", \"drive\", or \"not shared\". "
        + "Reading or driving a tab that is not shared asks the user first; a tab is shared until "
        + "the user withdraws it, and \"drive\" falls back to \"read\" when the tab moves to "
        + "another site. These tabs carry the user's own logins, so a page behind a sign-in that "
        + "WebFetch cannot reach is readable here.",
      inputSchema: ["type": "object", "properties": [String: Any](), "additionalProperties": false]
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
  ]

  /// What a `tools/list` answers with.
  static var toolList: [[String: Any]] {
    tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema] }
  }

  /// One JSON-RPC message in, one reply out — through `reply`, which is called exactly once, on
  /// the main thread. The handshake (`initialize`, `ping`, the `initialized` notification) and
  /// `tools/list` are answered here; a `tools/call` goes to the handler.
  ///
  /// A notification carries no id and expects no reply, but the control request that delivered
  /// it does: the SDK answers one with an empty result under id 0, and so does this.
  static func handle(
    _ message: [String: Any], handler: Handler, reply: @escaping ([String: Any]) -> Void
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
      reply(
        response(
          id: id,
          result: [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": serverName, "version": "1"],
          ]))
    case "ping":
      reply(response(id: id, result: [:]))
    case "tools/list":
      reply(response(id: id, result: ["tools": toolList]))
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
