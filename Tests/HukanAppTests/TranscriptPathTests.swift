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
    XCTAssertNil(TranscriptPath.file(named: "https://example.com/a", relativeTo: root))
    XCTAssertNil(TranscriptPath.file(named: "maximumSpan", relativeTo: root))
  }

  /// A directory is answered as one, so the menu can offer it to the Finder and nothing else.
  @MainActor
  func testADirectoryOffersOnlyTheFinder() throws {
    let directory = try XCTUnwrap(TranscriptPath.file(named: "Sources/Hukan", relativeTo: root))
    XCTAssertTrue(directory.hasDirectoryPath)
    XCTAssertEqual(
      directory.path, root.appendingPathComponent("Sources/Hukan").standardizedFileURL.path)

    _ = NSApplication.shared
    let (scrollView, textView) = makeReadingView()
    scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
    textView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
    textView.setContent(Transcript.markdown("Look in `Sources/Hukan` first\n"))
    textView.resolvePath = { [root] in TranscriptPath.file(named: $0, relativeTo: root) }
    let text = textView.string as NSString
    let at = text.range(of: "Hukan").location
    let rect = try XCTUnwrap(textView.rects(for: NSRange(location: at, length: 1)).first)
    let menu = try XCTUnwrap(textView.menu(at: CGPoint(x: rect.midX, y: rect.midY)))
    XCTAssertEqual(menu.items.map(\.title), ["Open “Hukan” in Finder"])
  }

  /// A file the editor would only say it cannot read is not offered to it: Open With, whose first
  /// row is the default application, is the way to open it, and the rest stays.
  @MainActor
  func testAFileTheEditorCannotShowIsNotOfferedToIt() throws {
    try Data([0x50, 0x4B, 0x03, 0x04, 0xFF, 0xFE, 0x00, 0x80]).write(
      to: root.appendingPathComponent("archive.zip"))
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appendingPathComponent("shot.png"))
    let archive = root.appendingPathComponent("archive.zip")
    XCTAssertFalse(FileContentViewController.shows(fileAt: archive))
    XCTAssertTrue(FileContentViewController.shows(fileAt: model))
    XCTAssertTrue(
      FileContentViewController.shows(fileAt: root.appendingPathComponent("shot.png")),
      "an image is taken at its extension")

    _ = NSApplication.shared
    let (scrollView, textView) = makeReadingView()
    scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
    textView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
    textView.setContent(Transcript.markdown("Wrote `archive.zip` just now\n"))
    textView.resolvePath = { [root] in TranscriptPath.file(named: $0, relativeTo: root) }
    textView.opensFile = { FileContentViewController.shows(fileAt: $0) }
    let text = textView.string as NSString
    let at = text.range(of: "archive").location
    let rect = try XCTUnwrap(textView.rects(for: NSRange(location: at, length: 1)).first)
    let menu = try XCTUnwrap(textView.menu(at: CGPoint(x: rect.midX, y: rect.midY)))
    XCTAssertEqual(
      menu.items.map(\.title).filter { $0 != "Open With" }, ["Quick Look", "Reveal in Finder"])
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
    // Open With is there only when some application claims a `.swift`, which is the machine's.
    XCTAssertEqual(
      menu.items.map(\.title).filter { $0 != "Open With" },
      ["Open “Model.swift”", "Quick Look", "Reveal in Finder"])
    textView.openFile(menu.items[0])
    XCTAssertEqual(opened, [model])

    // A word that names no file offers nothing, as before.
    let word = try XCTUnwrap(
      textView.rects(for: NSRange(location: text.range(of: "Edited").location, length: 1)).first)
    XCTAssertNil(textView.menu(at: CGPoint(x: word.midX, y: word.midY)))
  }
}
