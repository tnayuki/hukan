import AppKit
import XCTest

@testable import Hukan

/// Round-trip check of the tool-call fold: folded line → opened block → folded line, driven
/// through the click delegate exactly as a link click would. Both states are plain text, so the
/// whole interaction is checkable offscreen — no window, no view realization. (This started life
/// as a `--test-toolfold` flag on the app binary; anything assertable belongs here instead.)
final class ToolFoldTests: XCTestCase {
  override class func setUp() {
    super.setUp()
    // Parts of the transcript machinery touch NSApplication.shared; make sure it exists.
    _ = NSApplication.shared
  }

  func testFoldRoundTripThroughClickDelegate() throws {
    let (_, textView) = makeTranscriptTextView()
    let storage = textView.textStorage!
    let command = "echo one\necho two\necho three"
    storage.setAttributedString(Transcript.toolUse(name: "Bash", input: ["command": command]))

    let delegate = try XCTUnwrap(transcriptClickDelegate(of: textView))
    func headerIndex(expanded: Bool) -> Int? {
      var found: Int?
      storage.enumerateAttribute(
        Transcript.toolTokenKey,
        in: NSRange(location: 0, length: storage.length)
      ) { value, range, _ in
        guard value is ToolCallToken else { return }
        let isExpanded =
          storage.attribute(
            Transcript.toolExpandedKey, at: range.location,
            effectiveRange: nil) != nil
        if isExpanded == expanded { found = range.location }
      }
      return found
    }

    // Folded by default: the ▸ line shows the summary, not the whole command.
    XCTAssertTrue(storage.string.contains("▸ Bash"), "folded line rendered")
    XCTAssertFalse(storage.string.contains("echo three"), "folded line hides the body")

    // Expand through the click delegate, exactly as clickedOnLink does.
    let folded = try XCTUnwrap(headerIndex(expanded: false), "folded header found")
    _ = delegate.textView(textView, clickedOnLink: Transcript.toolCallLinkURL, at: folded)
    XCTAssertTrue(storage.string.contains("▾ Bash"), "expands to an open header")
    XCTAssertTrue(storage.string.contains("echo three"), "expanded block shows the whole command")
    XCTAssertFalse(storage.string.contains("▸ Bash"), "folded line is gone while open")

    // Collapse from the open header, same path.
    let expanded = try XCTUnwrap(headerIndex(expanded: true), "expanded header found")
    _ = delegate.textView(textView, clickedOnLink: Transcript.toolCallLinkURL, at: expanded)
    XCTAssertTrue(storage.string.contains("▸ Bash"), "folds back to the ▸ line")
    XCTAssertFalse(storage.string.contains("echo three"), "body hidden again")
    XCTAssertNil(headerIndex(expanded: true), "no stray expanded marker remains")

    // A fast second click arrives as clickCount 2. Right after a toggle it must be read as
    // another toggle (the collapse above just recorded one), not a word selection.
    let transcriptView = try XCTUnwrap(textView as? TranscriptTextView)
    let doubleClick = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
        eventNumber: 1, clickCount: 2, pressure: 1), "double-click event synthesized")
    XCTAssertTrue(
      transcriptView.retoggleFold(for: doubleClick) && storage.string.contains("▾ Bash"),
      "double-click retoggles instead of selecting")

    // Long after the interval, the same second click is selection again — not consumed.
    let lateClick = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime + NSEvent.doubleClickInterval + 1,
        windowNumber: 0, context: nil, eventNumber: 2, clickCount: 2, pressure: 1))
    XCTAssertFalse(
      transcriptView.retoggleFold(for: lateClick), "a late double-click is not consumed")
  }

  /// An ExitPlanMode plan is a compact foldable record: a "Here is Claude's plan:" one-liner (no
  /// mechanical tool name, no preview) that opens to the whole plan and folds back.
  func testPlanFoldsToOneLinerAndRoundTrips() throws {
    let (_, textView) = makeTranscriptTextView()
    let storage = textView.textStorage!
    let plan = (1...12).map { "- item \($0)" }.joined(separator: "\n")
    storage.setAttributedString(Transcript.toolUse(name: "ExitPlanMode", input: ["plan": plan]))

    let delegate = try XCTUnwrap(transcriptClickDelegate(of: textView))
    func headerIndex(expanded: Bool) -> Int? {
      var found: Int?
      storage.enumerateAttribute(
        Transcript.toolTokenKey,
        in: NSRange(location: 0, length: storage.length)
      ) { value, range, _ in
        guard value is ToolCallToken else { return }
        let isExpanded =
          storage.attribute(
            Transcript.toolExpandedKey, at: range.location,
            effectiveRange: nil) != nil
        if isExpanded == expanded { found = range.location }
      }
      return found
    }

    // Folded: just the header, no plan body and no mechanical "ExitPlanMode".
    XCTAssertTrue(storage.string.contains("▸ Here is Claude's plan:"), "folded plan header")
    XCTAssertFalse(storage.string.contains("ExitPlanMode"), "the tool name is never shown")
    XCTAssertFalse(storage.string.contains("item 1"), "the plan body is folded away")

    // Open it: the whole plan shows.
    let folded = try XCTUnwrap(headerIndex(expanded: false), "folded header found")
    _ = delegate.textView(textView, clickedOnLink: Transcript.toolCallLinkURL, at: folded)
    XCTAssertTrue(storage.string.contains("▾ Here is Claude's plan:"), "opens to a ▾ header")
    XCTAssertTrue(storage.string.contains("item 12"), "the whole plan shows when opened")

    // Collapse back to the one-liner.
    let expanded = try XCTUnwrap(headerIndex(expanded: true), "expanded header found")
    _ = delegate.textView(textView, clickedOnLink: Transcript.toolCallLinkURL, at: expanded)
    XCTAssertTrue(
      storage.string.contains("▸ Here is Claude's plan:"), "folds back to the one-liner")
    XCTAssertFalse(storage.string.contains("item 12"), "the plan is hidden again")
  }
}
