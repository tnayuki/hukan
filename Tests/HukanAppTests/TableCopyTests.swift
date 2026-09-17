import AppKit
import XCTest

@testable import Hukan

/// A table renders as one drawn attachment, so a selection covering it would copy as `￼` unless the
/// attachment is expanded back to text. `TranscriptDocumentView.writeSelection` does that; this pins it,
/// offscreen, on a private pasteboard so it never touches the real clipboard.
final class TableCopyTests: XCTestCase {
  override class func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  func testCopyingSelectionExpandsTableToMarkdown() throws {
    let (_, textView) = makeTranscriptDocumentView()
    textView.setContent(
      Transcript.markdown(
        """
        | プロセス | 状態 |
        |---|---|
        | **検索インデクサ** | 継続中 |
        """))

    textView.setSelectedRange(NSRange(location: 0, length: textView.length))
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("hukan.table-copy-test"))
    pasteboard.clearContents()
    textView.writeSelection(to: pasteboard)

    let copied = try XCTUnwrap(pasteboard.string(forType: .string))
    XCTAssertFalse(copied.contains("\u{FFFC}"), "the attachment character leaked into the copy")
    // The header, a body cell, and the inline markup all come back as the source text.
    XCTAssertTrue(copied.contains("| プロセス | 状態 |"))
    XCTAssertTrue(copied.contains("| **検索インデクサ** | 継続中 |"))
  }
}
