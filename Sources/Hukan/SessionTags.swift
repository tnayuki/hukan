import AppKit

/// A session's tags: `kind: value` strings that label a row on the rail with what it is working
/// on — a ticket, an issue, a pull request. Only the value is drawn; the kind is what colours it,
/// so a row reads as a few short identifiers rather than a line of `JIRA:` prefixes, and the
/// colour still says which tracker each one is from.
///
/// A tag may end in the address of what it names, in angle brackets — `PR: #42 <https://…>` — and
/// then its chip opens that page. It rides in the string rather than beside it, so the tool, the
/// rail's editor, the saved state and the scripting property all stay one string per tag.
///
/// They are view state, the window's like the rail's order: keyed by session id in the restorable
/// state, set by the agent through the hosted tool or by hand from the rail.
enum SessionTags {
  /// A label no row could hold is cut here rather than at the chip, so what is stored, what the
  /// tool answers with and what is drawn are the same string. Sixty is what a title is cut to. The
  /// address is not cut: a shortened one is a different page.
  static let lengthLimit = 60

  /// The list as the session keeps it: trimmed, the empty ones dropped, each one once — in the
  /// order given, since the order a tag was written in is the only order it has.
  static func normalized(_ tags: [String]) -> [String] {
    var seen = Set<String>()
    return tags.compactMap { raw in
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      let (label, address) = parts(of: trimmed)
      guard !label.isEmpty else { return nil }
      let capped = label.count > lengthLimit ? String(label.prefix(lengthLimit)) : label
      let tag = address.map { "\(capped) <\($0)>" } ?? capped
      return seen.insert(tag).inserted ? tag : nil
    }
  }

  /// The tag's label and its address, when it ends in one. Only `http(s)`, the same narrow half of
  /// the scheme table a link in the transcript is held to: a chip must not conjure a tab out of
  /// anything else. A bracketed tail that is not such an address stays part of the label.
  private static func parts(of tag: String) -> (label: String, address: String?) {
    guard tag.hasSuffix(">"), let open = tag.range(of: "<", options: .backwards) else {
      return (tag, nil)
    }
    let address = String(tag[open.upperBound..<tag.index(before: tag.endIndex)])
      .trimmingCharacters(in: .whitespaces)
    guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()),
      url.host != nil
    else { return (tag, nil) }
    return (tag[..<open.lowerBound].trimmingCharacters(in: .whitespaces), address)
  }

  /// The tag without its address — what is split into a kind and a value.
  static func label(of tag: String) -> String { parts(of: tag).label }

  /// The page the tag names, or nil when it names none.
  static func url(of tag: String) -> URL? { parts(of: tag).address.flatMap(URL.init(string:)) }

  /// The order a row draws its tags in: by kind, then by value, so the same kind stands in the
  /// same place on every row and a column of them reads down; a tag with no kind after the rest.
  /// Only the drawing — the list is kept as it was written, by the agent or in the editor, so a
  /// rewrite of it and the text in the editor never disagree with what was stored.
  static func displayOrder(_ tags: [String]) -> [String] {
    tags.enumerated().sorted { a, b in
      let (x, y) = (split(a.element), split(b.element))
      switch (x.kind, y.kind) {
      case (let p?, let q?):
        let kind = p.localizedStandardCompare(q)
        if kind != .orderedSame { return kind == .orderedAscending }
      case (.some, nil): return true
      case (nil, .some): return false
      case (nil, nil): break
      }
      let value = x.value.localizedStandardCompare(y.value)
      return value == .orderedSame ? a.offset < b.offset : value == .orderedAscending
    }.map(\.element)
  }

  /// The kind and the value of one tag. Split at the first colon, so a value may carry colons of
  /// its own; a tag with nothing on one side of it has no kind and is all value.
  static func split(_ tag: String) -> (kind: String?, value: String) {
    let tag = label(of: tag)
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
  /// one is rare enough inside a ticket id, or an address, to give up.
  static func joined(_ tags: [String]) -> String { tags.joined(separator: ", ") }
  static func parse(_ text: String) -> [String] {
    normalized(text.split(separator: ",").map(String.init))
  }
}

