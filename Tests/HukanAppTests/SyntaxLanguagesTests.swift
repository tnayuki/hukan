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
