import AppKit

extension NSAttributedString.Key {
  /// A paragraph tinted across the full column width, drawn by `BlockBackgroundFragment`.
  /// `.backgroundColor` cannot do this — it stops where the glyphs stop.
  static let blockBackground = NSAttributedString.Key("hukanBlockBackground")
  /// A bar down the left edge of the block.
  static let blockAccent = NSAttributedString.Key("hukanBlockAccent")
  /// Which edges of the block this paragraph is on, for rounding.
  static let blockEdges = NSAttributedString.Key("hukanBlockEdges")
}

/// The payload a foldable tool call carries in the transcript, riding in `Transcript.toolTokenKey`
/// on both of its states: the folded line (see `toolCallLinkRun`) and the opened block
/// (`toolCallExpandedRun`). A click reads it back to build the other state.
public final class ToolCallToken {
  public let name: String
  public let summary: String
  public let full: String
  /// The opened block renders `full` as markdown rather than a monospace code slab — for a tool
  /// whose payload is prose to read (ExitPlanMode's plan), not a command to glance at.
  public let rendersMarkdown: Bool

  public init(name: String, summary: String, full: String, rendersMarkdown: Bool = false) {
    self.name = name
    self.summary = summary
    self.full = full
    self.rendersMarkdown = rendersMarkdown
  }
}

public enum Transcript {
  public static let prose = NSFont.systemFont(ofSize: 14)
  public static let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

  /// How a run of paragraphs is drawn as one slab.
  ///
  /// Every block kind — your messages, code, quotes — goes through here, so they
  /// share one notion of padding and rounding instead of each inventing its own. Spacing is
  /// applied only at the outside of the run: put it on every paragraph and a multi-line block
  /// splits into a stack of separate-looking bands.
  struct BlockStyle {
    var fill: NSColor?
    var accent: NSColor?
    var indent: CGFloat = 10
    /// Extra room kept clear at the trailing edge of every line, beyond the indent — for
    /// something drawn over the block there (a message's `…`) that no line may run under.
    var trailingRoom: CGFloat = 0
    var spacingBefore: CGFloat = 8
    var spacingAfter: CGFloat = 8
    var lineHeight: CGFloat = 1.15
  }

