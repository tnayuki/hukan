import XCTest

@testable import Hukan

/// The held-elsewhere watch: a session another live process owns is marked held, and the hold
/// lifts on its own the moment that process exits — the release edge that drives the rail back
/// from greyed to startable. The same registry is also how a session started outside this window
/// reaches the rail at all, before it has written a transcript to be discovered by.
final class HeldElsewhereTests: XCTestCase {
  /// The watch that gives an adopted row its name matches on the transcript's file name, which
  /// is the one comparison in this window a case-insensitive volume cannot rescue. Both spellings
  /// have to land: a row born in a terminal carries an id the CLI minted and named in lower case,
  /// and hukan's own transcripts from before it spelt ids that way are still upper.
  func testATranscriptReachesItsRowInEitherSpelling() {
    let workspace = Workspace()
    let session = AgentSession(worktreeID: UUID())
    session.isRegistryBorn = true
    workspace.sessions = [session]

    let directory = "/Users/x/.claude/projects/-tmp-w/"
    XCTAssertEqual(
      workspace.watchedTranscripts(
        movedIn: [directory + ClaudeSessionStore.name(session.id) + ".jsonl"]),
      [session.id], "the spelling the CLI names a file it made itself with")
    XCTAssertEqual(
      workspace.watchedTranscripts(movedIn: [directory + session.id.uuidString + ".jsonl"]),
      [session.id], "and the one hukan used to write")
    XCTAssertEqual(
      workspace.watchedTranscripts(movedIn: [directory + UUID().uuidString + ".jsonl"]), [],
      "every claude on the machine writes into this directory; only these rows are watched for")
  }

  /// A live process to stand in for another engine. Terminated by the test's teardown.
  private var holders: [Process] = []

  override func tearDown() {
    for holder in holders where holder.isRunning { holder.terminate() }
    holders = []
    super.tearDown()
  }

  private func liveProcess() throws -> pid_t {
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
    holder.arguments = ["30"]
    try holder.run()
    holders.append(holder)
    return holder.processIdentifier
  }

  /// Marking a session held by a live pid, then killing that process, clears the hold via the
  /// direct `.exit` watch — no polling, no directory event needed. This is the crux of the
  /// design: the release fires on the holder's death (here a SIGTERM), whether clean or a crash.
  func testHoldLiftsWhenHolderExits() throws {
    let session = AgentSession(worktreeID: UUID())

    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
    holder.arguments = ["30"]
    try holder.run()
    let pid = holder.processIdentifier

    // markHeldElsewhere notifies synchronously, so the closure is armed before the call.
    session.onHeldChange = {}
    session.markHeldElsewhere(by: pid)
    XCTAssertEqual(session.heldByPID, pid, "marking held records the owning pid")

    let lifted = expectation(description: "hold lifted on holder exit")
    session.onHeldChange = {
      if session.heldByPID == nil { lifted.fulfill() }
    }
    holder.terminate()
    wait(for: [lifted], timeout: 5)
    XCTAssertNil(session.heldByPID, "the hold lifts once the holder is gone")
  }

  /// Marking held by the same pid twice does not re-notify — a re-scan finding the same holder is
  /// a no-op, so the rail is not reloaded on every registry event.
  func testReMarkingSamePidIsIdempotent() throws {
    let session = AgentSession(worktreeID: UUID())
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
    holder.arguments = ["30"]
    try holder.run()
    defer { holder.terminate() }
    let pid = holder.processIdentifier

    var notifications = 0
    session.onHeldChange = { notifications += 1 }
    session.markHeldElsewhere(by: pid)
    session.markHeldElsewhere(by: pid)
    XCTAssertEqual(notifications, 1, "the same holder marks once")

    session.clearHeldElsewhere()
    XCTAssertNil(session.heldByPID)
    XCTAssertEqual(notifications, 2, "clearing an active hold notifies")
    session.clearHeldElsewhere()
    XCTAssertEqual(notifications, 2, "clearing an already-clear hold does not")
  }

  // MARK: reading the registry

