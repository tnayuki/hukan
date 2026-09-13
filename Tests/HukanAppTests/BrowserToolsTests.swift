import XCTest

@testable import Hukan

/// The agent's side of the web tab: the grant a tab carries and the rule it lapses by, the MCP
/// server hukan hosts on the session's own stream, and the card a call stops on. None of it loads
/// WebKit — the rule is a value, the server is a dispatcher, and the session is driven through
/// `apply` — which is what keeps this suite off the slow worker `BrowserTests` sits on.
final class BrowserToolsTests: XCTestCase {

  // MARK: - The grant

  /// A drive is held to the site it was granted on; a read is not held to anything. The person
  /// never meets the word origin — what they see is the glyph going hollow.
  func testADriveLapsesToAReadWhenTheTabLeavesItsSite() {
    let pr = URL(string: "https://github.com/tnayuki/hukan/pull/1")!
    let drive = BrowserGrant(level: .drive, at: pr)
    XCTAssertEqual(drive.origin, "https://github.com")
    XCTAssertEqual(
      drive.afterNavigating(to: URL(string: "https://github.com/tnayuki/hukan/issues/2")!), drive,
      "the same site keeps the drive")
    XCTAssertEqual(
      drive.afterNavigating(to: URL(string: "https://docs.github.com/")!).level, .read,
      "another host is another site")
    XCTAssertEqual(
      drive.afterNavigating(to: URL(string: "http://github.com/")!).level, .read,
      "another scheme is another site")
    XCTAssertEqual(
      drive.afterNavigating(to: nil).level, .read, "no page is not the page the drive was for")

    let read = BrowserGrant(level: .read, at: pr)
    XCTAssertEqual(read.afterNavigating(to: URL(string: "https://elsewhere.example/")!), read)
    XCTAssertEqual(read.afterNavigating(to: nil), read)
  }

  func testAPortIsPartOfTheSite() {
    XCTAssertEqual(
      BrowserGrant.origin(of: URL(string: "http://localhost:3000/app")!), "http://localhost:3000")
    XCTAssertEqual(
      BrowserGrant.origin(of: URL(string: "HTTPS://GitHub.com/x")!), "https://github.com")
    XCTAssertNil(BrowserGrant.origin(of: URL(string: "about:blank")!))
  }

  /// A blank tab is granted on no site, so a read there is a tab handed over to navigate, and a
  /// drive there is gone the moment a page arrives.
  func testABlankTabCanBeSharedAndADriveOnItLapsesOnTheFirstPage() {
    let read = BrowserGrant(level: .read, at: nil)
    XCTAssertEqual(read.origin, "")
    XCTAssertTrue(read.allows(.read))
    XCTAssertFalse(read.allows(.drive))
    let drive = BrowserGrant(level: .drive, at: nil)
    XCTAssertEqual(drive.afterNavigating(to: URL(string: "https://example.com/")!).level, .read)
  }

  /// A bare expression is what a console reads and what an agent writes; a function body is what
  /// WebKit runs. The code decides which it is, and it runs exactly once either way.
  func testABareExpressionIsEvaluatedAndAFunctionBodyIsRunAsOne() {
    let bare = BrowserPaneViewController.asyncBody(for: "document.title")
    XCTAssertEqual(bare.script, "return eval(code);")
    XCTAssertEqual(bare.arguments["code"] as? String, "document.title")

    let statements = BrowserPaneViewController.asyncBody(for: "const a = 1;\na + 1")
    XCTAssertEqual(statements.script, "return eval(code);")

    let body = BrowserPaneViewController.asyncBody(
      for: "const r = await fetch('/x');\nreturn r.status;")
    XCTAssertEqual(body.script, "const r = await fetch('/x');\nreturn r.status;")
    XCTAssertTrue(body.arguments.isEmpty)

    // `returned` is not `return`.
    XCTAssertEqual(
      BrowserPaneViewController.asyncBody(for: "returned.value").script, "return eval(code);")
  }

  // MARK: - The server on the stream

