import XCTest

@testable import Hukan

/// Pure model transforms in the app module: the rail's archive rules and the sidebar file tree.
final class WorkspaceModelTests: XCTestCase {
  // MARK: archiving

  private func workspaceWithSessions(_ count: Int) -> (Workspace, Worktree, [AgentSession]) {
    let repo = Repository(id: "/repo/main")
    let main = Worktree(url: URL(fileURLWithPath: "/repo/main"), branch: "main", repository: repo)
    repo.worktrees = [main]
    return workspaceWithSessions(count, in: main, of: repo)
  }

  private func workspaceWithSessions(_ count: Int, in worktree: Worktree, of repo: Repository) -> (
    Workspace, Worktree, [AgentSession]
  ) {
    let main = worktree
    let workspace = Workspace()
    workspace.repositories = [repo]
    // Newest first on the rail, so stamp them apart and hand them back in that order.
    let sessions = (0..<count).map { index -> AgentSession in
      let session = AgentSession(worktreeID: main.id)
      session.lastInstructedAt = Date(timeIntervalSinceReferenceDate: Double(count - index))
      return session
    }
    workspace.sessions = sessions
    return (workspace, main, sessions)
  }

  /// Archiving is the only thing that puts a row below the fold. A count-based backstop was built
  /// and taken out: a rule that archives the ninth session is guessing at "done with it" from a
  /// number, and it would bury a session you are still using the moment you start one more.
  func testOnlyArchivingPutsASessionBelowTheFold() {
    let (workspace, _, sessions) = workspaceWithSessions(20)
    XCTAssertEqual(workspace.railRepositories[0].main!.sessions.count, 20)
    XCTAssertTrue(workspace.railRepositories[0].main!.archived.isEmpty)

    XCTAssertTrue(workspace.setArchived(true, for: [sessions[3], sessions[9]]))
    let worktree = workspace.railRepositories[0].main!
    XCTAssertEqual(worktree.sessions.count, 18)
    // Both lists stay in the rail's order, newest instruction first.
    XCTAssertEqual(worktree.archived.map(\.session.id), [sessions[3].id, sessions[9].id])
    XCTAssertFalse(worktree.sessions.contains { $0.session.id == sessions[3].id })
  }

  /// Only main's sessions can be archived. A linked worktree is the task itself — the
  /// `git worktree remove` that ends it takes its sessions off the rail — so nothing accumulates
  /// there for a fold to put away.
  func testALinkedWorktreesSessionsCannotBeArchived() {
    let repo = Repository(id: "/repo/main")
    let main = Worktree(url: URL(fileURLWithPath: "/repo/main"), branch: "main", repository: repo)
    let linked = Worktree(
      url: URL(fileURLWithPath: "/repo/feature"), branch: "feature", repository: repo)
    repo.worktrees = [main, linked]
    let (workspace, _, sessions) = workspaceWithSessions(2, in: linked, of: repo)

    XCTAssertFalse(workspace.canArchive(sessions[0]))
    XCTAssertFalse(workspace.setArchived(true, for: sessions))
    XCTAssertTrue(workspace.archivedSessionIDs.isEmpty)
    XCTAssertTrue(workspace.railRepositories[0].linked[0].archived.isEmpty)
    XCTAssertEqual(workspace.railRepositories[0].linked[0].sessions.count, 2)
  }

  /// A flag on a session that has since moved worktree goes inert rather than being cleared —
  /// it is still true that you archived it, and coming home is what makes it mean something.
  func testAnArchivedSessionThatMovesIntoAWorktreeGoesInertAndComesBack() {
    let repo = Repository(id: "/repo/main")
    let main = Worktree(url: URL(fileURLWithPath: "/repo/main"), branch: "main", repository: repo)
    let linked = Worktree(
      url: URL(fileURLWithPath: "/repo/feature"), branch: "feature", repository: repo)
    repo.worktrees = [main, linked]
    let (workspace, _, sessions) = workspaceWithSessions(1, in: main, of: repo)
    XCTAssertTrue(workspace.setArchived(true, for: sessions))

    sessions[0].worktreeID = linked.id
    XCTAssertFalse(workspace.isArchived(sessions[0]))
    XCTAssertTrue(workspace.archivedSessionIDs.contains(sessions[0].id))

    sessions[0].worktreeID = main.id
    XCTAssertTrue(workspace.isArchived(sessions[0]))
  }

