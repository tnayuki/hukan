import XCTest

@testable import Hukan

/// A subagent sent to the background outlives the turn that launched it: the turn's `result`
/// arrives while it is still working, and the engine opens a turn of its own when it reports
/// back. Read as the end of the work, that `result` put the green check on a session whose agent
/// was still busy.
final class BackgroundTaskTests: XCTestCase {
  private func system(_ subtype: String, _ payload: [String: Any] = [:]) -> ClaudeEvent {
    ClaudeEvent(type: "system", subtype: subtype, payload: payload)
  }

  private func started(_ id: String, type: String) -> ClaudeEvent {
    system("task_started", ["task_id": id, "task_type": type, "is_backgrounded": true])
  }

  private func notified(_ id: String) -> ClaudeEvent {
    system("task_notification", ["task_id": id, "status": "completed"])
  }

  private let result = ClaudeEvent(type: "result", subtype: "success", payload: [:])

  func testATurnThatLeavesASubagentRunningIsNotDone() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(system("init"))
    session.apply(started("a1", type: "local_agent"))
    session.apply(result)
    XCTAssertEqual(session.state, .running, "the subagent is still working")
    XCTAssertTrue(session.isWorking)
    XCTAssertFalse(session.isTurnActive, "a send now goes straight to the engine")
  }

  /// The engine hands the subagent's result to the model in a turn it opens itself, and that
  /// turn's `result` is what finally ends the work.
  func testTheTurnTheEngineOpensOnReportIsWhatEndsIt() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(system("init"))
    session.apply(started("a1", type: "local_agent"))
    session.apply(result)
    session.apply(notified("a1"))
    XCTAssertEqual(session.state, .running, "no check flashed between report and turn")
    session.apply(system("init"))
    XCTAssertTrue(session.isTurnActive, "the engine's own turn is a turn in flight")
    session.apply(result)
    XCTAssertEqual(session.state, .idle)
    XCTAssertFalse(session.isWorking)
  }

  /// A backgrounded shell is often a server meant to run until someone stops it.
  func testABackgroundShellDoesNotHoldTheSessionBusy() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(system("init"))
    session.apply(started("b1", type: "local_bash"))
    session.apply(result)
    XCTAssertEqual(session.state, .idle)
    XCTAssertFalse(session.isWorking)
  }

  /// A foreground subagent reports before its turn ends, so nothing is left over.
  func testAForegroundSubagentLeavesNothingBehind() {
    let session = AgentSession(worktreeID: UUID())
    session.apply(system("init"))
    session.apply(started("a1", type: "local_agent"))
    session.apply(notified("a1"))
    session.apply(result)
    XCTAssertEqual(session.state, .idle)
  }
}

/// What the parent's row says of its subagents: a line for each one at work and what it did last,
/// and the worktrees they made — read off the engine's own record beside the transcript.
final class SubagentRowTests: XCTestCase {
  private func system(_ subtype: String, _ payload: [String: Any] = [:]) -> ClaudeEvent {
    ClaudeEvent(type: "system", subtype: subtype, payload: payload)
  }

  /// A line per subagent: what it was sent to do and the last tool it used, in the order they were
  /// started — and past three, the last line counts the rest rather than the row growing on.
  func testTheRowGivesEachRunningSubagentALine() {
    let session = AgentSession(worktreeID: UUID())
    func lines() -> [String] { SessionRailViewController.agentLines(session.runningSubagents) }
    session.apply(system("init"))
    session.apply(
      system(
        "task_started",
        ["task_id": "a1", "task_type": "local_agent", "description": "Write tag tests"]))
    XCTAssertEqual(lines(), ["Write tag tests"])
    session.apply(system("task_progress", ["task_id": "a1", "last_tool_name": "Bash"]))
    session.apply(system("task_started", ["task_id": "a2", "task_type": "local_agent"]))
    XCTAssertEqual(lines(), ["Write tag tests · Bash", "Subagent"])
    for id in ["a3", "a4", "a5"] {
      session.apply(system("task_started", ["task_id": id, "task_type": "local_agent"]))
    }
    XCTAssertEqual(lines(), ["Write tag tests · Bash", "Subagent", "+3 more"])
    for id in ["a1", "a2", "a3", "a4", "a5"] {
      session.apply(system("task_notification", ["task_id": id, "status": "completed"]))
    }
    XCTAssertEqual(lines(), [])
  }

