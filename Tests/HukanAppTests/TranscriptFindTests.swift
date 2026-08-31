import AppKit
import XCTest

@testable import Hukan

/// ⌘F in the conversation, and the two things it has to do before the find bar sees anything:
/// open every folded tool call, and — for the rail's half of the same question — count those
/// calls as part of the transcript rather than as machinery underneath it.
final class TranscriptFindTests: XCTestCase {
  override class func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  /// A command long enough that the folded line's 90-character summary cannot hold it, and whose
  /// tail is what a search has to be able to reach.
  private static let command =
    "git worktree add ../feature-x -b feature/a-branch-name-long-enough-to-be-clipped origin/main"
  private static let tail = "origin/main"

  // MARK: The fold is not a filter

  func testExpandingOpensEveryFoldAndKeepsTheReadersPlace() throws {
    let (_, textView) = makeTranscriptTextView()
    let storage = try XCTUnwrap(textView.textStorage)
    storage.setAttributedString(
      Transcript.toolUse(name: "Bash", input: ["command": Self.command]))
    // The reader is standing on a word between the two calls, so opening the first moves them
    // and opening the second does not.
    storage.append(NSAttributedString(string: "the reader is here\n"))
    let offset = (storage.string as NSString).range(of: "here").location
    storage.append(Transcript.toolUse(name: "Bash", input: ["command": Self.command]))

    XCTAssertFalse(storage.string.contains(Self.tail), "folded, the tail is not text at all")

    let delegate = try XCTUnwrap(transcriptClickDelegate(of: textView))
    let moved = delegate.expandAllFolds(in: textView, preserving: offset)

    XCTAssertFalse(storage.string.contains("▸"), "no fold left shut")
    XCTAssertEqual(
      storage.string.components(separatedBy: Self.tail).count - 1, 2,
      "both calls open, each showing the whole command")
    XCTAssertGreaterThan(moved, offset, "the fold that opened above the reader moved them down")
    XCTAssertTrue(
      (storage.string as NSString).substring(from: moved).hasPrefix("here"),
      "and the offset handed back still names the character it named before")
  }

  /// The gesture the app makes: ⌘F on a conversation whose tool calls are folded opens the bar
  /// over a transcript that now holds the whole of what it is being asked about.
  @MainActor
  func testFindOpensTheBarOverAnUnfoldedTranscript() throws {
    let workspace = Workspace()
    let repo = Repository(id: "/repo/hukan")
    let main = Worktree(url: URL(fileURLWithPath: "/repo/hukan"), branch: "main", repository: repo)
    repo.worktrees = [main]
    workspace.repositories = [repo]
    let session = AgentSession(worktreeID: main.id)
    session.transcript.append(Transcript.toolUse(name: "Bash", input: ["command": Self.command]))
    workspace.sessions = [session]
    workspace.selectedWorktreeID = main.id
    workspace.selectedSessionID = session.id

    let column = RunningColumnViewController()
    column.workspace = workspace
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.contentView = column.view
    column.reload()
    window.contentView?.layoutSubtreeIfNeeded()

    let item = NSMenuItem()
    item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
    column.performFind(item)
    window.contentView?.layoutSubtreeIfNeeded()

    let scrollView = try XCTUnwrap(findScrollView(in: column.view))
    XCTAssertTrue(scrollView.isFindBarVisible, "⌘F shows the bar")
    XCTAssertTrue(
      session.transcript.string.contains(Self.tail),
      "and the fold opened first, in the session's own copy as well as the view's")
  }

  private func findScrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView, scrollView.documentView is TranscriptTextView {
      return scrollView
    }
    for subview in view.subviews {
      if let found = findScrollView(in: subview) { return found }
    }
    return nil
  }

  /// The routing itself: ⌘F is one item, and where it lands is where the focus is. With the
  /// transcript focused it must reach the conversation even though the desk is what the key used
  /// to be wired to unconditionally.
  @MainActor
  func testTheFocusDecidesWhichColumnFindMeans() throws {
    let workspace = RailPreviewTests.sampleWorkspace()
    workspace.selectedWorktreeID = workspace.sessions[0].worktreeID
    workspace.selectedSessionID = workspace.sessions[0].id
    workspace.sessions[0].transcript.append(
      Transcript.toolUse(name: "Bash", input: ["command": Self.command]))

    let controller = WorkspaceWindowController(workspace: workspace)
    let window = try XCTUnwrap(controller.window)
    window.setFrame(NSRect(x: 0, y: -4000, width: 1200, height: 700), display: true)
    window.makeKeyAndOrderFront(nil)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
    controller.arrangeColumnsIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
    defer { window.close() }

    let scrollView = try XCTUnwrap(findScrollView(in: try XCTUnwrap(window.contentView)))
    let textView = try XCTUnwrap(scrollView.documentView as? TranscriptTextView)
    window.makeFirstResponder(textView)

    let item = NSMenuItem()
    item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
    XCTAssertTrue(controller.validateMenuItem(item), "the key is live over a conversation")
    controller.find(item)
    window.contentView?.layoutSubtreeIfNeeded()

    XCTAssertTrue(
      scrollView.isFindBarVisible, "⌘F with the transcript focused finds in the transcript")
    XCTAssertTrue(
      workspace.sessions[0].transcript.string.contains(Self.tail), "and opened its folds first")
  }

  // MARK: The rail's half of the same question

  /// What decides whether a session matches at all. A tool call is on screen, so it counts — and
  /// it counts in full, because the 90 characters the folded line shows are a reading
  /// convenience and the search must not inherit them as a limit.
  func testTheRailsGateReadsToolCallsInFull() throws {
    let worktree = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-find-\(UUID().uuidString)")
    let id = UUID()
    let directory = ClaudeSessionStore.directory(for: worktree)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let lines = [
      #"{"type":"user","uuid":"a","message":{"role":"user","content":"cut me a branch"}}"#,
      """
      {"type":"assistant","parentUuid":"a","uuid":"b","message":{"role":"assistant",\
      "content":[{"type":"text","text":"Making the worktree."},\
      {"type":"tool_use","name":"Bash","input":{"command":"\(Self.command)"}}]}}
      """,
    ]
    try lines.joined(separator: "\n").write(
      to: ClaudeSessionStore.transcriptURL(id: id, worktree: worktree), atomically: true,
      encoding: .utf8)

    let records = try XCTUnwrap(ClaudeSessionStore.history(id: id, worktree: worktree)?.records)
    let gate = SessionRailViewController.gateText(records)

    XCTAssertTrue(gate.contains("cut me a branch"), "what the person typed")
    XCTAssertTrue(gate.contains("making the worktree"), "what the agent answered")
    XCTAssertTrue(gate.contains("bash"), "the tool's name, which is on the line")
    XCTAssertTrue(gate.contains(Self.tail), "and its argument past the summary's cut")
    XCTAssertFalse(
      Transcript.render(records).string.contains(Self.tail),
      "which the rendered transcript alone could never have answered for")
  }
}
