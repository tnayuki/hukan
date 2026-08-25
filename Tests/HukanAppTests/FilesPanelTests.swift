import AppKit
import XCTest

@testable import Hukan

/// The panel's own hazard: it is both the outline view's data source and the thing that reads
/// rows back off it. Every state it restores across a rebuild — what was open, what was
/// selected — is read through `item(atRow:)`, which asks the data source for the row, so the
/// model and the view have to still agree at that moment. Two of the three below crashed the
/// app before the rebuild was ordered against those reads.
final class FilesPanelTests: XCTestCase {
  private var temporaries: [URL] = []

  override func tearDown() {
    for url in temporaries { try? FileManager.default.removeItem(at: url) }
    temporaries = []
    super.tearDown()
  }

  /// `tracked`, where it differs from `files`, is a file list the tree is built from without
  /// writing any of it to disk — the tree reads git's answer, not the directory.
  private func makeWorktree(files: [String], tracked: [String]? = nil) throws -> Worktree {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-files-panel-\(UUID().uuidString)")
    temporaries.append(root)
    for path in files {
      let file = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try "needle\n".write(to: file, atomically: true, encoding: .utf8)
    }
    let repository = Repository(id: root.path)
    let worktree = Worktree(url: root, repository: repository)
    worktree.trackedFiles = tracked ?? files
    worktree.hasLoadedFiles = true
    repository.worktrees = [worktree]
    return worktree
  }

