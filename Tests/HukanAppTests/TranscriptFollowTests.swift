import AppKit
import XCTest

@testable import Hukan

/// Whether the transcript follows the stream, through the real window because the answer is a
/// clip view's position against a document that is being appended to thirty times a second.
///
/// The bug: the decision was re-measured on every flush, as "is the clip within `pinTolerance`
/// of the bottom" — so a scroll of less than the tolerance left the reader geometrically still
/// pinned and the next flush put them back under their own finger. Measured at 8, 16 and 24
/// points, which is where the start of a trackpad gesture lands.
///
/// `NSScrollView` posting the live-scroll notifications for a real gesture is AppKit's to keep;
/// these post them by hand, so what is pinned here is what the column does with them.
final class TranscriptFollowTests: XCTestCase {
  @MainActor
  private func openWindow() throws -> (NSWindow, NSScrollView, NSTextView, AgentSession) {
    let workspace = RailPreviewTests.sampleWorkspace()
    let session = try XCTUnwrap(workspace.sessions.first)
    for line in 0..<800 {
      session.transcript.append(
        NSAttributedString(
          string: "line \(line) — a line of the conversation, long enough to wrap once\n",
          attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
    }
    let controller = WorkspaceWindowController(workspace: workspace)
    let window = try XCTUnwrap(controller.window)
    workspace.selectedWorktreeID = session.worktreeID
    workspace.selectedSessionID = session.id
    controller.reload()
    // Parked below every screen, the way the other window-driven suites do it.
    window.setFrame(NSRect(x: 0, y: -4000, width: 1600, height: 800), display: true)
    window.makeKeyAndOrderFront(nil)
    controller.arrangeColumnsIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let textView = try XCTUnwrap(transcriptTextView(in: try XCTUnwrap(window.contentView)))
    return (window, try XCTUnwrap(textView.enclosingScrollView), textView, session)
  }

  private func transcriptTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView, textView.delegate is TranscriptClickDelegate {
      return textView
    }
    for subview in view.subviews {
      if let found = transcriptTextView(in: subview) { return found }
    }
    return nil
  }

  /// One `content_block_delta`, the event a streaming reply arrives as.
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

  /// Run a turn's worth of flushes past the view.
  @MainActor
  private func stream(_ session: AgentSession, steps: Int) {
    for step in 0..<steps {
      session.apply(delta("streamed chunk \(step), a sentence's worth of the agent's reply. "))
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
  }

  @MainActor
  private func liveScroll(_ scrollView: NSScrollView, by points: CGFloat) {
    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
    scrollView.contentView.scroll(
      to: NSPoint(x: 0, y: scrollView.documentVisibleRect.minY - points))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    NotificationCenter.default.post(
      name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
  }

  /// The case the tolerance was swallowing: a nudge shorter than it, made by hand, during a turn.
  @MainActor
  func testAShortScrollAwayFromTheTailHoldsThroughAStream() throws {
    let (window, scrollView, _, session) = try openWindow()
    defer { window.close() }
    stream(session, steps: 6)
    XCTAssertEqual(
      scrollView.documentVisibleRect.maxY, scrollView.documentView!.frame.height,
      accuracy: 24, "the view follows the stream until told otherwise")

    liveScroll(scrollView, by: 8)
    let asked = scrollView.documentVisibleRect.minY
    stream(session, steps: 10)

    XCTAssertEqual(
      scrollView.documentVisibleRect.minY, asked, accuracy: 0.5,
      "eight points is a distance the reader moved, not the layout's jitter")
  }

  /// And a scroll long enough that the old rule already caught it stays caught.
  @MainActor
  func testALongScrollAwayFromTheTailHoldsThroughAStream() throws {
    let (window, scrollView, _, session) = try openWindow()
    defer { window.close() }
    stream(session, steps: 6)

    liveScroll(scrollView, by: 400)
    let asked = scrollView.documentVisibleRect.minY
    stream(session, steps: 10)

    XCTAssertEqual(scrollView.documentVisibleRect.minY, asked, accuracy: 0.5)
  }

  /// Coming back to the bottom by hand rejoins the stream — the pill's other half, and the
  /// reason the tolerance stays generous for this question: `scrollToEndOfDocument` stops a few
  /// points short of the clip's own limit, so "at the bottom" cannot mean exactly.
  @MainActor
  func testScrollingBackToTheBottomFollowsTheStreamAgain() throws {
    let (window, scrollView, _, session) = try openWindow()
    defer { window.close() }
    stream(session, steps: 6)
    liveScroll(scrollView, by: 400)
    stream(session, steps: 4)
    XCTAssertLessThan(
      scrollView.documentVisibleRect.maxY, scrollView.documentView!.frame.height - 24,
      "scrolled up and left there")

    liveScroll(scrollView, by: -10_000)
    stream(session, steps: 6)

    XCTAssertEqual(
      scrollView.documentVisibleRect.maxY, scrollView.documentView!.frame.height,
      accuracy: 24, "back at the bottom, following again")
  }

  /// The move the direction rule must *not* read as a decision: the clip's origin comes up
  /// because the document shrank under a reader who was already at the bottom, with nobody
  /// touching the scroll view. That is the layout's doing, and the view goes on following.
  @MainActor
  func testTheDocumentShrinkingUnderneathDoesNotStopTheFollow() throws {
    let (window, scrollView, _, session) = try openWindow()
    defer { window.close() }
    stream(session, steps: 6)

    // No live-scroll notifications: this is the clip being moved for the reader, not by them.
    scrollView.contentView.scroll(
      to: NSPoint(x: 0, y: scrollView.documentVisibleRect.minY - 8))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    stream(session, steps: 10)

    XCTAssertEqual(
      scrollView.documentVisibleRect.maxY, scrollView.documentView!.frame.height,
      accuracy: 24, "still at the bottom")
  }
}
