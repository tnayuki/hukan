import AppKit
import XCTest

@testable import Hukan

/// The copy mark at a code slab's top-right corner. It is drawn rather than typed, so what it
/// copies rides in an attribute and where it is hit is geometry — both of which are checkable
/// offscreen, on a private pasteboard so the test never touches the real clipboard.
final class CodeCopyTests: XCTestCase {
  override class func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  /// A fence and an opened tool call are the same slab, so both carry the code — and neither
  /// carries the trailing newline that would run the command rather than offer it.
  func testBothKindsOfCodeSlabCarryTheirCode() throws {
    let fenced = Transcript.markdown(
      """
      Run this:

      ```
      cloudflared tunnel --url http://127.0.0.1:8791
      ```
      """)
    let code = try XCTUnwrap(blocks(in: fenced).first)
    XCTAssertEqual(code, "cloudflared tunnel --url http://127.0.0.1:8791")
    XCTAssertEqual(blocks(in: fenced).count, 1, "only the fence is a slab, not the prose")

    let command = "echo one\necho two"
    let (_, textView) = makeTranscriptDocumentView()
    textView.setContent(Transcript.toolUse(name: "Bash", input: ["command": command]))
    let header = try XCTUnwrap(textView.foldStates().folded.first)
    XCTAssertTrue(textView.toggleFold(at: header))
    XCTAssertEqual(
      blocks(in: textView.attributedSubstring(NSRange(location: 0, length: textView.length))),
      [command], "the opened tool call's body is a slab too")
  }

  /// A fence you typed is not a slab: the message's own block styling has written over it.
  func testAFenceInsideAMessageIsNotMarked() {
    XCTAssertEqual(
      blocks(
        in: Transcript.userMessage(
          """
          try this

          ```
          make test
          ```
          """, forkAnchor: "a1")), [],
      "the message's `…` owns that corner, and there is no code slab under it")
  }

  /// The mark is hit exactly where it is drawn: the trailing room of the slab's first line.
  func testTheMarkIsHitWhereItIsDrawn() throws {
    let (scrollView, textView) = makeTranscriptDocumentView()
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.setContent(
      Transcript.markdown(
        """
        ```
        first line
        second line
        third line
        ```
        """))

    var range = NSRange(location: 0, length: 0)
    _ = textView.attribute(Transcript.copyableCodeKey, at: 2, longestEffectiveRange: &range)
    let line = try XCTUnwrap(textView.blockFirstLineFrame(of: range))
    let middle = line.midY
    let right = textView.bounds.width - textView.textContainerInset.width

    let hit = try XCTUnwrap(textView.copyMark(at: NSPoint(x: right - 15, y: middle)))
    XCTAssertEqual(hit.code, "first line\nsecond line\nthird line")
    XCTAssertNil(
      textView.copyMark(at: NSPoint(x: 30, y: middle)), "the code itself is not the mark")
    XCTAssertNil(
      textView.copyMark(at: NSPoint(x: right - 15, y: middle + line.height * 2)),
      "nor is the trailing edge of a later line — the mark is at the corner")

    let pasteboard = NSPasteboard(name: NSPasteboard.Name("hukan.code-copy-test"))
    textView.copyCode(hit.code, of: hit.range, to: pasteboard)
    XCTAssertEqual(pasteboard.string(forType: .string), hit.code)
  }

  /// A long command wraps, and the mark stays on its first *line* — a layout fragment is a
  /// paragraph, so taking its middle put the mark halfway down the block, which is where the
  /// message's `…` lives and the whole thing the corner was chosen against.
  func testTheMarkStaysOnTheFirstLineOfAWrappedCommand() throws {
    let (scrollView, textView) = makeTranscriptDocumentView()
    scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
    textView.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
    let command =
      "nohup cloudflared tunnel --url http://127.0.0.1:8791 >/tmp/cf-tunnel.log 2>&1 & sleep 12"
    textView.setContent(Transcript.markdown("```\n\(command)\n```"))

    var range = NSRange(location: 0, length: 0)
    _ = textView.attribute(Transcript.copyableCodeKey, at: 2, longestEffectiveRange: &range)
    // The command's own paragraph: the slab opens with its margin and pad lines.
    let paragraph = NSRange(location: range.location + 2, length: command.utf16.count)
    let rows = Set(textView.rects(for: paragraph).map { $0.minY.rounded() })
    XCTAssertGreaterThan(rows.count, 1, "the fixture has to wrap for this to say anything")
    let line = try XCTUnwrap(textView.blockFirstLineFrame(of: range))
    let block = try XCTUnwrap(textView.blockFrame(of: range))
    let right = textView.bounds.width - textView.textContainerInset.width - 15

    XCTAssertNotNil(
      textView.copyMark(at: NSPoint(x: right, y: line.midY)),
      "the mark is beside the command's first line")
    XCTAssertNil(
      textView.copyMark(at: NSPoint(x: right, y: block.midY)),
      "and not at the middle of the paragraph it wrapped into")
  }

