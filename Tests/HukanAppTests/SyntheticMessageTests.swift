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
