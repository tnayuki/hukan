import XCTest

@testable import Hukan

/// The commit tab's own rules: the file is the unit of work, a row is a line, and which side a
/// line is on is carried by its band and its gutter rather than by a character in front of the
/// code. What the pane *looks* like is `CommitSnapshotTests`; this is what it says.
final class CommitTabTests: XCTestCase {
  /// A commit's file list arrives whole; its diffs do not. A folded card costs nothing — the
  /// point of the file being the unit of work.
  @MainActor
  func testAFoldedCardCarriesNoneOfItsDiff() {
    let tab = CommitContentViewController()
    let sections = Self.detail.files.map { CommitSection(file: $0) }
    sections[0].diff = CommitDiffLoader.render(Self.fileDiff, file: Self.detail.files[0])
    tab.present(Self.detail, sections: sections)

    XCTAssertTrue(
      labels(in: tab.view).contains { $0.contains("Renderer.swift") }, "every file has a card")
    XCTAssertFalse(tab.renderedText.contains("struct Renderer {"), "and none of its text")

    tab.toggleSection(at: 0)
    XCTAssertTrue(tab.renderedText.contains("struct Renderer {"))
  }

  /// The gutter and the bands both index by line, so the row list and the body have to agree on
  /// how many lines there are — every row is exactly one paragraph.
  @MainActor
  func testEveryRowIsOneLineOfTheBody() {
    let diff = CommitDiffLoader.render(Self.fileDiff, file: Self.detail.files[0])

    XCTAssertEqual(diff.rows.count, diff.text.string.components(separatedBy: "\n").count - 1)
  }

  /// The `+`/`-` column is gone: which side a line is on is the band behind it and the blank half
  /// of the gutter, so the text of a row is the code and nothing else — which is what makes it
  /// copy as code.
  @MainActor
  func testALineIsBandedRatherThanPrefixed() {
    let diff = CommitDiffLoader.render(Self.fileDiff, file: Self.detail.files[0])

    XCTAssertTrue(diff.text.string.contains("  let name = \"commit\"\n"))
    XCTAssertFalse(diff.text.string.contains("+  let name"))
    XCTAssertEqual(band(of: "  let name = \"commit\"", in: diff.text), CommitTheme.addedBand)
    XCTAssertEqual(band(of: "  let name = \"old\"", in: diff.text), CommitTheme.removedBand)
    XCTAssertNil(band(of: "    return true", in: diff.text), "a context line is not banded")
    XCTAssertEqual(
      diff.rows.first, .hunk, "the hunk header is a row of its own, and carries no number")
    XCTAssertEqual(diff.rows[2], .code(old: 4, new: nil, kind: .removed))
    XCTAssertEqual(diff.rows[3], .code(old: nil, new: 4, kind: .added))
  }

  /// A file too large to show is one card saying so, not a wall in front of the commit: the rest
  /// of the files are still listed, and still open.
  @MainActor
  func testATooLargeFileIsOneCardWide() {
    let tab = CommitContentViewController()
    let sections = Self.detail.files.map { CommitSection(file: $0) }
    sections[0].isOpen = true
    sections[0].diff = LoadedFileDiff(note: .tooLarge(lines: 41200, bytes: 3_400_000))
    sections[1].isOpen = true
    sections[1].diff = CommitDiffLoader.render(Self.fileDiff, file: Self.detail.files[1])
    tab.present(Self.detail, sections: sections)

    let said = labels(in: tab.view)
    XCTAssertTrue(said.contains { $0.contains("41200 lines") && $0.contains("too large") })
    XCTAssertTrue(tab.renderedText.contains("struct Renderer {"), "the next file is unaffected")
  }

  /// Colours come from parsing the file, not the hunk — a keyword is a keyword on both sides of
  /// the diff, including on a line that only the parent had.
  @MainActor
  func testTheCodeInADiffIsHighlighted() {
    let diff = CommitDiffLoader.render(Self.fileDiff, file: Self.detail.files[0])
    let text = diff.text

    XCTAssertEqual(colour(of: "struct", in: text, text.string), SyntaxHighlighting.Palette.pink)
    XCTAssertEqual(colour(of: "\"commit\"", in: text, text.string), SyntaxHighlighting.Palette.red)
    XCTAssertEqual(colour(of: "\"old\"", in: text, text.string), SyntaxHighlighting.Palette.red)
  }

  /// The tab's find crosses cards, which is why it is the tab's and not a text view's: every open
  /// card is searched, and every occurrence is marked at once.
  @MainActor
  func testFindCrossesEveryOpenCard() {
    let tab = CommitContentViewController()
    let sections = Self.detail.files.map { CommitSection(file: $0) }
    for (index, section) in sections.enumerated() {
      section.isOpen = true
      section.diff = CommitDiffLoader.render(Self.fileDiff, file: Self.detail.files[index])
    }
    tab.present(Self.detail, sections: sections)

    tab.find("name")
    XCTAssertEqual(tab.findState.count, 4, "two cards, two occurrences each")
    tab.find("nothing here")
    XCTAssertEqual(tab.findState.count, 0)
  }

