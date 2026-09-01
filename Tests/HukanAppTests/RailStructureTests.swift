import XCTest

@testable import Hukan

/// The worktree-first rail model: a repository's main worktree (the common dir's parent) folds
/// into the heading, linked worktrees are its children, and a worktree with no session is kept so
/// its file tree stays reachable.
final class RailStructureTests: XCTestCase {
  func testMainIsTheCommonDirParent() {
    let repo = Repository(id: "/repo/main")
    let main = Worktree(url: URL(fileURLWithPath: "/repo/main"), repository: repo)
    let linked = Worktree(
      url: URL(fileURLWithPath: "/repo/feature"), branch: "feature", repository: repo)
    XCTAssertTrue(main.isMain)
    XCTAssertFalse(linked.isMain)
  }

  func testRailNodeHeadingFlagsTellTheKindsApart() {
    let repo = Repository(id: "/repo/main")
    let main = Worktree(url: URL(fileURLWithPath: "/repo/main"), repository: repo)
    let linked = Worktree(
      url: URL(fileURLWithPath: "/repo/feature"), branch: "feature", repository: repo)

    // Repository heading: carries the repository key, and main so that selecting it is still a
    // destination rather than a bare label.
    let repoHeading = RailNode(title: "MAIN", worktree: main, groupRepositoryID: repo.id)
    XCTAssertTrue(repoHeading.isRepositoryHeading)
    XCTAssertFalse(repoHeading.isWorktreeHeading)
    XCTAssertFalse(repoHeading.isSectionHeading)

    // A linked worktree's heading: carries a worktree but no repository or archive key.
    let worktreeHeading = RailNode(title: "feature", worktree: linked)
    XCTAssertTrue(worktreeHeading.isWorktreeHeading)
    XCTAssertFalse(worktreeHeading.isRepositoryHeading)
    XCTAssertFalse(worktreeHeading.isSectionHeading)

    // A section heading — Archived here — carries a kind and a key, and is not a destination.
    let archive = RailNode(
      title: "Archived", section: .archived, sectionKey: main.id.uuidString)
    XCTAssertTrue(archive.isSectionHeading)
    XCTAssertFalse(archive.isRepositoryHeading)
    XCTAssertFalse(archive.isWorktreeHeading)
  }

  /// The order the rail reads down: main first, then the linked ones by directory name — and a
  /// worktree that arrives later slots into it rather than landing at the end, which is what a
  /// `git worktree add` noticed mid-session used to do. The names are compared the Finder's way,
  /// so `task-9` comes before `task-10`.
  func testWorktreesLandMainFirstThenByName() {
    let repo = Repository(id: "/repo/main")
    let zeta = Worktree(url: URL(fileURLWithPath: "/repo/zeta"), repository: repo)
    let task10 = Worktree(url: URL(fileURLWithPath: "/repo/task-10"), repository: repo)
    let main = Worktree(url: URL(fileURLWithPath: "/repo/main"), repository: repo)
    // Deliberately out of order, and main last: git enumerates the linked ones in `.git/worktrees/`
    // directory order, which is neither of the orders anything on screen is read in.
    repo.add(zeta)
    repo.add(task10)
    repo.add(main)
    XCTAssertEqual(
      repo.worktrees.map { $0.url.lastPathComponent }, ["main", "task-10", "zeta"])

    let task9 = Worktree(url: URL(fileURLWithPath: "/repo/task-9"), repository: repo)
    repo.add(task9)
    XCTAssertEqual(
      repo.worktrees.map { $0.url.lastPathComponent }, ["main", "task-9", "task-10", "zeta"])
  }

  /// Two worktrees can be called the same thing under different parents, so the full path settles
  /// it — an order that depended on which one was added first would move a row under a refresh
  /// that changed nothing.
  func testWorktreesSharingADirectoryNameAreSettledByPath() {
    let repo = Repository(id: "/repo/main")
    let second = Worktree(url: URL(fileURLWithPath: "/work/b/task"), repository: repo)
    let first = Worktree(url: URL(fileURLWithPath: "/work/a/task"), repository: repo)
    repo.add(second)
    repo.add(first)
    XCTAssertEqual(repo.worktrees.map { $0.url.path }, ["/work/a/task", "/work/b/task"])
  }

