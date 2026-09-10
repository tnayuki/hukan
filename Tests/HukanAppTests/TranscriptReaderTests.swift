import AppKit
import XCTest

@testable import Hukan

/// The reader keeps their place in the conversation while the text moves under them — through
/// the real window, because that is where it went wrong both times. `ScrollAnchorTests` proves
/// the anchor arithmetic on a bare text view; what it cannot see is the column's chrome, and on
/// a bare view `NSTextView` compensates for an insertion by itself, so neither failure shows
/// there at all.
///
/// A width change was the first: `NSTextView` runs a live resize — the split view collapsing
/// under a maximize, a divider drag — with its frame notifications switched off, so the handler
/// that put the reader back never ran, and the reader was left at a point offset that now named
/// another part of the text. And the text is re-wrapped only when the *container* moves, which
/// under that resize is at the end rather than per frame, so a placement made on the frame's
/// width was laid out against the old one.
///
/// Earlier conversation landing above them is the other, and it had a placement of its own that
/// laid out only as far as the anchor. That pass read the geometry the document had before the
/// insert, so the y it aimed at was the y the reader was already at and the scroll did nothing:
/// they stayed where they stood, which was a whole slice further back in the conversation.
final class TranscriptReaderTests: XCTestCase {
  /// A window on a session whose transcript is long enough for a re-wrap to move the reader by
  /// thousands of points, and wide enough that the maximize doubles its width.
  @MainActor
  private func openWindow() throws -> (
    WorkspaceWindowController, NSWindow, NSScrollView, NSTextView
  ) {
    let workspace = RailPreviewTests.sampleWorkspace()
    let session = try XCTUnwrap(workspace.sessions.first)
    fill(session)
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
    return (controller, window, try XCTUnwrap(textView.enclosingScrollView), textView)
  }

  /// Two thousand lines of transcript: tall enough that a re-wrap moves the reader by thousands
  /// of points, and that the bottom is a long way from the top.
  private func fill(_ session: AgentSession) {
    for line in 0..<2000 {
      session.transcript.append(
        NSAttributedString(
          string:
            "line \(line) — a transcript line long enough to wrap in a narrower column, and then "
            + "some more words so that it wraps twice\n",
          attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
    }
  }

  /// The engine asking to run a tool, which is what puts an approval card under the transcript.
  private func approvalRequest() -> ClaudeEvent {
    ClaudeEvent(
      type: "control_request", subtype: nil,
      payload: [
        "request_id": "r1",
        "request": [
          "subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "git push"],
        ],
      ])
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

  /// The line the reader has at the top of the viewport, read back off the view.
  private func topLine(of scrollView: NSScrollView, _ textView: NSTextView) -> String {
    let index = textView.characterIndexForInsertion(at: scrollView.documentVisibleRect.origin)
    let text = textView.string as NSString
    return text.substring(with: text.lineRange(for: NSRange(location: index, length: 0)))
      .trimmingCharacters(in: .newlines)
  }

  private func isAtBottom(_ scrollView: NSScrollView, _ textView: NSTextView) -> Bool {
    scrollView.documentVisibleRect.maxY >= textView.frame.height - 1
  }

  private func scrollToMiddle(_ scrollView: NSScrollView, _ textView: NSTextView) {
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: textView.frame.height / 2))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
  }

  /// Run the loop until the layout has arrived, rather than for a fixed beat.
  ///
  /// These waits were `0.8` seconds after a maximize or an animated resize, which is a guess
  /// about a machine: too short when the host is busy — the parallel suite is enough, and a CI
  /// runner more so — and the whole of it wasted when it is not. What the tests are actually
  /// waiting for is the column to reach a width and the reader to reach a place and both to stay
  /// there, so that is what they ask for.
  ///
  /// Stillness is measured on the clock and not in turns of the loop, which is the trap this was
  /// first written into: `RunLoop.run(until:)` returns as soon as it has processed a source, so
  /// counting five short slices can be over in no time at all and read a layout that has not
  /// started moving as one that has finished.
  @MainActor
  private func settle(
    _ scrollView: NSScrollView, _ textView: NSTextView, still: TimeInterval = 0.25,
    timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line
  ) {
    var last: [CGFloat] = []
    var lastChanged = Date()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      let now = [
        textView.frame.width, textView.frame.height, scrollView.documentVisibleRect.origin.y,
      ]
      if now != last {
        last = now
        lastChanged = Date()
      } else if Date().timeIntervalSince(lastChanged) >= still {
        return
      }
    }
    XCTFail("the column never settled (last \(last))", file: file, line: line)
  }

