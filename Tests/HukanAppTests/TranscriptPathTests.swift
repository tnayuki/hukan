import AppKit
import XCTest

@testable import Hukan

/// A path named in the transcript opens from the right-click menu. Nothing is coloured for it
/// ahead of time, so what has to hold is the narrow answer at the click: the token the double-click
/// would select, resolved against the checkout the conversation stands in, and only when the disk
/// has a file there.
final class TranscriptPathTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-transcript-path-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Sources/Hukan"), withIntermediateDirectories: true)
    try "let a = 1\n".write(
      to: root.appendingPathComponent("Sources/Hukan/Model.swift"), atomically: true,
      encoding: .utf8)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private var model: URL {
    root.appendingPathComponent("Sources/Hukan/Model.swift").standardizedFileURL
  }

  func testARelativePathIsTheCheckoutsAndAbsoluteIsItself() {
    XCTAssertEqual(TranscriptPath.file(named: "Sources/Hukan/Model.swift", relativeTo: root), model)
    XCTAssertEqual(TranscriptPath.file(named: model.path, relativeTo: nil), model)
    XCTAssertNil(
      TranscriptPath.file(named: "Sources/Hukan/Model.swift", relativeTo: nil),
      "a relative path with no checkout to be relative to names nothing")
  }

  /// The double-click takes the line with the file; the tab cannot be opened at a line, so the
  /// line is dropped rather than making the path unresolvable.
  func testTheLineAnAgentHandsWithAFileIsDropped() {
    XCTAssertEqual(
      TranscriptPath.file(named: "Sources/Hukan/Model.swift:120", relativeTo: root), model)
  }

  func testWhatIsNotAFileOnDiskNamesNothing() {
    XCTAssertNil(TranscriptPath.file(named: "Sources/Hukan/Gone.swift", relativeTo: root))
    XCTAssertNil(TranscriptPath.file(named: "Sources/Hukan", relativeTo: root), "a directory")
    XCTAssertNil(TranscriptPath.file(named: "https://example.com/a", relativeTo: root))
    XCTAssertNil(TranscriptPath.file(named: "maximumSpan", relativeTo: root))
  }

  /// The menu is offered on the token a double-click would select — here inside a code span,
  /// which is where an agent puts nearly every path — and Open hands the file to the owner.
  @MainActor
  func testARightClickOnAPathOffersToOpenIt() throws {
    _ = NSApplication.shared
    let (scrollView, textView) = makeReadingView()
    scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
    textView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
    textView.setContent(Transcript.markdown("Edited `Sources/Hukan/Model.swift:12` just now\n"))
    textView.resolvePath = { [root] in TranscriptPath.file(named: $0, relativeTo: root) }
    var opened: [URL] = []
    textView.onOpenFile = { opened.append($0) }

    let text = textView.string as NSString
    let at = text.range(of: "Model").location
    let rect = try XCTUnwrap(textView.rects(for: NSRange(location: at, length: 1)).first)
    let menu = try XCTUnwrap(textView.menu(at: CGPoint(x: rect.midX, y: rect.midY)))
    XCTAssertEqual(menu.items.first?.title, "Open “Model.swift”")
    XCTAssertTrue(menu.items.contains { $0.title == "Quick Look" }, "\(menu.items.map(\.title))")
    textView.openFile(menu.items[0])
    XCTAssertEqual(opened, [model])

    // A word that names no file offers nothing, as before.
    let word = try XCTUnwrap(
      textView.rects(for: NSRange(location: text.range(of: "Edited").location, length: 1)).first)
    XCTAssertNil(textView.menu(at: CGPoint(x: word.midX, y: word.midY)))
  }
}
