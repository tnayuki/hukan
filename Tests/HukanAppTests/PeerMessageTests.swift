import XCTest

@testable import Hukan

/// A message another Claude session sent (`SendMessage`) is drawn as its own body under the
/// sender's name, not as the engine's wrapper and not as something typed here. The record's shape
/// is a real one's, trimmed.
final class PeerMessageTests: XCTestCase {
  private let record: [String: Any] = [
    "type": "user", "isMeta": true, "uuid": "476b644c",
    "message": [
      "role": "user",
      "content":
        "Another Claude session sent a message:\n<cross-session-message from-name=\"kakei-63\">"
        + "Here is the list.</cross-session-message>\n\nThis came from another Claude session.",
    ],
    "origin": ["kind": "peer", "name": "kakei-63", "body": "Here is the list."],
  ]

  func testTheBodyAndTheSenderAreReadOffTheOrigin() throws {
    let peer = try XCTUnwrap(ClaudeSessionStore.peerMessage(record))
    XCTAssertEqual(peer.from, "kakei-63")
    XCTAssertEqual(peer.body, "Here is the list.")
    XCTAssertNil(ClaudeSessionStore.peerMessage(["type": "user", "origin": ["kind": "human"]]))
  }

  func testItIsDrawnUnderTheSendersName() {
    let drawn = Transcript.render([
      HistoryRecord(kind: .userText("Here is the list."), stamp: nil, from: "kakei-63")
    ]).string
    XCTAssertTrue(drawn.contains("Sent from session “kakei-63”."), drawn)
    XCTAssertTrue(drawn.contains("Here is the list."), drawn)
    XCTAssertFalse(drawn.contains("cross-session-message"), drawn)
  }
}
