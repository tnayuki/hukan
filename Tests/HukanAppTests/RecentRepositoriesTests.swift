import XCTest

@testable import Hukan

/// Open Recent's list: what it holds, in what order, and what it refuses to hold. The store is the
/// one thing hukan keeps outside a window, so the rules that keep it from rotting — pruning what is
/// gone, capping the length, dropping what the window already has open — are the whole of it.
final class RecentRepositoriesTests: XCTestCase {
  private var root: URL!
  private var recents: RecentRepositories!

  override func setUpWithError() throws {
    Git.initialize()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-recents-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    root = tmp.resolvingSymlinksInPath()
    // Memory-backed: nothing a test does may reach the defaults the running app reads.
    recents = RecentRepositories(defaults: nil)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  @discardableResult
  private func directory(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func testNewestFirstAndNotedOnce() throws {
    let a = try directory("a")
    let b = try directory("b")
    recents.note(a.path)
    recents.note(b.path)
    recents.note(a.path)
    XCTAssertEqual(recents.paths, [a.path, b.path])
  }

  func testCappedAtTen() throws {
    let made = try (0..<(RecentRepositories.limit + 3)).map { try directory("r\($0)") }
    for url in made { recents.note(url.path) }
    XCTAssertEqual(recents.paths.count, RecentRepositories.limit)
    XCTAssertEqual(recents.paths.first, made.last?.path)
    XCTAssertFalse(recents.paths.contains(made[0].path))
  }

  /// A repository that has been deleted or moved is not recent, it is gone — and it must not go on
  /// holding one of the ten places.
  func testPrunesWhatIsGone() throws {
    let a = try directory("a")
    let b = try directory("b")
    recents.note(a.path)
    recents.note(b.path)
    try FileManager.default.removeItem(at: b)
    XCTAssertEqual(recents.paths, [a.path])
    // Pruned from the store too, so the place is free rather than merely unlisted.
    try directory("b")
    XCTAssertEqual(recents.paths, [a.path])
  }

  /// A file with the right name is not a repository to reopen.
  func testAFileIsNotAnEntry() throws {
    let file = root.appendingPathComponent("notes.txt")
    try "x\n".write(to: file, atomically: true, encoding: .utf8)
    recents.note(file.path)
    XCTAssertEqual(recents.paths, [])
  }

  func testEntriesDropWhatIsAlreadyOpen() throws {
    let a = try directory("a")
    let b = try directory("b")
    recents.note(a.path)
    recents.note(b.path)
    XCTAssertEqual(recents.entries(excluding: [b.path]).map(\.path), [a.path])
    XCTAssertEqual(recents.entries(excluding: [a.path, b.path]).count, 0)
  }

  /// Two rows both reading `hukan` name nothing, so the repeated name carries where it lives.
  func testRepeatedNamesCarryTheirDirectory() throws {
    let one = try directory("one/hukan")
    let two = try directory("two/hukan")
    let alone = try directory("alone")
    recents.note(one.path)
    recents.note(two.path)
    recents.note(alone.path)
    let titles = recents.entries(excluding: []).map(\.title)
    XCTAssertEqual(titles.first, "alone")
    XCTAssertTrue(titles.contains { $0.hasPrefix("hukan — ") && $0.hasSuffix("/one") })
    XCTAssertTrue(titles.contains { $0.hasPrefix("hukan — ") && $0.hasSuffix("/two") })
  }

  func testClearAndForget() throws {
    let a = try directory("a")
    let b = try directory("b")
    recents.note(a.path)
    recents.note(b.path)
    recents.forget(a.path)
    XCTAssertEqual(recents.paths, [b.path])
    recents.clear()
    XCTAssertEqual(recents.paths, [])
  }

  /// The two moments a repository is noted, through the model rather than through a menu: opening
  /// one and closing it. The identity noted is the repository's — git's common dir's parent — so
  /// opening a *linked* worktree records the checkout Open Recent would reopen.
  func testOpeningAndClosingNoteTheRepository() throws {
    let main = root.appendingPathComponent("main")
    try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
    run(["git", "init", "-q", "-b", "main"], in: main)
    run(["git", "config", "user.email", "test@example.com"], in: main)
    run(["git", "config", "user.name", "Test"], in: main)
    try "hello\n".write(to: main.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    run(["git", "add", "."], in: main)
    run(["git", "commit", "-q", "-m", "Initial"], in: main)
    let linked = root.appendingPathComponent("task")
    run(["git", "worktree", "add", "-q", "-b", "task", linked.path], in: main)

    // Under XCTest the shared store is memory-backed, so this stays out of the app's own list.
    RecentRepositories.shared.clear()
    let workspace = Workspace()
    workspace.openRepository(linked)
    XCTAssertEqual(RecentRepositories.shared.paths.first, main.path)
    workspace.closeRepository(main.path)
    XCTAssertEqual(RecentRepositories.shared.paths.first, main.path)
    RecentRepositories.shared.clear()
  }

  /// The menu the three places share, built the way opening it builds it. It cannot be opened
  /// from a script — two of the three are context menus — so what a row would say and what it
  /// would do is checked here.
  func testMenuBuildsRowsAndTheirAction() throws {
    let a = try directory("a")
    let b = try directory("b")
    RecentRepositories.shared.clear()
    RecentRepositories.shared.note(a.path)
    RecentRepositories.shared.note(b.path)

    let menu = RecentRepositoriesMenu(title: "Open Recent")
    menu.pullDownTitle = "Open Recent"
    menu.menuNeedsUpdate(menu)
    // The pull-down's own title, the two entries newest first, a separator, then Clear Menu.
    XCTAssertEqual(
      menu.items.map(\.title), ["Open Recent", "b", "a", "", "Clear Menu"])
    XCTAssertEqual(menu.items[1].representedObject as? String, b.path)
    XCTAssertEqual(
      menu.items[1].action, #selector(WorkspaceWindowController.openRecentRepository(_:)))
    // nil target: the responder chain is what carries it to the window it would open in.
    XCTAssertNil(menu.items[1].target)

    // Nothing to offer is a disabled line, not an empty menu with a Clear on it.
    RecentRepositories.shared.clear()
    menu.menuNeedsUpdate(menu)
    XCTAssertEqual(menu.items.map(\.title), ["Open Recent", "No Recent Repositories"])
    XCTAssertNil(menu.items[1].action)
  }

  @discardableResult
  private func run(_ arguments: [String], in dir: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = dir
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
