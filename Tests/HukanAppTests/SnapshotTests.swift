import XCTest

@testable import Hukan

/// Pixel-compares every `RenderCase` against a reference PNG in `Snapshots/`, rendered through
/// exactly the drawing path the app ships (`TranscriptPreview.image`). A look change is caught
/// as a diff instead of depending on someone remembering to eyeball the right case.
///
/// References live in the source tree and are found via `#filePath`, not a resource bundle, so
/// recording writes straight back to the repository. `xcodebuild` forwards environment variables
/// to the test process via the `TEST_RUNNER_` prefix:
///
///     TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test …    # re-record every reference
///     TEST_RUNNER_HUKAN_PREVIEW=tables xcodebuild test -only-testing:HukanAppTests/SnapshotTests/testPreview
///                                                     # render one case (or "all") to /tmp, references untouched
///
/// `testPreview` is the throwaway look-iteration loop the standalone `hukan-render` tool used to
/// be, folded back in now that rendering lives in the app module (no separate library to build a
/// tool against). Comparison is byte-exact on the decoded bitmaps: a single-machine project (see
/// the charter), so text antialiasing is stable and a tolerance would only blur the question the
/// test exists to answer — "did the rendering change?".
final class SnapshotTests: XCTestCase {
  private static let snapshotsDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Snapshots")

  /// The width every case renders at — what a recorded reference and a `testPreview` PNG share.
  private static let width: CGFloat = 520

  override class func setUp() {
    super.setUp()
    // The renderer sets the appearance on NSApplication.shared; make sure it exists before
    // any case renders (the xctest runner does not create it).
    _ = NSApplication.shared
  }

  func testRenderCasesMatchSnapshots() throws {
    let record = ProcessInfo.processInfo.environment["HUKAN_RECORD"] == "1"
    if record {
      try FileManager.default.createDirectory(
        at: Self.snapshotsDir, withIntermediateDirectories: true)
    }

    for (name, content) in RenderCase.all {
      let reference = Self.snapshotsDir.appendingPathComponent("\(name).png")
      let actual = pngData(TranscriptPreview.image(content: content(), width: Self.width))

      if record {
        try actual.write(to: reference)
        continue
      }

      guard let expected = try? Data(contentsOf: reference) else {
        XCTFail(
          "\(name): no reference at \(reference.path) — record with TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test"
        )
        continue
      }
      if pixels(expected) != pixels(actual) {
        let failed = attach(name: name, expected: expected, actual: actual)
        XCTFail(
          "\(name): rendered output differs from \(reference.lastPathComponent)"
            + " (actual written to \(failed.path); if the change is intended,"
            + " re-record with TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test)")
      }
    }
    if record {
      XCTFail(
        "recorded \(RenderCase.all.count) snapshots — run again without HUKAN_RECORD to verify")
    }
  }

  /// Non-destructive look iteration: render `HUKAN_PREVIEW` (a case name, or "all") to /tmp and
  /// stop, leaving the committed references alone. A no-op when the variable is unset.
  func testPreview() throws {
    guard let want = ProcessInfo.processInfo.environment["HUKAN_PREVIEW"] else { return }
    let cases = want == "all" ? RenderCase.all : RenderCase.all.filter { $0.name == want }
    guard !cases.isEmpty else {
      XCTFail("unknown preview case '\(want)'; known: \(RenderCase.names.joined(separator: ", "))")
      return
    }
    // Override the width to eyeball how a case reflows (tables especially) at a narrow pane.
    var width = Self.width
    if let raw = ProcessInfo.processInfo.environment["HUKAN_PREVIEW_WIDTH"], let value = Double(raw)
    {
      width = CGFloat(value)
    }
    for (name, content) in cases {
      let out = URL(fileURLWithPath: "/tmp/hukan-preview-\(name).png")
      try pngData(TranscriptPreview.image(content: content(), width: width)).write(to: out)
      print("preview: \(out.path)")
    }
  }

  /// PNG-encode through the same bitmap rep the comparison decodes, so a recorded reference and a
  /// `testPreview` PNG are the same bytes-for-pixels.
  private func pngData(_ image: NSImage) -> Data {
    guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else {
      fatalError("could not encode a PNG")
    }
    return png
  }

  /// Decoded size + raw pixels. Compared instead of the PNG bytes so a change in encoder
  /// settings between OS versions cannot fail (or worse, mask) a comparison.
  private func pixels(_ png: Data) -> [Data] {
    guard let rep = NSBitmapImageRep(data: png), let data = rep.tiffRepresentation else {
      return [png]
    }
    return [Data("\(rep.pixelsWide)x\(rep.pixelsHigh)".utf8), data]
  }

  /// Write the failing actual next to nothing permanent (a temp dir), attach both images to
  /// the test result, and hand back the actual's path for the failure message.
  private func attach(name: String, expected: Data, actual: Data) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hukan-snapshots")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let actualURL = dir.appendingPathComponent("\(name)-actual.png")
    try? actual.write(to: actualURL)
    for (label, data) in [("expected", expected), ("actual", actual)] {
      let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
      attachment.name = "\(name)-\(label)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    return actualURL
  }
}
