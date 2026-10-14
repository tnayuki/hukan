import AppKit
import XCTest

@testable import Hukan

/// A transcript search turns the rail into a results list: one row per matched session, its hits
/// beneath it. A session that matched dozens of times buries every other result, so its header
/// folds — by its chevron or by ← and →, like any heading — and the fold is the one a search
/// keeps while everything else stands open.
final class RailResultFoldTests: XCTestCase {
  private var worktreeURL: URL!
  private var window: NSWindow?

  override func setUpWithError() throws {
    worktreeURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-result-fold-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: ClaudeSessionStore.directory(for: worktreeURL), withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    window?.close()
    try? FileManager.default.removeItem(at: ClaudeSessionStore.directory(for: worktreeURL))
    try? FileManager.default.removeItem(at: worktreeURL)
  }

  private func line(_ uuid: String, parent: String?, role: String, text: String) -> String {
    var record: [String: Any] = [
      "uuid": uuid, "type": role, "timestamp": "2026-09-01T00:00:00.000Z",
      "message": [
        "role": role,
        "content": role == "user" ? text : [["type": "text", "text": text]],
      ] as [String: Any],
    ]
    if let parent { record["parentUuid"] = parent }
    let data = try! JSONSerialization.data(withJSONObject: record)
    return String(data: data, encoding: .utf8)! + "\n"
  }

  /// A rail holding one session whose transcript names the needle twice, searched for it.
  private func searchedRail() throws -> (SessionRailViewController, NSOutlineView) {
    let repo = Repository(id: worktreeURL.path)
    let main = Worktree(url: worktreeURL, branch: "main", repository: repo)
    repo.worktrees = [main]
    let workspace = Workspace()
    workspace.repositories = [repo]
    workspace.selectedWorktreeID = main.id
    let session = AgentSession(worktreeID: main.id)
    session.title = "Session"
    workspace.sessions = [session]
    try Data(
      (line("a", parent: nil, role: "user", text: "where is the needle")
        + line("b", parent: "a", role: "assistant", text: "the needle is here")).utf8
    ).write(to: ClaudeSessionStore.transcriptURL(id: session.id, worktree: worktreeURL))

    let rail = SessionRailViewController()
    rail.workspace = workspace
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentViewController = rail
    self.window = window
    rail.loadViewIfNeeded()
    rail.reload()
    rail.applyScriptedSearch("needle")
    let outline = rail.outlineViewForTesting
    window.makeFirstResponder(outline)
    rail.view.layoutSubtreeIfNeeded()
    return (rail, outline)
  }

  private func press(_ outline: NSOutlineView, left: Bool) {
    let characters = left ? "\u{F702}" : "\u{F703}"
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: left ? 123 : 124)!
    outline.keyDown(with: event)
  }

  /// The header row's own chevron, found by what it does rather than where it is drawn.
  private func chevron(in outline: NSOutlineView) -> NSButton? {
    func find(_ view: NSView) -> NSButton? {
      if let button = view as? NSButton, button.action == Selector(("toggleResultSession:")) {
        return button
      }
      for subview in view.subviews {
        if let found = find(subview) { return found }
      }
      return nil
    }
    return outline.view(atColumn: 0, row: 0, makeIfNecessary: true).flatMap(find)
  }

  func testTheHeaderFoldsItsHitsAwayByKey() throws {
    let (rail, outline) = try searchedRail()
    XCTAssertEqual(outline.numberOfRows, 3, "the session and its two hits")
    outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

    press(outline, left: true)
    XCTAssertEqual(outline.numberOfRows, 1, "← folds the hits away, leaving the session")
    rail.reload()
    XCTAssertEqual(outline.numberOfRows, 1, "and a background reload leaves it folded")

    press(outline, left: false)
    XCTAssertEqual(outline.numberOfRows, 3, "→ brings them back")
  }

  func testTheHeaderFoldsItsHitsAwayByItsChevron() throws {
    let (_, outline) = try searchedRail()
    XCTAssertEqual(outline.numberOfRows, 3)

    try XCTUnwrap(chevron(in: outline)).performClick(nil)
    XCTAssertEqual(outline.numberOfRows, 1, "the chevron folds the hits away")
    try XCTUnwrap(chevron(in: outline)).performClick(nil)
    XCTAssertEqual(outline.numberOfRows, 3, "and opens them again")
  }

  /// A new query is a new result set, so a fold made in the last one does not carry over.
  func testANewSearchStartsWithEveryHeaderOpen() throws {
    let (rail, outline) = try searchedRail()
    outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    press(outline, left: true)
    XCTAssertEqual(outline.numberOfRows, 1)

    rail.applyScriptedSearch("")
    rail.applyScriptedSearch("needle")
    XCTAssertEqual(outline.numberOfRows, 3)
  }
}