/// A session row's line under its title: the branch it stands on, then its tags, in order,
/// wrapping onto as many lines as they need. Laid out by hand rather than by a stack, because the
/// row's height has to be known before the row exists — the rail asks for it to place every row
/// below — and `height` is that same layout, run without the views.
final class TagFlowView: NSView {
  static let spacing = NSSize(width: 4, height: 3)

  private let branch: BranchMark?
  private let chips: [TagChip]
  private var items: [NSView] { (branch.map { [$0] } ?? []) + chips }

  /// `open` is what a chip naming a page does when it is clicked.
  init(tags: [String], branch: BranchMark.Content? = nil, open: ((URL) -> Void)? = nil) {
    self.branch = branch.map(BranchMark.init)
    chips = tags.map { TagChip(tag: $0, open: open) }
    super.init(frame: .zero)
    items.forEach(addSubview)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  /// Where each chip goes in `width`: along a line until the next would not fit, then down a line.
  /// A chip wider than the whole line is cut to it rather than overrunning the row.
  private static func frames(of sizes: [NSSize], width: CGFloat) -> [NSRect] {
    var frames: [NSRect] = []
    var origin = NSPoint.zero
    for size in sizes {
      let chipWidth = min(size.width, max(width, 0))
      if origin.x > 0, origin.x + chipWidth > width {
        origin = NSPoint(x: 0, y: origin.y + size.height + spacing.height)
      }
      frames.append(NSRect(origin: origin, size: NSSize(width: chipWidth, height: size.height)))
      origin.x += chipWidth + spacing.width
    }
    return frames
  }

  /// How tall a line of `tags`, led by `branch`, stands in `width` — what the rail asks before it
  /// has a row to measure.
  static func height(of tags: [String], branch: BranchMark.Content? = nil, width: CGFloat)
    -> CGFloat
  {
    let sizes = (branch.map { [BranchMark.size(of: $0)] } ?? []) + tags.map { TagChip.size(of: $0) }
    return frames(of: sizes, width: width).reduce(0) { max($0, $1.maxY) }
  }

  override func layout() {
    super.layout()
    let frames = Self.frames(of: items.map(\.intrinsicContentSize), width: bounds.width)
    for (item, frame) in zip(items, frames) { item.frame = frame }
  }
}

/// Where a session stands, at the head of the line under its title: the branch glyph and the
/// branch's name — the name rather than the worktree's directory, since git never checks one
/// branch out twice and the branch is what a pull request and the agent both call it. A worktree
/// git no longer lists is drawn struck through, which is the whole of the report that it went: the
/// session goes on, in the main checkout, and the row only has to say where it was.
final class BranchMark: NSView {
  struct Content: Equatable {
    var name: String
    var isGone = false
    /// The checkout's path, for the tooltip — the one place it is said, the row having no room.
    var path: String
  }

  private let content: Content
  private static let font = NSFont.systemFont(ofSize: 11)
  private static let gap: CGFloat = 3
  static let maximumWidth: CGFloat = 150

  private static let glyph: NSImage? = NSImage(
    systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")?
    .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))

  init(_ content: Content) {
    self.content = content
    super.init(frame: .zero)
    toolTip = content.isGone ? "\(content.path) — no longer a worktree" : content.path
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel(
      content.isGone ? "Branch \(content.name), worktree gone" : "Branch \(content.name)")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  private static func attributes(gone: Bool) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    var attributes: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
    ]
    if gone { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    return attributes
  }

  /// The size a mark for `content` takes, without making one.
  static func size(of content: Content) -> NSSize {
    let text = (content.name as NSString).size(withAttributes: attributes(gone: content.isGone))
    let glyphWidth = glyph?.size.width ?? 0
    return NSSize(
      width: min(ceil(glyphWidth + gap + text.width), maximumWidth),
      height: ceil(font.ascender - font.descender) + 2)
  }

  override var intrinsicContentSize: NSSize { Self.size(of: content) }