  /// The rule the time buckets could not keep: a pulsing row is never behind a fold. The rail's
  /// one job is finding what is waiting on you, so an archive that could hide it would be worse
  /// than no archive at all.
  func testAnArchivedSessionThatNeedsYouComesBackOut() {
    let (workspace, _, sessions) = workspaceWithSessions(3)
    XCTAssertTrue(workspace.setArchived(true, for: sessions))
    XCTAssertEqual(workspace.railRepositories[0].main!.sessions.count, 0)

    sessions[1].state = .needsAttention
    let worktree = workspace.railRepositories[0].main!
    XCTAssertEqual(worktree.sessions.map(\.session.id), [sessions[1].id])
    XCTAssertEqual(worktree.archived.count, 2)
    // The flag itself is untouched — it is the *showing* that the rule overrides, so putting the
    // session back to idle drops it below the fold again with nothing to re-archive.
    XCTAssertTrue(workspace.archivedSessionIDs.contains(sessions[1].id))
    sessions[1].state = .idle
    XCTAssertEqual(workspace.railRepositories[0].main!.sessions.count, 0)
  }

  /// Unarchiving reads the stored flag, not what is on screen: a session that only *looks*
  /// unarchived because it is awake still has a flag to clear.
  func testUnarchivingClearsTheFlagOfAnAwakeSession() {
    let (workspace, _, sessions) = workspaceWithSessions(1)
    XCTAssertTrue(workspace.setArchived(true, for: sessions))
    sessions[0].state = .needsAttention
    XCTAssertFalse(workspace.isArchived(sessions[0]))

    XCTAssertTrue(workspace.setArchived(false, for: sessions))
    XCTAssertTrue(workspace.archivedSessionIDs.isEmpty)
    // And says so: nothing moved the second time, which is what the menu reads to pick a verb.
    XCTAssertFalse(workspace.setArchived(false, for: sessions))
  }

  // MARK: ages

