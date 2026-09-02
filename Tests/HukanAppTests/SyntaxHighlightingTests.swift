import XCTest

@testable import Hukan

/// The spans a file's highlighting is built from. The cases that matter are the ones that
/// silently go wrong: offsets around multi-byte characters, and files no grammar covers.
final class SyntaxHighlightingTests: XCTestCase {
  /// Every span has to land on the text it was computed for. An em dash is one UTF-16 unit
  /// but three UTF-8 bytes, so a byte offset mistaken for a character offset drifts from here
  /// on — and drifts further with each one, which is exactly how it looked in the app: colors
  /// sliding into the middle of words further down the file.
  func testSpansStayAlignedAcrossMultibyteCharacters() {
    let source = """
      /// Usage — the plan's rolling window.
      let label = "session"
      /// Another — comment.
      func fetch() -> Bool { return true }
      """
    let text = source as NSString
    let spans = SyntaxHighlighting.spans(in: source, forPath: "usage.swift")
    let words = spans.map { text.substring(with: $0.range) }
    // The keywords past both em dashes, spelled whole.
    XCTAssertTrue(words.contains("let"), "spans: \(words)")
    XCTAssertTrue(words.contains("func"), "spans: \(words)")
    XCTAssertTrue(words.contains("return"), "spans: \(words)")
    XCTAssertTrue(words.contains("Bool"), "spans: \(words)")
    // And nothing ran off the end of the document.
    for span in spans {
      XCTAssertLessThanOrEqual(NSMaxRange(span.range), text.length)
    }
  }

  func testCommentsAreOneSpanNotWords() {
    // The symptom in the app was words *inside* a comment picking up keyword colors.
    let source = "/// return the window and the plan\nlet x = 1\n"
    let text = source as NSString
    let commentEnd = (source as NSString).range(of: "\n").location
    for span in SyntaxHighlighting.spans(in: source, forPath: "x.swift")
    where span.range.location < commentEnd {
      XCTAssertEqual(
        text.substring(with: span.range), "/// return the window and the plan",
        "a comment must colour as one span")
    }
  }

  func testUnknownExtensionRendersPlain() {
    XCTAssertFalse(SyntaxHighlighting.canHighlight(path: "notes.txt"))
    XCTAssertTrue(SyntaxHighlighting.spans(in: "let x = 1", forPath: "notes.txt").isEmpty)
  }

  func testHugeFileIsLeftPlain() {
    let huge = String(repeating: "let x = 1\n", count: 120_000)
    XCTAssertGreaterThan(huge.utf16.count, SyntaxHighlighting.sizeLimit)
    XCTAssertTrue(SyntaxHighlighting.spans(in: huge, forPath: "huge.swift").isEmpty)
  }

  /// Narrowing the query must not change the answer. What tree-sitter returns for a byte range
  /// is every match that *intersects* it, so a node enclosing the range still arrives and the
  /// nesting the spans are built from is the nesting the whole file would have given — which is
  /// the property the viewport window rides on, and the one a runtime bump could quietly break.
  func testANarrowedQueryAgreesWithTheWholeFile() throws {
    let source = String(
      repeating: """
        /// A comment about the window.
        func work(_ name: String) -> Int {
          let greeting = "hello \(name), how are you"
          return greeting.count  // counted
        }

        """, count: 40)
    let whole = SyntaxHighlighting.spans(in: source, forPath: "a.swift")
    XCTAssertFalse(whole.isEmpty)
    let window = NSRange(location: (source as NSString).length / 3, length: 900)
    let narrowed = SyntaxHighlighting.spans(in: source, forPath: "a.swift", within: window)
    XCTAssertLessThan(narrowed.count, whole.count, "the window did not narrow anything")
    // Everything the whole-file read found strictly inside the window, the narrowed one found
    // too — same range, same colour, same emphasis.
    let inside = whole.filter {
      $0.range.location >= window.location && NSMaxRange($0.range) <= NSMaxRange(window)
    }
    XCTAssertFalse(inside.isEmpty)
    for span in inside {
      XCTAssertTrue(
        narrowed.contains {
          $0.range == span.range && $0.color == span.color && $0.emphasis == span.emphasis
        }, "\(span.range) came out differently when the query was narrowed")
    }
  }

