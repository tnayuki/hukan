import XCTest

@testable import Hukan

/// A session's tags: what the agent's `set_tags` and the rail's editor make of a list, which colour
/// a kind is drawn in, and that the window carries them across a relaunch.
final class SessionTagsTests: XCTestCase {
  func testTheListIsTrimmedDeduplicatedAndKeptInOrder() {
    XCTAssertEqual(
      SessionTags.normalized(["  JIRA: ABC-1 ", "", "PR: #2", "JIRA: ABC-1", "\n"]),
      ["JIRA: ABC-1", "PR: #2"])
    let long = String(repeating: "x", count: 100)
    XCTAssertEqual(SessionTags.normalized([long]).first?.count, SessionTags.lengthLimit)
  }

  func testAKindIsWhatPrecedesTheFirstColon() {
    XCTAssertEqual(SessionTags.split("JIRA: ABC-123").kind, "JIRA")
    XCTAssertEqual(SessionTags.split("JIRA: ABC-123").value, "ABC-123")
    // A value may carry colons of its own.
    XCTAssertEqual(SessionTags.split("Time: 10:30").value, "10:30")
    // Nothing on one side of the colon is no kind at all, and the tag is shown whole.
    XCTAssertNil(SessionTags.split("urgent").kind)
    XCTAssertNil(SessionTags.split(": orphan").kind)
    XCTAssertEqual(SessionTags.split("PR:").value, "PR:")
  }

  /// The colour is the only place the kind is shown, so it has to be the same one tomorrow:
  /// `hashValue` is seeded per process, and these numbers would wander if it were what decided.
  func testAKindLandsOnTheSameColourEveryLaunch() {
    XCTAssertEqual(
      SessionTags.paletteIndex(forKind: "JIRA"), SessionTags.paletteIndex(forKind: "jira"))
    XCTAssertEqual(SessionTags.paletteIndex(forKind: "JIRA"), 1)
    XCTAssertEqual(SessionTags.paletteIndex(forKind: "PR"), 7)
    XCTAssertNil(SessionTags.paletteIndex(forKind: nil))
    XCTAssertNotEqual(
      SessionTags.paletteIndex(forKind: "JIRA"), SessionTags.paletteIndex(forKind: "PR"))
  }

  func testTheEditorReadsCommas() {
    XCTAssertEqual(SessionTags.parse("JIRA: A-1,  PR: #2 ,"), ["JIRA: A-1", "PR: #2"])
    XCTAssertEqual(SessionTags.joined(["JIRA: A-1", "PR: #2"]), "JIRA: A-1, PR: #2")
  }

  /// The agent's call is answered by the session, without a window, and reports the list as it
  /// now stands — which is what lets the agent add a tag by restating the ones it keeps.
  func testSetTagsIsAnsweredByTheSessionAndReportsTheList() {
    let session = AgentSession(worktreeID: UUID())
    var changes = 0
    session.onTagsChange = { changes += 1 }
    var outcome: HukanMCP.Outcome?
    session.performTool(
      HukanMCP.Call(name: "set_tags", arguments: ["tags": ["JIRA: ABC-1", " PR: #2 "]])
    ) { outcome = $0 }
    XCTAssertEqual(session.tags, ["JIRA: ABC-1", "PR: #2"])
    guard case .text(let text) = outcome else { return XCTFail("\(String(describing: outcome))") }
    XCTAssertEqual(text, "JIRA: ABC-1\nPR: #2")
    XCTAssertEqual(changes, 1)

    // Re-stating the same list is not a change.
    let same = HukanMCP.Call(name: "set_tags", arguments: ["tags": ["JIRA: ABC-1", "PR: #2"]])
    session.performTool(same) { _ in }
    XCTAssertEqual(changes, 1)

    session.performTool(HukanMCP.Call(name: "set_tags", arguments: ["tags": [String]()])) {
      outcome = $0
    }
    XCTAssertEqual(session.tags, [])
    guard case .text(let cleared) = outcome else { return XCTFail() }
    XCTAssertEqual(cleared, "No tags.")

    // A list that is not all strings is refused rather than half-applied.
    session.performTool(HukanMCP.Call(name: "set_tags", arguments: ["tags": ["A: 1", 2]])) {
      outcome = $0
    }
    guard case .error = outcome else { return XCTFail("a mixed list is refused") }
    XCTAssertEqual(session.tags, [])
  }

  func testTagsRoundTripThroughTheWindowsState() throws {
    let workspace = Workspace()
    let tagged = AgentSession(worktreeID: UUID())
    tagged.setTags(["JIRA: ABC-1", "PR: #2"])
    workspace.sessions = [tagged, AgentSession(worktreeID: UUID())]

    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    workspace.encodeState(to: archiver)
    archiver.finishEncoding()
    let restored = Workspace()
    restored.decodeState(from: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData))

    let revived = AgentSession(id: tagged.id, worktreeID: UUID(), isDetached: true)
    restored.applyRestoredPrefs(to: revived)
    XCTAssertEqual(revived.tags, ["JIRA: ABC-1", "PR: #2"])

