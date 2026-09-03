import XCTest

@testable import Hukan

/// Bold and italic without a font change. Rendering attributes turned out to be colour-only in
/// practice (the layout manager keeps a stroke or an underline and never merges it into the
/// line it draws), so emphasis is drawn by `EmphasisFragment` over the laid-out glyphs. These
/// pin that it lands, and that it lands on the right word.
final class EmphasisTests: XCTestCase {
  /// The delimiters belong to the word they delimit. `@punctuation.delimiter` says what the
  /// `**` *is*, which is a matter of colour; it does not say the bold around them has stopped,
  /// and `**bold**` reads as one thing rather than a bold word between two upright stars.
  func testTheStarsAreBoldWithTheWord() {
    let source = "plain **bold** and *italic* here\n"
    let spans = SyntaxHighlighting.spans(in: source, forPath: "a.md")
    let text = source as NSString
    /// The last span covering an offset is the one that decides it.
    func emphasis(at offset: Int) -> SyntaxHighlighting.Emphasis {
      var result = SyntaxHighlighting.Emphasis()
      for span in spans where NSLocationInRange(offset, span.range) { result = span.emphasis }
      return result
    }
    XCTAssertTrue(emphasis(at: text.range(of: "bold").location).contains(.bold))
    XCTAssertTrue(emphasis(at: text.range(of: "**").location).contains(.bold))
    let italic = text.range(of: "italic").location
    XCTAssertTrue(emphasis(at: italic).contains(.italic))
    XCTAssertTrue(emphasis(at: italic - 1).contains(.italic), "the delimiter fell out of the slant")
    XCTAssertTrue(emphasis(at: 0).isEmpty, "the plain text before it was caught up in something")
  }

  /// A fence's content is nobody's language until an injection claims it — `@none` in the
  /// Markdown grammar — so a fence with no info string reads plain rather than keeping the
  /// colour the block around it was given.
  func testAFenceWithNoLanguageIsPlain() {
    let source = "```\nnot code in any language\n```\n"
    let spans = SyntaxHighlighting.spans(in: source, forPath: "a.md")
    let text = source as NSString
    let content = text.range(of: "not code")
    var colour: NSColor?
    for span in spans where NSIntersectionRange(span.range, content).length > 0 {
      colour = span.color
    }
    XCTAssertNotEqual(
      colour, SyntaxHighlighting.Palette.red, "the fence kept text.literal's red inside it")
  }

  func testMarkdownEmphasisIsAskedFor() {
    let source = "plain **bold** and *italic* here\n"
    let spans = SyntaxHighlighting.spans(in: source, forPath: "a.md")
    let text = source as NSString
    func emphasis(of word: String) -> SyntaxHighlighting.Emphasis {
      let range = text.range(of: word)
      return spans.filter { NSIntersectionRange($0.range, range).length > 0 }
        .reduce(into: SyntaxHighlighting.Emphasis()) { $0.formUnion($1.emphasis) }
    }
    XCTAssertTrue(emphasis(of: "bold").contains(.bold))
    XCTAssertTrue(emphasis(of: "italic").contains(.italic))
    XCTAssertTrue(emphasis(of: "plain").isEmpty)
  }

  /// How much of the paper a pixel covers, over the white this renders on. `brightnessComponent`
  /// was the measure and it cannot see this line: HSB brightness is the largest component, and
  /// "world" carries a red rendering attribute, so its pixels come out with red pinned at 1 and
  /// only green and blue falling. Every one of them reads as brightness 1.0, thickened or not.
  private func ink(_ color: NSColor) -> CGFloat {
    guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
    return 1 - (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3
  }

  /// The editor's stack, drawn through its real layout delegate with `emphasis` in the
  /// table the fragments read.
  @MainActor
  private func render(emphasis: [(NSRange, SyntaxHighlighting.Emphasis)]) -> (
    NSBitmapImageRep, CGFloat
  ) {
    let (scrollView, textView) = makeEditorTextView()
    let window = SnapshotSurface.window(
      size: NSSize(width: 400, height: 60), appearance: NSAppearance(named: .aqua)!)
    window.contentView = scrollView
    textView.textStorage?.setAttributedString(
      NSAttributedString(
        string: "hello world again",
        attributes: [.font: monospace, .foregroundColor: NSColor.black]))
    scrollView.layoutSubtreeIfNeeded()
    let layoutManager = textView.textLayoutManager!
    let table = try! XCTUnwrap(layoutManager.delegate as? EmphasisTable)
    table.spans = emphasis
    // The colour goes the way every colour goes, as a rendering attribute — which the
    // emphasis draw has to carry through, since it stands in for the draw that would have.
    if let cm = layoutManager.textContentManager,
      let from = cm.location(cm.documentRange.location, offsetBy: 6),
      let to = cm.location(cm.documentRange.location, offsetBy: 11),
      let range = NSTextRange(location: from, end: to)
    {
      layoutManager.setRenderingAttributes([.foregroundColor: NSColor.systemRed], for: range)
    }
    layoutManager.ensureLayout(for: layoutManager.documentRange)

    var width: CGFloat = 0
    let rep = SnapshotSurface.bitmap(
      size: NSSize(width: 400, height: 40), appearance: nil
    ) { graphics in
      NSColor.white.setFill()
      NSRect(x: 0, y: 0, width: 400, height: 40).fill()
      let context = graphics.cgContext
      context.translateBy(x: 0, y: 40)
      context.scaleBy(x: 1, y: -1)
      layoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) {
        width = max(width, $0.layoutFragmentFrame.width)
        $0.draw(at: .zero, in: context)
        return true
      }
    }
    return (rep, width)
  }