  /// The pointer says the mark is a control: an arrow over it, the I-beam everywhere else. Both
  /// halves matter — the text view answers with the I-beam for the whole column, and the hand it
  /// shows over a link comes from the same call, so the mark may not take that answer away from
  /// anywhere but its own rectangle. Pinned with the tracking area that makes the call reachable
  /// at all: one, over the whole view, carrying `.cursorUpdate`.
  func testThePointerIsAnArrowOnTheMarkAndAnIBeamOffIt() throws {
    let (scrollView, textView) = makeTranscriptDocumentView()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    // Let go of it before the next class in this worker process runs: an NSWindow left standing
    // is one the reader tests' own windows then share a process with. Closing it must not release
    // it as well — that is `isReleasedWhenClosed`'s default for a window built by hand, and it
    // over-releases the one ARC is still holding here.
    window.isReleasedWhenClosed = false
    window.contentView = scrollView
    defer {
      window.contentView = nil
      window.close()
    }
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.setContent(Transcript.markdown("```\nfirst line\nsecond line\n```"))
    // In a window and laid out, but never ordered on screen: the tracking areas are built here,
    // and showing the window takes key away from whatever else the parallel run has up — which
    // is enough to move the reader tests' own windows out from under them.
    textView.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    textView.updateTrackingAreas()

    let area = try XCTUnwrap(textView.trackingAreas.first)
    XCTAssertTrue(
      area.options.contains(.cursorUpdate) && area.rect.contains(textView.bounds),
      "the whole view asks for cursor updates, which is what reaches the override")

    var range = NSRange(location: 0, length: 0)
    _ = textView.attribute(Transcript.copyableCodeKey, at: 2, longestEffectiveRange: &range)
    let line = try XCTUnwrap(textView.blockFirstLineFrame(of: range))
    let onMark = NSPoint(
      x: textView.bounds.width - textView.textContainerInset.width - 15, y: line.midY)

    func cursorUpdate(at point: NSPoint) -> NSEvent {
      NSEvent.enterExitEvent(
        with: .cursorUpdate, location: textView.convert(point, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, trackingNumber: 1, userData: nil)!
    }

    func mouseMoved(at point: NSPoint) -> NSEvent {
      NSEvent.mouseEvent(
        with: .mouseMoved, location: textView.convert(point, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 2, clickCount: 0, pressure: 0)!
    }

    NSCursor.iBeam.set()
    textView.cursorUpdate(with: cursorUpdate(at: onMark))
    XCTAssertEqual(NSCursor.current, NSCursor.arrow, "entering on the mark is an arrow")

    NSCursor.arrow.set()
    textView.cursorUpdate(with: cursorUpdate(at: NSPoint(x: 40, y: onMark.y)))
    XCTAssertEqual(NSCursor.current, NSCursor.iBeam, "the code beside it is still text")

    // And the step from the code onto the mark, which is the one `cursorUpdate` never sees: the
    // view's tracking area covers the whole column, so nothing re-enters it on the way over.
    NSCursor.iBeam.set()
    textView.mouseMoved(with: mouseMoved(at: onMark))
    XCTAssertEqual(NSCursor.current, NSCursor.arrow, "walking onto the mark is an arrow too")
  }

  private func blocks(in storage: NSAttributedString) -> [String] {
    var found: [String] = []
    storage.enumerateAttribute(
      Transcript.copyableCodeKey, in: NSRange(location: 0, length: storage.length)
    ) { value, _, _ in
      if let code = value as? String { found.append(code) }
    }
    return found
  }
}
