import AppKit

/// Completing a slash command in the composer.
///
/// The list is the engine's own — its built-ins beside every skill and user command it found —
/// so nothing here knows what commands exist. What this owns is the two things the engine cannot
/// answer: which of them match what has been typed, and the panel that shows them.
enum CommandCompletion {
  /// hukan runs `/login` and `/logout` itself — they need a real TTY for their browser flow and
  /// cannot go over stream-json (see `AgentSession.onLoginRequested`) — so the engine, which is
  /// only asked about commands it would run, never lists them. They are the one place a command
  /// is named in hukan's own source, and that is the reason.
  static let intercepted = [
    ClaudeCommand(
      name: "login", description: "Sign in to Claude, in a terminal", argumentHint: "",
      aliases: []),
    ClaudeCommand(
      name: "logout", description: "Sign out of Claude, in a terminal", argumentHint: "",
      aliases: []),
  ]

  /// The text being completed, when the composer holds one. A slash command is the whole message
  /// or it is nothing: `/` opens the field and the name runs to the first space, after which what
  /// is being typed is the argument and the list has nothing left to say. A `/` anywhere but the
  /// start is a path, which is why only the first character opens this at all.
  static func query(in text: String) -> String? {
    guard text.hasPrefix("/") else { return nil }
    let rest = text.dropFirst()
    guard !rest.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
    return String(rest)
  }

  /// The commands `query` names, best first.
  ///
  /// Plain substring, ASCII case-folded — the same rule the files panel matches paths by, so what
  /// matched is always explicable. What is typed at a completion list is nearly always the start
  /// of a name, though, so a prefix match sorts above a match found in the middle; within each
  /// group the engine's own order stands, which puts skills before built-ins. An alias matches
  /// but is never listed on its own: `/cost` finds `usage`, and one row says `usage`.
  static func matches(_ query: String, in commands: [ClaudeCommand]) -> [ClaudeCommand] {
    let needle = folded(query)
    var prefixed: [ClaudeCommand] = []
    var contained: [ClaudeCommand] = []
    for command in commands where command.isTypeable {
      let names = [command.name] + command.aliases
      let folded = names.map(Self.folded)
      if folded.contains(where: { $0.hasPrefix(needle) }) {
        prefixed.append(command)
      } else if needle.isEmpty || folded.contains(where: { $0.contains(needle) }) {
        contained.append(command)
      }
    }
    return prefixed + contained
  }

  /// ASCII case folding, the rule `FileSearch` settled on: Foundation's `.caseInsensitive` was
  /// most of what made a whole-worktree scan take ten seconds, and one rule across the app is
  /// worth more than the accented Latin it gives up. A command name is ASCII anyway.
  private static func folded(_ text: String) -> String {
    String(text.map { $0.isASCII ? Character($0.lowercased()) : $0 })
  }

  /// What replaces the composer's text when a row is taken. The trailing space is only for a
  /// command that takes an argument — it is where the caret should already be — while one that
  /// takes none is complete as it stands and a space would only have to be deleted.
  static func completion(for command: ClaudeCommand) -> String {
    command.argumentHint.isEmpty ? "/\(command.name)" : "/\(command.name) "
  }
}

/// What a row of the composer's completion list stands for.
///
/// Two kinds share one panel because they are one gesture: the field is completing what the whole
/// message is going to be, and whether that came from the engine's command list or from what this
/// person has typed before is not a distinction the person completing it is making. Which of the
/// two is offered is decided by the text — a leading `/` is a command, ASCII is a reading — so the
/// panel never holds both at once.
enum CompletionItem {
  case command(ClaudeCommand)
  /// A past prompt, matched by its reading. See `PromptCompletion`.
  case prompt(String)

  var isPrompt: Bool {
    if case .prompt = self { return true }
    return false
  }
}

/// The keys a completion list takes before the composer sees them.
enum CompletionKey {
  case up
  case down
  /// Return. It takes the selected row and only a selected row: a prompt list opens with none,
  /// and there Return is the composer's own send, exactly as it is with no list on screen.
  case accept
  /// Tab. It takes the selected row, or the best one when nothing is selected — Tab has no other
  /// meaning while a list is open, which is what keeps completing to one key after Return gave
  /// its meaning back to sending.
  case complete
  case dismiss
}

/// The floating list above the composer. A panel rather than a view in the column: it has to
/// stand over the transcript, and the composer's own box clips.
final class CommandCompletionPanel: NSPanel {
  /// A row was taken, by click or by Return.
  var onPick: ((CompletionItem) -> Void)?

