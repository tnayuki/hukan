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

  func testSeedModelsNeverOverwritesAnExistingRoster() {
    let session = AgentSession(worktreeID: UUID())
    session.seedModels([model("opus")])
    session.seedModels([model("haiku")])
    XCTAssertEqual(session.availableModels.map(\.value), ["opus"])
  }
}
