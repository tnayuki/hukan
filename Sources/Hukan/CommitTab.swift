import AppKit

/// One file's section in a commit tab: the row that folds it, and the diff under it once it has
/// been read. Held by reference because the fold is toggled from a click on the text and read
/// back by the builder that draws it.
final class CommitSection {
  let file: Git.CommitFile
  var isOpen = false
  var isLoading = false
  var diff: LoadedFileDiff?

  init(file: Git.CommitFile) { self.file = file }

  /// What opening it is expected to cost, in rows — nil when the commit was too wide for its
  /// lines to be counted, which is exactly the case where nothing should open unasked.
  var estimatedRows: Int? {
    guard let added = file.added, let removed = file.removed else { return nil }
    return added + removed
  }
}

/// One file's diff after loading: the body, already coloured, and the gutter's parallel list.
///
/// Both are built off the main thread. That is the point of the section being the unit of work —
/// what used to happen here was one commit-wide patch built, coloured and laid out in one go, and
/// the laying out is the half that has to be on the main thread.
struct LoadedFileDiff {
  /// One paragraph per row, each ending in its newline.
  var text = NSAttributedString()
  /// One entry per paragraph of `text`.
  var rows: [CommitRow] = []
  /// Why the body is empty, when it is.
  var note: Git.FileDiff.Note?
}

/// Reads one file's diff out of a commit and colours it.
enum CommitDiffLoader {
  static func load(worktree: URL, oid: String, file: Git.CommitFile) -> LoadedFileDiff {
    let wantsSource = SyntaxHighlighting.canHighlight(path: file.path)
    guard
      let diff = Git.fileDiff(
        at: worktree, oid: oid, path: file.path, wantsSource: wantsSource)
    else { return LoadedFileDiff(note: .unreadable) }
    return render(diff, file: file)
  }

