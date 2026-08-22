import XCTest

@testable import Hukan

/// The footprint's split: a process belongs to whatever its branch off hukan's own pid is — the
/// engine's branch is the engine and what it spawned, any other branch is a terminal's.
final class SystemUsageTests: XCTestCase {
  func testProcessesAreSharedOutByTheirBranchOffTheRoot() {
    // root 1 ─┬─ 10 claude ─── 11 xcodebuild ─── 12 clang
    //         ├─ 13 claude
    //         └─ 20 zsh ─── 21 make ─── 22 cc
    let parents: [pid_t: pid_t] = [1: 0, 10: 1, 11: 10, 12: 11, 13: 1, 20: 1, 21: 20, 22: 21]
    let kinds = SystemUsageSampler.classify(parents: parents, root: 1, engines: [10, 13])
    XCTAssertEqual(kinds[1], .hukan)
    XCTAssertEqual(kinds[10], .engine)
    XCTAssertEqual(kinds[13], .engine)
    XCTAssertEqual(kinds[11], .spawned)
    XCTAssertEqual(kinds[12], .spawned, "an engine's grandchild is still the engine's")
    XCTAssertEqual(kinds[20], .terminal)
    XCTAssertEqual(kinds[22], .terminal, "and what runs in a terminal is the terminal's")
    XCTAssertEqual(kinds.count, parents.count, "the split covers the whole tree")
  }

  /// A live reading of this very process: the root is one process with a real footprint, and a
  /// second reading has a CPU rate to report.
  func testALiveSampleCountsTheRootOnce() {
    var sampler = SystemUsageSampler()
    _ = sampler.sample(engines: [])
    Thread.sleep(forTimeInterval: 0.05)
    let snapshot = sampler.sample(engines: [])
    XCTAssertEqual(snapshot[.hukan].processes, 1)
    XCTAssertGreaterThan(snapshot[.hukan].memoryBytes, 0)
    XCTAssertEqual(snapshot[.engine].processes, 0, "nothing was named as an engine")
    XCTAssertGreaterThanOrEqual(snapshot.cpuPercent, 0)
  }
}