    // What the tags became in this run is what a session rebuilt later in it comes back with.
    revived.setTags([])
    restored.rememberTags(of: revived)
    let again = AgentSession(id: tagged.id, worktreeID: UUID(), isDetached: true)
    restored.applyRestoredPrefs(to: again)
    XCTAssertEqual(again.tags, [])
  }

  // MARK: - The rail's tag lines

  /// The tags wrap at a width worked out before any row exists, from insets the source-list style
  /// puts around a cell. Those insets are the style's, not documented anywhere, so they are held
  /// here against the outline's own cell frames at every level the rail draws — a release that
  /// moves them makes the counted lines and the drawn lines disagree, and that has to fail here.
  func testTheTagWidthMatchesTheOutlinesCells() throws {
    let rail = SessionRailViewController()
    rail.workspace = RailPreviewTests.sampleWorkspace()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 280, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentViewController = rail
    rail.loadViewIfNeeded()
    rail.reload()
    rail.view.layoutSubtreeIfNeeded()
    let outline = rail.outlineViewForTesting
    XCTAssertGreaterThan(outline.numberOfRows, 4)
    for row in 0..<outline.numberOfRows {
      let cell = outline.frameOfCell(atColumn: 0, row: row)
      let level = CGFloat(outline.level(forRow: row))
      XCTAssertEqual(
        cell.minX, SessionRailViewController.cellLeading + level * outline.indentationPerLevel,
        "row \(row)")
      XCTAssertEqual(
        outline.bounds.width - cell.maxX, SessionRailViewController.cellTrailing, "row \(row)")
    }

    // A tagged row is as tall as its tags wrap to; an untagged one still has the line under its
    // title, which carries its branch; a heading keeps the rail's height.
    let tagged = try XCTUnwrap(
      (0..<outline.numberOfRows).first {
        ((outline.item(atRow: $0) as? RailNode)?.session?.tags.count ?? 0) > 2
      })
    XCTAssertGreaterThan(outline.rect(ofRow: tagged).height, outline.rowHeight * 2)
    let plain = try XCTUnwrap(
      (0..<outline.numberOfRows).first {
        (outline.item(atRow: $0) as? RailNode)?.session?.tags.isEmpty == true
      })
    XCTAssertGreaterThan(outline.rect(ofRow: plain).height, outline.rowHeight)
    XCTAssertLessThan(outline.rect(ofRow: plain).height, outline.rect(ofRow: tagged).height)
    let heading = try XCTUnwrap(
      (0..<outline.numberOfRows).first {
        (outline.item(atRow: $0) as? RailNode)?.isRepositoryHeading == true
      })
    XCTAssertEqual(outline.rect(ofRow: heading).height, outline.rowHeight)
  }

  /// Every row draws its tags in one order — by kind, then by value, a tag with no kind last — so
  /// the same kind stands in the same place down the rail, whatever order each list was written in.
  func testARowDrawsItsTagsByKindThenValue() {
    XCTAssertEqual(
      SessionTags.displayOrder(["urgent", "PR: #58", "JIRA: HUK-10", "jira: HUK-9"]),
      ["jira: HUK-9", "JIRA: HUK-10", "PR: #58", "urgent"])
  }

  func testChipsWrapOntoAnotherLineWhenTheyDoNotFit() {
    let tags = ["JIRA: HUK-131", "JIRA: HUK-140", "PR: #58886"]
    let one = TagFlowView.height(of: tags, width: 1000)
    XCTAssertEqual(
      TagFlowView.height(of: tags, width: 60), one * 3 + TagFlowView.spacing.height * 2)
    XCTAssertEqual(TagFlowView.height(of: [], width: 100), 0)
  }

  // MARK: - A tag's page

  func testATagMayEndInTheAddressOfWhatItNames() {
    let tag = "PR: #42 <https://github.com/o/r/pull/42>"
    XCTAssertEqual(SessionTags.url(of: tag)?.absoluteString, "https://github.com/o/r/pull/42")
    XCTAssertEqual(SessionTags.label(of: tag), "PR: #42")
    XCTAssertEqual(SessionTags.split(tag).kind, "PR")
    XCTAssertEqual(SessionTags.split(tag).value, "#42")
    XCTAssertNil(SessionTags.url(of: "PR: #42"))
    // Only http(s), and only an address with a host: anything else in brackets is label.
    XCTAssertNil(SessionTags.url(of: "Doc: x <file:///etc/hosts>"))
    XCTAssertEqual(
      SessionTags.label(of: "Doc: x <file:///etc/hosts>"), "Doc: x <file:///etc/hosts>")
    XCTAssertNil(SessionTags.url(of: "Note: <draft>"))
  }

  /// The label is cut to what a row can hold; the address is not, since a shortened one is a
  /// different page.
  func testTheLabelIsCutButTheAddressIsNot() {
    let address = "https://example.com/" + String(repeating: "a", count: 200)
    let long = String(repeating: "x", count: 100)
    let tag = SessionTags.normalized(["\(long) <\(address)>"]).first
    XCTAssertEqual(tag.map(SessionTags.label(of:))?.count, SessionTags.lengthLimit)
    XCTAssertEqual(tag.flatMap(SessionTags.url(of:))?.absoluteString, address)
    XCTAssertEqual(
      SessionTags.normalized(["PR: #1   <https://a.example/1>", "PR: #1 <https://a.example/1>"]),
      ["PR: #1 <https://a.example/1>"])
  }

  /// A chip naming a page takes the click for itself and opens it; one naming none leaves the
  /// click to the row.
  func testAChipNamingAPageOpensIt() {
    var opened: [URL] = []
    let linked = TagChip(tag: "PR: #42 <https://github.com/o/r/pull/42>") { opened.append($0) }
    XCTAssertTrue(linked.validateProposedFirstResponder(linked, for: nil))
    linked.performOpen()
    XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/o/r/pull/42"])
    XCTAssertEqual(linked.toolTip, "PR: #42\nhttps://github.com/o/r/pull/42")

    let plain = TagChip(tag: "JIRA: ABC-1") { opened.append($0) }
    XCTAssertNil(plain.url)
    XCTAssertFalse(plain.validateProposedFirstResponder(plain, for: nil))
    // The address does not widen the chip: only the value is drawn.
    XCTAssertEqual(
      TagChip.size(of: "PR: #42 <https://github.com/o/r/pull/42>"), TagChip.size(of: "PR: #42"))
  }
}
