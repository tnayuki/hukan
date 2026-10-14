import AppKit

/// A session's tags: `kind: value` strings that label a row on the rail with what it is working
/// on — a ticket, an issue, a pull request. Only the value is drawn; the kind is what colours it,
/// so a row reads as a few short identifiers rather than a line of `JIRA:` prefixes, and the
/// colour still says which tracker each one is from.
///
/// They are view state, the window's like the rail's order: keyed by session id in the restorable
/// state, set by the agent through the hosted tool or by hand from the rail.
enum SessionTags {
  /// A tag no row could hold is cut here rather than at the chip, so what is stored, what the
  /// tool answers with and what is drawn are the same string. Sixty is what a title is cut to.
  static let lengthLimit = 60

  /// The list as the session keeps it: trimmed, the empty ones dropped, each one once — in the
  /// order given, since the order a tag was written in is the only order it has.
  static func normalized(_ tags: [String]) -> [String] {
    var seen = Set<String>()
    return tags.compactMap { raw in
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      let capped = trimmed.count > lengthLimit ? String(trimmed.prefix(lengthLimit)) : trimmed
      return seen.insert(capped).inserted ? capped : nil
    }
  }

  /// The kind and the value of one tag. Split at the first colon, so a value may carry colons of
  /// its own; a tag with nothing on one side of it has no kind and is all value.
  static func split(_ tag: String) -> (kind: String?, value: String) {
    guard let colon = tag.firstIndex(of: ":") else { return (nil, tag) }
    let kind = tag[..<colon].trimmingCharacters(in: .whitespaces)
    let value = tag[tag.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    guard !kind.isEmpty, !value.isEmpty else { return (nil, tag) }
    return (kind, value)
  }

  /// The colours a kind can land on. System colours, so they follow the appearance; yellow and
  /// red are left out — the one does not read as text on a light row, and the other is what a
  /// failure is drawn in.
  static let palette: [NSColor] = [
    .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal,
    .systemIndigo, .systemBrown,
  ]

  /// Which of `palette` a kind is drawn in — the same one in every window and after every launch,
  /// since the colour is the only place the kind is shown at all. So it is FNV-1a over the
  /// lowercased name rather than `hashValue`, which Swift seeds afresh per process; lowercased so
  /// `JIRA` and `Jira` are one kind. Nil for a tag with no kind, which is drawn grey.
  static func paletteIndex(forKind kind: String?) -> Int? {
    guard let kind else { return nil }
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in kind.lowercased().utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return Int(hash % UInt64(palette.count))
  }

  static func color(forKind kind: String?) -> NSColor {
    paletteIndex(forKind: kind).map { palette[$0] } ?? .secondaryLabelColor
  }

  /// What a person types into the rail's editor, and what it is pre-filled with: the tags on one
  /// line, a comma between. A comma rather than a newline because the field is a single line, and
  /// one is rare enough inside a ticket id to give up.
  static func joined(_ tags: [String]) -> String { tags.joined(separator: ", ") }
  static func parse(_ text: String) -> [String] {
    normalized(text.split(separator: ",").map(String.init))
  }
}

/// One tag on a rail row: the value, in its kind's colour over a wash of the same. Drawn rather
/// than set in a label so the wash can sit under the text without a layer, and capped so a long
/// value gives way before the row's title does.
final class TagChip: NSView {
  private let value: String
  private let color: NSColor
  private static let font = NSFont.systemFont(ofSize: 10, weight: .medium)
  private static let inset = NSSize(width: 5, height: 1)
  static let maximumWidth: CGFloat = 96

  init(tag: String) {
    let (kind, value) = SessionTags.split(tag)
    self.value = value
    color = SessionTags.color(forKind: kind)
    super.init(frame: .zero)
    toolTip = tag
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel(tag)
    setContentHuggingPriority(.required, for: .horizontal)
    // Above the title's, so the title is what truncates first; below required, so a row too narrow
    // for every chip still lays out rather than spilling.
    setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  private var attributes: [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    return [.font: Self.font, .foregroundColor: color, .paragraphStyle: paragraph]
  }

  override var intrinsicContentSize: NSSize {
    let text = (value as NSString).size(withAttributes: attributes)
    return NSSize(
      width: min(ceil(text.width) + Self.inset.width * 2, Self.maximumWidth),
      height: ceil(Self.font.ascender - Self.font.descender) + Self.inset.height * 2)
  }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
    color.withAlphaComponent(0.14).setFill()
    path.fill()
    let text = bounds.insetBy(dx: Self.inset.width, dy: Self.inset.height)
    (value as NSString).draw(
      with: text, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
      attributes: attributes)
  }

  override var isFlipped: Bool { true }
}
