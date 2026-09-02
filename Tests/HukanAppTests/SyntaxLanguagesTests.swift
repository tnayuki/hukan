import XCTest

@testable import Hukan

/// Every vendored grammar, exercised end to end: the parser links, its queries load, and a
/// scrap of that language comes back coloured. A grammar that is compiled in but whose queries
/// never made it into the bundle fails here rather than in a file nobody opens for a month.
final class SyntaxLanguagesTests: XCTestCase {
  /// One line per language that has to colour something. The samples are deliberately plain —
  /// this pins that the wiring is live, not what any one theme makes of a token.
  private static let samples: [(path: String, source: String)] = [
    ("a.swift", "let name = \"x\"  // comment\nfunc f() -> Bool { true }\n"),
    ("a.ts", "const x: number = 1\nfunction f(): void {}\n"),
    ("a.tsx", "const App = () => <div className=\"x\">hi</div>\n"),
    ("a.js", "const x = 1\nfunction f() { return null }\n"),
    ("a.py", "def f(x):\n    return \"y\"  # comment\n"),
    ("a.rb", "def f(x)\n  \"y\" # comment\nend\n"),
    ("a.rs", "fn main() { let x: u32 = 1; }\n"),
    ("a.go", "package main\nfunc main() { var x int = 1 }\n"),
    ("a.c", "#include <stdio.h>\nint main(void) { return 0; }\n"),
    ("a.h", "struct T { int x; };\n"),
    ("a.cpp", "namespace n { class T { public: int x; }; }\n"),
    ("a.cs", "class T { public int X => 1; }\n"),
    ("a.sh", "#!/bin/sh\nfor f in *.c; do echo \"$f\"; done\n"),
    ("a.json", "{\"a\": 1, \"b\": [true, null]}\n"),
    ("a.yml", "key: value\nlist:\n  - one\n"),
    ("a.md", "# Heading\n\nsome text\n\n```swift\nlet x = 1\n```\n"),
    (
      "a.diff",
      """
      diff --git a/a.swift b/a.swift
      index 1111111..2222222 100644
      --- a/a.swift
      +++ b/a.swift
      @@ -1,3 +1,3 @@
       let kept = 0
      -let gone = 1
      +let added = 2
      """
    ),
  ]

  func testEveryVendoredLanguageColours() {
    for (path, source) in Self.samples {
      XCTAssertTrue(
        SyntaxHighlighting.canHighlight(path: path), "\(path): no grammar claims this extension")
      let spans = SyntaxHighlighting.spans(in: source, forPath: path)
      XCTAssertFalse(spans.isEmpty, "\(path): parsed, but nothing came back coloured")
      for span in spans {
        XCTAssertGreaterThan(span.range.length, 0, "\(path): empty span")
        XCTAssertLessThanOrEqual(
          NSMaxRange(span.range), (source as NSString).length, "\(path): span past the end")
      }
    }
  }

  /// A header could be either language and the extension cannot say, so it goes to the one that
  /// reads both — C++, whose grammar extends C's.
  func testHeadersGoToTheGrammarThatReadsBoth() {
    XCTAssertFalse(SyntaxHighlighting.spans(in: "struct T { int x; };\n", forPath: "a.h").isEmpty)
    XCTAssertFalse(
      SyntaxHighlighting.spans(in: "template <class T> class A {};\n", forPath: "a.h").isEmpty,
      "a C++ header has to read too, which is the whole reason .h is not C")
  }

  /// A patch says what its payload is by naming the file it patches, so the lines of a hunk have
  /// to come back coloured as *that* language — Swift's `func` is a keyword and the diff grammar
  /// has no idea of one.
  func testAPatchIsColouredByTheLanguageItPatches() {
    let source = """
      diff --git a/a.swift b/a.swift
      index 1111111..2222222 100644
      --- a/a.swift
      +++ b/a.swift
      @@ -1,4 +1,4 @@
       func f() -> Int {
      -  let gone = "old"
      +  let added = "new"
         return 0
       }
      """
    let text = source as NSString
    let coloured = Set(
      SyntaxHighlighting.spans(in: source, forPath: "a.diff").map { text.substring(with: $0.range) }
    )
    XCTAssertTrue(coloured.contains("func"), "the payload was not read as Swift")
    XCTAssertTrue(coloured.contains("let"), "the payload was not read as Swift")
    // Both sides: the addition rule builds the file as it will be, the deletion rule as it was.
    // Swift's grammar captures a string's quotes apart from what is between them, so the content
    // is what to look for — the two sides differ in nothing else.
    XCTAssertTrue(coloured.contains("new"), "the added line was not coloured")
    XCTAssertTrue(coloured.contains("old"), "the removed line was not coloured")
    // The frame is still the diff's own.
    XCTAssertTrue(coloured.contains("@@ -1,4 +1,4 @@"))
  }

