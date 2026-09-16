import XCTest

@testable import Hukan

/// A turn that ended because the request never got through. The engine reports it twice — as an
/// assistant message it synthesized (`is_api_error_message`), then as a result — and neither of
/// those is what hukan used to read: the result arrives with `subtype: "success"` and
/// `is_error: true`, so an unreachable API left the session wearing the green check of a turn
/// that went fine, with the engine's own sentence drawn as if the agent had written it.
final class APIFailureTests: XCTestCase {
  private let message = "API Error: Can't reach the API server — check your internet or DNS"

  private func apiErrorMessage(_ text: String) -> ClaudeEvent {
    ClaudeEvent(
      type: "assistant", subtype: nil,
      payload: [
        "is_api_error_message": true,
        "message": [
          "model": "<synthetic>",
          "content": [["type": "text", "text": text]],
        ],
      ])
  }

  private func result(
    subtype: String = "success", isError: Bool = false, terminalReason: String? = nil
  ) -> ClaudeEvent {
    var payload: [String: Any] = ["is_error": isError]
    if let terminalReason { payload["terminal_reason"] = terminalReason }
    return ClaudeEvent(type: "result", subtype: subtype, payload: payload)
  }

  private func colors(of session: AgentSession) -> [NSColor] {
    var found: [NSColor] = []
    session.transcript.enumerateAttribute(
      .foregroundColor, in: NSRange(location: 0, length: session.transcript.length)
    ) { value, _, _ in
      if let color = value as? NSColor { found.append(color) }
    }
    return found
  }

  // MARK: the turn is a failure

  func testAnUnreachableAPIFailsTheTurn() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(apiErrorMessage(message))
    session.apply(result(isError: true, terminalReason: "api_error"))
    XCTAssertEqual(
      session.state, .failed,
      "`is_error` is what says the turn failed — the subtype of this one is `success`")
  }

  func testASucceedingTurnIsStillIdle() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(result(terminalReason: "completed"))
    XCTAssertEqual(session.state, .idle)
  }

  /// The subtype stays in the test: it is the older spelling, and an engine that predates
  /// `is_error` still reports a turn it gave up on that way.
  func testANonSuccessSubtypeStillFails() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(ClaudeEvent(type: "result", subtype: "error_max_turns", payload: [:]))
    XCTAssertEqual(session.state, .failed)
  }

  // MARK: what it says, and how often

  func testTheFailureIsNamedByTerminalReason() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(result(isError: true, terminalReason: "prompt_too_long"))
    XCTAssertTrue(
      session.transcript.string.contains("prompt_too_long"),
      "one subtype covers every way the loop can stop; `terminal_reason` is what tells them apart")
  }

  func testAnAPIErrorIsSaidOnce() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(apiErrorMessage(message))
    session.apply(result(isError: true, terminalReason: "api_error"))
    XCTAssertTrue(session.transcript.string.contains(message))
    XCTAssertFalse(
      session.transcript.string.contains("Stopped ("),
      "the engine's own sentence is already in the transcript; the result must not repeat it")
  }

  func testAnAPIErrorIsDrawnAsOne() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(apiErrorMessage(message))
    XCTAssertTrue(
      colors(of: session).contains(.systemRed),
      "a synthesized failure rendered as prose is indistinguishable from the agent speaking")
  }

  /// "The response above may be incomplete" — so the response above has to still be there. The
  /// buffered `assistant` event normally replaces the streamed span with its formatted self,
  /// which on a synthesized error would delete the partial answer the error is reporting on.
  func testAPartialAnswerSurvivesTheErrorThatReportsIt() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(
      ClaudeEvent(
        type: "stream_event", subtype: nil,
        payload: [
          "event": [
            "type": "content_block_delta",
            "delta": ["type": "text_delta", "text": "half an answer"],
          ]
        ]))
    session.apply(apiErrorMessage("API Error: Connection closed mid-response."))
    XCTAssertTrue(session.transcript.string.contains("half an answer"))
    XCTAssertTrue(session.transcript.string.contains("Connection closed mid-response."))
  }

  // MARK: the retries

  private func retry(attempt: Int, status: Int? = nil) -> ClaudeEvent {
    var payload: [String: Any] = ["attempt": attempt, "max_retries": 10]
    if let status { payload["error_status"] = status }
    return ClaudeEvent(type: "system", subtype: "api_retry", payload: payload)
  }

  func testRetriesAreSaidOncePerTurn() {
    let session = AgentSession(worktreeID: UUID())
    for attempt in 1...10 { session.apply(retry(attempt: attempt)) }
    XCTAssertEqual(
      session.transcript.string.components(separatedBy: "retrying").count - 1, 1,
      "ten retries are one gap in the conversation, not ten things to say")
  }

  func testARetryUnderAnOpenRunSaysNothing() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(
      ClaudeEvent(
        type: "stream_event", subtype: nil,
        payload: [
          "event": [
            "type": "content_block_delta",
            "delta": ["type": "text_delta", "text": "arriving"],
          ]
        ]))
    session.flushStreamRender()
    session.apply(retry(attempt: 1))
    XCTAssertFalse(
      session.transcript.string.contains("retrying"),
      "the note is for a silent window; text is arriving, and the note would sit in the span "
        + "the buffered message replaces")
  }

  func testTheNextTurnMaySayItAgain() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(retry(attempt: 1))
    session.apply(result())
    session.apply(retry(attempt: 1))
    XCTAssertEqual(
      session.transcript.string.components(separatedBy: "retrying").count - 1, 2,
      "the count is per turn: a second turn stalling is a second thing worth knowing")
  }

  // MARK: and the same conversation read back off disk

  /// A restart re-reads the jsonl, where the flag is spelt `isApiErrorMessage`. Reading it there
  /// too is what keeps a reloaded conversation looking like the one that was on screen.
  func testASavedAPIErrorIsStillDrawnAsOne() throws {
    let worktree = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-apierror-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    let store = ClaudeSessionStore.directory(for: worktree)
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: store)
      try? FileManager.default.removeItem(at: worktree)
    }

    let id = UUID()
    let line = """
      {"type":"assistant","uuid":"a1","isApiErrorMessage":true,\
      "message":{"role":"assistant","model":"<synthetic>",\
      "content":[{"type":"text","text":"API Error: 529 Overloaded."}]}}

      """
    try Data(line.utf8).write(to: ClaudeSessionStore.transcriptURL(id: id, worktree: worktree))

    let history = try XCTUnwrap(ClaudeSessionStore.history(id: id, worktree: worktree))
    guard case .apiError(let text) = history.records.first?.kind else {
      return XCTFail("a flagged record is a failure, not something the agent said")
    }
    XCTAssertEqual(text, "API Error: 529 Overloaded.")

    let rendered = Transcript.render(history.records)
    var reds = 0
    rendered.enumerateAttribute(
      .foregroundColor, in: NSRange(location: 0, length: rendered.length)
    ) { value, _, _ in
      if value as? NSColor == .systemRed { reds += 1 }
    }
    XCTAssertGreaterThan(reds, 0)
  }

  func testAConnectionErrorCarriesNoStatus() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(retry(attempt: 1))
    XCTAssertFalse(
      session.transcript.string.contains("HTTP"),
      "`error_status` is null when the request never got a response")

    let answered = AgentSession(worktreeID: UUID())
    answered.apply(retry(attempt: 1, status: 529))
    XCTAssertTrue(answered.transcript.string.contains("HTTP 529"))
  }
}