  private let table = NSTableView()
  private let scroll = NSScrollView()
  private var items: [CompletionItem] = []
  /// A command's row is a name over a description; a prompt's is the line itself. So the height
  /// is the list's, set when it is presented, rather than one number both kinds live with — at a
  /// command's height a prompt floats in the middle of its row, and at a prompt's a description
  /// has nowhere to go.
  private static let commandRowHeight: CGFloat = 34
  private static let promptRowHeight: CGFloat = 24
  /// Enough rows to read as a list rather than a peephole, few enough to leave the conversation
  /// visible behind it. Past this the list scrolls.
  private static let visibleRows = 8

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    isFloatingPanel = true
    level = .popUpMenu
    hasShadow = true
    backgroundColor = .clear
    isOpaque = false
    // The composer keeps focus the whole time: this is a list being steered by the field's own
    // arrow keys, not somewhere the caret goes.
    ignoresMouseEvents = false

    let container = NSVisualEffectView()
    container.material = .menu
    container.blendingMode = .behindWindow
    container.state = .active
    container.wantsLayer = true
    container.layer?.cornerRadius = 8
    container.layer?.masksToBounds = true

    table.headerView = nil
    table.rowHeight = Self.commandRowHeight
    table.backgroundColor = .clear
    table.selectionHighlightStyle = .regular
    table.style = .plain
    table.intercellSpacing = NSSize(width: 0, height: 0)
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command")))
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(rowClicked)

    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.automaticallyAdjustsContentInsets = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(scroll)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
      scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
      scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
    ])
    contentView = container
  }

  /// Never key: the composer must keep the caret and the typing, or the list would be a place
  /// you fall into rather than something you steer.
  override var canBecomeKey: Bool { false }

  var selected: CompletionItem? {
    let row = table.selectedRow
    return items.indices.contains(row) ? items[row] : nil
  }

  /// The best match, whether or not the selection is on it: the bottom row, the list reading
  /// bottom-up. What Tab takes when nothing has been aimed at yet.
  var best: CompletionItem? { items.last }

  /// Show `items` under `anchor` (the composer, in its window's coordinates). Hides itself when
  /// there is nothing to show, so the caller can hand over an empty list rather than having to
  /// decide twice.
  ///
  /// **The list reads bottom-up**: the caller hands over its best match first and the panel puts
  /// that on the row nearest the field, with the rest running away upwards. The panel stands over
  /// the transcript because the composer is at the foot of the column and there is nothing under
  /// it but the screen edge — so the row the caret is closest to is the bottom one, and a list
  /// ranked from the top puts its best answer as far from the caret as the list is long. That is
  /// also where an arrow enters it, which leaves the two reading as they look: up walks back
  /// through the ranking, and the best match is one key away rather than eight.
  ///
  /// **A command list opens on its best row; a prompt list opens on none.** A command is asked
  /// for — `/` is typed, and while it stands there Return can mean nothing but "take a row" — so
  /// selecting the best one costs nothing and saves a keystroke. A prompt list opens by itself,
  /// over ordinary text, where Return already means send; a row selected before anything was
  /// aimed at it turns that send into a prompt nobody chose, which is the one mistake a list
  /// offered unasked must not be able to cause. So it opens beside the message rather than in
  /// front of it, and an arrow — or Tab, which takes the best row outright — is what enters it.
  func present(_ items: [CompletionItem], below anchor: NSView) {
    guard !items.isEmpty, let host = anchor.window else {
      dismiss()
      return
    }
    self.items = items.reversed()
    let unasked = items.contains(where: \.isPrompt)
    table.rowHeight = unasked ? Self.promptRowHeight : Self.commandRowHeight
    table.reloadData()
    let best = self.items.count - 1
    if unasked {
      table.deselectAll(nil)
    } else {
      table.selectRowIndexes(IndexSet(integer: best), byExtendingSelection: false)
    }
    table.scrollRowToVisible(best)

    let rows = min(items.count, Self.visibleRows)
    let frame = anchor.convert(anchor.bounds, to: nil)
    let origin = host.convertPoint(toScreen: frame.origin)
    let size = NSSize(width: max(frame.width, 320), height: CGFloat(rows) * table.rowHeight + 8)
    // Above the field, not below it: the composer sits at the foot of the column, so there is
    // nothing under it but the screen edge.
    setFrame(
      NSRect(x: origin.x, y: origin.y + frame.height + 4, width: size.width, height: size.height),
      display: true)
    if parent == nil { host.addChildWindow(self, ordered: .above) }
    orderFront(nil)
  }

  func dismiss() {
    guard isVisible else { return }
    parent?.removeChildWindow(self)
    orderOut(nil)
  }

  /// What the list is showing, for the `completions` verb: the rows carry no text a script could
  /// read, and checking where a keystroke landed any other way means clicking at coordinates.
  /// Reported top-down, the way it is drawn, so the best match is the last line and `▸` starts
  /// there — a report in ranking order would be describing a list nobody can see.
  var report: String {
    guard isVisible else { return "closed" }
    guard !items.isEmpty else { return "empty" }
    let selected = table.selectedRow
    return items.enumerated().map { index, item in
      let mark = index == selected ? "▸" : " "
      switch item {
      case .command(let command):
        let hint = command.argumentHint.isEmpty ? "" : " \(command.argumentHint)"
        return "\(mark) /\(command.name)\(hint)"
      case .prompt(let prompt):
        return "\(mark) \(Self.line(of: prompt))"
      }
    }.joined(separator: "\n")
  }

  /// Move the selection, wrapping at both ends — a list this short is quicker to walk round than
  /// to walk back. With nothing selected the walk starts from the field itself, which sits below
  /// the bottom row: up enters at the best match, down wraps round to the far end.
  func move(_ delta: Int) {
    guard !items.isEmpty else { return }
    let row =
      table.selectedRow < 0
      ? (delta < 0 ? items.count - 1 : 0)
      : (table.selectedRow + delta + items.count) % items.count
    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    table.scrollRowToVisible(row)
  }

  @objc private func rowClicked() {
    guard let item = selected else { return }
    onPick?(item)
  }
}

