import XCTest

@testable import Hukan

/// The gutter's reading of a file: two texts in, per-line bars out. Pure — `Git.hunks` diffs
/// two strings with no repository behind it — so each git shape that has to read right is
/// pinned as a case here, and `GitLineChangesTests` covers the reads that need a real one.
final class LineChangesTests: XCTestCase {
  private func changes(_ base: String, _ current: String, staged: String? = nil)
    -> Git.LineChanges
  {
    Git.lineChanges(base: Git.FileBase(head: base, index: staged), current: current)
  }

  func testUnchangedFileHasNothing() {
    let changes = changes("one\ntwo\n", "one\ntwo\n")
    XCTAssertTrue(changes.bars.isEmpty)
    XCTAssertTrue(changes.deletions.isEmpty)
  }

  func testAddedLinesAreAdded() {
    let changes = changes("one\nfour\n", "one\ntwo\nthree\nfour\n")
    XCTAssertEqual(changes.bars[2], Git.LineChanges.Bar(kind: .added, staged: false))
    XCTAssertEqual(changes.bars[3], Git.LineChanges.Bar(kind: .added, staged: false))
    XCTAssertNil(changes.bars[1])
    XCTAssertNil(changes.bars[4])
  }

  func testReplacedRunReadsModified() {
    let changes = changes("one\ntwo\nthree\n", "one\nTWO\nthree\n")
    XCTAssertEqual(changes.bars[2], Git.LineChanges.Bar(kind: .modified, staged: false))
    XCTAssertTrue(changes.deletions.isEmpty)
  }

  func testDeletionAnchorsBelowTheSurvivingLine() {
    let changes = changes("one\ntwo\nthree\n", "one\nthree\n")
    XCTAssertEqual(changes.deletions, [1: false])
    XCTAssertTrue(changes.bars.isEmpty)
  }

  func testDeletionAtTheTopAnchorsAboveTheFirstLine() {
    let changes = changes("one\ntwo\nthree\n", "two\nthree\n")
    XCTAssertEqual(changes.deletions, [0: false])
  }

  func testDeletionAtTheEndAnchorsUnderTheLastLine() {
    let changes = changes("one\ntwo\nthree\n", "one\n")
    XCTAssertEqual(changes.deletions, [1: false])
  }

  func testSurplusRemovedLinesFoldIntoTheModifiedSpan() {
    // Three lines rewritten into one: the block replaced something, so its whole new span is
    // modified and the two lines with nowhere to go do not also draw a wedge — one change is
    // one mark.
    let changes = changes("one\na\nb\nc\nfive\n", "one\nA\nfive\n")
    XCTAssertEqual(changes.bars[2], Git.LineChanges.Bar(kind: .modified, staged: false))
    XCTAssertTrue(changes.deletions.isEmpty)
  }

  func testAnIdenticalChangeInTheIndexReadsStaged() {
    let changes = changes("one\ntwo\n", "one\nTWO\n", staged: "one\nTWO\n")
    XCTAssertEqual(changes.bars[2], Git.LineChanges.Bar(kind: .modified, staged: true))
  }

  func testEditingFurtherAfterStagingReadsUnstaged() {
    // Staged as TWO, then typed on again: what is in the index is no longer what is here.
    let changes = changes("one\ntwo\n", "one\nTHREE\n", staged: "one\nTWO\n")
    XCTAssertEqual(changes.bars[2], Git.LineChanges.Bar(kind: .modified, staged: false))
  }

  func testOneBlockStagedAndAnotherNot() {
    let base = "one\ntwo\nthree\nfour\n"
    let changes = changes(base, "ONE\ntwo\nthree\nFOUR\n", staged: "ONE\ntwo\nthree\nfour\n")
    XCTAssertEqual(changes.bars[1], Git.LineChanges.Bar(kind: .modified, staged: true))
    XCTAssertEqual(changes.bars[4], Git.LineChanges.Bar(kind: .modified, staged: false))
  }

  func testHunkCarriesBothSidesForThePeek() {
    let hunks = Git.hunks(base: "one\ntwo\nthree\n", current: "one\nTWO\nthree\n")
    XCTAssertEqual(hunks.count, 1)
    XCTAssertEqual(hunks.first?.oldLines, ["two"])
    XCTAssertEqual(hunks.first?.newLines, ["TWO"])
  }

  func testAPureAdditionHasNothingRemovedToShow() {
    let hunks = Git.hunks(base: "one\n", current: "one\ntwo\n")
    XCTAssertEqual(hunks.first?.oldLines, [])
    XCTAssertEqual(hunks.first?.newLines, ["two"])
  }

  func testAFileWithNoCommittedSideIsNotAllAdded() {
    // Untracked, or a path that never existed at HEAD: no base, so nothing to say about it.
    let changes = Git.lineChanges(base: Git.FileBase(), current: "one\ntwo\n")
    XCTAssertTrue(changes.bars.isEmpty)
  }
}