  /// The tab has to fit the desk it is in.
  ///
  /// Content compression resistance outranks a split item's holding priority, so a label that
  /// refuses to shrink does not get a wider desk — it moves the divider and takes the width out
  /// of the transcript column beside it, which is what opening a commit tab used to do. The width
  /// here is constrained at the desk's own holding priority, exactly as the split view holds it,
  /// so anything inside resisting harder wins and the tab comes out too wide.
  @MainActor
  func testTheTabFitsTheDeskRatherThanWideningIt() {
    let long = String(repeating: "a long line of message ", count: 12)
    let detail = Git.CommitDetail(
      oid: String(repeating: "a", count: 40), summary: long, body: long, author: "Test",
      date: Date(timeIntervalSince1970: 0),
      files: [
        Git.CommitFile(
          path: "Sources/Hukan/Some/Very/Deep/Directory/With/A/Long/Name/Renderer.swift",
          oldPath: "Sources/Hukan/Another/Equally/Deep/Directory/Renderer.swift",
          status: .renamed, added: 4321, removed: 8765, isBinary: false)
      ],
      countsOmitted: false)

    for note in [Git.FileDiff.Note?.none, .tooLarge(lines: 41200, bytes: 3_400_000), .binary] {
      let tab = CommitContentViewController()
      let sections = detail.files.map { CommitSection(file: $0) }
      if let note {
        sections[0].isOpen = true
        sections[0].diff = LoadedFileDiff(note: note)
      }
      tab.present(detail, sections: sections)

      let desk = WorkspaceWindowController.deskMinimumWidth
      let host = NSView(frame: NSRect(x: 0, y: 0, width: desk, height: 600))
      tab.view.translatesAutoresizingMaskIntoConstraints = false
      host.addSubview(tab.view)
      let width = tab.view.widthAnchor.constraint(equalToConstant: desk)
      width.priority = WorkspaceWindowController.deskHoldingPriority
      NSLayoutConstraint.activate([
        tab.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        tab.view.topAnchor.constraint(equalTo: host.topAnchor),
        tab.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        width,
      ])
      host.layoutSubtreeIfNeeded()

      XCTAssertEqual(
        tab.view.frame.width, desk, accuracy: 0.5,
        "the tab widened the desk with note \(String(describing: note))")
    }
  }

  private func labels(in view: NSView) -> [String] {
    var found: [String] = []
    if let field = view as? NSTextField { found.append(field.stringValue) }
    for subview in view.subviews { found += labels(in: subview) }
    return found
  }

  private static let detail = Git.CommitDetail(
    oid: String(repeating: "a", count: 40), summary: "Rewrite the renderer", body: "Because.",
    author: "Test", date: Date(timeIntervalSince1970: 0),
    files: [
      Git.CommitFile(
        path: "Sources/Renderer.swift", oldPath: nil, status: .modified, added: 3, removed: 1,
        isBinary: false),
      Git.CommitFile(
        path: "Sources/Other.swift", oldPath: nil, status: .added, added: 9, removed: 0,
        isBinary: false),
    ],
    countsOmitted: false)

  private static let fileDiff = Git.FileDiff(
    rows: [
      .hunk("@@ -3,3 +3,3 @@"),
      .line(old: 3, new: 3, kind: .context, text: "struct Renderer {"),
      .line(old: 4, new: nil, kind: .removed, text: "  let name = \"old\""),
      .line(old: nil, new: 4, kind: .added, text: "  let name = \"commit\""),
      .line(old: 5, new: 5, kind: .context, text: "    return true"),
    ],
    note: nil,
    // The line numbers have to be the file's own: a row is coloured from the line it *is*.
    newSource: """
      import AppKit

      struct Renderer {
        let name = "commit"
          return true
      }
      """,
    oldSource: """
      import AppKit

      struct Renderer {
        let name = "old"
          return true
      }
      """)

  private func band(of needle: String, in text: NSAttributedString) -> NSColor? {
    guard let range = text.string.range(of: needle) else { return nil }
    let offset = text.string.distance(from: text.string.startIndex, to: range.lowerBound)
    return text.attribute(.diffBand, at: offset, effectiveRange: nil) as? NSColor
  }

  private func colour(of needle: String, in text: NSAttributedString, _ string: String) -> NSColor?
  {
    guard let range = string.range(of: needle) else { return nil }
    let offset = string.distance(from: string.startIndex, to: range.lowerBound)
    return text.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
  }
}