  override func draw(_ dirtyRect: NSRect) {
    var x: CGFloat = 0
    if let glyph = Self.glyph {
      let tinted = glyph.tinted(.secondaryLabelColor)
      let y = (bounds.height - glyph.size.height) / 2
      tinted.draw(
        in: NSRect(origin: NSPoint(x: 0, y: y), size: glyph.size), from: .zero,
        operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      x = glyph.size.width + Self.gap
    }
    let text = NSRect(x: x, y: 1, width: max(bounds.width - x, 0), height: bounds.height - 1)
    (content.name as NSString).draw(
      with: text, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
      attributes: Self.attributes(gone: content.isGone))
  }
}

extension NSImage {
  /// A template image filled with `color`, for drawing a symbol where no image view tints it.
  fileprivate func tinted(_ color: NSColor) -> NSImage {
    NSImage(size: size, flipped: false) { rect in
      self.draw(in: rect)
      color.set()
      rect.fill(using: .sourceAtop)
      return true
    }
  }
}

/// One tag on a rail row: the value, in its kind's colour over a wash of the same. Drawn rather
/// than set in a label so the wash can sit under the text without a layer, and capped so a single
/// long value cannot take a whole line.
final class TagChip: NSView {
  private let value: String
  private let color: NSColor
  private static let font = NSFont.systemFont(ofSize: 10, weight: .medium)
  private static let inset = NSSize(width: 5, height: 1)
  static let maximumWidth: CGFloat = 140

  /// The whole tag, `kind: value` — named so because `tag` is already `NSView`'s.
  private let fullTag: String
  /// The page the chip opens, and how; nil for a chip that names none, which is only a label.
  let url: URL?
  private let open: ((URL) -> Void)?

  init(tag: String, open: ((URL) -> Void)? = nil) {
    fullTag = tag
    let (kind, value) = SessionTags.split(tag)
    self.value = value
    color = SessionTags.color(forKind: kind)
    url = SessionTags.url(of: tag)
    self.open = open
    super.init(frame: .zero)
    let label = SessionTags.label(of: tag)
    toolTip = url.map { "\(label)\n\($0.absoluteString)" } ?? label
    setAccessibilityElement(true)
    setAccessibilityRole(url == nil ? .staticText : .link)
    setAccessibilityLabel(label)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  private var attributes: [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    return [.font: Self.font, .foregroundColor: color, .paragraphStyle: paragraph]
  }

  /// The size a chip for `tag` takes, without making one.
  static func size(of tag: String) -> NSSize {
    let text = (SessionTags.split(tag).value as NSString).size(withAttributes: [.font: font])
    return NSSize(
      width: min(ceil(text.width) + inset.width * 2, maximumWidth),
      height: ceil(font.ascender - font.descender) + inset.height * 2)
  }

  override var intrinsicContentSize: NSSize { Self.size(of: fullTag) }

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

  // MARK: Opening the page

  /// The rail's outline takes every click for its selection unless the view under it says
  /// otherwise. A chip naming a page says so, so the click opens the page rather than choosing the
  /// row; one naming none leaves the click to the row, which is what it was before chips had pages.
  override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?)
    -> Bool
  {
    url != nil && open != nil
  }

  override func mouseDown(with event: NSEvent) {
    guard url != nil, open != nil else { return super.mouseDown(with: event) }
  }

  /// Opened on the release, and only over the chip — the way a button is, so a press dragged off
  /// it is a press taken back.
  override func mouseUp(with event: NSEvent) {
    guard let url, let open else { return super.mouseUp(with: event) }
    if bounds.contains(convert(event.locationInWindow, from: nil)) { open(url) }
  }

  /// A hand over a chip that opens something, as over a link in the transcript: the arrow the rest
  /// of the row shows would say there is nothing here to press.
  override func resetCursorRects() {
    if url != nil, open != nil { addCursorRect(bounds, cursor: .pointingHand) }
  }

  /// What a click does, for a test or a script that cannot click.
  func performOpen() {
    if let url { open?(url) }
  }
}