  /// The reading and the drawing kept apart, so the look can be pinned from a fixture rather
  /// than from a repository built to have the right commit in it.
  static func render(_ diff: Git.FileDiff, file: Git.CommitFile) -> LoadedFileDiff {
    guard diff.note == nil else { return LoadedFileDiff(note: diff.note) }

    // The colours come from the file, not from the hunk — see `Git.FileDiff.newSource`.
    let new = spansByLine(diff.newSource, path: file.path)
    let old = spansByLine(diff.oldSource, path: file.oldPath ?? file.path)

    var loaded = LoadedFileDiff()
    let body = NSMutableAttributedString()
    loaded.rows.reserveCapacity(diff.rows.count)
    for row in diff.rows {
      switch row {
      case .hunk(let header):
        body.append(
          NSAttributedString(
            string: header + "\n",
            attributes: [
              .font: CommitTheme.font, .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        loaded.rows.append(.hunk)
      case .line(let oldNumber, let newNumber, let kind, let text):
        let removed = kind == .removed
        body.append(
          line(
            text, kind: kind, spans: removed ? old : new, number: removed ? oldNumber : newNumber)
        )
        loaded.rows.append(.code(old: oldNumber, new: newNumber, kind: kind))
      }
    }
    loaded.text = body
    return loaded
  }

  /// One row: the line's own text, banded by which side it is on, coloured by the file's grammar.
  private static func line(
    _ text: String, kind: Git.FileDiff.Kind,
    spans: [[(range: NSRange, color: NSColor)]], number: Int?
  ) -> NSAttributedString {
    var attributes: [NSAttributedString.Key: Any] = [
      .font: CommitTheme.font, .foregroundColor: NSColor.labelColor,
    ]
    if let band = CommitTheme.band(for: kind) { attributes[.diffBand] = band }
    let row = NSMutableAttributedString(string: text + "\n", attributes: attributes)
    guard let number, spans.indices.contains(number - 1) else { return row }
    let length = (text as NSString).length
    for span in spans[number - 1] {
      // Clamped: the file's line carries its newline where the row does not, and a CRLF file
      // hands the diff a line one unit shorter than the blob's.
      let start = min(span.range.location, length)
      let end = min(NSMaxRange(span.range), length)
      guard end > start else { continue }
      row.addAttribute(
        .foregroundColor, value: span.color, range: NSRange(location: start, length: end - start))
    }
    return row
  }

  /// The file's colour spans, cut per line. tree-sitter answers in offsets into the whole file,
  /// and a diff row is one line of it — so every span is split at the line breaks it crosses and
  /// rebased onto the line it lands on, indexed 0-based.
  private static func spansByLine(_ source: String?, path: String)
    -> [[(range: NSRange, color: NSColor)]]
  {
    guard let source, SyntaxHighlighting.canHighlight(path: path) else { return [] }
    let string = source as NSString
    var index = LineIndex()
    index.rebuildIfNeeded(from: string)
    var result = Array(repeating: [(range: NSRange, color: NSColor)](), count: index.count)
    for span in SyntaxHighlighting.spans(in: source, forPath: path) {
      var offset = span.range.location
      let end = min(NSMaxRange(span.range), string.length)
      while offset < end {
        let line = index.line(at: offset)
        let start = index.start(of: line)
        let next = line < index.count ? index.start(of: line + 1) : string.length
        let upper = min(end, next)
        guard upper > offset else { break }
        result[line - 1].append(
          (NSRange(location: offset - start, length: upper - offset), span.color))
        offset = upper
      }
    }
    return result
  }
}

/// A commit's message, at the top of its tab: prose, and prose is the one thing here that wraps.
///
/// That is the point of the tab not being a text document any more. A document has one layout, so
/// the message and the diff had to agree on whether lines wrap — and they do not agree: a commit
/// body is prose and wants the column's width, while a diff line is code and must never be split
/// across two gutter rows.
final class CommitMessageCard: NSView {
  init(detail: Git.CommitDetail) {
    super.init(frame: .zero)
    let summary = NSTextField(wrappingLabelWithString: detail.summary)
    summary.font = .systemFont(ofSize: 15, weight: .semibold)

    let stamp = DateFormatter()
    stamp.dateStyle = .medium
    stamp.timeStyle = .short
    let meta = NSTextField(labelWithString: "\(detail.author) · \(stamp.string(from: detail.date))")
    meta.font = .systemFont(ofSize: 11)
    meta.textColor = .secondaryLabelColor

    var views: [NSView] = [summary]
    if !detail.body.isEmpty {
      let body = NSTextField(wrappingLabelWithString: detail.body)
      body.font = .systemFont(ofSize: 12)
      body.textColor = .secondaryLabelColor
      views.append(body)
    }
    views.append(meta)

    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }
}

/// One file of a commit: a header that folds it, and its diff underneath.
///
/// A card, not a row of text. The header is real views — a status pill, the path with its
/// directory held back, the diffstat — so it can be clicked, laid out and coloured as a header
/// rather than being a line that happens to sit above other lines.
final class CommitFileCard: NSView {
  let index: Int
  private(set) var body: CommitDiffBodyView?

  override var wantsUpdateLayer: Bool { true }

  init(section: CommitSection, index: Int, onToggle: @escaping (Int) -> Void) {
    self.index = index
    super.init(frame: .zero)
    wantsLayer = true

    let header = CardHeader(section: section) { onToggle(index) }
    header.translatesAutoresizingMaskIntoConstraints = false
    addSubview(header)
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: leadingAnchor),
      header.trailingAnchor.constraint(equalTo: trailingAnchor),
      header.topAnchor.constraint(equalTo: topAnchor),
    ])

    guard section.isOpen else {
      header.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
      return
    }

    let rule = NSBox()
    rule.boxType = .custom
    rule.borderWidth = 0
    rule.fillColor = .separatorColor
    rule.translatesAutoresizingMaskIntoConstraints = false

    let content: NSView
    if let diff = section.diff {
      if let note = diff.note {
        content = CommitFileCard.label(Self.describe(note))
      } else {
        let view = CommitDiffBodyView(diff: diff)
        body = view
        content = view
      }
    } else {
      content = CommitFileCard.label("Reading…")
    }
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rule)
    addSubview(content)
    NSLayoutConstraint.activate([
      rule.leadingAnchor.constraint(equalTo: leadingAnchor),
      rule.trailingAnchor.constraint(equalTo: trailingAnchor),
      rule.topAnchor.constraint(equalTo: header.bottomAnchor),
      rule.heightAnchor.constraint(equalToConstant: 1),
      content.leadingAnchor.constraint(equalTo: leadingAnchor),
      content.trailingAnchor.constraint(equalTo: trailingAnchor),
      content.topAnchor.constraint(equalTo: rule.bottomAnchor),
      content.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  /// The slab, drawn rather than filled by a box so it follows the appearance without a second
  /// view in the way. Clipped to its own corners, which is what rounds the header strip inside.
  override func updateLayer() {
    layer?.cornerRadius = 8
    layer?.masksToBounds = true
    layer?.borderWidth = 1
    layer?.backgroundColor = CommitTheme.card.cgColor
    layer?.borderColor = NSColor.separatorColor.cgColor
  }

  /// A card's note — why there is no diff under it. Wrapping rather than truncating, which is
  /// also what keeps it from setting a floor under the whole desk's width: a wrapping label can
  /// be as narrow as the column asks, where a plain one refuses to compress and moves the divider
  /// beside it.
  private static func label(_ text: String) -> NSView {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.isSelectable = false
    let container = NSView()
    label.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
      label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
      label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
      label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
    ])
    return container
  }