  /// Apply `style` across every paragraph of `text`, in place.
  static func applyBlock(_ style: BlockStyle, to text: NSMutableAttributedString) {
    let string = text.string as NSString
    var ranges: [NSRange] = []
    var location = 0
    while location < string.length {
      let range = string.paragraphRange(for: NSRange(location: location, length: 0))
      ranges.append(range)
      location = NSMaxRange(range)
    }

    for (index, range) in ranges.enumerated() {
      let isFirst = index == 0
      let isLast = index == ranges.count - 1

      let paragraph = NSMutableParagraphStyle()
      paragraph.firstLineHeadIndent = style.indent
      paragraph.headIndent = style.indent
      paragraph.tailIndent = -(style.indent + style.trailingRoom)
      paragraph.lineHeightMultiple = style.lineHeight
      paragraph.paragraphSpacingBefore = isFirst ? style.spacingBefore : 0
      paragraph.paragraphSpacing = isLast ? style.spacingAfter : 0

      var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph]
      if let fill = style.fill { attributes[.blockBackground] = fill }
      if let accent = style.accent { attributes[.blockAccent] = accent }
      var edges: BlockEdges = []
      if isFirst { edges.insert(.top) }
      if isLast { edges.insert(.bottom) }
      attributes[.blockEdges] = edges.rawValue
      text.addAttributes(attributes, range: range)
    }
  }

  /// TextKit has no box model, so a slab's padding and its outside margin both have to be
  /// built out of blank lines.
  ///
  /// The margin cannot come from `paragraphSpacingBefore`: that space lands *inside* the
  /// fragment, so the fill paints over it and the block grows a lopsided gap above its text.
  /// It has to be a separate, untinted paragraph.
  static func spacer(_ points: CGFloat) -> NSAttributedString {
    NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: points)])
  }

  /// Wrap `body` as a tinted slab: inner padding, then the block styling, then the margin.
  static func slab(
    _ body: NSMutableAttributedString, _ style: BlockStyle,
    margin: CGFloat = 7
  ) -> NSAttributedString {
    // Top pad is a blank paragraph before the text — that works because it is followed by the
    // text, so it lays out as its own tinted line. The bottom needs two newlines, not one: a
    // lone appended newline just terminates the last line of text (same paragraph, no band),
    // so the first closes that paragraph and the second is the standalone tinted pad line.
    body.insert(spacer(5), at: 0)
    body.append(spacer(5))
    body.append(spacer(5))

    var inner = style
    inner.spacingBefore = 0
    inner.spacingAfter = 0
    applyBlock(inner, to: body)
    balanceTopPad(body, multiple: style.lineHeight)

    let result = NSMutableAttributedString(attributedString: spacer(margin))
    result.append(body)
    result.append(spacer(margin))
    return result
  }

  /// `lineHeightMultiple` lays its extra half-leading above the first text line and almost none
  /// below the last, so equal top/bottom pads read as a top-heavy block (~3pt at the prose size).
  /// Trim the top pad by that overhang so the text sits centred in the tint. The bottom pad is
  /// left alone: its line already carries the missing space as descent room.
  static func balanceTopPad(_ body: NSMutableAttributedString, multiple: CGFloat) {
    // The first paragraph is the top pad blank line; the text it precedes starts at index 1.
    guard body.length > 1,
      let font = body.attribute(.font, at: 1, effectiveRange: nil) as? NSFont,
      let style = body.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
      let padStyle = style.mutableCopy() as? NSMutableParagraphStyle
    else { return }
    let layout = NSLayoutManager()
    let overhang = layout.defaultLineHeight(for: font) * multiple - (font.ascender - font.descender)
    let padHeight = layout.defaultLineHeight(for: NSFont.systemFont(ofSize: 5)) * multiple
    let target = max(1, padHeight - overhang)
    padStyle.lineHeightMultiple = 0
    padStyle.minimumLineHeight = target
    padStyle.maximumLineHeight = target
    let range = (body.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
    body.addAttribute(.paragraphStyle, value: padStyle, range: range)
  }

  public static func text(_ string: String) -> NSAttributedString {
    NSAttributedString(
      string: string, attributes: [.font: prose, .foregroundColor: NSColor.labelColor])
  }

  // MARK: - Markdown

  /// Agents write markdown, so a transcript that shows it raw is showing `**` and `##` to
  /// the one person who least needs to see them.
  ///
  /// Blocks are handled line by line here rather than through a CommonMark parser. Every one
  /// of them — Foundation's, Apple's swift-markdown, anything on cmark — drops emphasis that
  /// touches CJK punctuation (see `styled`), so adopting a library would trade a fixed bug
  /// for an unfixed one. Tables were the feature worth having from that side, so they are
  /// implemented here instead.
  public static func markdown(_ source: String, base: NSFont = prose) -> NSAttributedString {
    let rendered = NSMutableAttributedString()
    let lines = source.components(separatedBy: "\n")
    var index = 0
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      // Fenced code: gather the whole run first, so the slab is styled as one thing.
      if trimmed.hasPrefix("```") {
        var body: [String] = []
        index += 1
        while index < lines.count,
          !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```")
        {
          body.append(lines[index])
          index += 1
        }
        index += 1  // the closing fence
        rendered.append(codeBlock(body))
        continue
      }
      index += 1

      if let table = Table(lines: lines, start: index - 1) {
        rendered.append(table.rendered(base: base))
        index = table.end
        continue
      }

      // Dropped: every block already carries its own spacing, and turning the blank
      // line between two of them into a real empty paragraph doubles every gap.
      if trimmed.isEmpty { continue }

      // A run of `>` lines is one quote, with a bar down its left edge.
      if trimmed.hasPrefix(">") {
        var body = [String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)]
        while index < lines.count,
          lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">")
        {
          body.append(
            String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst())
              .trimmingCharacters(in: .whitespaces))
          index += 1
        }
        rendered.append(quote(body, base: base))
        continue
      }

      if trimmed == "---" || trimmed == "***" || trimmed == "___" {
        rendered.append(rule())
        continue
      }

      if let heading = headingLevel(of: trimmed) {
        rendered.append(
          self.heading(
            String(trimmed.dropFirst(heading).drop { $0 == " " }), level: heading, base: base))
        continue
      }

      if let bullet = bulletBody(of: trimmed) {
        rendered.append(
          listItem(bullet, marker: "•", indent: line.prefix { $0 == " " }.count, base: base))
        continue
      }
      if let (marker, body) = orderedBody(of: trimmed) {
        rendered.append(
          listItem(body, marker: marker, indent: line.prefix { $0 == " " }.count, base: base))
        continue
      }

      let paragraph = NSMutableAttributedString(attributedString: styled(line, base: base))
      paragraph.append(NSAttributedString(string: "\n", attributes: [.font: base]))
      applyBlock(BlockStyle(indent: 0, spacingBefore: 0, spacingAfter: 6), to: paragraph)
      rendered.append(paragraph)
    }
    return rendered
  }

  // MARK: - Block builders

  private static func codeBlock(_ body: [String]) -> NSAttributedString {
    let text = NSMutableAttributedString()
    for line in body {
      text.append(
        NSAttributedString(
          string: line + "\n",
          attributes: [
            .font: mono, .foregroundColor: NSColor.labelColor,
          ]))
    }
    return slab(text, BlockStyle(fill: .quaternarySystemFill, indent: 12, lineHeight: 1.1))
  }

  private static func quote(_ body: [String], base: NSFont) -> NSAttributedString {
    let text = NSMutableAttributedString()
    for line in body {
      text.append(styled(line, base: base))
      text.append(NSAttributedString(string: "\n", attributes: [.font: base]))
    }
    text.addAttribute(
      .foregroundColor, value: NSColor.secondaryLabelColor,
      range: NSRange(location: 0, length: text.length))
    return slab(
      text,
      BlockStyle(
        fill: .quaternarySystemFill.withAlphaComponent(0.25),
        accent: .controlAccentColor.withAlphaComponent(0.45),
        indent: 16))
  }

  private static func heading(_ body: String, level: Int, base: NSFont) -> NSAttributedString {
    // Two steps only. A six-level scale in a chat transcript just makes noise.
    let size = level <= 2 ? base.pointSize + 3 : base.pointSize + 1
    let text = NSMutableAttributedString(
      attributedString:
        styled(body, base: .systemFont(ofSize: size, weight: .bold)))
    text.append(NSAttributedString(string: "\n", attributes: [.font: base]))
    applyBlock(
      BlockStyle(
        indent: 0, spacingBefore: level <= 2 ? 18 : 14, spacingAfter: 4,
        lineHeight: 1.05), to: text)
    return text
  }

  private static func listItem(_ body: String, marker: String, indent: Int, base: NSFont)
    -> NSAttributedString
  {
    let text = NSMutableAttributedString(
      string: marker + "  ",
      attributes: [
        .font: base, .foregroundColor: NSColor.tertiaryLabelColor,
      ])
    text.append(styled(body, base: base))
    text.append(NSAttributedString(string: "\n", attributes: [.font: base]))

    // Nesting is by leading spaces; two or four per level are both common in the wild.
    let depth = CGFloat(min(indent / 2, 4))
    let paragraph = NSMutableParagraphStyle()
    paragraph.firstLineHeadIndent = 4 + depth * 14
    paragraph.headIndent = 4 + depth * 14 + 16
    paragraph.lineHeightMultiple = 1.15
    paragraph.paragraphSpacing = 3
    text.addAttribute(
      .paragraphStyle, value: paragraph,
      range: NSRange(location: 0, length: text.length))
    return text
  }

  /// A hairline, not a band. The margins have to be their own paragraphs: spacing set on the
  /// filled one lands inside the fragment and gets painted, turning the rule into a slab.
  private static func rule() -> NSAttributedString {
    let line = NSMutableAttributedString(
      string: "\n",
      attributes: [
        .font: NSFont.systemFont(ofSize: 1),
        .blockBackground: NSColor.separatorColor,
        .paragraphStyle: {
          let paragraph = NSMutableParagraphStyle()
          paragraph.lineHeightMultiple = 1
          paragraph.maximumLineHeight = 1
          return paragraph
        }(),
      ])
    let text = NSMutableAttributedString(attributedString: spacer(10))
    text.append(line)
    text.append(spacer(10))
    return text
  }

  private static func orderedBody(of line: String) -> (String, String)? {
    let digits = line.prefix { $0.isNumber }
    guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
    return (digits + ".", String(line.dropFirst(digits.count + 2)))
  }

  /// A GFM pipe table. Drawn as a `TableAttachment` sized to the pane rather than with
  /// NSTextTable: text tables are a TextKit 1 feature whose behaviour under TextKit 2 is not
  /// something to stake the transcript on.
  private struct Table {
    let header: [String]
    let rows: [[String]]
    /// Index just past the table, for the caller's loop.
    let end: Int

    init?(lines: [String], start: Int) {
      guard start + 1 < lines.count,
        let header = Self.cells(lines[start]),
        let divider = Self.cells(lines[start + 1]),
        divider.count == header.count,
        divider.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } && $0.contains("-") })
      else { return nil }

      var rows: [[String]] = []
      var index = start + 2
      while index < lines.count, let row = Self.cells(lines[index]) {
        rows.append(row)
        index += 1
      }
      self.header = header
      self.rows = rows
      self.end = index
    }

    /// A row is `| a | b |`, with the outer pipes optional. Escaped pipes are left alone
    /// rather than split on.
    private static func cells(_ line: String) -> [String]? {
      var trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.contains("|") else { return nil }
      if trimmed.hasPrefix("|") { trimmed.removeFirst() }
      if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
      let parts =
        trimmed
        .replacingOccurrences(of: "\\|", with: "\u{0}")
        .components(separatedBy: "|")
        .map {
          $0.replacingOccurrences(of: "\u{0}", with: "|")
            .trimmingCharacters(in: .whitespaces)
        }
      return parts.count >= 2 ? parts : nil
    }

    func rendered(base: NSFont) -> NSAttributedString {
      // Cells carry inline markup of their own, and the column has to be measured after
      // it is resolved — padding around a raw `**bold**` would be wrong by four cells.
      //
      // Word-wrapping, not the drawing default of char-wrapping: a squeezed column should break
      // `transcript` before the space, not into `transcrip`/`t`. CJK still wraps between glyphs
      // (each is its own break unit), so this only spares Latin words. Baked onto the cell so the
      // height measured in `TableLayout` and the glyphs drawn there break the same way.
      let headerCells = header.map { Self.wrapped(Transcript.styled($0, base: Self.headerFont)) }
      let bodyCells = rows.map { row in row.map { Self.wrapped(Transcript.styled($0, base: mono)) }
      }

      // The table draws itself to the pane's width (see `TableAttachment`) rather than laying out
      // as tab-stopped rows that fall apart once wider than the pane. It rides as an attachment on
      // its own line, with a blank line of breathing room on each side. Its markdown rides along so
      // a copied selection expands back to text (see `TranscriptTextView.writeSelection`).
      let attachment = TableAttachment(
        header: headerCells, rows: bodyCells,
        markdown: Self.markdownSource(header: header, rows: rows))
      let result = NSMutableAttributedString(attributedString: Transcript.spacer(7))
      let line = NSMutableAttributedString(
        attributedString: NSAttributedString(attachment: attachment))
      line.append(NSAttributedString(string: "\n"))
      result.append(line)
      result.append(Transcript.spacer(7))
      return result
    }

    private static let headerFont = NSFont.monospacedSystemFont(
      ofSize: mono.pointSize, weight: .semibold)

    /// The table rebuilt as a GFM pipe table from its raw cells (markup and all), so a copied
    /// selection pastes the source the agent wrote. Literal pipes in a cell are re-escaped, the
    /// inverse of the `cells` parser that unescaped them.
    private static func markdownSource(header: [String], rows: [[String]]) -> String {
      func line(_ cells: [String]) -> String {
        "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ")
          + " |"
      }
      var lines = [line(header), line(Array(repeating: "---", count: header.count))]
      lines.append(contentsOf: rows.map(line))
      return lines.joined(separator: "\n")
    }

    /// A copy of the cell that wraps at word boundaries rather than mid-glyph.
    private static func wrapped(_ cell: NSAttributedString) -> NSAttributedString {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byWordWrapping
      let result = NSMutableAttributedString(attributedString: cell)
      result.addAttribute(
        .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
      return result
    }
  }

  private struct InlineStyle {
    var bold = false
    var italic = false
    var strikethrough = false
    var link: URL?
  }

  /// Inline markup — bold, italic, inline code, strikethrough, links — on top of `base`.
  ///
  /// Hand-rolled rather than handed to `AttributedString(markdown:)`, which follows
  /// CommonMark's flanking rules to the letter: a `**` next to punctuation only opens
  /// emphasis if it is also next to whitespace. Japanese hits that constantly, because
  /// emphasis lands on quoted or bracketed phrases — `**「…」**` and `**（…）**` both come
  /// back as literal asterisks. Delimiters are simply paired here, which is what a
  /// transcript wants.
  fileprivate static func styled(_ line: String, base: NSFont) -> NSAttributedString {
    let result = NSMutableAttributedString()
    render(Substring(line), base: base, style: InlineStyle(), into: result)
    return result
  }

  private static func render(
    _ text: Substring, base: NSFont,
    style: InlineStyle, into result: NSMutableAttributedString
  ) {
    var plain = ""
    var index = text.startIndex

    func flush() {
      guard !plain.isEmpty else { return }
      result.append(attributed(plain, base: base, style: style))
      plain = ""
    }

    /// The next occurrence of `marker` that could close a span opened here.
    func close(_ marker: String, from start: String.Index) -> Range<String.Index>? {
      text.range(of: marker, range: start..<text.endIndex)
    }

    while index < text.endIndex {
      let rest = text[index...]

      if rest.hasPrefix("\\"), text.index(after: index) < text.endIndex {
        let escaped = text.index(after: index)
        plain.append(text[escaped])
        index = text.index(after: escaped)
        continue
      }

      // Code spans win: nothing inside them is markup.
      if rest.hasPrefix("`") {
        let start = text.index(after: index)
        if let end = close("`", from: start) {
          flush()
          result.append(
            NSAttributedString(
              string: String(text[start..<end.lowerBound]),
              attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular),
                .foregroundColor: NSColor.systemTeal,
              ]))
          index = end.upperBound
          continue
        }
      }

      // Longest marker first, so `**` is never mistaken for the start of `*`.
      if let marker = ["**", "~~", "*", "_"].first(where: { rest.hasPrefix($0) }) {
        let start = text.index(index, offsetBy: marker.count)
        if let end = close(marker, from: start), start < end.lowerBound {
          flush()
          var inner = style
          switch marker {
          case "**": inner.bold = true
          case "~~": inner.strikethrough = true
          default: inner.italic = true
          }
          render(text[start..<end.lowerBound], base: base, style: inner, into: result)
          index = end.upperBound
          continue
        }
      }

      // A bare URL is a link too, and until now it was not: markdown syntax is what an agent
      // writes least — `gh pr create` answers with a naked URL, and so does the sentence that
      // reports it — so the most valuable address in the transcript was plain black text.
      //
      // The rule stays narrow so it stays explicable: an explicit `http(s)://`, running to the
      // first space, with trailing sentence punctuation handed back. No `www.`-style guessing,
      // which is what would start turning `foo.bar` inside a snippet blue. Code spans return
      // above this and fenced blocks never reach `styled` at all, so neither can be touched.
      if style.link == nil, rest.hasPrefix("http://") || rest.hasPrefix("https://") {
        let end = autolinkEnd(of: rest)
        if end > rest.startIndex, let url = URL(string: String(rest[rest.startIndex..<end])) {
          flush()
          var inner = style
          inner.link = url
          // Appended, not recursed: a URL is full of the characters this walker treats as
          // markup — `_` most of all — and its text is not markdown.
          result.append(attributed(String(rest[rest.startIndex..<end]), base: base, style: inner))
          index = end
          continue
        }
      }

      if rest.hasPrefix("["),
        let labelEnd = close("](", from: text.index(after: index)),
        let urlEnd = close(")", from: labelEnd.upperBound)
      {
        flush()
        var inner = style
        inner.link = URL(string: String(text[labelEnd.upperBound..<urlEnd.lowerBound]))
        render(
          text[text.index(after: index)..<labelEnd.lowerBound],
          base: base, style: inner, into: result)
        index = urlEnd.upperBound
        continue
      }

      plain.append(text[index])
      index = text.index(after: index)
    }
    flush()
  }

  /// Where an autolinked URL stops: the first space, less the punctuation that belongs to the
  /// sentence rather than the address. A closing bracket is given back only when it closes
  /// nothing inside the URL, so `(https://example.com/a_(b))` keeps its inner pair and loses the
  /// outer one.
  private static func autolinkEnd(of text: Substring) -> Substring.Index {
    var end = text.firstIndex(where: { $0.isWhitespace }) ?? text.endIndex
    let trailing = Set(".,;:!?'\"\u{201d}\u{2019}\u{3001}\u{3002}\u{ff0c}\u{ff0e}")
    while end > text.startIndex {
      let last = text.index(before: end)
      let character = text[last]
      if trailing.contains(character) {
        end = last
        continue
      }
      if character == ")" || character == "]" {
        let opening: Character = character == ")" ? "(" : "["
        let inside = text[text.startIndex..<end]
        if inside.filter({ $0 == character }).count > inside.filter({ $0 == opening }).count {
          end = last
          continue
        }
      }
      break
    }
    return end
  }

  private static func attributed(_ string: String, base: NSFont, style: InlineStyle)
    -> NSAttributedString
  {
    var font =
      style.bold
      ? NSFont.systemFont(ofSize: base.pointSize, weight: .bold)
      : base
    if style.italic, let italic = italicized(font) { font = italic }

    var attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: style.link == nil ? NSColor.labelColor : NSColor.linkColor,
    ]
    if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    if let link = style.link { attributes[.link] = link }
    return NSAttributedString(string: string, attributes: attributes)
  }

  private static func italicized(_ font: NSFont) -> NSFont? {
    NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
  }

  /// `#` through `######`, and only when followed by a space — `#1` is not a heading.
  private static func headingLevel(of line: String) -> Int? {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
    return hashes
  }

  private static func bulletBody(of line: String) -> String? {
    for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
      return String(line.dropFirst(marker.count))
    }
    return nil
  }

  /// Tools hukan answers with a card of its own — the agent's question, the agent's task list —
  /// so a transcript line for the call would only repeat what is already on screen. The task
  /// tools are the sharper case: `TaskUpdate` is a status and an id, which says nothing at all
  /// without the list beside it, and `TaskCreate`'s subject is a row of that list already.
  /// `TaskStop` and `TaskOutput` only share the prefix — they drive background tasks, and are
  /// ordinary calls with an ordinary line.
  ///
  /// The live path skips the block outright; this is what keeps a conversation *replayed* from
  /// disk reading the way it did while it ran.
  public static func hasOwnCard(tool name: String) -> Bool {
    name == "AskUserQuestion" || name == "TaskCreate" || name == "TaskUpdate"
  }

  public static func toolUse(name: String, input: [String: Any]) -> NSAttributedString {
    // Nothing at all for a call that has a card — and nothing rather than a filter in `render`,
    // so the time separators land in exactly the same places whether a conversation is rendered
    // whole or in slices (see `render`).
    if hasOwnCard(tool: name) { return NSAttributedString() }
    // ExitPlanMode's payload is a plan to read, not a command to glance at, so it renders as
    // markdown under a "Here is Claude's plan:" header — no mechanical tool name (matching the
    // Claude Code CLI and Unterm). A long plan shows its first lines and folds the rest.
    if name == "ExitPlanMode",
      let plan = (input["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !plan.isEmpty
    {
      return planBlock(plan)
    }
    let argument = toolArgument(tool: name, input: input)

    // Something to hide — a multi-line command, or a single line clipped in its summary — folds
    // behind a disclosure. Folded is the default, and folded is plain text: a clickable line
    // carrying the payload, no view attachment until it is opened (see `toolCallLinkRun` and the
    // transcript view's delegate). A short call has nothing to reveal, so it is the same shape
    // without the click.
    // Both forms get the same top and bottom breathing room, so a tool call sits apart from the
    // prose around it and from the next call instead of crowding against them.
    let result = NSMutableAttributedString(attributedString: spacer(7))
    if let argument, argument.full != argument.summary {
      let token = ToolCallToken(name: name, summary: argument.summary, full: argument.full)
      result.append(toolCallLinkRun(token))
    } else {
      result.append(
        NSAttributedString(
          string: name, attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]))
      result.append(
        NSAttributedString(
          string: "  " + (argument?.summary ?? ""),
          attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor]))
    }
    result.append(NSAttributedString(string: "\n", attributes: [.font: mono]))
    result.append(spacer(3))
    return result
  }

  /// The custom attribute both fold states carry, so a click can recover the call's payload.
  public static let toolTokenKey = NSAttributedString.Key("hukan.toolCallToken")
  /// Present across an opened tool call's whole extent, so a click on its header can find how
  /// far the block runs and fold all of it back into the one-line form.
  public static let toolExpandedKey = NSAttributedString.Key("hukan.toolCallExpanded")

  /// The folded tool call as one clickable transcript line: a `▸` disclosure, the tool name, and
  /// the clipped summary — no trailing newline, since the caller (or a collapse) places it.
  /// The payload rides in `toolTokenKey`; a `.link` gives the run link-click behaviour and the
  /// hand cursor (its value is unused — the delegate reads the token). `linkTextAttributes` on the
  /// text view is emptied so the link keeps these colours instead of turning blue and underlined.
  static func toolCallLinkRun(_ token: ToolCallToken) -> NSAttributedString {
    if token.rendersMarkdown { return planFoldedRun(token) }
    let line = NSMutableAttributedString(
      string: "▸ \(token.name)",
      attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor])
    line.append(
      NSAttributedString(
        string: "  " + token.summary,
        attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor]))
    line.addAttributes(
      [.link: toolCallLinkURL, toolTokenKey: token],
      range: NSRange(location: 0, length: line.length))
    return line
  }

  /// The opened tool call, and it is all text: a `▾` header line that folds it back on click,
  /// then the full command as a code-block slab. Deliberately not a view attachment — macOS's
  /// NSTextView asks an attachment for its view provider and then never loads the provider's
  /// view (measured live: providerRequests grew, viewLoads stayed 0 forever), so a view-based
  /// block reserves its box but can neither draw nor take a click. Text draws everywhere, the
  /// body is selectable for free, and the header click is a link like the folded line's.
  static func toolCallExpandedRun(_ token: ToolCallToken) -> NSAttributedString {
    if token.rendersMarkdown { return planExpandedRun(token) }
    let result = NSMutableAttributedString(
      string: "▾ \(token.name)",
      attributes: [
        .font: mono, .foregroundColor: NSColor.secondaryLabelColor,
        .link: toolCallLinkURL,
      ])
    result.append(NSAttributedString(string: "\n", attributes: [.font: mono]))
    result.append(codeBlock(token.full.components(separatedBy: "\n")))
    result.addAttributes(
      [toolTokenKey: token, toolExpandedKey: true],
      range: NSRange(location: 0, length: result.length))
    return result
  }

  public static let toolCallLinkURL = URL(string: "hukan:toolcall")!

  // MARK: ExitPlanMode

  /// The plan header, borrowed from the Claude Code CLI's own phrasing. No mechanical tool name.
  public static let planHeaderText = "Here is Claude's plan:"

  /// A plan in the transcript is a compact, foldable record: just the header, folded, so it does
  /// not dominate the log. The plan you read to *decide* is the scrollable box in the approval
  /// card (`PlanBox`); this keeps it reachable afterwards — open it to read the whole plan back.
  static func planBlock(_ plan: String) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: spacer(7))
    result.append(
      planFoldedRun(
        ToolCallToken(
          name: "ExitPlanMode", summary: "", full: plan, rendersMarkdown: true)))
    result.append(NSAttributedString(string: "\n", attributes: [.font: mono]))
    result.append(spacer(3))
    return result
  }

  /// The folded plan: just the `▸ Here is Claude's plan:` header, a toggle link carrying the token
  /// so a click opens the whole plan (see `planExpandedRun`).
  static func planFoldedRun(_ token: ToolCallToken) -> NSAttributedString {
    let result = NSMutableAttributedString(
      string: "▸ " + planHeaderText,
      attributes: [
        .font: prose, .foregroundColor: NSColor.secondaryLabelColor, .link: toolCallLinkURL,
      ])
    result.addAttributes([toolTokenKey: token], range: NSRange(location: 0, length: result.length))
    return result
  }

  /// The opened plan: a `▾` header that folds it back on click, then the whole plan as markdown.
  static func planExpandedRun(_ token: ToolCallToken) -> NSAttributedString {
    let result = NSMutableAttributedString(
      string: "▾ " + planHeaderText + "\n",
      attributes: [
        .font: prose, .foregroundColor: NSColor.secondaryLabelColor, .link: toolCallLinkURL,
      ])
    result.append(markdown(token.full))
    result.addAttributes(
      [toolTokenKey: token, toolExpandedKey: true],
      range: NSRange(location: 0, length: result.length))
    return result
  }

  /// What you said, set apart from what the agent said.
  ///
  /// Scrolling back through a long transcript, the one thing being looked for is usually
  /// "where did I last ask for something", so this gets a tint and an indent rather than
  /// just a heavier font. The `>` stays because the transcript is also read as plain text
  /// through AppleScript, where the tint does not exist.
  ///
  /// Rendered as markdown too: people type backticks and bold, and showing them raw here
  /// while formatting the reply reads like a bug.
  /// `forkAnchor` is the transcript record this message follows — carried as an attribute over
  /// the whole block so the mark's menu can offer to rewind here and branch, without the view
  /// having to know anything about sessions. Nil leaves the block unmarked: the first message of
  /// a conversation has nothing before it to fork from.
  public static func userMessage(
    _ string: String, imagePaths: [String] = [], forkAnchor: String? = nil
  ) -> NSAttributedString {
    let base = NSFont.systemFont(ofSize: 14, weight: .medium)
    let result = NSMutableAttributedString(attributedString: markdown(string, base: base))

    // markdown() terminates every line, and a tinted trailing newline draws as a stray
    // band below the text. Style the body, then close the paragraph outside it.
    if result.string.hasSuffix("\n") {
      result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
    }

    // Show what you attached, not just its filename — a thumbnail of each image under the text,
    // so a message that was mostly a screenshot reads as one.
    for path in imagePaths {
      guard let image = NSImage(contentsOfFile: path) else { continue }
      if result.length > 0 {
        result.append(NSAttributedString(string: "\n", attributes: [.font: base]))
      }
      result.append(imageThumbnail(image))
    }

    // A marked message keeps its trailing edge clear on every line, not just the last: the mark
    // sits at the block's vertical centre, so any line could be the one beside it.
    let block = NSMutableAttributedString(
      attributedString: slab(
        result,
        BlockStyle(
          fill: .controlAccentColor.withAlphaComponent(0.14),
          accent: .controlAccentColor.withAlphaComponent(0.7),
          indent: 14, trailingRoom: forkAnchor == nil ? 0 : messageMarkWidth), margin: 10))
    if let forkAnchor {
      block.addAttribute(
        forkAnchorKey, value: forkAnchor, range: NSRange(location: 0, length: block.length))
    }
    return block
  }

  /// The room a message's `…` takes at the block's trailing edge, on every line: the dots, a gap
  /// so no word touches them, and the block's own text indent on their far side (the view draws
  /// the mark that far in, so it lines up with where the text stops rather than with the fill).
  /// The mark is the message's own menu and it is drawn, never typed — as text it would either sit
  /// inline, wrapping wherever the line happened to end, or take a line of its own to reach the
  /// edge, and it would be copied out with the message, which is furniture no one said. See
  /// `TranscriptTextView.drawMessageMarks`.
  public static let messageMarkWidth: CGFloat = 30

  /// The uuid a fork started from this block would truncate at. Present across the whole of a
  /// user message that has a conversation before it — see `userMessage(_:imagePaths:forkAnchor:)`.
  public static let forkAnchorKey = NSAttributedString.Key("hukan.forkAnchor")

  /// Every place in a transcript a fork could be taken, in the order they were said. One entry
  /// per user message that has a conversation above it; `range.location` is where that message
  /// begins, which is how much of the transcript a branch taken there inherits.
  public static func forkPoints(in storage: NSAttributedString) -> [(
    anchor: String, range: NSRange
  )] {
    var points: [(anchor: String, range: NSRange)] = []
    storage.enumerateAttribute(
      forkAnchorKey, in: NSRange(location: 0, length: storage.length)
    ) { value, range, _ in
      guard let anchor = value as? String else { return }
      points.append((anchor, range))
    }
    return points
  }

  /// The fork anchor under a character offset, and how far the block it marks runs. Nil where the
  /// transcript carries no anchor — anywhere outside a user message, and on the first one.
  public static func forkAnchor(in storage: NSAttributedString, at index: Int) -> (
    anchor: String, range: NSRange
  )? {
    guard index >= 0, index < storage.length else { return nil }
    var range = NSRange(location: 0, length: 0)
    guard
      let anchor = storage.attribute(
        forkAnchorKey, at: index, longestEffectiveRange: &range,
        in: NSRange(location: 0, length: storage.length)) as? String
    else { return nil }
    return (anchor, range)
  }

  private static func imageThumbnail(_ image: NSImage) -> NSAttributedString {
    let maxSide: CGFloat = 180
    let scale = min(1, maxSide / max(image.size.width, image.size.height, 1))
    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = CGRect(
      x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
    return NSAttributedString(attachment: attachment)
  }

  // MARK: - Time separators

  /// A lull this long earns a timestamp. Same rule as Unity-Unterm: the first block always
  /// gets one so the top says when the conversation started, and after that they appear only
  /// where the conversation actually paused — chat-app style, never per line.
  public static let timeGap: TimeInterval = 5 * 60

  /// Unterm shows these as "12 minutes ago" and repaints once a minute to keep them true.
  /// This transcript is a memoized attributed string that is never re-rendered, so a
  /// relative label would silently go stale. An absolute clock time cannot.
  public static func timeSeparator(_ date: Date) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.paragraphSpacingBefore = 16
    paragraph.paragraphSpacing = 4
    return NSAttributedString(
      string: stampLabel(date) + "\n",
      attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor.tertiaryLabelColor,
        .paragraphStyle: paragraph,
      ])
  }

  private static func stampLabel(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
      ? timeOnly.string(from: date)
      : dateAndTime.string(from: date)
  }

  private static let timeOnly: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("jmm")
    return formatter
  }()

  private static let dateAndTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
    return formatter
  }()

  public static func note(_ string: String) -> NSAttributedString {
    NSAttributedString(
      string: string + "\n",
      attributes: [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.tertiaryLabelColor,
      ])
  }

  public static func error(_ string: String) -> NSAttributedString {
    NSAttributedString(
      string: string + "\n",
      attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemRed])
  }

  /// The one argument worth showing for a tool call. Printing every argument is unreadable;
  /// printing none leaves you unable to tell what the tool did. `summary` is the first line,
  /// clipped — for anywhere that must stay on one line — and `full` is the untouched value, so
  /// the transcript can spell a multi-line command out instead of hiding it (see `toolUse`).
  static func toolArgument(tool name: String, input: [String: Any]) -> (
    summary: String, full: String
  )? {
    for key in [
      "file_path", "path", "pattern", "command", "url", "query", "prompt", "description", "plan",
    ] {
      if let value = input[key] as? String {
        var single = value.split(separator: "\n").first.map(String.init) ?? value
        // A plan's first line is usually a markdown heading; drop the leading `#`s so the
        // folded summary and the approval card read as a title, not "## title".
        if key == "plan" {
          single = String(single.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        }
        let summary = single.count > 90 ? String(single.prefix(90)) + "…" : single
        return (summary, value)
      }
    }
    return nil
  }

  /// The single-line form, for the approval card where compactness is the whole point.
  public static func summarize(tool name: String, input: [String: Any]) -> String {
    toolArgument(tool: name, input: input)?.summary ?? ""
  }
}