  /// Opening a session lands at the bottom; maximizing the conversation and putting the columns
  /// back must leave it there — the narrowing on the way back is where it used to end up a
  /// screen and a half short of the end, with the pill hidden because nothing had "arrived".
  @MainActor
  func testTheBottomStaysTheBottomAcrossAMaximize() throws {
    let (controller, window, scrollView, textView) = try openWindow()
    defer { window.close() }
    XCTAssertTrue(isAtBottom(scrollView, textView), "a session opens at the bottom")

    controller.focusComposer()
    controller.toggleMaximize(nil)
    settle(scrollView, textView)
    XCTAssertEqual(controller.maximizedColumn, .session)
    XCTAssertTrue(
      isAtBottom(scrollView, textView),
      "maximized: \(scrollView.documentVisibleRect) in \(textView.frame.height)")

    controller.toggleMaximize(nil)
    settle(scrollView, textView)
    XCTAssertNil(controller.maximizedColumn)
    XCTAssertTrue(
      isAtBottom(scrollView, textView),
      "restored: \(scrollView.documentVisibleRect) in \(textView.frame.height)")
  }

  /// A reader partway up the conversation is on the same line after the column has doubled in
  /// width and halved again — the case the anchor exists for.
  @MainActor
  func testTheReadersLineHoldsAcrossAMaximize() throws {
    let (controller, window, scrollView, textView) = try openWindow()
    defer { window.close() }
    scrollToMiddle(scrollView, textView)
    let line = topLine(of: scrollView, textView)
    XCTAssertTrue(line.hasPrefix("line "), "scrolled to the middle of the transcript: \(line)")

    controller.focusComposer()
    controller.toggleMaximize(nil)
    settle(scrollView, textView)
    XCTAssertEqual(topLine(of: scrollView, textView), line, "maximized")

    controller.toggleMaximize(nil)
    settle(scrollView, textView)
    XCTAssertEqual(topLine(of: scrollView, textView), line, "restored")
  }

  /// The window itself resizing — animated, the way a zoom or a drag lands — is the other way
  /// the column changes width.
  @MainActor
  func testTheReadersLineHoldsAcrossAWindowResize() throws {
    let (_, window, scrollView, textView) = try openWindow()
    defer { window.close() }
    scrollToMiddle(scrollView, textView)
    let line = topLine(of: scrollView, textView)

    window.setFrame(
      NSRect(x: 0, y: -4000, width: 1100, height: 800), display: true, animate: true)
    settle(scrollView, textView)
    XCTAssertNotEqual(textView.frame.width, 428.5, "the column did not change width")
    XCTAssertEqual(topLine(of: scrollView, textView), line, "narrowed")

    window.setFrame(
      NSRect(x: 0, y: -4000, width: 1600, height: 800), display: true, animate: true)
    settle(scrollView, textView)
    XCTAssertEqual(topLine(of: scrollView, textView), line, "widened again")
  }

  /// A card landing under the transcript — an approval, a question, the task list — makes the
  /// bottom area taller and the scroll view shorter, and a clip view that shrinks keeps its
  /// origin: the tail slides out of view by exactly the card's height, and the reader who was at
  /// the bottom is now a card short of it with nothing having scrolled.
  @MainActor
  func testTheBottomStaysTheBottomWhenACardArrivesUnderIt() throws {
    let (controller, window, scrollView, textView) = try openWindow()
    defer { window.close() }
    XCTAssertTrue(isAtBottom(scrollView, textView), "a session opens at the bottom")

    let session = try XCTUnwrap(controller.workspace.selectedSession)
    session.apply(approvalRequest())
    XCTAssertNotNil(session.pendingApproval)
    controller.reload()
    settle(scrollView, textView)
    XCTAssertTrue(
      isAtBottom(scrollView, textView),
      "the card arrived: \(scrollView.documentVisibleRect) in \(textView.frame.height)")
  }

  /// A long reply landing at once — a tool result, a message that never streamed — is scrolled
  /// to before it is laid out, and the end it scrolls to is TextKit 2's estimate of where the
  /// end is. Once the real layout arrives the document is a different height, and the reader who
  /// was placed at the estimated end is that error away from the real one.
  @MainActor
  func testTheBottomStaysTheBottomWhenALongReplyLands() throws {
    let (controller, window, scrollView, textView) = try openWindow()
    defer { window.close() }
    XCTAssertTrue(isAtBottom(scrollView, textView), "a session opens at the bottom")

    let session = try XCTUnwrap(controller.workspace.selectedSession)
    let reply = (0..<400).map {
      "reply line \($0) with enough words in it to wrap once or twice in this column, and then some"
    }
    .joined(separator: "\n\n")
    session.apply(
      ClaudeEvent(
        type: "assistant", subtype: nil,
        payload: ["message": ["content": [["type": "text", "text": reply]]]]))
    settle(scrollView, textView)
    let before = textView.frame.height
    TranscriptScrollAnchor.layOutWholeDocument(of: textView)
    XCTAssertTrue(
      isAtBottom(scrollView, textView),
      "the reply landed: \(scrollView.documentVisibleRect) in \(textView.frame.height) (was \(before))"
    )
  }

