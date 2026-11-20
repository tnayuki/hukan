import AppKit
import XCTest

@testable import Hukan

/// Sessions a session starts (`start_session`): offered to the model the way the desktop app
/// offers its own, nested under their starter on the rail, archived with it once settled, and
/// reported back to it in words written for the model rather than as instructions.
final class SideSessionTests: XCTestCase {
  private var root: URL!
  private var window: NSWindow?

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-side-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    window?.close()
    try? FileManager.default.removeItem(at: root)
  }

  /// The tools a session is meant to reach for unasked are loaded with the conversation, not
  /// left deferred behind their names; the rest stay deferred.
  func testTheSessionToolsAreAlwaysLoaded() {
    func meta(_ name: String) -> [String: Any]? {
      HukanMCP.toolList.first { $0["name"] as? String == name }?["_meta"] as? [String: Any]
    }
    XCTAssertEqual(meta(HukanMCP.startSessionTool)?["anthropic/alwaysLoad"] as? Bool, true)
    XCTAssertEqual(meta(HukanMCP.detachSessionTool)?["anthropic/alwaysLoad"] as? Bool, true)
    XCTAssertEqual(meta(HukanMCP.handOffTool)?["anthropic/alwaysLoad"] as? Bool, true)
    XCTAssertNil(meta("browser_read"))
  }

  /// The prompt teaches every session when to start one, and a side session also what its
  /// report is.
  func testASideSessionIsToldWhereItsReportGoes() {
    func appendix(_ side: Bool) -> String? {
      let arguments = ClaudeSession.launchArguments(id: UUID(), sideSession: side)
      guard let index = arguments.firstIndex(of: "--append-system-prompt") else { return nil }
      return arguments[index + 1]
    }
    XCTAssertTrue(appendix(false)?.contains("# Starting other sessions") == true)
    XCTAssertTrue(appendix(false)?.contains("mcp__hukan__start_session") == true)
    XCTAssertFalse(appendix(false)?.contains("started from another session") == true)
    XCTAssertTrue(
      appendix(true)?.contains("# You are a session started from another session") == true)
    let notes = ClaudeSession.launchArguments(
      id: UUID(), sideSession: true, notesFolder: "/tmp/family")
    XCTAssertTrue(
      notes.contains { $0.contains("Shared notes folder") && $0.contains("/tmp/family") })
  }

  /// A side session gets no more than the session that started it: a model of the same family or
  /// a cheaper one, an effort at or below its own.
  func testRanksOrderModelsAndEfforts() {
    XCTAssertLessThan(
      SideSessionReports.modelRank("claude-haiku-5-5")!, SideSessionReports.modelRank("sonnet")!)
    XCTAssertLessThan(
      SideSessionReports.modelRank("claude-opus-5-5")!, SideSessionReports.modelRank("fable")!)
    XCTAssertNil(SideSessionReports.modelRank("default"))
    XCTAssertLessThan(
      SideSessionReports.effortRank("medium")!, SideSessionReports.effortRank("xhigh")!)
    XCTAssertNil(SideSessionReports.effortRank("default"))
  }

  /// A family's notes folder is outside the repository, one per family.
  func testTheNotesFolderIsTheFamilys() {
    let family = UUID()
    let folder = SideSessionReports.notesFolder(family: family)
    XCTAssertEqual(folder.lastPathComponent, family.uuidString)
    XCTAssertTrue(folder.path.contains("/Library/Caches/"))
  }

  func testOnlyThePersonsTurnMayStartASession() {
    XCTAssertTrue(TurnInput.person.mayStartSessions)
    XCTAssertFalse(TurnInput.peer.mayStartSessions)
    XCTAssertFalse(TurnInput.reports.mayStartSessions)
  }

  func testAReportIsTheOpeningOfTheFinalMessage() {
    XCTAssertEqual(SideSessionReports.report("  done: PR #3\n"), "done: PR #3")
    let long = String(repeating: "x", count: HukanMCP.reportLength + 50)
    XCTAssertEqual(SideSessionReports.report(long).count, HukanMCP.reportLength + 1)
    XCTAssertEqual(SideSessionReports.report(nil), "")
  }

  /// The wake names a session waiting on the person, and says only the person may answer it.
  func testTheWakeNamesWhatWaitsOnThePerson() {
    let id = UUID()
    let note = SideNote(sessionID: id, title: "Fix", report: "PR #1", failed: false)
    let settled = SideSessionReports.message(notes: [note], waiting: [])
    XCTAssertTrue(settled.contains("<side-sessions-event>"))
    XCTAssertTrue(settled.contains(id.uuidString))
    XCTAssertFalse(settled.contains("Only the user can answer"))
    let waiting = SideSessionReports.message(notes: [note], waiting: [(UUID(), "Other")])
    XCTAssertTrue(waiting.contains("Only the user can answer"))
    XCTAssertTrue(waiting.contains("\u{201C}Other\u{201D}"))
  }

  /// A report read back off disk is drawn as the note it was live, not as the wording written for
  /// the model, which nobody typed.
  func testASavedReportReadsAsItsNote() {
    let note = SideNote(sessionID: UUID(), title: "Fix", report: "PR #1", failed: false)
    let message = SideSessionReports.message(notes: [note], waiting: [])
    XCTAssertEqual(ClaudeSessionStore.sideSessionReportTitles(message), ["Fix"])
    XCTAssertNil(ClaudeSessionStore.sideSessionReportTitles("Session \u{201C}Fix\u{201D} ended"))
    let drawn = Transcript.render([
      HistoryRecord(kind: .userText(message), stamp: nil, reports: ["Fix"])
    ]).string
    XCTAssertTrue(drawn.contains("← reports from \u{201C}Fix\u{201D}"))
    XCTAssertFalse(drawn.contains("side-sessions-event"))
  }

  func testSlugs() {
    XCTAssertEqual(SideSessionReports.slug("Fix the CLI cleanup!"), "fix-the-cli-cleanup")
    XCTAssertEqual(SideSessionReports.slug("日本語"), "")
    XCTAssertEqual(SideSessionReports.slug(String(repeating: "ab-", count: 20)).count, 23)
  }

  /// A side session's checkout is a new branch cut from HEAD of the starter's checkout, made by
  /// hukan itself through libgit2, and a branch that already exists is refused rather than reused.
  func testAWorktreeIsCutFromTheStartersHead() throws {
    git(["init", "-q", "-b", "main"])
    git(["config", "user.email", "test@example.com"])
    git(["config", "user.name", "Test"])
    git(["config", "commit.gpgsign", "false"])
    try "hi\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    git(["add", "."])
    git(["commit", "-q", "-m", "first"])
    let path = root.appendingPathComponent(".claude/worktrees/fix")
    let made = Git.addWorktree(from: root, path: path, name: "fix", branch: "fix", base: nil)
    XCTAssertEqual(try made.get().path, path.standardizedFileURL.path)
    XCTAssertEqual(git(["rev-parse", "--abbrev-ref", "HEAD"], in: path), "fix")
    XCTAssertTrue(Git.branchExists("fix", at: root))
    XCTAssertFalse(Git.branchExists("fix-2", at: root))
    XCTAssertEqual(git(["rev-parse", "HEAD"], in: path), git(["rev-parse", "HEAD"]))
    XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("a.txt").path))
    let again = Git.addWorktree(
      from: root, path: root.appendingPathComponent(".claude/worktrees/fix-2"), name: "fix-2",
      branch: "fix", base: nil)
    XCTAssertThrowsError(try again.get())
    let missing = Git.addWorktree(
      from: root, path: root.appendingPathComponent(".claude/worktrees/x"), name: "x",
      branch: "x", base: "nope")
    XCTAssertThrowsError(try missing.get())
  }

  /// A tree, as deep as the starts go: a side session's own side session stands under it, the
  /// way its report climbs, and a detached one stands on its own.
  func testTheRailNestsAFamilyUnderItsTopSession() {
    let repo = Repository(id: root.path)
    let main = Worktree(url: root, branch: "main", repository: repo)
    repo.worktrees = [main]
    let workspace = Workspace()
    workspace.repositories = [repo]
    workspace.selectedWorktreeID = main.id
    func session(_ title: String, parent: AgentSession? = nil, detached: Bool = false)
      -> AgentSession
    {
      let session = AgentSession(worktreeID: main.id)
      session.title = title
      session.origin = parent.map { SessionOrigin(parentID: $0.id, detached: detached) }
      return session
    }
    let top = session("Top")
    let child = session("Child", parent: top)
    let grandchild = session("Grandchild", parent: child)
    let loose = session("Loose", parent: top, detached: true)
    workspace.sessions = [top, child, grandchild, loose]

    let rail = SessionRailViewController()
    rail.workspace = workspace
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentViewController = rail
    self.window = window
    rail.loadViewIfNeeded()
    rail.reload()
    let outline = rail.outlineViewForTesting
    var levels: [String: Int] = [:]
    for row in 0..<outline.numberOfRows {
      guard let node = outline.item(atRow: row) as? RailNode, let session = node.session else {
        continue
      }
      levels[session.title ?? ""] = outline.level(forRow: row)
    }
    XCTAssertEqual(levels["Child"], (levels["Top"] ?? -9) + 1)
    XCTAssertEqual(levels["Grandchild"], (levels["Child"] ?? -9) + 1)
    XCTAssertEqual(levels["Loose"], levels["Top"])
  }

  /// A family folds by hand, and a folded family's row says the loudest state inside it, so a
  /// side session waiting on the person is never hidden behind the fold.
  func testAFoldedFamilySaysWhatWaitsInsideIt() {
    let repo = Repository(id: root.path)
    let main = Worktree(url: root, branch: "main", repository: repo)
    repo.worktrees = [main]
    let workspace = Workspace()
    workspace.repositories = [repo]
    workspace.selectedWorktreeID = main.id
    let top = AgentSession(worktreeID: main.id)
    top.title = "Top"
    let child = AgentSession(worktreeID: main.id)
    child.title = "Child"
    child.origin = SessionOrigin(parentID: top.id)
    let grandchild = AgentSession(worktreeID: main.id)
    grandchild.title = "Grandchild"
    grandchild.origin = SessionOrigin(parentID: child.id)
    grandchild.state = .needsAttention
    workspace.sessions = [top, child, grandchild]
    workspace.collapsedFamilies = [top.id.uuidString]

    let rail = SessionRailViewController()
    rail.workspace = workspace
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentViewController = rail
    self.window = window
    rail.loadViewIfNeeded()
    rail.reload()
    let outline = rail.outlineViewForTesting
    let rows = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? RailNode }
    let topRow = rows.first { $0.session === top }
    XCTAssertNotNil(topRow)
    XCTAssertFalse(rows.contains { $0.session === child })
    XCTAssertEqual(topRow?.state, .needsAttention)

    workspace.collapsedFamilies = []
    rail.reload()
    let open = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? RailNode }
    XCTAssertTrue(open.contains { $0.session === grandchild })
    XCTAssertEqual(open.first { $0.session === top }?.state, top.state)
  }

  /// Archiving the top session takes the side sessions with nothing left to do with it, and
  /// leaves one that was moved to top level.
  func testArchivingTakesSettledSideSessionsAlong() {
    let workspace = Workspace()
    let worktree = UUID()
    let top = AgentSession(worktreeID: worktree)
    let child = AgentSession(worktreeID: worktree)
    child.origin = SessionOrigin(parentID: top.id)
    let loose = AgentSession(worktreeID: worktree)
    loose.origin = SessionOrigin(parentID: top.id, detached: true)
    workspace.sessions = [top, child, loose]
    XCTAssertTrue(workspace.setArchived(true, for: [top]))
    XCTAssertEqual(workspace.archivedSessionIDs, [top.id, child.id])
  }

  @discardableResult
  private func git(_ arguments: [String], in dir: URL? = nil) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = dir ?? root
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
