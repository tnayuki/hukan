import AppKit
import XCTest

@testable import Hukan

/// The queue's keyboard half: a line typed mid-turn queues on Return, and a second Return —
/// the field now empty — sends that line now rather than waiting for the turn. The row's own
/// send-now button without the trip to it.
final class TypeAheadTests: XCTestCase {
  /// Return on an empty field is reported as such, and Return on text is a send as before.
  @MainActor
  func testReturnOnTheEmptyFieldIsItsOwnSignal() throws {
    let input = ComposerInput()
    var sent: [String] = []
    var empties = 0
    input.onSend = { text, _ in sent.append(text) }
    input.onSendEmpty = { empties += 1 }
    let textView = try XCTUnwrap(composerTextView(in: input))

    textView.insertNewline(nil)
    XCTAssertEqual(empties, 1)
    XCTAssertEqual(sent, [])

    input.stringValue = "queue this"
    textView.insertNewline(nil)
    XCTAssertEqual(sent, ["queue this"])
    XCTAssertEqual(empties, 1, "a send is not an empty Return")
    XCTAssertEqual(input.stringValue, "", "the send clears the field, ready for the second Return")

    textView.insertNewline(nil)
    XCTAssertEqual(empties, 2)
  }

  /// The line sent now is the last one queued — the one the hand just left — and the rest of
  /// the queue keeps its place. With nothing queued the press does nothing at all.
  func testTheLastQueuedLineGoesNowAndTheRestWait() {
    let session = AgentSession(worktreeID: UUID())
    session.restoreQueue(["first, typed ahead on purpose", "second, meant now"])

    session.sendLastQueuedNow()
    XCTAssertEqual(session.queuedMessages.map(\.text), ["first, typed ahead on purpose"])
    XCTAssertTrue(
      session.transcript.string.contains("second, meant now"),
      "the line sent now is recorded in the transcript like any other send")

    session.sendLastQueuedNow()
    XCTAssertEqual(session.queuedMessages.count, 0)
    session.sendLastQueuedNow()
    XCTAssertEqual(session.queuedMessages.count, 0, "nothing queued, nothing to send")
  }

  private func composerTextView(in view: NSView) -> ComposerTextView? {
    if let textView = view as? ComposerTextView { return textView }
    for subview in view.subviews {
      if let found = composerTextView(in: subview) { return found }
    }
    return nil
  }
}
