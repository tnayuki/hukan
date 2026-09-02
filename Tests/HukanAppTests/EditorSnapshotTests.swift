import XCTest

@testable import Hukan

/// Pins the source pane's editor look — highlighted Swift through the real grammar, query and
/// theme, the gutter's line numbers, and every change-bar state — the way `SnapshotTests` pins
/// the transcript's. The async highlighter cannot be waited on deterministically, so the colors
/// come from `SyntaxHighlighting.spans`, the synchronous whole-file parse that drives the same
/// pieces, applied through the same channel (TextKit 2 rendering attributes). Same recording
/// flow: `TEST_RUNNER_HUKAN_RECORD=1` re-records, `TEST_RUNNER_HUKAN_PREVIEW=editor` writes
/// /tmp/hukan-preview-editor.png and leaves the reference alone.
final class EditorSnapshotTests: XCTestCase {
  private static let reference = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Snapshots/editor.png")
  private static let patchReference = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Snapshots/patch.png")

  private static let source = """
    import AppKit

    /// A documentation comment — the em dash is here on purpose: it is one UTF-16 unit and
    /// three UTF-8 bytes, so a span computed in the wrong units drifts from this line down.
    struct Renderer {
      let name = "editor"  // a trailing comment long enough to cross the right edge and prove lines never wrap
      var count: Int = 42

      @MainActor
      func render(scale: Double) -> Bool {
        guard count > 0 else { return false }
        for index in 0..<count {
          print("pass \\(index) at \\(scale)")
        }
        return true
      }
    }
    """

  /// Every change-bar state on one screen: a run of added lines (which has to read as one
  /// continuous mark, not a column of stubs), a staged run drawn hollow, a lone stub, and a
  /// deletion wedge on both kinds of boundary — above the first line and below a kept one.
  private static let lineChanges = Git.LineChanges(
    bars: [
      5: Git.LineChanges.Bar(kind: .added, staged: false),
      6: Git.LineChanges.Bar(kind: .added, staged: false),
      9: Git.LineChanges.Bar(kind: .modified, staged: true),
      10: Git.LineChanges.Bar(kind: .modified, staged: true),
      11: Git.LineChanges.Bar(kind: .modified, staged: true),
      14: Git.LineChanges.Bar(kind: .added, staged: false),
    ],
    deletions: [0: false, 12: true])

  /// A patch, which the pane reads as two things at once: the diff's own frame — the command,
  /// the index, the hunk's location — and, behind and inside the hunk's rows, the side each row
  /// is on and what it says in the language being patched. What has to be visible here is that
  /// the two do not fight: a green row's `func` is still pink, and the band is what carries the
  /// `+`. The last hunk crosses the foot of the pane, which is where a band drawn to the row
  /// rather than to the view would show its ragged edge.
  private static let patch = """
    diff --git a/Sources/Hukan/Renderer.swift b/Sources/Hukan/Renderer.swift
    index 1a2b3c4..5d6e7f8 100644
    --- a/Sources/Hukan/Renderer.swift
    +++ b/Sources/Hukan/Renderer.swift
    @@ -1,9 +1,10 @@
     import AppKit

     struct Renderer {
    -  let name = "old"
    +  let name = "editor"  // a trailing comment long enough to cross the right edge
    +  var count: Int = 42

       func render(scale: Double) -> Bool {
    -    guard count > 0 else { return false }
    +    guard count > 0, scale > 0 else { return false }
         return true
       }
     }
    """

  /// The card a hover opens, posed beside the run it belongs to.
  private static let peeked = Git.Hunk(
    oldStart: 8, oldLen: 2, newStart: 8, newLen: 3,
    oldLines: ["    guard count > 0 else { return nil }", "    for index in 0...count {"],
    newLines: [
      "    guard count > 0 else { return false }", "    for index in 0..<count {",
      "      print(\"pass \\(index)\")",
    ], staged: true)

