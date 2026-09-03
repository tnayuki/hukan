import AppKit
import XCTest

@testable import Hukan

/// A file whose content is pixels, opened from the files panel like any other. What is pinned
/// here is the pane's one promise — that what is on screen is the file's own pixels, one of them
/// to one device pixel — and the two rules that follow from a tab having no text in it: the zoom
/// keys reach it and the find does not.
final class ImagePaneTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    Git.initialize()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-image-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    root = tmp.resolvingSymlinksInPath()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: helpers

  /// A PNG of a known pixel size. `dpi` is what the file *claims*, which the pane has to ignore:
  /// a rep whose point size is the pixel count writes 72, and halving it writes 144.
  @discardableResult
  private func writePNG(_ name: String, width: Int, height: Int, dpi: Double = 72) throws -> URL {
    let rep = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = NSSize(width: Double(width) * 72 / dpi, height: Double(height) * 72 / dpi)
    let url = root.appendingPathComponent(name)
    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    return url
  }

  private func textView(in view: NSView) -> NSTextView? {
    if let text = view as? NSTextView { return text }
    for subview in view.subviews { if let found = textView(in: subview) { return found } }
    return nil
  }

  private func spin(until condition: () -> Bool, _ message: String) {
    let deadline = Date().addingTimeInterval(10)
    while !condition() && Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(condition(), message)
  }

  /// A desk on a worktree, with one file open on it.
  @MainActor
  private func open(_ path: String) throws -> (FileColumns, FileContentViewController, NSWindow) {
    let workspace = Workspace()
    let worktree = workspace.addWorktree(root)
    let files = FileColumns()
    files.workspace = workspace
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = files.desk.view
    files.desk.reload(worktreeID: worktree.id)
    files.desk.openFile(worktree: worktree, path: path, preview: false)
    return (files, try XCTUnwrap(files.desk.activeFileContent), window)
  }

  /// The scale the pane draws at — the window's, since that is what "one device pixel" is
  /// measured in and CI's runner is 1× where this machine is 2×.
  private func scale(of window: NSWindow) -> CGFloat { window.backingScaleFactor }

  // MARK: tests

  /// The whole of what was asked for: a `.png` picked in the files panel is drawn rather than
  /// read as text. It used to arrive as an empty, editable buffer — see `FileSaveTests` for the
  /// half of that which destroyed files.
  @MainActor
  func testAnImageOpensAsPixelsRatherThanText() throws {
    try writePNG("shot.png", width: 120, height: 80)
    let (files, content, window) = try open("shot.png")
    spin(until: { content.isShowingImage }, "the image landed in the pane")

    let drawn = try XCTUnwrap(content.imageDrawnSize)
    XCTAssertEqual(
      drawn.width * scale(of: window), 120, accuracy: 0.01, "one image pixel to one device pixel")
    XCTAssertEqual(drawn.height * scale(of: window), 80, accuracy: 0.01)
    XCTAssertEqual(content.imageMagnification, 1, "and it opens there, not fitted to the column")

    let text = try XCTUnwrap(textView(in: content.view))
    XCTAssertFalse(text.isEditable, "there is no buffer here to type into")
    XCTAssertEqual(text.string, "", "and no note either — the image is the answer")
    XCTAssertFalse(files.hasUnsavedEdit)
  }

  /// Actual pixels is a statement about the display, not about the file. A PNG that claims 144
  /// DPI has `NSImage.size` of half its pixels (measured), and every real file's DPI is noise —
  /// hukan's own 2× snapshot references say 72 — so the pixels are read from the header.
  @MainActor
  func testActualPixelsIgnoresTheDPITheFileClaims() throws {
    try writePNG("lying.png", width: 100, height: 100, dpi: 144)
    let (_, content, window) = try open("lying.png")
    spin(until: { content.isShowingImage }, "the image landed")

    let claimed = try XCTUnwrap(NSImage(contentsOf: root.appendingPathComponent("lying.png")))
    XCTAssertEqual(claimed.size.width, 50, "the file does claim half — this is the trap")

    let drawn = try XCTUnwrap(content.imageDrawnSize)
    XCTAssertEqual(
      drawn.width * scale(of: window), 100, accuracy: 0.01, "the header's pixels win")
  }

  /// The zoom keys are aimed by the focus, the way ⌘F is — and ⌘F is the one aimed away, an
  /// image being the only surface on the desk with no text in it for a find bar to reach.
  @MainActor
  func testTheZoomKeysReachTheImageAndTheFindDoesNot() throws {
    try writePNG("shot.png", width: 400, height: 300)
    let (files, content, _) = try open("shot.png")
    spin(until: { content.isShowingImage }, "the image landed")

    XCTAssertTrue(files.canZoom, "⌘+ / ⌘− / ⌘0 have a surface")
    XCTAssertFalse(files.canFind, "⌘F has nothing to find")

    files.zoom(by: 1)
    XCTAssertGreaterThan(try XCTUnwrap(content.imageMagnification), 1, "one rung in")
    files.zoom(by: -1)
    XCTAssertEqual(try XCTUnwrap(content.imageMagnification), 1, accuracy: 0.001, "and back")

    files.zoom(by: 2)
    files.resetZoom()
    XCTAssertEqual(
      try XCTUnwrap(content.imageMagnification), 1, accuracy: 0.001,
      "Actual Size is the rung itself, not a walk back along the ladder")
  }

  /// How far in a press may go is a size on screen, not a factor: 4× of a 16px icon is still
  /// 32pt of nothing.
  @MainActor
  func testTheCeilingRisesForASmallImage() throws {
    try writePNG("icon.png", width: 16, height: 16)
    try writePNG("wide.png", width: 2000, height: 1200)
    let (_, icon, _) = try open("icon.png")
    spin(until: { icon.isShowingImage }, "the icon landed")
    let iconCeiling = try XCTUnwrap(icon.imageMaxMagnification)

    let (_, wide, _) = try open("wide.png")
    spin(until: { wide.isShowingImage }, "the screenshot landed")
    let wideCeiling = try XCTUnwrap(wide.imageMaxMagnification)

    XCTAssertGreaterThan(iconCeiling, wideCeiling, "the icon can be brought up to something")
    XCTAssertEqual(wideCeiling, 4, accuracy: 0.001, "a screenshot needs no more than 4×")
  }

  /// The table, and the three names it deliberately refuses. `.svg` is the one that matters: both
  /// tests hukan could have used instead — `NSImage(contentsOfFile:)` and `UTType`'s `.image`
  /// conformance — say yes to it (measured), and it is source an agent edits.
  func testTheTableRefusesWhatIsNotPixels() {
    XCTAssertTrue(ImageFile.covers(path: "a/b/shot.png"))
    XCTAssertTrue(ImageFile.covers(path: "SHOT.PNG"), "the extension is read case-insensitively")
    XCTAssertTrue(ImageFile.covers(path: "photo.jpeg"))
    XCTAssertTrue(ImageFile.covers(path: "hukan.icns"), "a container, drawn at its largest")
    XCTAssertFalse(ImageFile.covers(path: "Icon.svg"), "source, and an agent edits it")
    XCTAssertFalse(ImageFile.covers(path: "spec.pdf"), "instructions rather than pixels")
    XCTAssertFalse(ImageFile.covers(path: "Model.swift"))
    XCTAssertFalse(ImageFile.covers(path: "noextension"))
  }

  /// A file holding several bitmaps is drawn at its largest, and says which of them that was.
  /// `NSImage` cannot answer this — hukan's own icon holds ten, 1024 down to 16, and `NSImage`
  /// reports 512, which is neither the largest nor the size of any single one of them.
  @MainActor
  func testAContainerIsDrawnAtItsLargest() throws {
    let icns = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/hukan.icns")
    try FileManager.default.copyItem(at: icns, to: root.appendingPathComponent("app.icns"))

    let claimed = try XCTUnwrap(NSImage(contentsOf: icns))
    XCTAssertEqual(claimed.size.width, 512, "what NSImage would have said — the trap")

    guard case .image(let loaded) = ImageFile.read(at: icns) else {
      return XCTFail("the icon did not read as an image")
    }
    XCTAssertEqual(loaded.pixelWidth, 1024, "the largest bitmap in the file")
    XCTAssertGreaterThan(loaded.count, 1, "and it is one of several")
    XCTAssertTrue(
      loaded.caption.hasPrefix("1024 × 1024, largest of \(loaded.count)"), loaded.caption)

    let (_, content, window) = try open("app.icns")
    spin(until: { content.isShowingImage }, "the icon landed in the pane")
    XCTAssertEqual(
      try XCTUnwrap(content.imageDrawnSize).width * scale(of: window), 1024, accuracy: 0.01)
  }

  /// An image hukan will not draw says so where a file that is not text says so — the same
  /// answer in the same place, which is what keeps a `.png` that is broken from reading as an
  /// empty one.
  @MainActor
  func testAnUnreadableImageSaysSoRatherThanShowingNothing() throws {
    try Data("not really a png".utf8).write(to: root.appendingPathComponent("broken.png"))
    let (files, content, _) = try open("broken.png")
    let text = try XCTUnwrap(textView(in: content.view))
    spin(until: { !text.string.isEmpty }, "the pane said what it found")

    XCTAssertFalse(content.isShowingImage, "there is no image to show")
    XCTAssertEqual(text.string, "This image could not be read")
    XCTAssertFalse(text.isEditable, "and the bytes are not typed over")
    XCTAssertFalse(files.canZoom, "nor is there anything to zoom")
  }

  /// The strip's report is the only place an image tab can be read back at all, the tab being a
  /// row of buttons and the pane holding no text. See the `tabs` verb.
  @MainActor
  func testTheStripSaysWhichTabIsAnImage() throws {
    try writePNG("shot.png", width: 40, height: 40)
    let (files, content, _) = try open("shot.png")
    spin(until: { content.isShowingImage }, "the image landed")
    XCTAssertTrue(
      files.desk.tabStripReport.contains("file      shot.png  (image)"),
      files.desk.tabStripReport)
  }
}