  /// Rendered through the editor's real layout delegate: the emphasised word's pixels change,
  /// the rest of the line's do not, and nothing moves — every advance is what it was.
  @MainActor
  func testEmphasisIsDrawnOnTheWordAndOnlyTheWord() throws {
    let plain = render(emphasis: [])
    // "world" is characters 6..<11 of a 17-character line.
    let bold = render(emphasis: [(NSRange(location: 6, length: 5), .bold)])
    XCTAssertEqual(bold.1, plain.1, accuracy: 0.01, "an advance moved")

    // Where did the pixels change? Expressed as a fraction of the line's width.
    var minX = Int.max
    var maxX = -1
    for y in 0..<plain.0.pixelsHigh {
      for x in 0..<plain.0.pixelsWide
      where plain.0.colorAt(x: x, y: y) != bold.0.colorAt(x: x, y: y) {
        minX = min(minX, x)
        maxX = max(maxX, x)
      }
    }
    XCTAssertLessThan(minX, maxX, "nothing was drawn differently")

    // Heavier, not merely different. "Pixels changed" was the assertion before, and it passed at
    // a stroke a third of a point wide — which read as the plain face, and left the feature
    // looking like it had never been wired up. Compared against the plain render rather than a
    // threshold, so nothing is assumed about the colours either one drew in.
    var darker = 0
    var lighter = 0
    for y in 0..<plain.0.pixelsHigh {
      for x in minX...maxX {
        guard let a = plain.0.colorAt(x: x, y: y), let b = bold.0.colorAt(x: x, y: y) else {
          continue
        }
        if ink(b) > ink(a) + 0.05 { darker += 1 }
        if ink(b) < ink(a) - 0.05 { lighter += 1 }
      }
    }
    XCTAssertGreaterThan(
      darker, lighter * 3,
      "the emphasised word is not visibly heavier (darker \(darker), lighter \(lighter))")

    // And the word kept its colour: the stroke is laid over a red "world", not a black one.
    var sawRed = false
    for y in 0..<bold.0.pixelsHigh {
      for x in minX...maxX {
        guard let c = bold.0.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        // Antialiased over white, a red glyph's pixels come out pink rather than pure red; what
        // tells them from black or grey is red standing well clear of the other two.
        if c.redComponent > 0.7 && c.redComponent - max(c.greenComponent, c.blueComponent) > 0.3 {
          sawRed = true
        }
      }
    }
    XCTAssertTrue(sawRed, "the emphasis draw dropped the rendering colour")
    let scale = CGFloat(plain.0.pixelsWide) / 400
    let advance = plain.1 / 17 * scale
    XCTAssertGreaterThanOrEqual(CGFloat(minX), advance * 6 - advance / 2, "reached into hello")
    XCTAssertLessThanOrEqual(CGFloat(maxX), advance * 11 + advance / 2, "reached into again")
  }

  /// Italic is a shear, so it *moves* ink rather than adding it — which is what tells it apart
  /// from a weight, and what keeps every advance where the layout put it.
  @MainActor
  func testItalicSlantsTheWordWithoutMovingIt() throws {
    let plain = render(emphasis: [])
    let italic = render(emphasis: [(NSRange(location: 6, length: 5), .italic)])
    XCTAssertEqual(italic.1, plain.1, accuracy: 0.01, "an advance moved")

    var darker = 0
    var lighter = 0
    for y in 0..<plain.0.pixelsHigh {
      for x in 0..<plain.0.pixelsWide {
        guard let a = plain.0.colorAt(x: x, y: y), let b = italic.0.colorAt(x: x, y: y) else {
          continue
        }
        if ink(b) > ink(a) + 0.05 { darker += 1 }
        if ink(b) < ink(a) - 0.05 { lighter += 1 }
      }
    }
    XCTAssertGreaterThan(darker, 0, "nothing was slanted")
    XCTAssertGreaterThan(
      lighter, 0, "ink appeared with none leaving — that is a weight, not a slant")
  }
}