  /// The same for an injected language: a fence inside the window is coloured as the language it
  /// names, and one outside it is not parsed at all.
  func testANarrowedQuerySkipsFencesOutOfRange() throws {
    let fence = "```swift\nlet answer = \"forty two\"\n```\n\nsome prose here.\n\n"
    let source = String(repeating: fence, count: 30)
    let text = source as NSString
    let first = text.range(of: "forty two")
    let last = text.range(
      of: "forty two", options: .backwards, range: NSRange(location: 0, length: text.length))
    let window = NSRange(location: 0, length: NSMaxRange(first) + 10)
    let narrowed = SyntaxHighlighting.spans(in: source, forPath: "a.md", within: window)
    XCTAssertTrue(
      narrowed.contains { NSIntersectionRange($0.range, first).length > 0 },
      "the fence inside the window was not coloured")
    XCTAssertFalse(
      narrowed.contains { NSIntersectionRange($0.range, last).length > 0 },
      "a fence far outside the window was parsed anyway")
  }

  /// The same for an injection made of many pieces. A patch's hunk is one piece per line, joined
  /// and parsed as one — so a window over the middle of it has to place what comes back on the
  /// same lines the whole-file read placed it on, which is the join's map read backwards.
  func testANarrowedQueryAgreesWithTheWholeFileInAPatch() throws {
    let hunk = """
      diff --git a/a.swift b/a.swift
      --- a/a.swift
      +++ b/a.swift
      @@ -1,4 +1,4 @@
       func f() -> Int {
      -  let gone = "old"
      +  let added = "new"
         return 0
       }

      """
    let source = String(repeating: hunk, count: 20)
    let whole = SyntaxHighlighting.spans(in: source, forPath: "a.diff")
    XCTAssertFalse(whole.isEmpty)
    let window = NSRange(location: (source as NSString).length / 3, length: 400)
    let narrowed = SyntaxHighlighting.spans(in: source, forPath: "a.diff", within: window)
    XCTAssertLessThan(narrowed.count, whole.count, "the window did not narrow anything")
    let inside = whole.filter {
      $0.range.location >= window.location && NSMaxRange($0.range) <= NSMaxRange(window)
    }
    XCTAssertFalse(inside.isEmpty)
    for span in inside {
      XCTAssertTrue(
        narrowed.contains {
          $0.range == span.range && $0.color == span.color && $0.emphasis == span.emphasis
        }, "\(span.range) came out differently when the query was narrowed")
    }
  }

  /// The kept parse and the one-shot are one code path with the parse lifted out, so asking a
  /// held tree for a window has to answer exactly what asking from the text would. This is what
  /// a scroll rides on: the buffer has not moved, so nothing about the answer may move either.
  func testAKeptParseAnswersWhatAFreshOneWould() throws {
    let source = String(
      repeating: """
        /// A comment about the window.
        func work(_ name: String) -> Int {
          let greeting = "hello \(name), how are you"
          return greeting.count  // counted
        }

        """, count: 40)
    let parsed = try XCTUnwrap(SyntaxHighlighting.parse(source, forPath: "a.swift"))
    XCTAssertEqual(parsed.text, source)
    for window in [
      nil,
      NSRange(location: 0, length: 400),
      NSRange(location: (source as NSString).length / 3, length: 900),
    ] as [NSRange?] {
      let kept = SyntaxHighlighting.spans(of: parsed, within: window)
      let fresh = SyntaxHighlighting.spans(in: source, forPath: "a.swift", within: window)
      XCTAssertEqual(kept.count, fresh.count, "\(String(describing: window))")
      for (a, b) in zip(kept, fresh) {
        XCTAssertEqual(a.range, b.range)
        XCTAssertEqual(a.color, b.color)
        XCTAssertEqual(a.emphasis, b.emphasis)
      }
    }
  }
}
