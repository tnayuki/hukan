import XCTest

@testable import Hukan

/// The MCP server a client outside hukan reaches it through: the handshake its stdio half
/// answers alone, and the conversation read as turns. The Apple event between the two halves is
/// not driven here — it needs a second process and an automation grant — so what is pinned is
/// everything either side of it.
final class ExternalMCPTests: XCTestCase {

  private func reply(to message: [String: Any]) -> [String: Any]? {
    var answer: [String: Any]?
    HukanMCP.handle(
      message, tools: HukanMCP.listing(ExternalMCP.tools), instructions: ExternalMCP.instructions,
      handler: { _, done in done(.text("called")) }, reply: { answer = $0 })
    return answer
  }

  /// The client meets hukan for the first time here, so the handshake carries what hukan is, and
  /// the list offers this server's tools — not the ones a session's agent is offered.
  func testTheHandshakeSaysWhatHukanIsAndOffersItsOwnTools() throws {
    let initialize = try XCTUnwrap(
      reply(to: ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])?["result"]
        as? [String: Any])
    XCTAssertEqual(initialize["instructions"] as? String, ExternalMCP.instructions)

    let list = try XCTUnwrap(
      reply(to: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"] as? [String: Any])
    let names = (list["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
    XCTAssertEqual(
      names,
      [
        ExternalMCP.sessionsTool, ExternalMCP.sessionTool, ExternalMCP.sendTool,
        ExternalMCP.newSessionTool,
      ])
  }

  /// A session stopped on an approval is a decision put to the person. A message there would cut
  /// the turn and drop it, so the send is refused and the session is left exactly as it was.
  func testASessionWaitingOnTheDeveloperIsNotSentTo() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(
      ClaudeEvent(
        type: "control_request", subtype: nil,
        payload: [
          "request_id": "r1",
          "request": [
            "subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "git push"],
          ],
        ]))
    XCTAssertNotNil(session.pendingApproval)
    let before = session.lastInstructedAt

    guard
      case .error(let message) = ExternalMCP.send(
        "go ahead", to: session, from: "Claude", reattaching: nil)
    else { return XCTFail("a waiting session took the message") }
    XCTAssertTrue(message.contains("approval of Bash"), message)
    XCTAssertNotNil(session.pendingApproval, "the decision is still the developer's")
    XCTAssertEqual(session.lastInstructedAt, before)
    XCTAssertFalse(session.transcript.string.contains("Sent from"))
  }

  /// What arrives from outside says where it came from, so a transcript read later can tell a
  /// message the developer typed here from one a chat sent.
  func testAMessageFromOutsideSaysWhereItCameFrom() {
    let session = AgentSession(worktreeID: UUID())
    guard
      case .text = ExternalMCP.send("run the tests", to: session, from: "Claude", reattaching: nil)
    else { return XCTFail("an idle session refused the message") }
    XCTAssertTrue(session.transcript.string.contains("Sent from Claude."))
    XCTAssertNotEqual(session.lastInstructedAt, .distantPast, "the send is an instruction")
  }

  /// A new session needs somewhere to stand: a repository that is not open is said so rather than
  /// guessed at, and nothing is made.
  func testANewSessionInARepositoryThatIsNotOpenIsRefused() {
    var outcome: HukanMCP.Outcome?
    ExternalMCP.answer(
      HukanMCP.Call(
        name: ExternalMCP.newSessionTool, arguments: ["repository": "nowhere", "message": "hi"]),
      in: []
    ) { outcome = $0 }
    guard case .error(let message) = outcome else { return XCTFail("a session was made nowhere") }
    XCTAssertTrue(message.contains("no repository named nowhere"), message)
  }

  /// The note names what the client said it was and the app it runs under, once when they agree:
  /// the first is unchecked and the second, for a client in a terminal, is only the terminal.
  func testTheOriginIsTheClientsNameAndTheAppItRunsUnder() {
    XCTAssertEqual(ExternalMCP.origin(declared: "codex", app: "Terminal"), "codex in Terminal")
    XCTAssertEqual(ExternalMCP.origin(declared: "claude", app: "Claude"), "Claude")
    XCTAssertEqual(ExternalMCP.origin(declared: nil, app: "Script Editor"), "Script Editor")
    XCTAssertEqual(ExternalMCP.origin(declared: "cron-job", app: nil), "cron-job")
    XCTAssertNil(ExternalMCP.origin(declared: nil, app: nil))
  }

  /// The session's own server is untouched by the parameters: no instructions, its own tools.
  func testTheSessionsOwnServerKeepsItsToolsAndSaysNothingMore() throws {
    var answer: [String: Any]?
    HukanMCP.handle(
      ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]],
      handler: { _, _ in }, reply: { answer = $0 })
    let result = try XCTUnwrap(answer?["result"] as? [String: Any])
    XCTAssertNil(result["instructions"])
  }

