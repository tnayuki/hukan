import XCTest

@testable import Hukan

/// `Transcript.markdownStream` renders a streaming run incrementally — the settled prefix once,
/// only the open tail per delta. Its whole claim is equivalence: at every flush, what has been
/// emitted so far must equal `Transcript.markdown` of the whole source so far, whatever the
/// chunking. These tests hammer that claim across every block kind and a range of chunkings,
/// including the reach-back cases (a line of cells that a later delimiter row crowns as a table
/// header, a quote run that a later line extends) that decide where the cut may fall.
final class StreamingMarkdownTests: XCTestCase {

  private static let corpus: [String] = [
    // Plain prose, multi-line, with inline markup and CJK.
    "First paragraph with **bold** and `code`.\nSecond line.\n\n次の段落は日本語で、**強調**を含む。\n",
    // A closed fence between prose, and one with a language tag.
    "Before.\n```swift\nfunc f() {\n  return\n}\n```\nAfter.\n",
    // An unclosed fence at the end — swallowed to the end, still growing.
    "Intro.\n```\nline one\nline two\nline three",
    // A fence closed and reopened.
    "```\na\n```\nmiddle\n```\nb\n",
    // A complete table with prose on both sides.
    "Above.\n| one | two |\n|---|---|\n| a | b |\n| c | d |\nBelow.\n",
    // A table still growing at the end.
    "Above.\n| one | two |\n|---|---|\n| a | b |\n| c | d |",
    // The reach-back: a lone line of cells whose delimiter row arrives later.
    "text\n| head one | head two |\n|---|---|\n| r1 | r2 |\n",
    // A line of cells that never becomes a table.
    "text\n| just | pipes |\nplain line\n",
    // Quote runs: closed by prose, and open at the end.
    "> quoted one\n> quoted two\n\nprose\n> trailing quote\n> still going",
    // Headings, rules, bullets (nested), ordered lists, blank runs.
    "# Title\n\nSome text.\n\n---\n\n- one\n- two\n  - nested\n1. first\n2. second\n\n## Sub\ntail\n",
    // Fence markers as content: a fence whose body contains pipes and quote markers.
    "```\n| not | a | table |\n> not a quote\n```\ndone\n",
    // No trailing newline at all.
    "single line without newline",
    // Ends exactly at a newline.
    "one\ntwo\n",
    // Empty-ish: blank lines only.
    "\n\n\n",
  ]

  /// Every chunking a stream might arrive in: single characters, small uneven chunks, big ones.
  private static let chunkSizes = [1, 3, 7, 16, 64, 1024]

  func testIncrementalRenderMatchesWholeRenderAtEveryFlush() {
    for source in Self.corpus {
      for size in Self.chunkSizes {
        var state = Transcript.MarkdownStreamState()
        let stable = NSMutableAttributedString()
        var consumed = ""
        var rest = Substring(source)
        while !rest.isEmpty {
          let chunk = String(rest.prefix(size))
          rest = rest.dropFirst(size)
          consumed += chunk
          let (settled, volatile) = Transcript.markdownStream(&state, appending: chunk)
          stable.append(settled)
          let incremental = NSMutableAttributedString(attributedString: stable)
          incremental.append(volatile)
          assertRendersEqual(
            incremental, Transcript.markdown(consumed),
            "chunk size \(size), after \(consumed.count) chars of: \(source.prefix(40))…")
        }
      }
    }
  }

  /// The settled prefix must actually settle: a long prose stream may not keep everything
  /// volatile, or the incremental path would still be the O(n²) it exists to remove.
  func testStablePrefixGrows() {
    var state = Transcript.MarkdownStreamState()
    let stable = NSMutableAttributedString()
    for index in 0..<100 {
      let (settled, _) = Transcript.markdownStream(
        &state, appending: "paragraph number \(index) with some words in it\n")
      stable.append(settled)
    }
    XCTAssertGreaterThan(
      stable.length, 0, "a hundred closed paragraphs must not all still be volatile")
    XCTAssertLessThan(
      state.rest.count, 100,
      "the carried tail must stay the open run, not the whole message")
  }

  /// An open fence is the one construct that legitimately keeps growing; the carry must be the
  /// fence, not everything before it.
  func testOpenFenceStaysVolatileAndProseBeforeItSettles() {
    var state = Transcript.MarkdownStreamState()
    let (settled, _) = Transcript.markdownStream(
      &state, appending: "prose before\n```\ninside\n")
    XCTAssertTrue(settled.string.contains("prose before"))
    XCTAssertTrue(state.rest.hasPrefix("```"))
  }

  // MARK: - The session's pooled flush

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

  /// Deltas pool until a flush; a flush lands them rendered, exactly as the whole-run render
  /// would have.
  func testPooledDeltasLandOnFlush() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(delta("Hello **wo"))
    session.apply(delta("rld** and more.\nSecond"))
    session.flushStreamRender()
    XCTAssertTrue(
      session.transcript.string.contains("Hello world and more."),
      "the flushed run renders as markdown, bold resolved")
    session.apply(delta(" line."))
    session.flushStreamRender()
    XCTAssertTrue(session.transcript.string.contains("Second line."))
  }

  /// The buffered `assistant` event replaces the streamed span even when deltas are still
  /// pooled — the entry flush puts them in first, so the close replaces one whole run.
  func testAssistantCloseReplacesPooledRun() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(delta("Hello"))
    session.apply(delta(" there"))
    session.apply(
      ClaudeEvent(
        type: "assistant", subtype: nil,
        payload: [
          "message": [
            "content": [["type": "text", "text": "Hello there"]]
          ]
        ]))
    XCTAssertEqual(
      session.transcript.string.components(separatedBy: "Hello there").count - 1, 1,
      "the close reformats the streamed span in place, never beside it")
  }

  // MARK: - Comparing renders

  /// Byte-for-byte equality, with two allowances `isEqual` cannot make: attribute values are
  /// compared by value per run (two renders build distinct but equal paragraph styles), and a
  /// table attachment by the markdown it carries (two renders build distinct instances).
  private func assertRendersEqual(
    _ a: NSAttributedString, _ b: NSAttributedString, _ context: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(a.string, b.string, "text diverged: \(context)", file: file, line: line)
    guard a.string == b.string else { return }
    var index = 0
    while index < a.length {
      var rangeA = NSRange()
      var rangeB = NSRange()
      let attributesA = a.attributes(at: index, effectiveRange: &rangeA)
      let attributesB = b.attributes(at: index, effectiveRange: &rangeB)
      XCTAssertEqual(
        Set(attributesA.keys.map(\.rawValue)), Set(attributesB.keys.map(\.rawValue)),
        "attribute keys diverged at \(index): \(context)", file: file, line: line)
      for (key, valueA) in attributesA {
        guard let valueB = attributesB[key] else { continue }
        if let tableA = valueA as? TableAttachment {
          XCTAssertEqual(
            tableA.markdown, (valueB as? TableAttachment)?.markdown,
            "table diverged at \(index): \(context)", file: file, line: line)
        } else {
          XCTAssertTrue(
            (valueA as AnyObject).isEqual(valueB),
            "\(key.rawValue) diverged at \(index): \(context)", file: file, line: line)
        }
      }
      index = min(NSMaxRange(rangeA), NSMaxRange(rangeB))
    }
  }
}