  func testRailRepositoriesSplitMainFromLinkedAndKeepEmptyWorktrees() {
    let repo = Repository(id: "/repo/main")
    let main = Worktree(url: URL(fileURLWithPath: "/repo/main"), repository: repo)
    let linked = Worktree(
      url: URL(fileURLWithPath: "/repo/feature"), branch: "feature", repository: repo)
    repo.worktrees = [main, linked]

    let workspace = Workspace()
    workspace.repositories = [repo]
    let session = AgentSession(worktreeID: main.id)
    session.lastInstructedAt = Date()
    workspace.sessions = [session]

    let repos = workspace.railRepositories
    XCTAssertEqual(repos.count, 1)
    XCTAssertEqual(repos[0].main?.worktree.id, main.id)
    // main's session hangs straight off the heading, which is main.
    XCTAssertEqual(repos[0].main?.sessions.map(\.session.id), [session.id])
    XCTAssertEqual(repos[0].main?.archived.isEmpty, true)
    // The linked worktree is kept even with no session — a selectable, file-tree-bearing container.
    XCTAssertEqual(repos[0].linked.map(\.worktree.id), [linked.id])
    XCTAssertTrue(repos[0].linked[0].sessions.isEmpty)
    // `worktrees` is main then the linked ones, for the readers that do not care which is which.
    XCTAssertEqual(repos[0].worktrees.map(\.worktree.id), [main.id, linked.id])
  }

  /// A repository whose main checkout is not open has no heading worktree at all — every worktree
  /// it has is a linked one, and none of them is dressed as main.
  func testARepositoryWithNoMainCheckoutOpenHasOnlyLinkedWorktrees() {
    let repo = Repository(id: "/repo/main")
    let one = Worktree(url: URL(fileURLWithPath: "/repo/a"), branch: "a", repository: repo)
    let two = Worktree(url: URL(fileURLWithPath: "/repo/b"), branch: "b", repository: repo)
    repo.worktrees = [one, two]
    let workspace = Workspace()
    workspace.repositories = [repo]

    let rail = workspace.railRepositories[0]
    XCTAssertNil(rail.main)
    XCTAssertEqual(rail.linked.map(\.worktree.id), [one.id, two.id])
  }

  /// The rail's heading is the only place a worktree's branch is named, so it is dropped only
  /// when the directory name already carries it — the `<repo>-<branch>` shape — and kept
  /// whenever the two genuinely drift.
  func testBranchLabelDropsOnlyWhenTheDirectoryAlreadyCarriesIt() {
    XCTAssertTrue(
      RailNode.branchRepeatsDirectory(
        directory: "hukan-worktree-heading", branch: "worktree-heading"))
    XCTAssertTrue(
      RailNode.branchRepeatsDirectory(directory: "hukan_files-panel", branch: "files-panel"))
    XCTAssertTrue(RailNode.branchRepeatsDirectory(directory: "feature", branch: "feature"))
    // Drifted: the directory says nothing about the branch, so both belong on the row.
    XCTAssertFalse(
      RailNode.branchRepeatsDirectory(directory: "hukan-wt1", branch: "worktree-heading"))
    // A suffix, not a substring — "main" inside "domain" is a coincidence.
    XCTAssertFalse(RailNode.branchRepeatsDirectory(directory: "domain", branch: "main"))
    // The branch is a prefix of the directory, so the tail the row shows would lose it.
    XCTAssertFalse(RailNode.branchRepeatsDirectory(directory: "heading-hukan", branch: "heading"))
  }

  /// The selection restore's fallback. It runs outside `shouldSelectItem`, so it has to refuse
  /// the unselectable rows itself — and with nothing selected it must match no row at all,
  /// rather than the first one whose worktree is nil.
  func testFallbackSelectionMatchesNoRowWhenNothingIsSelected() {
    let repo = Repository(id: "/repo/main")
    let main = Worktree(url: URL(fileURLWithPath: "/repo/main"), repository: repo)
    let heading = RailNode(title: "main", worktree: main, groupRepositoryID: repo.id)
    let bucket = RailNode(title: "Archived", section: .archived, sectionKey: main.id.uuidString)
    let session = AgentSession(worktreeID: main.id)
    let sessionRow = RailNode(title: "A session", worktree: main, session: session)

    // Nothing selected: no row is the fallback — least of all the section, whose worktree is nil.
    for node in [heading, bucket, sessionRow] {
      XCTAssertFalse(RailNode.isFallbackSelection(node, sessionID: nil, worktreeID: nil))
    }
    // A worktree selected: its heading, and nothing else.
    XCTAssertTrue(RailNode.isFallbackSelection(heading, sessionID: nil, worktreeID: main.id))
    XCTAssertFalse(RailNode.isFallbackSelection(bucket, sessionID: nil, worktreeID: main.id))
    XCTAssertFalse(RailNode.isFallbackSelection(sessionRow, sessionID: nil, worktreeID: main.id))
    // A session selected: its row wins over the heading of the worktree it sits in.
    XCTAssertTrue(
      RailNode.isFallbackSelection(sessionRow, sessionID: session.id, worktreeID: main.id))
    XCTAssertFalse(
      RailNode.isFallbackSelection(heading, sessionID: session.id, worktreeID: main.id))
  }

