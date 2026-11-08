import XCTest

@testable import Hukan

final class MachineUsageTests: XCTestCase {
  func testMachineUsageContributesToTotalsAlongsideAppAndTools() {
    let snapshot = SystemUsageSampler.Snapshot(buckets: [
      .hukan: .init(cpuPercent: 2, memoryBytes: 100, processes: 1),
      .spawned: .init(cpuPercent: 50, memoryBytes: 200, processes: 2),
      .machine: .init(cpuPercent: 175, memoryBytes: 8 << 30, processes: 2),
    ])
    XCTAssertEqual(snapshot.cpuPercent, 227)
    XCTAssertEqual(snapshot.memoryBytes, (8 << 30) + 300)
    XCTAssertEqual(snapshot[.machine].processes, 2)
    XCTAssertEqual(snapshot[.terminal], .init())
  }
}