  private static func describe(_ note: Git.FileDiff.Note) -> String {
    switch note {
    case .binary:
      return "Binary file — nothing to read here"
    case .tooLarge(let lines, let bytes):
      return "\(lines) lines, \(bytes / 1024) KB — too large to show; read this one in the PR"
    case .unreadable:
      return "This file's diff could not be read"
    }
  }
}

/// A card's header: the whole strip takes the click, because the thing being aimed at is the file,
/// not a chevron the size of a full stop.
private final class CardHeader: NSView {
  private let onClick: () -> Void

  override var wantsUpdateLayer: Bool { true }

  init(section: CommitSection, onClick: @escaping () -> Void) {
    self.onClick = onClick
    super.init(frame: .zero)
    wantsLayer = true
    let file = section.file

    let chevron = NSImageView()
    chevron.image = NSImage(
      systemSymbolName: section.isOpen ? "chevron.down" : "chevron.right",
      accessibilityDescription: nil)
    chevron.contentTintColor = .tertiaryLabelColor
    chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
    chevron.setContentHuggingPriority(.required, for: .horizontal)

    let path = NSTextField(labelWithAttributedString: CardHeader.path(of: file))
    path.lineBreakMode = .byTruncatingMiddle
    path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    var views: [NSView] = [chevron, CardHeader.pill(for: file.status), path]
    if let added = file.added, let removed = file.removed, added + removed > 0 {
      let stat = NSTextField(
        labelWithAttributedString: diffstatText(added: added, removed: removed))
      stat.setContentHuggingPriority(.required, for: .horizontal)
      views.append(stat)
    } else if file.isBinary {
      let binary = NSTextField(labelWithString: "binary")
      binary.font = .systemFont(ofSize: 10)
      binary.textColor = .tertiaryLabelColor
      views.append(binary)
    }

    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 7
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      heightAnchor.constraint(equalToConstant: 30),
    ])
    toolTip = file.oldPath.map { "\(file.path)\nrenamed from \($0)" } ?? file.path
  }

  required init?(coder: NSCoder) { fatalError() }

  override func updateLayer() {
    layer?.backgroundColor = CommitTheme.fileBand.cgColor
  }

  override func mouseDown(with event: NSEvent) { onClick() }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  /// The directory held back so the name reads first, and the name it came from after it when the
  /// file moved.
  private static func path(of file: Git.CommitFile) -> NSAttributedString {
    let text = NSMutableAttributedString()
    let directory = (file.path as NSString).deletingLastPathComponent
    let font = NSFont.systemFont(ofSize: 12)
    if !directory.isEmpty {
      text.append(
        NSAttributedString(
          string: directory + "/",
          attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
    }
    text.append(
      NSAttributedString(
        string: (file.path as NSString).lastPathComponent,
        attributes: [
          .font: NSFont.systemFont(ofSize: 12, weight: .medium),
          .foregroundColor: NSColor.labelColor,
        ]))
    if let oldPath = file.oldPath {
      text.append(
        NSAttributedString(
          string: "  ← " + oldPath,
          attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor,
          ]))
    }
    return text
  }

  /// git's status letter, in git's own vocabulary — a pill rather than a word, because the column
  /// of them is what makes a long file list scannable.
  private static func pill(for status: Git.CommitFile.Status) -> NSView {
    let color = CommitTheme.color(for: status)
    let label = NSTextField(labelWithString: status.rawValue)
    label.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
    label.textColor = color
    label.alignment = .center
    label.wantsLayer = true
    label.drawsBackground = true
    label.backgroundColor = color.withAlphaComponent(0.18)
    label.layer?.cornerRadius = 3
    label.layer?.masksToBounds = true
    label.setContentHuggingPriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
      label.widthAnchor.constraint(equalToConstant: 16),
      label.heightAnchor.constraint(equalToConstant: 15),
    ])
    return label
  }
}