  @MainActor
  func testEditorMatchesSnapshot() throws {
    if ProcessInfo.processInfo.environment["HUKAN_PREVIEW"] == "editor" {
      let out = URL(fileURLWithPath: "/tmp/hukan-preview-editor.png")
      try render().write(to: out)
      print("preview: \(out.path)")
      return
    }

    let record = ProcessInfo.processInfo.environment["HUKAN_RECORD"] == "1"
    let actual = try render()
    if record {
      try actual.write(to: Self.reference)
      XCTFail("recorded editor snapshot — run again without HUKAN_RECORD to verify")
      return
    }
    guard let expected = try? Data(contentsOf: Self.reference) else {
      XCTFail(
        "no reference at \(Self.reference.path) — record with TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test"
      )
      return
    }
    if pixels(expected) != pixels(actual) {
      let failed = FileManager.default.temporaryDirectory
        .appendingPathComponent("hukan-snapshots/editor-actual.png")
      try? FileManager.default.createDirectory(
        at: failed.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? actual.write(to: failed)
      XCTFail(
        "editor: rendered output differs from editor.png (actual written to \(failed.path);"
          + " if the change is intended, re-record with TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test)"
      )
    }
  }

  /// The same pane showing a patch. Its own reference, because what it pins is a different
  /// answer to the same question — a file whose grammar bands rows, against every file that has
  /// none — and one image cannot hold both.
  @MainActor
  func testPatchMatchesSnapshot() throws {
    let render = {
      try self.render(
        source: Self.patch, path: "change.diff", lineChanges: Git.LineChanges(), peek: nil)
    }
    if ProcessInfo.processInfo.environment["HUKAN_PREVIEW"] == "patch" {
      let out = URL(fileURLWithPath: "/tmp/hukan-preview-patch.png")
      try render().write(to: out)
      print("preview: \(out.path)")
      return
    }
    let actual = try render()
    if ProcessInfo.processInfo.environment["HUKAN_RECORD"] == "1" {
      try actual.write(to: Self.patchReference)
      XCTFail("recorded patch snapshot — run again without HUKAN_RECORD to verify")
      return
    }
    guard let expected = try? Data(contentsOf: Self.patchReference) else {
      XCTFail(
        "no reference at \(Self.patchReference.path) — record with TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test"
      )
      return
    }
    if pixels(expected) != pixels(actual) {
      let failed = FileManager.default.temporaryDirectory
        .appendingPathComponent("hukan-snapshots/patch-actual.png")
      try? FileManager.default.createDirectory(
        at: failed.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? actual.write(to: failed)
      XCTFail(
        "patch: rendered output differs from patch.png (actual written to \(failed.path);"
          + " if the change is intended, re-record with TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test)"
      )
    }
  }

  /// Draw the editor stack offscreen. The views live in a real (never shown) window because
  /// the ruler only draws against a live scroll relationship — but the drawing itself is
  /// manual, fragment by fragment like `TranscriptPreview`: `cacheDisplay` on a windowless
  /// TextKit 2 text view comes back without the text.
  @MainActor
  private func render(
    source: String = EditorSnapshotTests.source, path: String = "editor.swift",
    lineChanges: Git.LineChanges = EditorSnapshotTests.lineChanges,
    peek: Git.Hunk? = EditorSnapshotTests.peeked
  ) throws -> Data {
    let appearance = NSAppearance(named: .darkAqua)!
    NSApplication.shared.appearance = appearance

    let (scrollView, textView) = makeEditorTextView()
    scrollView.hasVerticalScroller = false
    textView.textStorage?.setAttributedString(
      NSAttributedString(
        string: source,
        attributes: [.font: monospace, .foregroundColor: NSColor.labelColor]))

    let gutter = EditorGutter(scrollView: scrollView, textView: textView)
    scrollView.verticalRulerView = gutter
    scrollView.hasVerticalRuler = true
    scrollView.rulersVisible = true
    gutter.lineChanges = lineChanges

    let size = NSSize(width: 520, height: 300)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = scrollView
    scrollView.layoutSubtreeIfNeeded()

    guard let layoutManager = textView.textLayoutManager,
      let contentManager = layoutManager.textContentManager
    else { throw XCTSkip("no TextKit 2 layout manager") }
    // The bands go in before the layout: whether a file has any is what the fragments' own
    // rendering surface is read off, and that is read once, when a fragment is laid out.
    let read = SyntaxHighlighting.highlight(in: source, forPath: path)
    (layoutManager.delegate as? EmphasisTable)?.bands = read.bands
    layoutManager.ensureLayout(for: layoutManager.documentRange)

    // The colors, through the channel the live highlighter uses.
    let start = contentManager.documentRange.location
    for span in read.spans {
      guard let from = contentManager.location(start, offsetBy: span.range.location),
        let to = contentManager.location(start, offsetBy: NSMaxRange(span.range)),
        let range = NSTextRange(location: from, end: to)
      else { continue }
      layoutManager.setRenderingAttributes([.foregroundColor: span.color], for: range)
    }

    let image = NSImage(size: size)
    image.lockFocus()
    appearance.performAsCurrentDrawingAppearance {
      // What sits behind the transparent editor stack in the app: the window's background.
      NSColor.windowBackgroundColor.setFill()
      NSBezierPath.fill(NSRect(origin: .zero, size: size))
      guard let context = NSGraphicsContext.current?.cgContext else { return }

      // Both pieces draw in top-down coordinates; the image context counts up from the bottom.
      context.saveGState()
      context.translateBy(x: 0, y: size.height)
      context.scaleBy(x: 1, y: -1)
      // The CTM flip alone leaves NSString.draw upside down — string drawing reads the
      // *graphics context's* flipped flag, which AppKit sets when it drives a flipped view.
      let flipped = NSGraphicsContext(cgContext: context, flipped: true)
      let previous = NSGraphicsContext.current
      NSGraphicsContext.current = flipped
      gutter.drawHashMarksAndLabels(in: gutter.bounds)
      NSGraphicsContext.current = previous

      let inset = textView.textContainerInset
      context.translateBy(x: gutter.ruleThickness + inset.width, y: inset.height)
      layoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) {
        fragment in
        fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
        return true
      }
      // The peek card, posed where a hover over the modified run would put it.
      if let peek {
        let card = DiffPeekView(hunk: peek)
        context.saveGState()
        context.translateBy(x: -inset.width + 8, y: 150)
        let cardContext = NSGraphicsContext(cgContext: context, flipped: true)
        let previousCard = NSGraphicsContext.current
        NSGraphicsContext.current = cardContext
        card.draw(card.bounds)
        NSGraphicsContext.current = previousCard
        context.restoreGState()
      }

      context.restoreGState()
    }
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else { fatalError("could not encode a PNG") }
    return png
  }

  /// Decoded size + raw pixels, the way `SnapshotTests` compares — encoder-setting drift
  /// between OS versions must not pass (or mask) a comparison.
  private func pixels(_ png: Data) -> [Data] {
    guard let rep = NSBitmapImageRep(data: png), let data = rep.tiffRepresentation else {
      return [png]
    }
    return [Data("\(rep.pixelsWide)x\(rep.pixelsHigh)".utf8), data]
  }
}
