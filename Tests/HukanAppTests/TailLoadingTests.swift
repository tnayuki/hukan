import XCTest

@testable import Hukan

/// The transcript loads tail-first: `loadHistoryIfNeeded` renders only the last
/// `historySliceCount` records and parks the rest in `pendingPrefix`, and
/// `loadEarlierIfNeeded` walks that prefix backwards, prepending slice by slice. What these pin
/// is the assembly: however the conversation arrives, the transcript ends up the byte-identical
/// text a whole render produces (ChunkedRenderTests pins the render side of that claim).
final class TailLoadingTests: XCTestCase {
  private static func records(_ count: Int) -> [HistoryRecord] {
    let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
    return (0..<count).map { index in
      HistoryRecord(
        kind: index.isMultiple(of: 2)
          ? .userText("message \(index)") : .assistantText("reply \(index)"),
        // Pauses at every tenth record, so slices cut across separator decisions too.
        stamp: base.addingTimeInterval(
          Double(index) * (index.isMultiple(of: 10) ? Transcript.timeGap + 1 : 1)))
    }
  }

  /// Prepending every slice reassembles the whole render exactly, and in order.
  @MainActor
  func testBackwardLoadsReassembleTheWholeRender() {
    let records = Self.records(AgentSession.historySliceCount * 2 + 57)
    let session = AgentSession(worktreeID: UUID())
    let cut = records.count - AgentSession.historySliceCount
    session.pendingPrefix = Array(records[..<cut])
    session.transcript.setAttributedString(
      Transcript.render(
        Array(records[cut...]),
        previousStamp: records[..<cut].reversed().compactMap(\.stamp).first))

    while session.hasPendingPrefix {
      let loaded = expectation(description: "slice prepended")
      session.onPrepend = { _ in loaded.fulfill() }
      session.loadEarlierIfNeeded()
      wait(for: [loaded], timeout: 5)
    }
    XCTAssertEqual(session.transcript.string, Transcript.render(records).string)
  }

  /// A hit-jump needs everything above its offset, so `all: true` drains the prefix in one load.
  @MainActor
  func testLoadAllDrainsThePrefixInOnePass() {
    let records = Self.records(AgentSession.historySliceCount * 3)
    let session = AgentSession(worktreeID: UUID())
    let cut = records.count - AgentSession.historySliceCount
    session.pendingPrefix = Array(records[..<cut])
    session.transcript.setAttributedString(
      Transcript.render(
        Array(records[cut...]),
        previousStamp: records[..<cut].reversed().compactMap(\.stamp).first))

    let loaded = expectation(description: "everything prepended")
    session.onPrepend = { _ in loaded.fulfill() }
    session.loadEarlierIfNeeded(all: true)
    wait(for: [loaded], timeout: 5)
    XCTAssertFalse(session.hasPendingPrefix)
    XCTAssertEqual(session.transcript.string, Transcript.render(records).string)
  }
}
