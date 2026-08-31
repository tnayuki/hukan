import XCTest

@testable import Hukan

/// The History section's own rules, the ones that are not git's: what a row says, when the
/// section is there at all, and how much of the panel it is allowed to take.
final class HistoryPanelTests: XCTestCase {
  /// `forkIndex` defaults to the whole list — every commit is this branch's own, and the rule
  /// closes it — which is the shape the section had when it was bounded at the base.
  private func history(
    _ count: Int, pushedFrom: Int? = nil, forkIndex: Int? = nil, truncated: Bool = false
  ) -> Git.History {
    Git.History(
      commits: (0..<count).map { i in
        Git.Commit(
          oid: String(format: "%040x", i + 1), summary: "Step \(count - i)",
          isPushed: pushedFrom.map { i >= $0 })
      },
      base: "origin/main", forkIndex: forkIndex ?? count, truncated: truncated)
  }

  @MainActor
  func testRowsCarryTheHashAndSummary() throws {
    let panel = HistoryPanelViewController()
    panel.show(history: history(3))
    let table = try XCTUnwrap(findTable(in: panel.view))

    XCTAssertEqual(table.numberOfRows, 4, "three commits and the fork-point rule")
    let row = try XCTUnwrap(
      panel.tableView(table, viewFor: table.tableColumns.first, row: 0) as? NSStackView)
    let labels = row.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    XCTAssertEqual(labels.count, 3, "marker, hash, summary")
    XCTAssertEqual(labels[1], String(format: "%040x", 1).prefix(7).description)
    XCTAssertEqual(labels[2], "Step 3")
  }

  /// The dot marks what the upstream does not carry. Its column is there either way, so the
  /// hashes stay in a line rather than stepping in and out.
  @MainActor
  func testOnlyUnpushedCommitsAreMarked() throws {
    let panel = HistoryPanelViewController()
    panel.show(history: history(3, pushedFrom: 1))
    let table = try XCTUnwrap(findTable(in: panel.view))

    let markers = try (0..<3).map { row -> String in
      let view = try XCTUnwrap(
        panel.tableView(table, viewFor: table.tableColumns.first, row: row) as? NSStackView)
      return try XCTUnwrap((view.arrangedSubviews.first as? NSTextField)?.stringValue)
    }
    XCTAssertEqual(markers, ["●", " ", " "])
  }

  /// The rule sits between what this branch committed and what it inherited, naming the base —
  /// and it is a caption, so arrowing through the commits steps over it.
  @MainActor
  func testTheForkPointRuleDividesTheList() throws {
    let panel = HistoryPanelViewController()
    panel.show(history: history(4, forkIndex: 2))
    let table = try XCTUnwrap(findTable(in: panel.view))

    XCTAssertEqual(table.numberOfRows, 5, "four commits and the rule between them")
    let rule = try XCTUnwrap(
      panel.tableView(table, viewFor: table.tableColumns.first, row: 2) as? NSStackView)
    let labels = rule.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    XCTAssertEqual(labels, ["origin/main"])
    XCTAssertFalse(panel.tableView(table, shouldSelectRow: 2))
    XCTAssertTrue(panel.tableView(table, shouldSelectRow: 3), "the log carries on below it")

    let below = try XCTUnwrap(
      panel.tableView(table, viewFor: table.tableColumns.first, row: 3) as? NSStackView)
    let summary = below.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.last
    XCTAssertEqual(summary, "Step 2", "the third commit, one row further down for the rule")
  }

  /// A tag is drawn as a rule too, directly above the commit it names — where the fork rule
  /// already sits relative to the base tip, so both read as "the ref below this is what
  /// everything above is not in yet". It is a caption like the other one, so the arrows step
  /// over it and the commits below keep their own rows.
  @MainActor
  func testATagRuleNamesTheCommitBelowIt() throws {
    let panel = HistoryPanelViewController()
    var list = history(3, forkIndex: 0)
    list.tags = [list.commits[1].oid: ["v1.0"]]
    panel.show(history: list)
    let table = try XCTUnwrap(findTable(in: panel.view))

    XCTAssertEqual(table.numberOfRows, 4, "three commits and the tag rule")
    let rule = try XCTUnwrap(
      panel.tableView(table, viewFor: table.tableColumns.first, row: 1) as? NSStackView)
    XCTAssertEqual(rule.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }, ["v1.0"])
    XCTAssertFalse(panel.tableView(table, shouldSelectRow: 1))
    XCTAssertTrue(
      rule.arrangedSubviews.contains { $0 is NSImageView },
      "and it carries the glyph that tells it from the fork point")