  /// The panel drawn the way the window draws it: rows an outline view has never displayed keep
  /// their item lazy, and a lazy row is one the data source is asked for again on the way out.
  @MainActor
  private func host(_ panel: FilesPanelViewController) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 260, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = panel.view
    window.displayIfNeeded()
    return window
  }

  private func findOutline(in view: NSView) -> NSOutlineView? {
    if let outline = view as? NSOutlineView { return outline }
    for subview in view.subviews {
      if let found = findOutline(in: subview) { return found }
    }
    return nil
  }

  /// The line between the tree and the History section is a split's divider, so it can be
  /// dragged: the section used to be pinned at seven rows, and seven rows is not a reading of a
  /// log. Being a split item is also what makes folding it the same act as folding the panel.
  @MainActor
  func testTheHistorySectionCanBeGivenMoreRoom() throws {
    let worktree = try makeWorktree(files: ["a.swift"])
    worktree.history = Git.History(
      commits: (0..<40).map {
        Git.Commit(oid: String(format: "%040x", $0 + 1), summary: "Step \($0)", isPushed: false)
      }, base: "origin/main", forkIndex: 40)
    let panel = FilesPanelViewController()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 280, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = panel.view
    window.displayIfNeeded()
    panel.show(worktree: worktree)
    window.displayIfNeeded()

    XCTAssertGreaterThan(panel.view.bounds.height, 0, "the panel has a height to divide")
    XCTAssertGreaterThan(panel.historyHeight, 0, "commits, so the section is showing")

    panel.historyHeight = 320
    window.displayIfNeeded()
    XCTAssertEqual(panel.historyHeight, 320, accuracy: 2, "past the old seven-row ceiling")
  }

  /// A worktree with nothing committed folds the section away, and coming back to one that has
  /// commits brings it back — unless it was folded by hand, which outlives the switch.
  @MainActor
  func testTheSectionFollowsWhetherThereIsAnythingToShow() throws {
    let empty = try makeWorktree(files: ["a.swift"])
    let committed = try makeWorktree(files: ["b.swift"])
    committed.history = Git.History(
      commits: [
        Git.Commit(oid: String(repeating: "a", count: 40), summary: "One", isPushed: false)
      ],
      base: "origin/main", forkIndex: 1)
    let panel = FilesPanelViewController()
    let window = host(panel)

    panel.show(worktree: empty)
    window.layoutIfNeeded()
    XCTAssertFalse(panel.isHistoryVisible, "nothing committed: the panel is all tree")

    panel.show(worktree: committed)
    window.layoutIfNeeded()
    XCTAssertTrue(panel.isHistoryVisible)

    panel.toggleHistory()
    XCTAssertFalse(panel.isHistoryVisible)
    panel.show(worktree: empty)
    panel.show(worktree: committed)
    window.layoutIfNeeded()
    XCTAssertFalse(panel.isHistoryVisible, "folded by hand stays folded across the switch")
  }

  /// A refresh that shrinks the tree — a branch move, the scope narrowed to the changed files —
  /// rebuilds `roots` under rows the view still holds, and the disclosure state is read back off
  /// those rows.
  @MainActor
  func testARefreshThatShrinksTheTreeKeepsTheViewInStep() throws {
    let worktree = try makeWorktree(files: (0..<40).map { "file\($0).swift" })
    let panel = FilesPanelViewController()
    let window = host(panel)
    panel.show(worktree: worktree)
    let outline = try XCTUnwrap(findOutline(in: panel.view))
    window.displayIfNeeded()
    XCTAssertEqual(outline.numberOfRows, 40)

    worktree.trackedFiles = ["file0.swift"]
    panel.filesChangedOnDisk()

    XCTAssertEqual(outline.numberOfRows, 1, "the one survivor")
  }

  /// The result list is the same collision from the other side: the rows on screen are the
  /// results, and the panel drops them as it points itself at the new worktree, so the view's
  /// rows and the data source's answers belong to two different lists until the reload lands.
  @MainActor
  func testSwitchingWorktreesLeavesTheResultList() throws {
    let searched = try makeWorktree(files: (0..<12).map { "hit\($0).txt" })
    let other = try makeWorktree(files: ["only.txt"])
    let panel = FilesPanelViewController()
    let window = host(panel)
    panel.show(worktree: searched)
    let outline = try XCTUnwrap(findOutline(in: panel.view))

    panel.filterSearchField.stringValue = "needle"
    panel.focusSearch()
    let listed = expectation(description: "the scan answers")
    DispatchQueue.main.async {
      // The scan runs on the panel's own queue and hops back to the main queue to show what it
      // found; one more hop lands after it.
      DispatchQueue.main.async { listed.fulfill() }
    }
    wait(for: [listed], timeout: 5)
    window.displayIfNeeded()
    XCTAssertEqual(outline.numberOfRows, 24, "twelve files, each with its one matching line")

    panel.show(worktree: other)

    XCTAssertEqual(outline.numberOfRows, 1, "the new worktree's one file, no results left")
  }

  /// The crash as it actually happened: a rail click lands on a worktree git has not answered
  /// for yet, so the new tree is empty while the view still holds forty rows of the old one.
  @MainActor
  func testSwitchingToAWorktreeWhoseFilesHaveNotLoaded() throws {
    let loaded = try makeWorktree(files: (0..<40).map { "file\($0).swift" })
    let pending = try makeWorktree(files: [])
    pending.hasLoadedFiles = false
    let panel = FilesPanelViewController()
    let window = host(panel)
    panel.show(worktree: loaded)
    let outline = try XCTUnwrap(findOutline(in: panel.view))
    window.displayIfNeeded()
    XCTAssertEqual(outline.numberOfRows, 40)

    panel.show(worktree: pending)

    XCTAssertEqual(outline.numberOfRows, 0)
  }

  /// An empty tree has two meanings and the panel has to tell them apart: git has not answered
  /// yet, or it has and there is nothing. Saying "No files" for the first is a claim about the
  /// worktree that nothing has established.
  @MainActor
  func testAnUnreadWorktreeSaysItIsReadingRatherThanThatItIsEmpty() throws {
    let pending = try makeWorktree(files: [])
    pending.hasLoadedFiles = false
    let panel = FilesPanelViewController()
    let window = host(panel)
    panel.show(worktree: pending)

    let reading = expectation(description: "the note appears")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { reading.fulfill() }
    wait(for: [reading], timeout: 2)
    window.displayIfNeeded()
    XCTAssertTrue(labels(in: panel.view).contains("Reading…"))
    XCTAssertFalse(labels(in: panel.view).contains("No files"))

    pending.hasLoadedFiles = true
    panel.show(worktree: pending)
    window.displayIfNeeded()
    XCTAssertTrue(labels(in: panel.view).contains("No files"), "read, and empty, is the other one")
    XCTAssertFalse(labels(in: panel.view).contains("Reading…"))
  }

  /// A filtered tree opens itself so it can be read at a glance. One character against a large
  /// worktree narrows nothing, and opening all of it is what a keystroke used to cost.
  @MainActor
  func testAFilteredTreeOpensOnlyAsFarAsItsBudget() throws {
    let files = (0..<200).flatMap { directory in
      (0..<10).map { "dir\(String(format: "%03d", directory))/file\($0).swift" }
    }
    let worktree = try makeWorktree(files: [], tracked: files)
    let panel = FilesPanelViewController()
    let window = host(panel)
    panel.show(worktree: worktree)
    let outline = try XCTUnwrap(findOutline(in: panel.view))
    XCTAssertEqual(outline.numberOfRows, 200, "unfiltered: the directories, folded")

    panel.filterSearchField.stringValue = "file"
    panel.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: panel.filterSearchField))
    window.displayIfNeeded()

    XCTAssertGreaterThan(outline.numberOfRows, 200, "it did open itself")
    XCTAssertLessThan(
      outline.numberOfRows, 1000, "and stopped, rather than opening all 2200 matching rows")
  }

  private func labels(in view: NSView) -> [String] {
    var found: [String] = []
    if let field = view as? NSTextField, !field.isHidden { found.append(field.stringValue) }
    for subview in view.subviews where !subview.isHidden {
      found.append(contentsOf: labels(in: subview))
    }
    return found
  }
}