  // MARK: - Reordering repositories

  /// Three repositories, each with one linked worktree, as the workspace holds them.
  private func reorderable() -> (Workspace, [Repository]) {
    let workspace = Workspace()
    let repositories = ["/a", "/b", "/c"].map { path -> Repository in
      let repo = Repository(id: path)
      repo.worktrees = [
        Worktree(url: URL(fileURLWithPath: path), repository: repo),
        Worktree(
          url: URL(fileURLWithPath: path + "-feature"), branch: "feature", repository: repo),
      ]
      return repo
    }
    workspace.repositories = repositories
    return (workspace, repositories)
  }

  func testMovingARepositoryTakesItsWorktreesWithIt() {
    let (workspace, _) = reorderable()

    XCTAssertTrue(workspace.moveRepository("/c", before: "/a"))
    XCTAssertEqual(workspace.repositories.map(\.id), ["/c", "/a", "/b"])
    // Nothing had to carry the worktrees: they hang off the repository, and `worktrees` is a
    // flattening of the list that just moved.
    XCTAssertEqual(
      workspace.worktrees.map(\.url.lastPathComponent),
      ["c", "c-feature", "a", "a-feature", "b", "b-feature"])

    // A destination further down is read against the list as it reads now, not after the removal.
    XCTAssertTrue(workspace.moveRepository("/c", before: "/b"))
    XCTAssertEqual(workspace.repositories.map(\.id), ["/a", "/c", "/b"])

    // nil is the end of the list.
    XCTAssertTrue(workspace.moveRepository("/a", before: nil))
    XCTAssertEqual(workspace.repositories.map(\.id), ["/c", "/b", "/a"])
  }

  func testAMoveThatChangesNothingIsRefused() {
    let (workspace, _) = reorderable()

    // Dropped back where it already was, from either side.
    XCTAssertFalse(workspace.moveRepository("/a", before: "/b"))
    XCTAssertFalse(workspace.moveRepository("/c", before: nil))
    XCTAssertFalse(workspace.moveRepository("/b", before: "/b"))
    // A destination that is no longer open is a stale drop, not "the end".
    XCTAssertFalse(workspace.moveRepository("/a", before: "/gone"))
    XCTAssertFalse(workspace.moveRepository("/gone", before: "/a"))
    XCTAssertEqual(workspace.repositories.map(\.id), ["/a", "/b", "/c"])
  }

  /// The rail's top level is one row per repository now, so a drop anywhere inside a repository is
  /// a drop *on* it — there is no run of sibling rows to snap down through, which is what the old
  /// flat top level needed.
  func testDropBoundaryResolvesAnyRowToItsRepository() {
    let repositories = ["/a", "/b"].map { Repository(id: $0) }
    var nodes: [RailNode] = []
    var inner: [RailNode] = []
    for repo in repositories {
      let main = Worktree(url: URL(fileURLWithPath: repo.id), repository: repo)
      let session = AgentSession(worktreeID: main.id)
      let sessionRow = RailNode(title: "A session", worktree: main, session: session)
      let worktreeRow = RailNode(title: "main", worktree: main, children: [sessionRow])
      inner.append(sessionRow)
      nodes.append(
        RailNode(
          title: repo.name, worktree: main, children: [worktreeRow], groupRepositoryID: repo.id))
    }
    let boundary = { (item: Any?, index: Int) in
      SessionRailViewController.dropBoundary(nodes, item: item, childIndex: index)
    }
    XCTAssertEqual(boundary(nodes[0], 0), 0)
    XCTAssertEqual(boundary(nodes[1], 0), 1)
    // A row deep inside /b — a session under its worktree — is still a drop on /b.
    XCTAssertEqual(boundary(inner[1], 0), 1)
    // No item is a place in the top-level list; -1, the space under the last row, is the end.
    XCTAssertEqual(boundary(nil, 1), 1)
    XCTAssertEqual(boundary(nil, -1), 2)
    XCTAssertEqual(boundary(nil, 99), 2)
  }
}
