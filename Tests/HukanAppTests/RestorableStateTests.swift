import XCTest

@testable import Hukan

/// Round-trips `Workspace.encodeState`/`decodeState` through a real keyed archiver, the way
/// AppKit's restorable state machinery drives them. The per-session model roster is the fragile
/// part — nested parallel arrays with hand-written index fallbacks — so these tests pin both the
/// round trip and the raw key strings: renaming a key silently drops what last session stored.
final class RestorableStateTests: XCTestCase {
  private func roundTrip(_ workspace: Workspace) throws -> Workspace {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    workspace.encodeState(to: archiver)
    archiver.finishEncoding()
    let restored = Workspace()
    restored.decodeState(from: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData))
    return restored
  }

  /// A stand-in for what discovery rebuilds after decode: a fresh session carrying only its id,
  /// handed to `applyRestoredPrefs` the way `discoverSessions` hands every rebuilt one.
  private func revived(_ id: UUID, by workspace: Workspace) -> AgentSession {
    let session = AgentSession(id: id, worktreeID: UUID(), isDetached: true)
    workspace.applyRestoredPrefs(to: session)
    return session
  }

  private func model(_ value: String, name: String? = nil, resolved: String? = nil) -> ClaudeModel {
    ClaudeModel(value: value, displayName: name ?? value, resolvedModel: resolved ?? value)
  }

  /// Archiving is a decision of yours with no owner on disk, so it is the one piece of the rail's
  /// state that has to survive a restart intact — and the one that must not quietly grow forever.
  func testArchivedSessionsRoundTripAndPruneOnlyWhatWasResolved() throws {
    // A real main worktree behind them: only main's sessions can be archived at all.
    let repo = Repository(id: "/repo/main")
    let main = Worktree(url: URL(fileURLWithPath: "/repo/main"), branch: "main", repository: repo)
    repo.worktrees = [main]
    let workspace = Workspace()
    workspace.repositories = [repo]
    let kept = AgentSession(worktreeID: main.id)
    let plain = AgentSession(worktreeID: main.id)
    workspace.sessions = [kept, plain]
    XCTAssertTrue(workspace.setArchived(true, for: [kept]))

    let restored = try roundTrip(workspace)
    XCTAssertEqual(restored.archivedSessionIDs, [kept.id])

    // An id no discovery has claimed belongs to a repository this window has not opened, so it
    // rides through untouched — dropping it would silently unarchive a whole repository the next
    // time it is opened.
    XCTAssertEqual(try roundTrip(restored).archivedSessionIDs, [kept.id])

    // Once discovery *has* answered for it and the session is gone, the id goes with it: that is
    // what keeps the set bounded by what is on disk rather than by how long hukan has run.
    restored.resolveArchivedID(kept.id)
    XCTAssertTrue(try roundTrip(restored).archivedSessionIDs.isEmpty)
  }

  func testRosterRoundTripsPerSession() throws {
    let workspace = Workspace()
    let first = AgentSession(worktreeID: UUID())
    first.seedModels([
      model("default", name: "Default (recommended)", resolved: "claude-sonnet-5"),
      model("claude-fable-5[1m]", name: "Fable 1M"),
    ])
    let second = AgentSession(worktreeID: UUID())
    second.seedModels([model("opus", name: "Opus", resolved: "claude-opus-4-8")])
    let blank = AgentSession(worktreeID: UUID())
    workspace.sessions = [first, second, blank]

    let restored = try roundTrip(workspace)

    // Each session gets its own list back, not a shared or borrowed one.
    XCTAssertEqual(
      revived(first.id, by: restored).availableModels.map(\.value),
      ["default", "claude-fable-5[1m]"])
    let secondModels = revived(second.id, by: restored).availableModels
    XCTAssertEqual(secondModels.map(\.displayName), ["Opus"])
    XCTAssertEqual(secondModels.map(\.resolvedModel), ["claude-opus-4-8"])
    // A session that never connected stored nothing, and seeds nothing back.
    XCTAssertTrue(revived(blank.id, by: restored).availableModels.isEmpty)
    // A stale id — a session gone from disk between runs — is simply ignored.
    XCTAssertTrue(revived(UUID(), by: restored).availableModels.isEmpty)
  }

  func testBrowserTabsRoundTripWithTheirState() throws {
    let worktree = UUID()
    let tabs = [
      BrowserTabState(
        worktreeID: worktree, url: "https://github.com/tnayuki/hukan/pull/12",
        title: "Pull Request #12", interactionState: Data([0, 255, 7])),
      BrowserTabState(
        worktreeID: worktree, url: "https://example.com", title: "", interactionState: nil),
    ]
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    Workspace().encodeState(to: archiver, browserTabs: tabs)
    archiver.finishEncoding()
    let restored = Workspace()
    restored.decodeState(from: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData))
    XCTAssertEqual(restored.takeRestoredBrowserTabs(), tabs)
    XCTAssertTrue(restored.takeRestoredBrowserTabs().isEmpty, "taken once")
  }

  func testTerminalsRoundTripByWorktreeWithDirectoryAndSession() throws {
    let workspace = Workspace()
    let worktreeA = UUID()
    let worktreeB = UUID()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    // An unspawned terminal carrying restored scrollback stands in for one saved and not yet
    // re-shown: `scrollbackText()` passes its text straight through, no live shell needed.
    let first = TerminalSession(
      worktreeID: worktreeA, cwd: tmp, restoredScrollback: "line one\nline two")
    let second = TerminalSession(worktreeID: worktreeB, cwd: tmp)
    workspace.terminals = [first, second]

    let restored = try roundTrip(workspace)
    let pending = restored.takeRestoredTerminals()

    XCTAssertEqual(pending.count, 2)
    XCTAssertEqual(pending[0].worktreeID, worktreeA)
    // Directory and session id round-trip, so a restored terminal reopens where it was and picks
    // its history back up.
    XCTAssertEqual(pending[0].directory, tmp.path)
    XCTAssertEqual(pending[0].sessionID, first.sessionID)
    XCTAssertEqual(pending[0].scrollback, "line one\nline two")
    XCTAssertEqual(pending[1].worktreeID, worktreeB)
    XCTAssertEqual(pending[1].sessionID, second.sessionID)
    XCTAssertEqual(pending[1].scrollback, "", "an empty terminal saves no scrollback")
    // Taking the list empties it — the controller materializes once.
    XCTAssertTrue(restored.takeRestoredTerminals().isEmpty)
  }

  /// The strip's order rides with the tabs: the terminals are saved in the order handed in —
  /// the desk's, not the model's — and the rows naming each restorable tab's kind come back as
  /// they went, so a dragged terminal or web tab does not spring back on relaunch.
  func testTheStripOrderRoundTripsWithTheTerminalsInIt() throws {
    let workspace = Workspace()
    let worktree = UUID()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    let first = TerminalSession(worktreeID: worktree, cwd: tmp)
    let second = TerminalSession(worktreeID: worktree, cwd: tmp)
    workspace.terminals = [first, second]
    let order: [Workspace.RestoredTabOrder] = [
      .init(worktreeID: worktree, kind: .terminal), .init(worktreeID: worktree, kind: .browser),
      .init(worktreeID: worktree, kind: .terminal),
    ]

    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    workspace.encodeState(to: archiver, terminals: [second, first], tabOrder: order)
    archiver.finishEncoding()
    let restored = Workspace()
    restored.decodeState(from: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData))

    XCTAssertEqual(
      restored.takeRestoredTerminals().map(\.sessionID), [second.sessionID, first.sessionID],
      "the terminals are saved in the order given, which is the strip's")
    XCTAssertEqual(restored.takeRestoredTabOrder(), order)
    XCTAssertTrue(restored.takeRestoredTabOrder().isEmpty, "taken once")
  }

  /// File and commit tabs ride across as what identifies them — a worktree and a path, an oid —
  /// and nothing else: there is no copy of a buffer's text here, which is what the unsaved-edit
  /// prompt at close is for.
  func testFileAndCommitTabsRoundTripByWorktree() throws {
    let worktree = UUID()
    let other = UUID()
    let files = [
      FileTabState(worktreeID: worktree, path: "Sources/Model.swift"),
      FileTabState(worktreeID: other, path: "README.md"),
    ]
    let commits = [CommitTabState(worktreeID: worktree, oid: String(repeating: "a", count: 40))]

    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    Workspace().encodeState(to: archiver, fileTabs: files, commitTabs: commits)
    archiver.finishEncoding()
    let restored = Workspace()
    restored.decodeState(from: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData))

    XCTAssertEqual(restored.takeRestoredFileTabs(), files)
    XCTAssertTrue(restored.takeRestoredFileTabs().isEmpty, "taken once")
    XCTAssertEqual(restored.takeRestoredCommitTabs(), commits)
  }

  /// The strip order spans all four kinds now, and the tab that was showing is a place in it —
  /// carried with the worktree it is a place in, since that is the one strip it means anything
  /// against.
  func testTheSelectedTabRoundTripsAsAPlaceInTheSelectedWorktreesStrip() throws {
    let workspace = Workspace()
    let worktree = UUID()
    workspace.selectedWorktreeID = worktree
    let order: [Workspace.RestoredTabOrder] = [
      .init(worktreeID: worktree, kind: .file), .init(worktreeID: worktree, kind: .commit),
      .init(worktreeID: worktree, kind: .browser),
    ]

    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    workspace.encodeState(to: archiver, tabOrder: order, selectedTabIndex: 1)
    archiver.finishEncoding()
    let restored = Workspace()
    restored.decodeState(from: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData))

    XCTAssertEqual(restored.takeRestoredTabOrder(), order)
    let selection = try XCTUnwrap(restored.takeRestoredTabSelection())
    XCTAssertEqual(selection.worktreeID, worktree)
    XCTAssertEqual(selection.index, 1)
    XCTAssertNil(restored.takeRestoredTabSelection(), "taken once")
  }

  /// An empty desk saves no selection, and a restored one must not be handed a place in a strip
  /// that has no tabs on it.
  func testAnEmptyDeskRestoresNoSelection() throws {
    let workspace = Workspace()
    workspace.selectedWorktreeID = UUID()
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    workspace.encodeState(to: archiver, selectedTabIndex: -1)
    archiver.finishEncoding()
    let restored = Workspace()
    restored.decodeState(from: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData))

    XCTAssertNil(restored.pendingRestoredTabSelection)
  }

  func testRosterShortFieldsFallBackToValue() throws {
    // Hand-built archive with the display-name and resolved arrays truncated, the way a partial
    // or older archive would read. The raw keys here are the on-disk format, pinned on purpose.
    let id = UUID()
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    archiver.encode([id.uuidString] as NSArray, forKey: "roster.ids")
    archiver.encode([["default", "opus"] as NSArray] as NSArray, forKey: "roster.values")
    archiver.encode([["Default"] as NSArray] as NSArray, forKey: "roster.names")
    archiver.encode([[] as NSArray] as NSArray, forKey: "roster.resolved")
    archiver.finishEncoding()

    let workspace = Workspace()
    workspace.decodeState(from: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData))

    let models = revived(id, by: workspace).availableModels
    XCTAssertEqual(models.map(\.value), ["default", "opus"])
    // Missing tail entries fall back to the value string rather than misaligning the rest.
    XCTAssertEqual(models.map(\.displayName), ["Default", "opus"])
    XCTAssertEqual(models.map(\.resolvedModel), ["default", "opus"])
  }

  func testRosterIDWithoutValueListIsSkipped() throws {
    let kept = UUID()
    let orphan = UUID()
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    archiver.encode([kept.uuidString, orphan.uuidString] as NSArray, forKey: "roster.ids")
    archiver.encode([["default"] as NSArray] as NSArray, forKey: "roster.values")
    archiver.finishEncoding()

    let workspace = Workspace()
    workspace.decodeState(from: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData))

    // Only the first id brought a value list; the orphan decodes to nothing, not a crash and
    // not its neighbour's list.
    XCTAssertEqual(revived(kept, by: workspace).availableModels.map(\.value), ["default"])
    XCTAssertTrue(revived(orphan, by: workspace).availableModels.isEmpty)
  }

  func testInstructionStampRoundTripsAndOutranksTheTranscriptMtime() throws {
    let workspace = Workspace()
    let instructed = AgentSession(worktreeID: UUID())
    instructed.lastInstructedAt = Date(timeIntervalSinceReferenceDate: 800_000)
    let untouched = AgentSession(worktreeID: UUID())
    workspace.sessions = [instructed, untouched]

    let restored = try roundTrip(workspace)

    // The mtime stands in for what discovery reads off the transcript: later than the real
    // instruction, the way a quitting engine's `last-prompt` line leaves it.
    let mtime = Date(timeIntervalSinceReferenceDate: 900_000)
    XCTAssertEqual(
      restored.restoredInstruction(for: instructed.id, fallback: mtime),
      instructed.lastInstructedAt,
      "a stored stamp outranks the mtime, so the rail's order survives a restart")
    // Never instructed, so nothing was stored: the mtime is all there is to sort by.
    XCTAssertEqual(restored.restoredInstruction(for: untouched.id, fallback: mtime), mtime)
    // A session this window has never seen — started in a terminal — seeds from its mtime too.
    XCTAssertEqual(restored.restoredInstruction(for: UUID(), fallback: mtime), mtime)
  }

  func testSeedModelsNeverOverwritesAnExistingRoster() {
    let session = AgentSession(worktreeID: UUID())
    session.seedModels([model("opus")])
    session.seedModels([model("haiku")])
    XCTAssertEqual(session.availableModels.map(\.value), ["opus"])
  }
}
