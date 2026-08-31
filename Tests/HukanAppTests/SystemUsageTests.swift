import XCTest

@testable import Hukan

/// The footprint's split: a process belongs to whatever its branch off hukan's own pid is — the
/// engine's branch is the engine and what it spawned, a shell's branch is that terminal's.
final class SystemUsageTests: XCTestCase {
  func testProcessesAreSharedOutByTheirBranchOffTheRoot() {
    // root 1 ─┬─ 10 claude ─── 11 xcodebuild ─── 12 clang
    //         ├─ 13 claude
    //         └─ 20 zsh ─── 21 make ─── 22 cc
    let parents: [pid_t: pid_t] = [1: 0, 10: 1, 11: 10, 12: 11, 13: 1, 20: 1, 21: 20, 22: 21]
    let kinds = SystemUsageSampler.classify(
      parents: parents, root: 1, engines: [10, 13], shells: [20])
    XCTAssertEqual(kinds[1], .hukan)
    XCTAssertEqual(kinds[10], .engine)
    XCTAssertEqual(kinds[13], .engine)
    XCTAssertEqual(kinds[11], .spawned)
    XCTAssertEqual(kinds[12], .spawned, "an engine's grandchild is still the engine's")
    XCTAssertEqual(kinds[20], .terminal)
    XCTAssertEqual(kinds[22], .terminal, "and what runs in a terminal is the terminal's")
    XCTAssertEqual(kinds.count, parents.count, "the split covers what this window is running")
  }

  /// The reading is one window's, and the tree is the app's: a second window's engine is a branch
  /// off the same root, and it used to be counted here — as a *terminal*, since the only sets
  /// named were this window's. That put `Terminals (4)` over a desk holding one terminal and
  /// charged another window's agents to it.
  func testAnotherWindowsBranchesAreNotThisWindows() {
    // root 1 ─┬─ 10 claude (ours) ─── 11 gh
    //         ├─ 30 claude (another window's) ─── 31 zsh ─── 32 zsh
    //         └─ 40 zsh (another window's terminal)
    let parents: [pid_t: pid_t] = [1: 0, 10: 1, 11: 10, 30: 1, 31: 30, 32: 31, 40: 1]
    let kinds = SystemUsageSampler.classify(parents: parents, root: 1, engines: [10], shells: [])
    XCTAssertEqual(kinds[10], .engine)
    XCTAssertEqual(kinds[11], .spawned)
    for pid: pid_t in [30, 31, 32, 40] {
      XCTAssertNil(kinds[pid], "\(pid) is another window's and is not this one's terminal")
    }
    XCTAssertEqual(kinds[1], .hukan, "the root is one process, so every window carries it")
  }

  /// A live reading of this very process: the root is one process with a real footprint, and a
  /// second reading has a CPU rate to report.
  func testALiveSampleCountsTheRootOnce() {
    var sampler = SystemUsageSampler()
    _ = sampler.sample(engines: [], shells: [])
    Thread.sleep(forTimeInterval: 0.05)
    let snapshot = sampler.sample(engines: [], shells: [])
    XCTAssertEqual(snapshot[.hukan].processes, 1)
    XCTAssertGreaterThan(snapshot[.hukan].memoryBytes, 0)
    XCTAssertEqual(snapshot[.engine].processes, 0, "nothing was named as an engine")
    XCTAssertEqual(snapshot[.terminal].processes, 0, "nor as a terminal")
    XCTAssertGreaterThanOrEqual(snapshot.cpuPercent, 0)
  }
}