  /// The record a subagent sent into a worktree leaves, as the engine writes it (measured on
  /// 2.1.300): the worktree's path, its branch and the call that launched it.
  func testASubagentsRecordNamesTheWorktreeItMade() throws {
    let checkout = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let id = UUID()
    let store = ClaudeSessionStore.directory(for: checkout)
    let directory = store.appendingPathComponent(ClaudeSessionStore.name(id))
      .appendingPathComponent("subagents")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: store) }
    let meta = """
      {"agentType":"general-purpose","worktreePath":"/repo/.claude/worktrees/agent-a0b7",\
      "spawnedWithWorktree":true,"worktreeBranch":"worktree-agent-a0b7",\
      "description":"Create sub.txt and commit","toolUseId":"toolu_01","spawnDepth":1}
      """
    try Data(meta.utf8).write(to: directory.appendingPathComponent("agent-a0b7.meta.json"))
    try Data("{}".utf8).write(to: directory.appendingPathComponent("agent-a0b7.jsonl"))
    try Data(#"{"description":"No worktree"}"#.utf8).write(
      to: directory.appendingPathComponent("agent-c1d2.meta.json"))

    let found = ClaudeSessionStore.subagents(of: id, worktree: checkout)
    XCTAssertEqual(found.count, 2, "one record per subagent, the transcripts beside them not read")
    let made = try XCTUnwrap(found.first { $0.agentID == "a0b7" })
    XCTAssertEqual(made.worktree?.path, "/repo/.claude/worktrees/agent-a0b7")
    XCTAssertEqual(made.toolUseID, "toolu_01")
    XCTAssertEqual(made.description, "Create sub.txt and commit")
    XCTAssertNil(found.first { $0.agentID == "c1d2" }?.worktree)
  }

  /// Opening the `Agent` call that launched a subagent reads the subagent's own conversation into
  /// it — a file whose every record is marked as a sidechain, the mark a session's own file is read
  /// past — under the prompt, which its first message would only repeat, and with nothing in it
  /// that answers a click.
  func testOpeningAnAgentCallReadsItsSubagentsConversationIntoIt() throws {
    let checkout = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let session = AgentSession(worktreeID: UUID())
    let store = ClaudeSessionStore.directory(for: checkout)
    let directory = store.appendingPathComponent(ClaudeSessionStore.name(session.id))
      .appendingPathComponent("subagents")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: store) }
    try Data(#"{"description":"Write tests","toolUseId":"toolu_01"}"#.utf8).write(
      to: directory.appendingPathComponent("agent-a0b7.meta.json"))
    let lines = [
      #"{"type":"user","isSidechain":true,"uuid":"u1","parentUuid":null,"#
        + #""message":{"role":"user","content":"Write the tag tests"}}"#,
      #"{"type":"assistant","isSidechain":true,"uuid":"a1","parentUuid":"u1","#
        + #""message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_09","#
        + #""name":"Bash","input":{"command":"swift test"}}]}}"#,
      #"{"type":"assistant","isSidechain":true,"uuid":"a2","parentUuid":"a1","#
        + #""message":{"role":"assistant","content":[{"type":"text","text":"All tests pass."}]}}"#,
    ]
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(
      to: directory.appendingPathComponent("agent-a0b7.jsonl"))
    session.loadHistoryIfNeeded(at: checkout)

    let child = try XCTUnwrap(session.subagentTranscript(forToolUseID: "toolu_01"))
    XCTAssertTrue(child.string.contains("All tests pass."), child.string)
    XCTAssertTrue(child.string.contains("Bash"), "its own tool calls are there too")
    XCTAssertFalse(child.string.contains("Write the tag tests"), "the prompt is shown once, above")
    XCTAssertNil(session.subagentTranscript(forToolUseID: "toolu_99"), "a call with no record")

    let token = ToolCallToken(
      name: "Agent", summary: "Write the tag tests", full: "Write the tag tests",
      subagent: { child })
    let opened = Transcript.toolCallExpandedRun(token)
    XCTAssertTrue(opened.string.contains("Subagent's transcript"))
    let body = (opened.string as NSString).range(of: "All tests pass.")
    XCTAssertNil(
      opened.attribute(.link, at: body.location, effectiveRange: nil),
      "nothing inside answers a click, which belongs to the call around it")
  }
}