    let below = try XCTUnwrap(
      panel.tableView(table, viewFor: table.tableColumns.first, row: 2) as? NSStackView)
    let summary = below.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.last
    XCTAssertEqual(summary, "Step 2", "the tagged commit, one row down for its own rule")
  }

  /// Several tags on one commit are one rule, and past two the row counts the rest rather than
  /// running the names out to an ellipsis: at the panel's width that took the rules and the glyph
  /// with it, leaving a line of grey text reading as no kind of row at all. The whole list is
  /// still in the tooltip.
  @MainActor
  func testSeveralTagsOnOneCommitAreOneRuleAndACount() throws {
    let panel = HistoryPanelViewController()
    var list = history(2, forkIndex: 0)
    list.tags = [list.commits[0].oid: ["v1.0", "v1.0-rc.1", "release-1"]]
    panel.show(history: list)
    let table = try XCTUnwrap(findTable(in: panel.view))

    let rule = try XCTUnwrap(
      panel.tableView(table, viewFor: table.tableColumns.first, row: 0) as? NSStackView)
    XCTAssertEqual(
      rule.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }, ["v1.0 +2"])
    XCTAssertEqual(rule.toolTip, "Tagged v1.0, v1.0-rc.1, release-1")
  }

  /// A checkout with nothing of its own — in sync with its remote — has nothing to divide, so it
  /// is all log and no rule. This is the case that used to empty the section altogether.
  @MainActor
  func testACheckoutInSyncIsAllLogAndNoRule() throws {
    let panel = HistoryPanelViewController()
    panel.show(history: history(3, forkIndex: 0))
    let table = try XCTUnwrap(findTable(in: panel.view))

    XCTAssertEqual(table.numberOfRows, 3)
    XCTAssertTrue(panel.hasAnythingToShow)
  }

  /// A page that stopped before the fork draws no rule: the count is capped at what was read, so
  /// a rule on the last row would claim to know where the branch began when the walk never
  /// reached it.
  @MainActor
  func testAPageThatStoppedShortDrawsNoRule() throws {
    let panel = HistoryPanelViewController()
    panel.show(history: history(3, forkIndex: 3, truncated: true))
    let table = try XCTUnwrap(findTable(in: panel.view))

    XCTAssertEqual(table.numberOfRows, 3)
  }

  /// A commit landing on the list — this window's, another session's — must not throw a diff onto
  /// the desk. The panel puts the selection back after every refresh, and that posts the same
  /// notification a click does.
  @MainActor
  func testACommitLandingDoesNotOpenAnything() throws {
    let panel = HistoryPanelViewController()
    panel.show(history: history(3))
    let table = try XCTUnwrap(findTable(in: panel.view))

    var opened: [String] = []
    panel.onSelect = { opened.append($0) }
    table.selectRowIndexes([1], byExtendingSelection: false)
    XCTAssertEqual(opened.count, 1, "a person's pick opens one")

    // A newer commit arrives on top, so every row shifts down one.
    let newer = Git.Commit(
      oid: String(repeating: "a", count: 40), summary: "Newer", isPushed: false)
    panel.show(
      history: Git.History(commits: [newer] + history(3).commits, base: "origin/main"))

    XCTAssertEqual(opened.count, 1, "the refresh opened a commit on its own")
    XCTAssertEqual(
      table.selectedRow, 2, "the same commit stays selected, at the row it moved to")
  }

  /// A commit that leaves the list — amended, or rebased away — takes the selection with it,
  /// rather than leaving the row pointing at whatever moved into it.
  @MainActor
  func testARebasedAwayCommitDropsTheSelection() throws {
    let panel = HistoryPanelViewController()
    panel.show(history: history(3))
    let table = try XCTUnwrap(findTable(in: panel.view))
    var opened: [String] = []
    table.selectRowIndexes([0], byExtendingSelection: false)
    panel.onSelect = { opened.append($0) }

    panel.show(
      history: Git.History(
        commits: [
          Git.Commit(oid: String(repeating: "f", count: 40), summary: "Reworded", isPushed: false)
        ],
        base: "origin/main"))

    XCTAssertEqual(table.selectedRow, -1)
    XCTAssertTrue(opened.isEmpty)
  }

  /// One flick, one page. The section is redrawn constantly — every FSEvents batch, and once
  /// more from inside the very call that asks for a page, since asking triggers a reload that
  /// redraws with the list as it stands — so a guard cleared by "a refresh happened" is no guard
  /// at all: every scroll notification fired another read, and on a large repository those are
  /// whole-worktree reads that pile up.
  @MainActor
  func testARedrawDoesNotRearmPaging() throws {
    let panel = HistoryPanelViewController()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 260, height: 80), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = panel.view
    var asked = 0
    panel.onLoadMore = { asked += 1 }
    panel.show(history: history(10, forkIndex: 10, truncated: true))
    window.displayIfNeeded()

    scrollToEnd(panel)
    XCTAssertEqual(asked, 1, "the first scroll asks")

    // What the app does between asking and answering: the reload the request itself triggers
    // redraws the section with the list it already had, and FSEvents redraws it again.
    panel.show(history: history(10, forkIndex: 10, truncated: true))
    panel.show(history: history(10, forkIndex: 10, truncated: true))
    scrollToEnd(panel)
    XCTAssertEqual(asked, 1, "still the one page, until it arrives")

    // The page lands.
    panel.show(history: history(20, forkIndex: 20, truncated: true))
    window.displayIfNeeded()
    scrollToEnd(panel)
    XCTAssertEqual(asked, 2, "and then the next scroll may ask again")
  }

  /// The end of the log releases the guard too, or a list that stops being truncated would leave
  /// the section unable to ask for anything ever again.
  @MainActor
  func testReachingTheEndReleasesPaging() throws {
    let panel = HistoryPanelViewController()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 260, height: 80), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = panel.view
    var asked = 0
    panel.onLoadMore = { asked += 1 }
    panel.show(history: history(10, forkIndex: 10, truncated: true))
    window.displayIfNeeded()
    scrollToEnd(panel)
    XCTAssertEqual(asked, 1)

    panel.show(history: history(10, forkIndex: 10, truncated: false))
    window.displayIfNeeded()
    scrollToEnd(panel)
    XCTAssertEqual(asked, 1, "nothing left to ask for, but the guard is not stuck either")

    panel.show(history: history(10, forkIndex: 10, truncated: true))
    window.displayIfNeeded()
    scrollToEnd(panel)
    XCTAssertEqual(asked, 2)
  }

  /// Drive the scroll the way a person's flick does — the section watches its own clip view's
  /// bounds, so moving them is what a scroll *is* as far as it is concerned.
  @MainActor
  private func scrollToEnd(_ panel: HistoryPanelViewController) {
    guard let table = findTable(in: panel.view), let clip = table.enclosingScrollView?.contentView
    else { return XCTFail("no table") }
    table.layoutSubtreeIfNeeded()
    clip.scroll(to: NSPoint(x: 0, y: max(0, table.bounds.height - clip.bounds.height)))
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
  }

  /// A checkout that has committed nothing of its own has no section, rather than an empty one.
  @MainActor
  func testTheSectionIsEmptyWithoutCommits() {
    let panel = HistoryPanelViewController()
    panel.show(history: Git.History())
    XCTAssertTrue(panel.isEmpty)

    panel.show(history: history(1))
    XCTAssertFalse(panel.isEmpty)
  }

  /// A worktree in the middle of a rebase has no commits past its base to list — that is exactly
  /// the trouble — so the section has to stay on screen and say what is going on.
  @MainActor
  func testAnOperationKeepsTheSectionOnScreen() throws {
    let panel = HistoryPanelViewController()
    panel.show(history: Git.History())
    XCTAssertFalse(panel.hasAnythingToShow, "nothing at all: the panel is all tree")

    panel.show(
      history: Git.History(
        operation: Git.Operation(kind: .rebase, branch: "task", step: 1, total: 2)))
    XCTAssertTrue(panel.isEmpty, "still no commits")
    XCTAssertTrue(panel.hasAnythingToShow, "but a reason to be drawn")
    XCTAssertEqual(operationLine(in: panel.view), "Rebasing task — 1 of 2")
  }

  /// git runs every rebase through the merge backend, so it leaves an `interactive` marker even
  /// for a plain `git rebase main` — the banner must not repeat libgit2's word for that.
  @MainActor
  func testEachOperationSaysWhatItIsPlainly() throws {
    let cases: [(Git.Operation, String)] = [
      (Git.Operation(kind: .rebase, branch: nil, step: nil, total: nil), "Rebasing"),
      (Git.Operation(kind: .merge, branch: "main", step: nil, total: nil), "Merging main"),
      (
        Git.Operation(kind: .cherryPick, branch: "task", step: 2, total: 3),
        "Cherry-picking task — 2 of 3"
      ),
      (Git.Operation(kind: .bisect, branch: nil, step: nil, total: nil), "Bisecting"),
    ]
    for (operation, expected) in cases {
      let panel = HistoryPanelViewController()
      panel.show(history: Git.History(operation: operation))
      XCTAssertEqual(operationLine(in: panel.view), expected)
    }
  }

  /// The banner is pinned above the rows, not scrolled with them: it is the reason the rows read
  /// the way they do, so making the section short must not be what hides it.
  private func operationLine(in view: NSView) -> String? {
    let labels = fields(in: view).filter { $0.textColor == .systemOrange }
    return labels.first?.stringValue
  }

  private func fields(in view: NSView) -> [NSTextField] {
    (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
  }

  private func findTable(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    for subview in view.subviews {
      if let found = findTable(in: subview) { return found }
    }
    return nil
  }
}