  /// The lines of a hunk are one injection, not one each. A grammar handed a single line gets
  /// its strings and comments wrong at both ends, so what is parsed is the lines joined — with
  /// each marker taken off and each newline taken back, which is what `#offset!` says and what
  /// makes the join read as a file. A comment opened on one line and closed on the next is the
  /// cheapest proof: line by line, neither half is a comment.
  func testAHunksLinesAreParsedTogether() {
    let source = """
      diff --git a/a.swift b/a.swift
      --- a/a.swift
      +++ b/a.swift
      @@ -1,3 +1,3 @@
      +/* opened here
      +   and closed here */
      +let after = 1
      """
    let text = source as NSString
    let spans = SyntaxHighlighting.spans(in: source, forPath: "a.diff")
    XCTAssertTrue(
      spans.contains {
        text.substring(with: $0.range).contains("and closed here */")
          && $0.color == .secondaryLabelColor
      }, "the second line of the comment was not read as part of it")
    XCTAssertTrue(
      spans.contains { text.substring(with: $0.range) == "let" },
      "the line after the comment was not read as code")
  }

  /// Only a patch carrying the `diff` line it was produced by builds the hunks the injection
  /// query reads, and that form is also the one that puts a timestamp after each filename — a
  /// tab and then the time, which is where the format says the name ends. Read it whole and the
  /// extension is the clock's.
  func testAPatchsFilenameStopsAtItsTimestamp() {
    let source = """
      diff -u a.py b.py
      --- a.py\t2026-09-02 10:00:00
      +++ b.py\t2026-09-02 10:01:00
      @@ -1,2 +1,2 @@
      -x = 'old'
      +y = "new"
      """
    let text = source as NSString
    let coloured = Set(
      SyntaxHighlighting.spans(in: source, forPath: "a.diff").map { text.substring(with: $0.range) }
    )
    XCTAssertTrue(coloured.contains("\"new\""), "the payload was not read as Python")
    XCTAssertTrue(coloured.contains("'old'"), "the payload was not read as Python")
  }

  /// A fenced block is another language, and the grammar says so in `injections.scm`. Its code
  /// has to come back coloured by *that* language — Swift's `let` is a keyword, and the Markdown
  /// grammar has no idea of one.
  func testAFencedBlockIsColouredByTheLanguageItNames() {
    let source = "# Title\n\n```swift\nlet answer = 42\n```\n"
    let spans = SyntaxHighlighting.spans(in: source, forPath: "a.md")
    let text = source as NSString
    let coloured = Set(spans.map { text.substring(with: $0.range) })
    XCTAssertTrue(
      coloured.contains("let"), "the fence's Swift was not parsed as Swift: \(coloured)")
    XCTAssertTrue(coloured.contains("42"), "the fence's number was not coloured: \(coloured)")
  }

  /// The info string is whatever the writer typed, so the short spellings have to resolve too.
  func testAFenceNamedByAnExtensionResolves() {
    for fence in ["js", "javascript", "sh", "py"] {
      let source = "```\(fence)\nreturn 1\n```\n"
      XCTAssertFalse(
        SyntaxHighlighting.spans(in: source, forPath: "a.md").isEmpty,
        "```\(fence) reached no grammar")
    }
  }

  /// Markdown's own emphasis lives in a second grammar, injected into every paragraph.
  func testInlineMarkupIsColoured() {
    let source = "some **bold** and `code` here\n"
    let spans = SyntaxHighlighting.spans(in: source, forPath: "a.md")
    let text = source as NSString
    let coloured = Set(spans.map { text.substring(with: $0.range) })
    XCTAssertTrue(coloured.contains("`code`"), "inline code was not coloured: \(coloured)")
  }

  /// A language an injection names but hukan does not vendor is skipped, not a crash.
  func testAFenceInALanguageWeDoNotHaveIsLeftPlain() {
    let source = "```haskell\nmain = pure ()\n```\n"
    XCTAssertNoThrow(SyntaxHighlighting.spans(in: source, forPath: "a.md"))
  }

  func testAnUnknownExtensionIsLeftPlain() {
    XCTAssertFalse(SyntaxHighlighting.canHighlight(path: "a.zig"))
    XCTAssertTrue(SyntaxHighlighting.spans(in: "const x = 1;", forPath: "a.zig").isEmpty)
  }
}