  /// Switching to a session that is already waiting on you is where the same thing showed first:
  /// the column scrolls to the end while attaching and hangs the card afterwards, so the end it
  /// scrolled to is the end of a taller pane than the one left once the card is up.
  @MainActor
  func testSwitchingToASessionWithACardLandsAtTheBottom() throws {
    let (controller, window, scrollView, textView) = try openWindow()
    defer { window.close() }
    let workspace = controller.workspace
    let first = try XCTUnwrap(workspace.selectedSession)
    let other = try XCTUnwrap(
      workspace.sessions.first { $0.worktreeID == first.worktreeID && $0.id != first.id })
    fill(other)
    other.apply(approvalRequest())
    XCTAssertNotNil(other.pendingApproval)

    workspace.selectedSessionID = other.id
    controller.reload()
    settle(scrollView, textView)
    XCTAssertTrue(
      isAtBottom(scrollView, textView),
      "switched: \(scrollView.documentVisibleRect) in \(textView.frame.height)")
  }

  /// A conversation long enough that opening it renders the tail and leaves the rest on disk, so
  /// scrolling up pulls a slice in above the reader — the transcript hukan actually opens.
  @MainActor
  private func openWindowOnALazyConversation() throws -> (
    NSWindow, NSScrollView, NSTextView, URL
  ) {
    let worktree = URL(fileURLWithPath: "/repo/hukan")
    let workspace = RailPreviewTests.sampleWorkspace()
    let session = try XCTUnwrap(workspace.sessions.first)
    var lines: [String] = []
    var parent = "root"
    for index in 0..<900 {
      let uuid = "u\(index)"
      lines.append(
        "{\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"parentUuid\":\"\(parent)\","
          + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":"
          + "\"record \(index) — a line of conversation long enough to wrap in this column\"}]}}")
      parent = uuid
    }
    let url = ClaudeSessionStore.transcriptURL(id: session.id, worktree: worktree)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

    let controller = WorkspaceWindowController(workspace: workspace)
    let window = try XCTUnwrap(controller.window)
    workspace.selectedWorktreeID = session.worktreeID
    workspace.selectedSessionID = session.id
    controller.reload()
    window.setFrame(NSRect(x: 0, y: -4000, width: 1600, height: 800), display: true)
    window.makeKeyAndOrderFront(nil)
    controller.arrangeColumnsIfNeeded()
    // The history is read off disk on a background queue; the pane lands at the bottom of it.
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    let textView = try XCTUnwrap(transcriptTextView(in: try XCTUnwrap(window.contentView)))
    return (window, try XCTUnwrap(textView.enclosingScrollView), textView, url)
  }

  /// Scrolling up until the next slice of history lands must leave the reader on the line they
  /// were reading — the slice goes in above them, and their place moves down with it.
  @MainActor
  func testTheReadersLineHoldsWhenEarlierConversationLands() throws {
    let (window, scrollView, textView, url) = try openWindowOnALazyConversation()
    defer {
      window.close()
      try? FileManager.default.removeItem(at: url)
    }
    let height = textView.frame.height
    XCTAssertGreaterThan(height, 4000, "the rendered tail is a long transcript")

    // Walk up towards the top, which is what asks for the slice before this one.
    var landed = false
    for _ in 0..<80 {
      let line = topLine(of: scrollView, textView)
      let before = textView.frame.height
      scrollView.contentView.scroll(
        to: NSPoint(x: 0, y: scrollView.documentVisibleRect.minY - 300))
      scrollView.reflectScrolledClipView(scrollView.contentView)
      let asked = topLine(of: scrollView, textView)
      RunLoop.current.run(until: Date().addingTimeInterval(0.08))
      if textView.frame.height > before {
        landed = true
        XCTAssertEqual(
          topLine(of: scrollView, textView), asked,
          "a slice landed above the reader and took their line with it (from \(line))")
      }
      if scrollView.documentVisibleRect.minY <= 0 { break }
    }
    XCTAssertTrue(landed, "the walk up never pulled a slice in — nothing was under test")
  }
}
