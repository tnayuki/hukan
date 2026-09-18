import XCTest

@testable import Hukan

/// An `assistant` event that no `content_block_delta` preceded. The engine synthesizes these
/// itself (`model: "<synthetic>"`) for an API error or a usage-limit notice, so the buffered
/// event carries the only copy of the text — the live path has to append it, the way the jsonl
/// parse does, or it shows up only after a restart.
final class SyntheticMessageTests: XCTestCase {
  private func assistantEvent(_ text: String) -> ClaudeEvent {
    ClaudeEvent(
      type: "assistant",
      subtype: nil,
      payload: [
        "message": [
          "model": "<synthetic>",
          "content": [["type": "text", "text": text]],
        ]
      ])
  }

  func testUnstreamedAssistantTextIsAppended() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(assistantEvent("API Error: 529 Overloaded."))
    XCTAssertTrue(
      session.transcript.string.contains("API Error: 529 Overloaded."),
      "a synthetic message is the only copy of its text, so it must land in the transcript")
  }

  func testStreamedTextIsNotPrintedTwice() {
    let session = AgentSession(worktreeID: UUID())
    let delta = ClaudeEvent(
      type: "stream_event", subtype: nil,
      payload: [
        "event": [
          "type": "content_block_delta",
          "delta": ["type": "text_delta", "text": "Hello"],
        ]
      ])
    session.apply(delta)
    session.apply(assistantEvent("Hello"))
    XCTAssertEqual(
      session.transcript.string.components(separatedBy: "Hello").count - 1, 1,
      "the buffered text reformats the streamed span rather than appending beside it")
  }
}

/// A user message that arrives while the agent's text is still streaming. Every flush of the
/// run replaces from its settled point to the end of the transcript, so a message appended into
/// the open run was wiped by the next delta — a send pushed through mid-turn vanished.
final class MidStreamUserMessageTests: XCTestCase {
  private func delta(_ text: String) -> ClaudeEvent {
    ClaudeEvent(
      type: "stream_event", subtype: nil,
      payload: [
        "event": [
          "type": "content_block_delta",
          "delta": ["type": "text_delta", "text": text],
        ]
      ])
  }

  func testAMessageSentWhileTextStreamsSurvivesTheRun() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(delta("Working on "))
    session.flushStreamRender()
    // A line typed on a bridged phone takes the same drawing path as one sent from here.
    session.apply(
      ClaudeEvent(
        type: "user", subtype: nil,
        payload: [
          "isReplay": true, "uuid": "u-1", "origin": ["kind": "human"],
          "message": ["role": "user", "content": "stop and do this instead"],
        ]))
    session.apply(delta("it."))
    session.flushStreamRender()
    session.apply(
      ClaudeEvent(
        type: "assistant", subtype: nil,
        payload: ["message": ["content": [["type": "text", "text": "Working on it."]]]]))
    let text = session.transcript.string
    XCTAssertTrue(text.contains("stop and do this instead"), "the message must not be wiped")
    XCTAssertEqual(text.components(separatedBy: "Working on it.").count - 1, 1)
    let message = text.range(of: "stop and do this instead")!
    let reply = text.range(of: "Working on it.")!
    XCTAssertLessThan(reply.lowerBound, message.lowerBound, "drawn after the run it was sent under")
  }
}
