import AppKit
import XCTest

@testable import Hukan

/// A bare URL in the transcript is a link. The rule has to stay narrow in both directions: every
/// address an agent actually writes has to be caught, and nothing that merely looks like one —
/// inside a code span, inside a fenced block, a filename with a dot — may turn blue.
final class AutolinkTests: XCTestCase {
  /// The links in a rendered string, as (text, URL) pairs in order.
  private func links(_ rendered: NSAttributedString) -> [(String, URL)] {
    var found: [(String, URL)] = []
    rendered.enumerateAttribute(
      .link, in: NSRange(location: 0, length: rendered.length), options: []
    ) { value, range, _ in
      guard let url = value as? URL else { return }
      found.append((rendered.attributedSubstring(from: range).string, url))
    }
    return found
  }

  func testABareURLBecomesALink() {
    // The shape that made this worth doing: what `gh pr create` answers with.
    let found = links(
      Transcript.markdown("Opened the PR: https://github.com/tnayuki/hukan/pull/12\n"))
    XCTAssertEqual(found.count, 1)
    XCTAssertEqual(found.first?.0, "https://github.com/tnayuki/hukan/pull/12")
    XCTAssertEqual(
      found.first?.1, URL(string: "https://github.com/tnayuki/hukan/pull/12"))
  }

  func testTrailingPunctuationStaysInTheSentence() {
    for (line, want) in [
      ("See https://example.com/a.", "https://example.com/a"),
      ("See (https://example.com/a)", "https://example.com/a"),
      ("見てね → https://example.com/a。", "https://example.com/a"),
      ("https://example.com/a_(b) and more", "https://example.com/a_(b)"),
    ] {
      let found = links(Transcript.markdown(line + "\n"))
      XCTAssertEqual(found.first?.0, want, "in: \(line)")
    }
  }

  func testMarkdownLinksAreUntouched() {
    let found = links(Transcript.markdown("A [link](https://example.com) here\n"))
    XCTAssertEqual(found.count, 1)
    XCTAssertEqual(found.first?.0, "link", "the label stays the text, not the URL")
    XCTAssertEqual(found.first?.1, URL(string: "https://example.com"))
  }

  /// Code is quoted, not followed. A URL in a snippet is text being discussed.
  func testCodeIsNotLinked() {
    XCTAssertTrue(links(Transcript.markdown("Run `curl https://example.com/a` now\n")).isEmpty)
    XCTAssertTrue(
      links(Transcript.markdown("```\ncurl https://example.com/a\n```\n")).isEmpty)
  }

  /// No `www.`-style guessing: a filename with a dot is the thing that would start being caught,
  /// and the transcript is full of them.
  func testOnlyAnExplicitSchemeCounts() {
    XCTAssertTrue(links(Transcript.markdown("edited Model.swift and www.example.com\n")).isEmpty)
  }

  /// The fold link and a real link share one attribute, so the delegate's first job is telling
  /// them apart: a fold toggles and never leaves the transcript, a real URL goes to whoever asked
  /// for it, and with nobody asking it falls through to AppKit and the default browser.
  func testTheClickDelegateSendsRealLinksOutAndFoldsFolds() {
    let (_, textView) = makeTranscriptTextView()
    textView.textStorage?.setAttributedString(
      Transcript.markdown("Opened https://example.com/pr/1\n"))
    guard let delegate = transcriptClickDelegate(of: textView) else {
      return XCTFail("the transcript's text view has no click delegate")
    }
    var opened: [URL] = []
    delegate.onOpenURL = { url in
      opened.append(url)
      return true
    }

    XCTAssertTrue(
      delegate.textView(textView, clickedOnLink: URL(string: "https://example.com/pr/1")!, at: 7))
    XCTAssertEqual(opened, [URL(string: "https://example.com/pr/1")!])

    // The fold link is not a hyperlink and must never reach the desk.
    _ = delegate.textView(textView, clickedOnLink: Transcript.toolCallLinkURL, at: 0)
    XCTAssertEqual(opened.count, 1, "the fold link stayed in the transcript")
  }

  /// The fold link and a real link share the `.link` attribute — the delegate tells them apart by
  /// value — so a plan whose text contains a URL must keep both working.
  func testAnOpenedPlanKeepsBothKindsOfLink() {
    let run = Transcript.toolCallExpandedRun(
      ToolCallToken(
        name: "ExitPlanMode", summary: "", full: "Read https://example.com/spec first",
        rendersMarkdown: true))
    let all = links(run)
    XCTAssertTrue(all.contains { $0.1 == Transcript.toolCallLinkURL }, "the fold header survives")
    XCTAssertTrue(
      all.contains { $0.1 == URL(string: "https://example.com/spec") }, "and so does the URL")
  }
}