  /// The engine is told about the server in the first thing hukan writes to it, and the call
  /// clock is a person's, not a network's.
  func testTheInitializeRequestNamesTheHostedServer() {
    let request = ClaudeSession.initializeRequest
    XCTAssertEqual(request["subtype"] as? String, "initialize")
    XCTAssertEqual(request["sdkMcpServers"] as? [String], ["hukan"])
    let configs = request["sdkMcpServerConfigs"] as? [String: [String: Any]]
    XCTAssertEqual(configs?["hukan"]?["timeout"] as? Int, 86_400_000)
  }

  private func reply(
    to message: [String: Any],
    handler: @escaping BrowserMCP.Handler = { _, done in
      done(.text("unexpected"))
    }
  ) -> [String: Any] {
    var answer: [String: Any] = [:]
    BrowserMCP.handle(message, handler: handler) { answer = $0 }
    return answer
  }

  func testTheHandshakeIsAnsweredHere() {
    let initialize = reply(to: [
      "jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": ["protocolVersion": "2025-03-26", "capabilities": [:]],
    ])
    XCTAssertEqual(initialize["id"] as? Int, 1)
    let result = initialize["result"] as? [String: Any]
    XCTAssertEqual(result?["protocolVersion"] as? String, "2025-03-26", "the client's version")
    XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "hukan")
    XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])

    // A notification wants no reply, but the control request carrying it does: the SDK's own
    // answer is an empty result under id 0, and the CLI is written against that.
    let initialized = reply(to: ["jsonrpc": "2.0", "method": "notifications/initialized"])
    XCTAssertEqual(initialized["id"] as? Int, 0)
    XCTAssertEqual((initialized["result"] as? [String: Any])?.isEmpty, true)

    let unknown = reply(to: ["jsonrpc": "2.0", "id": "x", "method": "resources/list"])
    XCTAssertEqual(unknown["id"] as? String, "x")
    XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
  }

  /// The list is the whole of what the model is told, so each tool's description has to say when
  /// the user is asked — that is the one behaviour the model has to expect.
  func testTheToolListSaysTheUserIsAsked() {
    let answer = reply(to: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
    let tools = (answer["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
    XCTAssertEqual(
      tools.map { $0["name"] as? String },
      [
        "browser_tabs", "browser_open", "browser_read", "browser_navigate", "browser_screenshot",
        "browser_run",
      ])
    for tool in tools where tool["name"] as? String != "browser_tabs" {
      let description = tool["description"] as? String ?? ""
      XCTAssertTrue(
        description.contains("asked"), "\(tool["name"] ?? "") does not say the user is asked")
      XCTAssertNotNil((tool["inputSchema"] as? [String: Any])?["properties"])
    }
  }

  func testACallReachesTheHandlerAndItsOutcomeBecomesTheResult() {
    var received: BrowserMCP.Call?
    let text = reply(
      to: [
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": ["name": "browser_read", "arguments": ["tab": "abc", "selector": "main"]],
      ],
      handler: { call, done in
        received = call
        done(.text("the page"))
      })
    XCTAssertEqual(received?.name, "browser_read")
    XCTAssertEqual(received?.string("tab"), "abc")
    XCTAssertEqual(received?.string("selector"), "main")
    XCTAssertNil(received?.string("missing"))
    let result = text["result"] as? [String: Any]
    XCTAssertEqual(result?["isError"] as? Bool, false)
    let content = result?["content"] as? [[String: Any]]
    XCTAssertEqual(content?.first?["text"] as? String, "the page")

    // A refusal is a failed tool result the model reads, not a protocol error.
    let declined = reply(
      to: [
        "jsonrpc": "2.0", "id": 4, "method": "tools/call",
        "params": ["name": "browser_run", "arguments": [:]],
      ],
      handler: { _, done in done(.error("declined")) })
    XCTAssertEqual((declined["result"] as? [String: Any])?["isError"] as? Bool, true)
    XCTAssertNil(declined["error"])

    let image = reply(
      to: [
        "jsonrpc": "2.0", "id": 5, "method": "tools/call",
        "params": ["name": "browser_screenshot", "arguments": [:]],
      ],
      handler: { _, done in done(.image(Data([0x89, 0x50]), mimeType: "image/png")) })
    let block = ((image["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first
    XCTAssertEqual(block?["type"] as? String, "image")
    XCTAssertEqual(block?["mimeType"] as? String, "image/png")
    XCTAssertEqual(block?["data"] as? String, Data([0x89, 0x50]).base64EncodedString())
  }

  // MARK: - The card on the session

  /// A call that needs a tab puts the session on you the way an approval does, and the answer
  /// goes back to the call and onto the record.
  func testAGrantRequestStopsTheSessionAndTheAnswerReachesTheCall() {
    let session = AgentSession(worktreeID: UUID())
    var decided: [BrowserGrant.Level?] = []
    session.requestGrant(tabID: UUID(), title: "PR #1", url: "https://github.com/x", level: .read) {
      decided.append($0)
    }
    XCTAssertEqual(session.state, .needsAttention)
    XCTAssertEqual(session.pendingGrant?.title, "PR #1")
    XCTAssertEqual(session.pendingGrant?.level, .read)

    session.resolveGrant(.drive)
    XCTAssertNil(session.pendingGrant)
    XCTAssertEqual(decided, [.drive])
    let note = "shared \u{201C}PR #1\u{201D} with the agent (read and drive)"
    XCTAssertTrue(session.transcript.string.contains(note), "what was given is on the record")

    session.resolveGrant(nil)
    XCTAssertEqual(decided, [.drive], "nothing pending, nothing answered twice")
  }

  /// Whatever ends the turn answers the card for it, so the call's closure never waits on an
  /// answer that cannot come. A decline nobody made leaves no note.
  func testTheTurnEndingDeclinesAPendingGrant() {
    let session = AgentSession(worktreeID: UUID())
    var decided: [BrowserGrant.Level?] = []
    session.requestGrant(tabID: UUID(), title: "t", url: "", level: .drive) { decided.append($0) }
    session.apply(ClaudeEvent(type: "result", subtype: "success", payload: [:]))
    XCTAssertEqual(decided.count, 1)
    XCTAssertNil(decided[0])
    XCTAssertNil(session.pendingGrant)
    XCTAssertFalse(session.transcript.string.contains("declined"))

    // An interrupt is a decline someone made, and says so.
    session.requestGrant(tabID: UUID(), title: "u", url: "", level: .read) { decided.append($0) }
    session.interrupt()
    XCTAssertEqual(decided.count, 2)
    XCTAssertNil(decided[1])
    XCTAssertTrue(session.transcript.string.contains("declined to share \u{201C}u\u{201D}"))
  }

  /// Opening is asked about as opening, and the record names the address rather than a page
  /// that does not exist yet.
  func testAnOpenIsRecordedAsOne() {
    let session = AgentSession(worktreeID: UUID())
    session.requestGrant(
      tabID: UUID(), title: "github.com", url: "https://github.com/x", level: .read, opening: true
    ) { _ in }
    XCTAssertEqual(session.pendingGrant?.opening, true)
    session.resolveGrant(.read)
    XCTAssertTrue(
      session.transcript.string.contains(
        "opened \u{201C}https://github.com/x\u{201D} for the agent (read)"))
  }

  /// hukan's own tools never reach the generic approval card: the grant is the consent, and an
  /// Allow in front of it would be the same question twice, the first naming no tab.
  func testHukansOwnToolsAreNotHeldForApproval() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(
      ClaudeEvent(
        type: "control_request", subtype: nil,
        payload: [
          "request_id": "r1",
          "request": [
            "subtype": "can_use_tool", "tool_name": "mcp__hukan__browser_read", "input": [:],
          ],
        ]))
    XCTAssertNil(session.pendingApproval)
    XCTAssertNotEqual(session.state, .needsAttention)
  }
}
