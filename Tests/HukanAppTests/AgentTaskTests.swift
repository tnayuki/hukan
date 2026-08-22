import XCTest

@testable import Hukan

/// The task list behind the card: reading Claude Code's own task store, and the three rules the
/// card is drawn from — when there is a card at all, what its folded row says, and which of the
/// tasks left are actually waiting on another one.
final class AgentTaskTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hukan-tasks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  /// Writes one task file the way `TaskCreate` does, `blockedBy` included.
  private func write(
    _ id: String, _ subject: String, activeForm: String = "", status: String,
    blockedBy: [String] = []
  ) throws {
    let record: [String: Any] = [
      "id": id, "subject": subject, "description": "", "activeForm": activeForm,
      "status": status, "blocks": [], "blockedBy": blockedBy,
    ]
    try JSONSerialization.data(withJSONObject: record)
      .write(to: directory.appendingPathComponent("\(id).json"))
  }

  private func tasks() -> [AgentTask] { ClaudeSessionStore.tasks(in: directory) }

  func testReadsSubjectActiveFormAndStatus() throws {
    try write("1", "Inspect the module conventions", status: "completed")
    try write(
      "2", "Create the OIDC module", activeForm: "Creating the OIDC module", status: "in_progress")
    try write("3", "Wire the batch role", status: "pending")

    let list = tasks()
    XCTAssertEqual(list.map(\.status), [.completed, .inProgress, .pending])
    XCTAssertEqual(list[1].subject, "Create the OIDC module")
    XCTAssertEqual(list[1].activeForm, "Creating the OIDC module")
  }

  /// Ids are numbers and the order is the order they were created in, so ten tasks must not
  /// sort `1, 10, 2` — which is what a plain string sort of the file names would give.
  func testOrdersByIdNumerically() throws {
    for id in ["1", "2", "10"] { try write(id, "Task \(id)", status: "pending") }
    XCTAssertEqual(tasks().map(\.id), ["1", "2", "10"])
  }

  /// An unknown status is a pending task, not a dropped one: losing a row would misstate the
  /// count on the folded card. A file with no subject has no row to draw and is skipped.
  func testUnknownStatusIsPendingAndASubjectlessFileIsSkipped() throws {
    try write("1", "Something", status: "blocked")
    try write("2", "", status: "pending")
    let list = tasks()
    XCTAssertEqual(list.count, 1)
    XCTAssertEqual(list.first?.status, .pending)
  }

  /// No directory at all is an empty list, not a crash: most sessions never write one.
  func testAMissingStoreIsAnEmptyList() {
    XCTAssertEqual(ClaudeSessionStore.tasks(in: directory.appendingPathComponent("nope")), [])
    XCTAssertEqual(ClaudeSessionStore.tasks(id: UUID()), [])
  }

  /// The task tools have the card, so they must leave no line in a replayed conversation either
  /// — otherwise a restored session reads differently from the one that just ran. `TaskStop`
  /// only shares the prefix and keeps its line.
  func testTheTaskToolsRenderNoTranscriptLine() {
    XCTAssertTrue(Transcript.hasOwnCard(tool: "TaskCreate"))
    XCTAssertTrue(Transcript.hasOwnCard(tool: "TaskUpdate"))
    XCTAssertTrue(Transcript.hasOwnCard(tool: "AskUserQuestion"))
    XCTAssertFalse(Transcript.hasOwnCard(tool: "TaskStop"))
    XCTAssertFalse(Transcript.hasOwnCard(tool: "Bash"))
    XCTAssertEqual(
      Transcript.toolUse(name: "TaskUpdate", input: ["taskId": "1", "status": "completed"]).length,
      0)
    XCTAssertGreaterThan(
      Transcript.toolUse(name: "TaskStop", input: ["task_id": "abc"]).length, 0)
  }

  /// The same list, seen from the session: which tools are worth re-reading the store after.
  func testOnlyTheTaskWritersTriggerARefresh() {
    XCTAssertTrue(AgentSession.writesTasks(tool: "TaskCreate"))
    XCTAssertTrue(AgentSession.writesTasks(tool: "TaskUpdate"))
    XCTAssertFalse(AgentSession.writesTasks(tool: "TaskOutput"))
    XCTAssertFalse(AgentSession.writesTasks(tool: "TaskStop"))
  }

  /// The card is the working list, so a finished one has no card — which is what makes a card
  /// still standing after the turn the sign that the work stopped half-done.
  func testAFinishedListHasNoCard() throws {
    let session = AgentSession(worktreeID: UUID())
    XCTAssertFalse(session.hasOpenTasks)

    try write("1", "Ship it", activeForm: "Shipping it", status: "in_progress")
    session.tasks = tasks()
    XCTAssertTrue(session.hasOpenTasks)

    try write("1", "Ship it", activeForm: "Shipping it", status: "completed")
    session.tasks = tasks()
    XCTAssertFalse(session.hasOpenTasks)
  }

  /// The folded row names what is running, in the phrasing the task carries for exactly that —
  /// and between tasks, what it will pick up next.
  func testTheFoldedRowNamesWhatIsRunningThenWhatIsNext() throws {
    try write("1", "Inspect the conventions", status: "completed")
    try write("2", "Create the module", activeForm: "Creating the module", status: "in_progress")
    XCTAssertEqual(TaskCard.currentLabel(of: tasks()), "Creating the module")

    try write("2", "Create the module", activeForm: "Creating the module", status: "pending")
    XCTAssertEqual(TaskCard.currentLabel(of: tasks()), "Create the module")
  }

  /// Blocked is a fact about the list, not a field: a task waiting on one that has since landed
  /// is free to start, and must not be drawn as held up.
  func testOnlyTasksWaitingOnUnfinishedWorkCountAsBlocked() throws {
    try write("1", "Land the migration", status: "completed")
    try write("2", "Rewrite the reader", status: "in_progress")
    try write("3", "Backfill", status: "pending", blockedBy: ["1"])
    try write("4", "Delete the old column", status: "pending", blockedBy: ["2"])
    XCTAssertEqual(TaskCard.blockedIDs(in: tasks()), ["4"])
  }
}