/// The scroll view's document: a plain view holding the stack of cards, top down.
///
/// The stack is not the document view itself. A document view is positioned by the clip view,
/// which ignores the margin a constraint to the clip's edge asks for — so the margin lives in a
/// container that *is* the document, and the stack sits inside it.
final class CommitDocumentView: NSView {
  override var isFlipped: Bool { true }
}

/// One commit, read on the desk: what it says, and a card per file it touched.
///
/// Read-only, and that is the point of it being here rather than in the file pane. The
/// Diff/Source switch was removed from that pane because a coloured diff cannot be edited and the
/// files carrying one are exactly the ones you want to correct — but a commit is finished.
/// Nothing about it can be edited, so the coloured diff is not a mode standing in the way of the
/// text, it *is* the text.
///
/// The file is the unit, not the commit. A card's diff is read, coloured and laid out only once
/// it is open, which is what lets even a 5000-file vendor drop open at once: its file list is
/// free, and nothing under it is built until it is asked for.
final class CommitContentViewController: NSViewController {
  private let hashLabel = NSTextField(labelWithString: "")
  private let totalsLabel = NSTextField(labelWithString: "")
  private let findField = NSSearchField()
  private let matchLabel = NSTextField(labelWithString: "")
  private let scrollView = NSScrollView()
  private let document = CommitDocumentView()
  private let stack = NSStackView()

  private var worktree: Worktree?
  private(set) var oid: String = ""
  private var detail: Git.CommitDetail?
  private var sections: [CommitSection] = []
  private var cards: [CommitFileCard] = []
  /// Bumped on every `show`, so a read that lands after the tab has moved on is dropped.
  private var generation = 0
  private var matches: [(card: Int, range: NSRange)] = []
  private var matchIndex = 0
  private var markedTerm = ""

  /// What the tab strip calls it.
  private(set) var tabTitle: String = ""

  /// One queue for every commit tab: two tabs reading at once would race over the grammar cache
  /// their colouring shares, and neither read is slow enough to want its own.
  private static let queue = DispatchQueue(label: "dev.tnayuki.Hukan.commit", qos: .userInitiated)

  /// How many diff lines open on their own. A commit is usually a handful of files and you came
  /// to read it, not to click it open; past this the rest arrive folded, which is the same rule
  /// that keeps a vendor drop instant.
  private static let openRowBudget = 1500
  /// What ⌘F will open before searching. Larger, because a search that only covered the cards
  /// that happened to be unfolded would be lying about the commit — but still bounded, since
  /// "open everything" on a 5000-file commit is the freeze this tab was rebuilt to avoid.
  private static let findRowBudget = 30_000
  /// How many cards are built at all. A card is real views, so ten thousand of them is a freeze
  /// of its own kind — and a commit that wide is the one CLAUDE.md sends to the PR anyway. What
  /// is left out says so at the foot of the list rather than being quietly dropped.
  private static let fileCardCap = 300

