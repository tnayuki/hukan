import AppKit
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
  func testGroupsAndLooseRepositoriesBuildAMixedTree() {
    let (workspace, _) = reorderable()
    let group = workspace.createGroup(name: "Customer")
    let empty = workspace.createGroup(name: "Empty")
    XCTAssertTrue(workspace.moveRailRepository("/b", to: group, at: 0))
    XCTAssertTrue(workspace.moveRailGroup(group, at: 0))
    let rail = SessionRailViewController()
    rail.workspace = workspace
    rail.reload()
    let outline = NSOutlineView()
    XCTAssertEqual(rail.outlineView(outline, numberOfChildrenOfItem: nil), 4)
    let heading = rail.outlineView(outline, child: 0, ofItem: nil) as! RailNode
    XCTAssertEqual(heading.groupID, group)
    XCTAssertEqual(heading.title, "CUSTOMER")
    XCTAssertEqual(heading.children.map(\.repositoryID), ["/b"])
    XCTAssertEqual(heading.children.first?.title, "b")
    XCTAssertEqual(
      (rail.outlineView(outline, child: 1, ofItem: nil) as! RailNode).repositoryID, "/a")
    XCTAssertEqual((rail.outlineView(outline, child: 3, ofItem: nil) as! RailNode).groupID, empty)
    XCTAssertEqual(SessionRailViewController.topLevelIndex([heading], of: heading.children[0]), 0)
  }

  func testRepositoriesJoinLeaveAndReorderWithinGroups() {
    let (workspace, _) = reorderable()
    let group = workspace.createGroup()
    XCTAssertTrue(workspace.moveRailRepository("/a", to: group, at: 0))
    XCTAssertTrue(workspace.moveRailRepository("/b", to: group, at: 1))
    XCTAssertTrue(workspace.moveRailRepository("/c", to: group, at: 1))
    XCTAssertEqual(workspace.groups[0].repositoryIDs, ["/a", "/c", "/b"])
    XCTAssertTrue(workspace.moveRailRepository("/b", to: group, at: 0))
    XCTAssertEqual(workspace.groups[0].repositoryIDs, ["/b", "/a", "/c"])
    XCTAssertFalse(workspace.moveRailRepository("/b", to: group, at: 1))
    XCTAssertTrue(workspace.moveRailRepository("/a", to: nil, at: 0))
    XCTAssertNil(workspace.groupID(for: "/a"))
    XCTAssertEqual(workspace.topLevelOrder, ["r:/a", "g:" + group])
    XCTAssertEqual(workspace.groups[0].repositoryIDs, ["/b", "/c"])
  }

  func testGroupsReorderAndUngroupAtTheirPosition() {
    let (workspace, _) = reorderable()
    let first = workspace.createGroup(name: "First")
    let second = workspace.createGroup(name: "Second")
    workspace.moveRailRepository("/a", to: first, at: 0)
    workspace.moveRailRepository("/b", to: first, at: 1)
    XCTAssertTrue(workspace.moveRailGroup(second, at: 0))
    XCTAssertEqual(workspace.topLevelOrder, ["g:" + second, "r:/c", "g:" + first])
    XCTAssertFalse(workspace.moveRailGroup(second, at: 1))
    workspace.collapsedGroups.insert(first)
    workspace.ungroup(first)
    XCTAssertEqual(workspace.topLevelOrder, ["g:" + second, "r:/c", "r:/a", "r:/b"])
    XCTAssertNil(workspace.groupID(for: "/a"))
    XCTAssertFalse(workspace.collapsedGroups.contains(first))
    XCTAssertEqual(workspace.repositories.count, 3)
  }

  func testMembershipSurvivesCloseAndReopenInTheSameWorkspace() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = Workspace()
    // The id is read before the close: a worktree's repository is unowned, and closing frees it.
    let repositoryID = workspace.addWorktree(directory).repositoryID
    let group = workspace.createGroup(name: "Customer")
    workspace.moveRailRepository(repositoryID, to: group, at: 0)
    workspace.closeRepository(repositoryID)
    XCTAssertTrue(workspace.railRepositories.isEmpty)
    XCTAssertEqual(workspace.groupID(for: repositoryID), group)
    let reopened = workspace.addWorktree(directory)
    XCTAssertEqual(workspace.groupID(for: reopened.repositoryID), group)
    XCTAssertEqual(workspace.topLevelOrder, ["g:" + group])
    workspace.closeRepository(reopened.repositoryID)
  }

  func testGroupNamesTrimAndEmptyNamesKeepThePreviousName() {
    let workspace = Workspace()
    let id = workspace.createGroup()
    workspace.renameGroup(id, name: "  Customer \n")
    XCTAssertEqual(workspace.groups[0].name, "Customer")
    workspace.renameGroup(id, name: " \n")
    XCTAssertEqual(workspace.groups[0].name, "Customer")
    let second = workspace.createGroup(name: "Customer")
    XCTAssertNotEqual(id, second)
    XCTAssertEqual(workspace.groups.map(\.name), ["Customer", "Customer"])
  }

  func testGroupDropDestinations() {
    let a = RailNode(title: "a", groupRepositoryID: "/a")
    let b = RailNode(title: "b", groupRepositoryID: "/b")
    let group = RailNode(title: "Customer", children: [a, b], groupID: "customer")
    let loose = RailNode(title: "c", groupRepositoryID: "/c")
    let nodes = [group, loose]
    let destination = { (item: Any?, index: Int, draggingGroup: Bool) in
      SessionRailViewController.dropDestination(
        nodes, item: item, childIndex: index, draggingGroup: draggingGroup)
    }
    XCTAssertEqual(destination(group, -1, false), .group("customer", NSOutlineViewDropOnItemIndex))
    XCTAssertEqual(destination(group, 1, false), .group("customer", 1))
    XCTAssertEqual(destination(b, -1, false), .group("customer", 1))
    XCTAssertEqual(destination(nil, 1, false), .topLevel(1))
    XCTAssertEqual(destination(nil, -1, false), .topLevel(2))
    XCTAssertEqual(destination(group, 1, true), .topLevel(0))
    XCTAssertEqual(destination(b, -1, true), .topLevel(0))
  }

  func testGroupAggregateAttentionAndUnpromptedRunningState() {
    let (workspace, repositories) = reorderable()
    let group = workspace.createGroup()
    workspace.moveRailRepository("/a", to: group, at: 0)
    let session = AgentSession(worktreeID: repositories[0].worktrees[0].id)
    workspace.sessions = [session]
    workspace.collapsedGroups.insert(group)
    let rail = SessionRailViewController()
    rail.workspace = workspace
    let outline = NSOutlineView()
    func heading() -> RailNode {
      rail.reload()
      return rail.outlineView(outline, child: 2, ofItem: nil) as! RailNode
    }
    XCTAssertNil(heading().state)
    session.state = .running
    XCTAssertFalse(session.isWorking)
    XCTAssertNil(heading().state)
    session.state = .needsAttention
    XCTAssertEqual(heading().state, .needsAttention)
    workspace.closeRepository("/a")
    XCTAssertNil(heading().state)
  }

  func testScriptingGroupNamesChooseTheFirstGroupInRailOrder() {
    let (workspace, _) = reorderable()
    let first = workspace.createGroup(name: "Customer")
    let second = workspace.createGroup(name: "Customer")
    workspace.moveRailGroup(second, at: 0)
    let proxy = SDRepository(repositoryID: "/a", workspace: workspace, window: NSWindow())
    XCTAssertEqual(proxy.group, "")
    proxy.group = " Customer "
    XCTAssertEqual(workspace.groupID(for: "/a"), second)
    XCTAssertEqual(proxy.group, "Customer")
    XCTAssertTrue(workspace.groups.first { $0.id == first }!.repositoryIDs.isEmpty)
    proxy.group = "New Customer"
    XCTAssertEqual(workspace.orderedGroups.last?.name, "New Customer")
    let grouped = SDGroup(
      id: workspace.groupID(for: "/a")!, workspace: workspace, window: proxy.window)
    XCTAssertEqual(grouped.repositories.map(\.uniqueID), ["/a"])
    proxy.group = ""
    XCTAssertNil(workspace.groupID(for: "/a"))
    XCTAssertEqual(workspace.topLevelOrder.last, "r:/a")
  }

  func testRepositoryTransferCarriesLiveObjectsAndRemovesSourceMembership() throws {
    let (source, repositories) = reorderable()
    let repository = repositories[0]
    let worktree = repository.worktrees[0]
    let session = AgentSession(worktreeID: worktree.id)
    session.state = .needsAttention
    session.draft = "Unsent draft"
    let terminal = TerminalSession(deskID: session.id, cwd: worktree.url)
    source.sessions = [session]
    source.terminals = [terminal]
    source.selectedWorktreeID = worktree.id
    source.selectedSessionID = session.id
    source.archivedSessionIDs = [session.id]
    source.collapsedRepositories = [repository.id]
    source.collapsedWorktrees = [worktree.id.uuidString]
    source.expandedArchives = [worktree.id.uuidString]
    source.collapsedWorktreeSections = [repository.id]
    let group = source.createGroup()
    source.moveRailRepository(repository.id, to: group, at: 0)

    let detached = try XCTUnwrap(source.detachRepository(repository.id))
    XCTAssertTrue(detached.repository === repository)
    XCTAssertTrue(detached.sessions[0] === session)
    XCTAssertTrue(detached.terminals[0] === terminal)
    XCTAssertEqual(repository.worktrees.count, 2)
    XCTAssertEqual(session.state, .needsAttention)
    XCTAssertEqual(session.draft, "Unsent draft")
    XCTAssertFalse(terminal.isSpawned)
    XCTAssertTrue(source.sessions.isEmpty)
    XCTAssertTrue(source.terminals.isEmpty)
    XCTAssertTrue(source.archivedSessionIDs.isEmpty)
    XCTAssertTrue(source.collapsedRepositories.isEmpty)
    XCTAssertTrue(source.collapsedWorktrees.isEmpty)
    XCTAssertTrue(source.expandedArchives.isEmpty)
    XCTAssertTrue(source.collapsedWorktreeSections.isEmpty)
    XCTAssertNil(source.groupID(for: repository.id))
    XCTAssertFalse(source.railOrder.contains("r:" + repository.id))
    XCTAssertEqual(source.selectedWorktreeID, repositories[1].worktrees[0].id)
    XCTAssertNil(source.selectedSessionID)

    let destination = Workspace()
    var heldChanges = 0
    destination.onSessionsChanged = { heldChanges += 1 }
    XCTAssertTrue(destination.adoptRepository(detached))
    XCTAssertTrue(destination.repositories[0] === repository)
    XCTAssertTrue(destination.sessions[0] === session)
    XCTAssertTrue(destination.terminals[0] === terminal)
    XCTAssertEqual(destination.archivedSessionIDs, [session.id])
    XCTAssertEqual(destination.collapsedRepositories, [repository.id])
    XCTAssertEqual(destination.collapsedWorktrees, [worktree.id.uuidString])
    XCTAssertEqual(destination.expandedArchives, [worktree.id.uuidString])
    XCTAssertEqual(destination.collapsedWorktreeSections, [repository.id])
    session.onHeldChange?()
    XCTAssertEqual(heldChanges, 1)
    XCTAssertFalse(destination.adoptRepository(detached))
    XCTAssertEqual(destination.sessions.count, 1)
    XCTAssertEqual(destination.terminals.count, 1)
    // Reopening in the source has no old group membership to recover.
    source.repositories.append(Repository(id: repository.id))
    XCTAssertNil(source.groupID(for: repository.id))
  }

  func testForeignRailDropsRefuseDuplicateRepositoriesAndGroups() {
    let (source, _) = reorderable()
    let destination = Workspace()
    let group = source.createGroup()
    func allows(repository: String? = nil, group: String? = nil) -> Bool {
      SessionRailViewController.allowsDrop(
        repositoryID: repository, groupID: group, from: source, to: destination)
    }
    XCTAssertTrue(allows(repository: "/a"))
    XCTAssertFalse(allows(repository: "/gone"))
    XCTAssertFalse(allows(group: group))
    destination.repositories = [Repository(id: "/a")]
    XCTAssertFalse(allows(repository: "/a"))
    XCTAssertTrue(
      SessionRailViewController.allowsDrop(
        repositoryID: "/a", groupID: nil, from: source, to: source))
    XCTAssertTrue(
      SessionRailViewController.allowsDrop(
        repositoryID: nil, groupID: group, from: source, to: source))
  }

}