  /// The unit steps up at each boundary and never shows two; a never-instructed session shows
  /// nothing rather than a number, since there is nothing to count from.
  func testAgeReadsAtTheCoarsestUnitThatSaysSomething() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    func age(_ seconds: TimeInterval) -> String? {
      AgentSession.age(since: now.addingTimeInterval(-seconds), at: now)
    }
    XCTAssertEqual(age(0), "0s")
    XCTAssertEqual(age(59), "59s")
    XCTAssertEqual(age(60), "1m")
    XCTAssertEqual(age(3599), "59m")
    XCTAssertEqual(age(3600), "1h")
    XCTAssertEqual(age(86399), "23h")
    XCTAssertEqual(age(86400), "1d")
    XCTAssertEqual(age(40 * 86400), "40d")
    // A clock that went backwards reads as now, not as a negative.
    XCTAssertEqual(age(-30), "0s")
    XCTAssertNil(AgentSession.age(since: .distantPast, at: now))
  }

  // MARK: file tree

  func testTreeNestsAndSortsDirectoriesFirst() {
    let nodes = FileNode.tree(paths: ["src/b/c.swift", "src/a.swift", "README.md"], changed: [:])
    // Top level: the directory sorts before the file.
    XCTAssertEqual(nodes.map(\.name), ["src", "README.md"])
    XCTAssertEqual(nodes.map(\.isDirectory), [true, false])

    // Inside src: nested dir before the file, and the leaf carries its full relative path.
    let src = nodes[0]
    XCTAssertEqual(src.children.map(\.name), ["b", "a.swift"])
    XCTAssertEqual(src.children[0].children.first?.relativePath, "src/b/c.swift")
  }

  func testTreeAttachesDiffstatsToChangedFilesAndSumsThemOntoDirectories() {
    let changed = ["src/a.swift": ChangedFile(path: "src/a.swift", added: 3, removed: 1)]
    let nodes = FileNode.tree(paths: ["src/a.swift", "src/b.swift"], changed: changed)
    let src = nodes[0]
    let a = try! XCTUnwrap(src.children.first { $0.name == "a.swift" })
    let b = try! XCTUnwrap(src.children.first { $0.name == "b.swift" })
    XCTAssertEqual(a.added, 3)
    XCTAssertEqual(a.removed, 1)
    XCTAssertNil(b.added, "an unchanged file carries no diffstat")
    XCTAssertEqual(src.added, 3, "a directory totals what changed beneath it")
    XCTAssertEqual(src.removed, 1)
  }

  func testDirectoryDiffstatSumsTheWholeSubtreeAndIsAbsentWithNoChanges() {
    let changed = [
      "src/deep/a.swift": ChangedFile(path: "src/deep/a.swift", added: 3, removed: 1),
      "src/b.swift": ChangedFile(path: "src/b.swift", added: 10, removed: 0),
      "docs/x.md": ChangedFile(path: "docs/x.md", added: 5, removed: 5),
    ]
    let nodes = FileNode.tree(
      paths: ["src/deep/a.swift", "src/b.swift", "docs/x.md", "vendor/untouched.swift"],
      changed: changed)
    let src = try! XCTUnwrap(nodes.first { $0.name == "src" })
    // Nested and direct children both count, and a sibling directory's files do not bleed in.
    XCTAssertEqual(src.added, 13)
    XCTAssertEqual(src.removed, 1)
    XCTAssertEqual(src.children.first { $0.name == "deep" }?.added, 3)
    let vendor = try! XCTUnwrap(nodes.first { $0.name == "vendor" })
    XCTAssertNil(vendor.added, "a directory with nothing changed under it carries no diffstat")
  }

  /// The lazy tree finds a directory's children by binary-searching to the end of its `"<dir>/"`
  /// block, so a sibling whose name extends the directory's (`src` vs `src-utils`) must not bleed
  /// into it. Byte-sorted input is the contract; `"src-"` (0x2D) sorts before `"src/"` (0x2F).
  func testTreeSeparatesSiblingsThatSharePrefix() {
    let nodes = FileTree(
      paths: ["src-utils/helper.swift", "src/a/deep.swift", "src/b.swift"], changed: [:]
    ).rootChildren

    XCTAssertEqual(nodes.map(\.name), ["src", "src-utils"])
    let src = nodes[0]
    XCTAssertEqual(src.children.map(\.name), ["a", "b.swift"])
    XCTAssertEqual(src.children[0].children.map(\.relativePath), ["src/a/deep.swift"])
    let srcUtils = nodes[1]
    XCTAssertEqual(srcUtils.children.map(\.relativePath), ["src-utils/helper.swift"])
  }

  // MARK: queued type-ahead

  /// A queued line holds its attachments as attachments — flattening to paths happens only where
  /// restoration forces it. The transcript and the engine both see the files themselves, so a
  /// pasted screenshot queued mid-turn still arrives as an image.
  func testAQueuedLineKeepsItsAttachments() {
    let shot = Attachment(path: "/tmp/shot.png", isImage: true)
    let message = QueuedMessage(text: "look at this", attachments: [shot])

    XCTAssertEqual(message.text, "look at this", "the path never joins the message body")
    XCTAssertEqual(message.attachments.map(\.path), ["/tmp/shot.png"])
  }

  /// Restorable state keeps strings, so that one path folds the files in as paths — text first,
  /// blank line, then one path per line — and a line with nothing attached is left alone.
  func testFlatteningAQueuedLineAppendsItsPaths() {
    let files = [
      Attachment(path: "/tmp/shot.png", isImage: true),
      Attachment(path: "/tmp/notes.txt", isImage: false),
    ]
    XCTAssertEqual(
      QueuedMessage(text: "look", attachments: files).flattened,
      "look\n\n/tmp/shot.png\n/tmp/notes.txt")
    XCTAssertEqual(
      QueuedMessage(text: "", attachments: [files[0]]).flattened, "/tmp/shot.png",
      "an attachment-only line flattens to the path alone, with no leading blank lines")
    XCTAssertEqual(QueuedMessage(text: "just words", attachments: []).flattened, "just words")
  }
}