  private func record(_ kind: HistoryRecord.Kind, at seconds: TimeInterval = 0) -> HistoryRecord {
    HistoryRecord(kind: kind, stamp: Date(timeIntervalSince1970: seconds))
  }

  /// A turn is what was said and what came of it: the agent's last words are the answer, what it
  /// wrote between tool calls is not, and the tools are counted rather than shown.
  func testATurnKeepsTheLastAnswerAndCountsTheTools() {
    let turns = ExternalMCP.turns(from: [
      record(.userText("fix the build")),
      record(.assistantText("Looking at the log.")),
      record(.toolUse(name: "Bash", input: [:])),
      record(.toolUse(name: "Read", input: [:])),
      record(.toolUse(name: "Bash", input: [:])),
      record(.assistantText("Fixed: a missing import.")),
      record(.userText("thanks"), at: 60),
      record(.assistantText("You're welcome."), at: 61),
    ])
    XCTAssertEqual(turns.count, 2)
    XCTAssertEqual(turns[0].said, "fix the build")
    XCTAssertEqual(turns[0].answer, "Fixed: a missing import.")
    XCTAssertEqual(turns[0].tools.map(\.name), ["Bash", "Read"])
    XCTAssertEqual(turns[0].tools.map(\.count), [2, 1])
    XCTAssertEqual(turns[1].answer, "You're welcome.")
  }

  /// A message of several text blocks is one thing said; and a failed turn says it failed rather
  /// than passing the engine's sentence off as the agent's answer.
  func testBlocksOfOneMessageAreOneTurnAndAFailureSaysSo() {
    let turns = ExternalMCP.turns(from: [
      record(.userText("first part")),
      record(.userText("second part")),
      record(.apiError("API Error: Connection error.")),
    ])
    XCTAssertEqual(turns.count, 1)
    XCTAssertEqual(turns[0].said, "first part\nsecond part")
    XCTAssertEqual(turns[0].answer, "(the turn failed) API Error: Connection error.")
  }

  /// The first turn is what the session is for and the latest ones are where it stands, so those
  /// are the default; a range asked for is clamped to what exists.
  func testTheWindowIsTheFirstTurnAndTheLatestOrARange() {
    XCTAssertEqual(ExternalMCP.TurnWindow(recent: 3).numbers(of: 10), [1, 8, 9, 10])
    XCTAssertEqual(ExternalMCP.TurnWindow(recent: 5).numbers(of: 3), [1, 2, 3])
    XCTAssertEqual(ExternalMCP.TurnWindow(start: 4, end: 6).numbers(of: 10), [4, 5, 6])
    XCTAssertEqual(ExternalMCP.TurnWindow(start: 8).numbers(of: 10), [8, 9, 10])
    XCTAssertEqual(ExternalMCP.TurnWindow(start: 50).numbers(of: 10), [10])
    XCTAssertEqual(ExternalMCP.TurnWindow().numbers(of: 0), [])
  }

  /// What is left out says so, a turn still running says so, and a long message is cut with the
  /// count of what was cut.
  func testTheRenderingSaysWhatItLeftOut() {
    let long = String(repeating: "x", count: ExternalMCP.messageLimit + 10)
    let turns =
      (1...6).map { ExternalMCP.Turn(stamp: nil, said: "ask \($0)", answer: "answer \($0)") }
      + [ExternalMCP.Turn(stamp: nil, said: long, answer: nil)]
    let text = ExternalMCP.render(
      turns, window: ExternalMCP.TurnWindow(recent: 2), lastIsRunning: true)
    XCTAssertTrue(text.hasPrefix("7 turns"))
    XCTAssertTrue(text.contains("(turns 2–5 not shown)"))
    XCTAssertTrue(text.contains("Developer: ask 6\nAgent: answer 6"))
    XCTAssertTrue(text.contains("… [10 more characters]"))
    XCTAssertTrue(text.contains("Agent — still working: (nothing written yet)"))
    XCTAssertFalse(text.contains("ask 2"))
  }
}
