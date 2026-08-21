import XCTest

@testable import Hukan

/// Pure model transforms in the app module: the rail's time bucketing and the sidebar file tree.
final class WorkspaceModelTests: XCTestCase {
  // MARK: time buckets

  /// `bucket` reads the real clock for today/yesterday, so anchor the fixtures on today at noon
  /// (away from midnight) and pass that same instant as `now` for the week window.
  private var noonToday: Date {
    Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
  }
  private func daysBefore(_ n: Int, _ base: Date) -> Date {
    Calendar.current.date(byAdding: .day, value: -n, to: base)!
  }

  func testBucketClassifiesByRecency() {
    let now = noonToday
    XCTAssertEqual(Workspace.bucket(for: now, now: now), .today)
    XCTAssertEqual(Workspace.bucket(for: daysBefore(1, now), now: now), .yesterday)
    XCTAssertEqual(Workspace.bucket(for: daysBefore(4, now), now: now), .thisWeek)
    XCTAssertEqual(Workspace.bucket(for: daysBefore(10, now), now: now), .older)
  }

  func testOnlyOlderCollapsesByDefault() {
    // The core promise: a waiting/working session is recent (Today), never folded away.
    XCTAssertTrue(Workspace.TimeBucket.older.collapsedByDefault)
    for bucket in Workspace.TimeBucket.allCases where bucket != .older {
      XCTAssertFalse(bucket.collapsedByDefault, "\(bucket) must not be collapsed")
    }
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

  func testTreeAttachesDiffstatsToChangedLeavesOnly() {
    let changed = ["src/a.swift": ChangedFile(path: "src/a.swift", added: 3, removed: 1)]
    let nodes = FileNode.tree(paths: ["src/a.swift", "src/b.swift"], changed: changed)
    let src = nodes[0]
    let a = try! XCTUnwrap(src.children.first { $0.name == "a.swift" })
    let b = try! XCTUnwrap(src.children.first { $0.name == "b.swift" })
    XCTAssertEqual(a.added, 3)
    XCTAssertEqual(a.removed, 1)
    XCTAssertNil(b.added, "an unchanged file carries no diffstat")
    XCTAssertNil(src.added, "a directory node is never a changed leaf")
  }
}