  /// The record says where the engine is standing, not only which process it is — the field the
  /// rail needs to place a session it has never seen. A dead pid is still skipped: the file
  /// outlives a crash, and a hold nobody holds would grey a row for good.
  func testARecordCarriesTheProcessAndTheDirectoryItStandsIn() throws {
    let registry = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-registry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: registry) }

    let live = UUID()
    let livePID = try liveProcess()
    try write(
      session: live, pid: livePID, cwd: "/tmp/hukan-live", to: registry)

    let dead = UUID()
    let corpse = Process()
    corpse.executableURL = URL(fileURLWithPath: "/bin/sleep")
    corpse.arguments = ["0"]
    try corpse.run()
    corpse.waitUntilExit()
    try write(session: dead, pid: corpse.processIdentifier, cwd: "/tmp/hukan-dead", to: registry)

    let owners = ClaudeSessionStore.liveProcessOwners(in: registry)
    XCTAssertEqual(owners.count, 1, "only the live record answers")
    XCTAssertEqual(owners[live]?.pid, livePID)
    XCTAssertEqual(owners[live]?.cwd?.path, "/tmp/hukan-live")
    XCTAssertNil(owners[dead], "a record whose process is gone is not a holder")
  }

  private func write(session: UUID, pid: pid_t, cwd: String, to registry: URL) throws {
    let record: [String: Any] = ["pid": Int(pid), "sessionId": session.uuidString, "cwd": cwd]
    try JSONSerialization.data(withJSONObject: record).write(
      to: registry.appendingPathComponent("\(pid).json"))
  }

  // MARK: a session born behind the window's back

  /// The case the registry read exists for: `claude` started in a terminal, in a worktree this
  /// window holds. Discovery cannot see it — the transcript does not exist until the first
  /// message — so the record is what puts the row up, held, in its own worktree.
  func testASessionStartedOutsideTheWindowJoinsItsWorktree() throws {
    let (workspace, root) = try openedWorktree()
    let id = UUID()
    let pid = try liveProcess()

    workspace.adoptRegisteredSessions([id: .init(pid: pid, cwd: root)])

    let session = try XCTUnwrap(workspace.sessions.first { $0.id == id })
    XCTAssertEqual(
      session.worktreeID, workspace.worktree(atPath: root.path)?.id,
      "it belongs to the worktree it was started in")
    XCTAssertEqual(session.heldByPID, pid, "and it is that process's, not ours to start")
    XCTAssertFalse(
      session.isDetached, "with no transcript yet, a start would be a fresh id and not a resume")
  }

  /// Adoption runs on every registry event, so it has to be idempotent: a session already on the
  /// rail — discovered, or adopted a moment ago — is not listed twice.
  func testASessionAlreadyOnTheRailIsNotAdoptedTwice() throws {
    let (workspace, root) = try openedWorktree()
    let id = UUID()
    let pid = try liveProcess()
    let owners: [UUID: ClaudeSessionStore.SessionOwner] = [id: .init(pid: pid, cwd: root)]

    workspace.adoptRegisteredSessions(owners)
    workspace.adoptRegisteredSessions(owners)
    XCTAssertEqual(workspace.sessions.filter { $0.id == id }.count, 1)
  }

  /// Only the worktree root counts. Claude Code keys its transcript directory off the cwd, so a
  /// session started one level down writes where `sessions(in:)` will never look — a row for it
  /// would be one the next discovery drops. A directory this window does not hold at all is not
  /// ours to show either: every other repository on the machine is in that registry too.
  func testADirectoryTheWindowDoesNotHoldIsNotAdopted() throws {
    let (workspace, root) = try openedWorktree()
    let inside = root.appendingPathComponent("sub")
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    let elsewhere = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-elsewhere-\(UUID().uuidString)")
    let pid = try liveProcess()

    workspace.adoptRegisteredSessions([
      UUID(): .init(pid: pid, cwd: inside),
      UUID(): .init(pid: pid, cwd: elsewhere),
      UUID(): .init(pid: pid, cwd: nil),
    ])
    XCTAssertTrue(workspace.sessions.isEmpty)
  }

  /// The other end of an adoption: the process is gone and it wrote nothing, so there was never a
  /// conversation and the row goes with it. Left standing, every `claude` started and quit before
  /// a word was typed would leave a "New session" behind for good.
  func testAnAdoptedRowThatWroteNothingLeavesWithItsProcess() throws {
    let (workspace, root) = try openedWorktree()
    let pid = try liveProcess()
    workspace.adoptRegisteredSessions([UUID(): .init(pid: pid, cwd: root)])
    XCTAssertEqual(workspace.sessions.count, 1)

    // The real registry does not name this id, so the rescan reads it as a holder that has gone.
    workspace.rescanHeldSessions()
    XCTAssertTrue(workspace.sessions.isEmpty, "a row standing for nothing does not stay")
  }

  /// The same rescan on a session that did write: it is an ordinary detached row from then on —
  /// kept, resumable, and no longer asked about.
  func testAnAdoptedRowThatWroteATranscriptStays() throws {
    let (workspace, root) = try openedWorktree()
    let id = UUID()
    let pid = try liveProcess()
    let transcripts = ClaudeSessionStore.directory(for: root)
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: transcripts) }
    try Data().write(to: transcripts.appendingPathComponent("\(id.uuidString).jsonl"))

    workspace.adoptRegisteredSessions([id: .init(pid: pid, cwd: root)])
    workspace.rescanHeldSessions()

    let session = try XCTUnwrap(workspace.sessions.first { $0.id == id })
    XCTAssertTrue(session.isDetached, "there is a conversation to resume")
  }

  /// The name is the other thing an adopted row has to wait for: it goes up before the transcript
  /// exists, and reading titles is discovery's job, which has already run. So the transcript store
  /// is watched — but only while something is actually waiting, since every claude on the machine
  /// writes into it.
  func testTheTranscriptStoreIsWatchedOnlyWhileARowIsWaitingForItsName() throws {
    let (workspace, root) = try openedWorktree()
    let id = UUID()
    let pid = try liveProcess()
    XCTAssertNil(workspace.transcriptsWatcher, "nothing is waiting, so nothing is watched")

    workspace.adoptRegisteredSessions([id: .init(pid: pid, cwd: root)])
    XCTAssertNotNil(
      workspace.transcriptsWatcher, "a nameless row is waiting for the file its name is in")

    workspace.sessions.first { $0.id == id }?.title = "named"
    workspace.syncTranscriptWatcher()
    XCTAssertNil(workspace.transcriptsWatcher, "and the stream goes down with the wait")
  }

  private func openedWorktree() throws -> (Workspace, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-adopt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace()
    workspace.addWorktree(root)
    return (workspace, root)
  }
}