  override func loadView() {
    hashLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    hashLabel.textColor = .secondaryLabelColor
    hashLabel.setContentHuggingPriority(.required, for: .horizontal)
    totalsLabel.font = .systemFont(ofSize: 11)
    totalsLabel.textColor = .secondaryLabelColor
    totalsLabel.lineBreakMode = .byTruncatingTail
    matchLabel.font = .systemFont(ofSize: 10)
    matchLabel.textColor = .tertiaryLabelColor
    matchLabel.setContentHuggingPriority(.required, for: .horizontal)
    // Neither of these may set a floor under the tab's width. A label refusing to compress
    // outranks the split view's holding priorities, so a bar that will not shrink does not get a
    // wider desk — it takes the difference out of the transcript column beside it.
    for label in [totalsLabel, matchLabel] {
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    findField.placeholderString = "Find"
    findField.controlSize = .small
    findField.font = .systemFont(ofSize: 11)
    findField.delegate = self
    findField.target = self
    findField.action = #selector(findReturned)
    findField.sendsWholeSearchString = true
    findField.widthAnchor.constraint(equalToConstant: 150).isActive = true

    let header = HeaderBar(views: [hashLabel, totalsLabel], trailing: [matchLabel, findField])
    header.translatesAutoresizingMaskIntoConstraints = false

    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    scrollView.documentView = document
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(header)
    container.addSubview(scrollView)
    let clip = scrollView.contentView
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      header.topAnchor.constraint(equalTo: container.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      document.topAnchor.constraint(equalTo: clip.topAnchor),
      document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
      document.widthAnchor.constraint(equalTo: clip.widthAnchor),
      stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -14),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -14),
    ])
    view = container
  }

  /// Show `oid` from `worktree`. The message and the file list are read off the main thread; each
  /// file's diff is read the same way, as its card opens.
  func show(worktree: Worktree, oid: String) {
    loadViewIfNeeded()
    self.worktree = worktree
    self.oid = oid
    tabTitle = String(oid.prefix(7))
    hashLabel.stringValue = tabTitle
    totalsLabel.stringValue = "Reading…"
    detail = nil
    sections = []
    cards = []
    clearStack()
    generation += 1
    let generation = self.generation
    let url = worktree.url
    Self.queue.async { [weak self] in
      let detail = Git.commit(at: url, oid: oid)
      DispatchQueue.main.async {
        guard let self, self.generation == generation else { return }
        guard let detail else {
          self.totalsLabel.stringValue = "This commit could not be read"
          return
        }
        self.present(detail, openingUpTo: Self.openRowBudget)
        self.load(self.sections.indices.filter { self.sections[$0].isOpen })
      }
    }
  }

  /// Show a commit that has already been read — what the read above lands on, and the seam the
  /// snapshot draws through.
  func present(_ detail: Git.CommitDetail, openingUpTo budget: Int?) {
    loadViewIfNeeded()
    self.detail = detail
    if sections.count != detail.files.count {
      sections = detail.files.map { CommitSection(file: $0) }
    }
    tabTitle = detail.shortOID
    hashLabel.stringValue = detail.shortOID
    totalsLabel.stringValue = Self.totals(of: detail)
    if let budget { open(upTo: budget) }
    rebuildCards()
  }

  /// Point the tab at sections built by hand — the snapshot's and the tests' way in, so a commit
  /// tab can be drawn without a repository standing behind it.
  func present(_ detail: Git.CommitDetail, sections: [CommitSection]) {
    loadViewIfNeeded()
    self.sections = sections
    present(detail, openingUpTo: nil)
  }

  /// ⌘F: the tab's own find field, not a text view's find bar — the commit is a stack of cards,
  /// so what a search has to cross is more than one text. Every card it can afford opens first,
  /// because a fold is a reading convenience and must not act as a filter on the search.
  /// ⌘G / ⌘⇧G step without taking the focus, and ⌘E takes the term off whatever is selected —
  /// the same tags the other panes read off the menu item.
  func performFind(_ sender: Any?) {
    switch NSFindPanelAction(rawValue: UInt((sender as? NSMenuItem)?.tag ?? 1)) {
    case .next?: runFind(step: 1)
    case .previous?: runFind(step: -1)
    case .setFindString?:
      guard let selection = selectedText, !selection.isEmpty else { return }
      findField.stringValue = selection
      runFind(step: 0)
    default:
      open(upTo: Self.findRowBudget)
      rebuildCards()
      load(sections.indices.filter { sections[$0].isOpen }) { [weak self] in
        guard let self else { return }
        self.view.window?.makeFirstResponder(self.findField)
        if !self.findField.stringValue.isEmpty { self.runFind(step: 0) }
      }
    }
  }

  /// What is selected in whichever card has the focus — a card's diff is a text view, so ⌘E has
  /// something to read even though the tab itself is not one text.
  private var selectedText: String? {
    guard let textView = view.window?.firstResponder as? NSTextView else { return nil }
    return (textView.string as NSString).substring(with: textView.selectedRange())
  }

  /// Fold a file's card, or unfold it — reading its diff first if this is the first time.
  func toggleSection(at index: Int) {
    guard sections.indices.contains(index) else { return }
    sections[index].isOpen.toggle()
    if sections[index].isOpen { load([index]) }
    refresh(index)
  }

  /// One line per card: its number, whether it is open, git's status letter, the path, and how
  /// many rows its diff holds. What an automated check reads, now that the tab has no single text
  /// of its own — see the `commit` verb in the dictionary.
  var report: String {
    var lines = [detail.map { "\($0.shortOID) \($0.summary)" } ?? "reading…"]
    for (index, section) in sections.enumerated() {
      let state = section.isOpen ? (section.diff == nil ? "…" : "▾") : "▸"
      let rows = section.diff?.rows.count ?? 0
      lines.append(
        "\(index + 1) \(state) \(section.file.status.rawValue) \(section.file.path) \(rows) rows")
    }
    return lines.joined(separator: "\n")
  }

  /// What the tab is showing, for the tests that drive it end to end.
  var renderedText: String {
    cards.compactMap { card -> String? in
      guard let body = card.body else { return nil }
      return body.text
    }.joined(separator: "\n")
  }

  /// Open what fits, in file order, and pass over what does not. Stopping at the first file too
  /// big for the budget was the other rule, and it hands you a wall of folded cards whenever the
  /// expensive file happens to sort first — where a card that is skipped still carries its own
  /// diffstat, so it says why it is shut. A file with no counts is never opened unasked: a commit
  /// past `commitFileCap` is exactly the one whose sizes were not measured.
  private func open(upTo budget: Int) {
    var left = budget
    for section in sections where !section.isOpen {
      guard let cost = section.estimatedRows, cost <= left else { continue }
      left -= cost
      section.isOpen = true
    }
  }

  /// Read whichever of `indices` has not been read yet, all in one hop.
  private func load(_ indices: [Int], then: (() -> Void)? = nil) {
    let targets = indices.filter {
      sections.indices.contains($0) && sections[$0].diff == nil && !sections[$0].isLoading
    }
    guard !targets.isEmpty, let url = worktree?.url else {
      then?()
      return
    }
    for index in targets { sections[index].isLoading = true }
    let generation = self.generation
    let oid = self.oid
    let files = targets.map { sections[$0].file }
    Self.queue.async { [weak self] in
      let loaded = files.map { CommitDiffLoader.load(worktree: url, oid: oid, file: $0) }
      DispatchQueue.main.async {
        guard let self, self.generation == generation else { return }
        for (index, diff) in zip(targets, loaded) {
          self.sections[index].isLoading = false
          self.sections[index].diff = diff
          self.refresh(index)
        }
        then?()
      }
    }
  }

  private func rebuildCards() {
    guard let detail else { return }
    clearStack()
    add(CommitMessageCard(detail: detail))
    for index in sections.indices.prefix(Self.fileCardCap) {
      let card = CommitFileCard(section: sections[index], index: index) { [weak self] in
        self?.toggleSection(at: $0)
      }
      cards.append(card)
      add(card)
    }
    if sections.count > Self.fileCardCap {
      let left = sections.count - Self.fileCardCap
      let label = NSTextField(labelWithString: "\(left) more files — read this one in the PR")
      label.font = .systemFont(ofSize: 11)
      label.textColor = .tertiaryLabelColor
      add(label)
    }
  }

  /// One card, rebuilt where it stands: a fold changes nothing above it, so the scroll position
  /// is still the right one and does not have to be restored.
  private func refresh(_ index: Int) {
    guard cards.indices.contains(index) else { return }
    let old = cards[index]
    let position = stack.arrangedSubviews.firstIndex(of: old) ?? index + 1
    let card = CommitFileCard(section: sections[index], index: index) { [weak self] in
      self?.toggleSection(at: $0)
    }
    stack.removeArrangedSubview(old)
    old.removeFromSuperview()
    card.translatesAutoresizingMaskIntoConstraints = false
    stack.insertArrangedSubview(card, at: position)
    card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    cards[index] = card
    if !markedTerm.isEmpty {
      let term = markedTerm
      markedTerm = ""
      findField.stringValue = term
      runFind(step: 0)
    }
  }

  private func add(_ view: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    stack.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
  }

  private func clearStack() {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    cards = []
    matches = []
    markedTerm = ""
    matchLabel.stringValue = ""
  }

  @objc private func findReturned(_ sender: Any?) {
    runFind(step: NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
  }

  /// Run a search, the way typing in the field does — one seam for the tests rather than an
  /// exposed field.
  func find(_ term: String) {
    loadViewIfNeeded()
    findField.stringValue = term
    runFind(step: 0)
  }

  /// How many matches the current search found, and which one it is standing on.
  var findState: (count: Int, index: Int) { (matches.count, matchIndex) }

  /// Mark every occurrence in every open card, and step through them by `step` (0 to stay where
  /// it is — a fresh search, which lands on the first). All of them are marked at once rather
  /// than only the current one, because in a diff the useful question is usually "where else"
  /// rather than "next".
  private func runFind(step: Int) {
    let term = findField.stringValue
    if term != markedTerm {
      markedTerm = term
      matches = []
      for card in cards {
        guard let body = card.body else { continue }
        for range in body.mark(term) { matches.append((card.index, range)) }
      }
      matchIndex = 0
    } else if step != 0, !matches.isEmpty {
      matchIndex = (matchIndex + step + matches.count) % matches.count
    }
    if term.isEmpty {
      matchLabel.stringValue = ""
    } else {
      matchLabel.stringValue =
        matches.isEmpty ? "not found" : "\(matchIndex + 1) of \(matches.count)"
    }
    guard matches.indices.contains(matchIndex) else { return }
    let match = matches[matchIndex]
    guard cards.indices.contains(match.card), let body = cards[match.card].body,
      let rect = body.rect(of: match.range)
    else { return }
    document.scrollToVisible(body.convert(rect, to: document).insetBy(dx: -40, dy: -60))
  }

  private static func totals(of detail: Git.CommitDetail) -> String {
    let count = detail.files.count
    let files = "\(count) file\(count == 1 ? "" : "s") changed"
    guard !detail.countsOmitted else { return files }
    let added = detail.files.compactMap(\.added).reduce(0, +)
    let removed = detail.files.compactMap(\.removed).reduce(0, +)
    return "\(files)  +\(added) −\(removed)"
  }
}

extension CommitContentViewController: NSSearchFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    runFind(step: 0)
  }
}
