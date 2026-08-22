import XCTest

@testable import Hukan

/// Rendering a conversation in slices must reproduce the whole-file render exactly. The tail
/// loads first and the prefix arrives later (in chunks, as the reader scrolls up), and every
/// offset computed against a full render — the rail's search hits above all — is only true of
/// the assembled transcript if the two are byte-identical. `previousStamp` is what carries the
/// one piece of cross-record state (the time-separator clock) over a cut.
final class ChunkedRenderTests: XCTestCase {
  /// A conversation whose stamps land on both sides of the separator gap, so a naive slice —
  /// one that resets the clock — puts a separator at the seam the full render does not have.
  private static func records(base: Date) -> [HistoryRecord] {
    let gap = Transcript.timeGap
    return [
      HistoryRecord(kind: .userText("first"), stamp: base),
      HistoryRecord(kind: .assistantText("close"), stamp: base.addingTimeInterval(1)),
      HistoryRecord(kind: .toolUse(name: "Bash", input: ["command": "ls"]), stamp: nil),
      HistoryRecord(kind: .userText("after a pause"), stamp: base.addingTimeInterval(gap + 60)),
      HistoryRecord(
        kind: .assistantText("still close"), stamp: base.addingTimeInterval(gap + 61)),
    ]
  }

  /// The stamp the next slice must inherit: the last non-nil one, however the slice was cut.
  private static func lastStamp(of records: ArraySlice<HistoryRecord>) -> Date? {
    records.reversed().compactMap(\.stamp).first
  }

  @MainActor
  func testSlicedRenderMatchesWholeRender() {
    let records = Self.records(base: Date(timeIntervalSinceReferenceDate: 800_000_000))
    let whole = Transcript.render(records)
    // Every cut point, including the ones straddling the un-stamped record and the pause.
    for cut in 0...records.count {
      let head = Transcript.render(Array(records[..<cut]))
      let tail = Transcript.render(
        Array(records[cut...]), previousStamp: Self.lastStamp(of: records[..<cut]))
      let assembled = NSMutableAttributedString(attributedString: head)
      assembled.append(tail)
      XCTAssertEqual(
        assembled.string, whole.string,
        "slicing at record \(cut) must not add or drop a time separator")
    }
  }
}