extension CommandCompletionPanel: NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in tableView: NSTableView) -> Int { items.count }

  func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
    guard items.indices.contains(row) else { return nil }
    switch items[row] {
    case .command(let command): return commandRow(command)
    case .prompt(let prompt): return promptRow(prompt)
    }
  }

  /// A past prompt's row: the line itself, and nothing beside it. There is no second field to
  /// fill — what a prompt means is what it says — and the reading that matched it is deliberately
  /// not shown, being machinery rather than something to read.
  private func promptRow(_ prompt: String) -> NSView {
    let label = NSTextField(labelWithString: Self.line(of: prompt))
    label.font = .systemFont(ofSize: 12)
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return Self.row(holding: label)
  }

  /// One line of a prompt, for a row and for the `completions` verb. A message written over
  /// several lines is still one candidate, so it is named by its first line with the rest
  /// standing as an ellipsis.
  static func line(of prompt: String) -> String {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    let head = String(lines.first ?? "")
    return lines.count > 1 ? head + " …" : head
  }

  private func commandRow(_ command: ClaudeCommand) -> NSView {
    let name = NSTextField(labelWithString: "/\(command.name)")
    name.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
    let hint = NSTextField(labelWithString: command.argumentHint)
    hint.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    // Secondary, not tertiary: the hint is the command's syntax, which is the one thing on the
    // row you would act on, and at tertiary it read as a smudge beside the name rather than text.
    hint.textColor = .secondaryLabelColor
    hint.lineBreakMode = .byTruncatingTail
    // A skill's description is a paragraph written for the model to route on, not a menu label,
    // so only its first sentence's worth reaches the row — the rest would push the name of the
    // next command off the screen.
    let detail = NSTextField(labelWithString: Self.summary(of: command.description))
    detail.font = .systemFont(ofSize: 11)
    detail.textColor = .secondaryLabelColor
    detail.lineBreakMode = .byTruncatingTail

    let top = NSStackView(views: [name, hint])
    top.orientation = .horizontal
    top.spacing = 6
    top.alignment = .firstBaseline
    top.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let stack = NSStackView(views: [top, detail])
    stack.orientation = .vertical
    stack.spacing = 1
    stack.alignment = .leading

    // The two labels that may truncate are told to give way, so the name keeps its width; see
    // `row(holding:)` for why the row is held to the column rather than to its contents.
    for label in [hint, detail] {
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    return Self.row(holding: stack)
  }

  /// The row's own box. The content is pinned to the column's width and truncates inside it:
  /// left to its intrinsic size it is as wide as its longest label, and a stack that wide is laid
  /// out from a leading edge off the side of the panel, which takes the row's left inset with it
  /// — the rows whose text is longest are exactly the ones that lose their margin.
  private static func row(holding content: NSView) -> NSView {
    let row = NSView()
    content.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
      content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
      content.centerYAnchor.constraint(equalTo: row.centerYAnchor),
    ])
    return row
  }

  /// The head of a description: up to its first sentence end, and never more than fits a row.
  private static func summary(of description: String) -> String {
    let flattened = description.replacingOccurrences(of: "\n", with: " ")
    let head =
      flattened.range(of: ". ").map { String(flattened[..<$0.lowerBound]) } ?? flattened
    return head.count > 120 ? String(head.prefix(120)) + "…" : head
  }
}
