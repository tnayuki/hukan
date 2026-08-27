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

/// The keys a completion list takes before the composer sees them.
enum CompletionKey {
  case up
  case down
  case accept
  case dismiss
}

/// The floating list above the composer. A panel rather than a view in the column: it has to
/// stand over the transcript, and the composer's own box clips.
final class CommandCompletionPanel: NSPanel {
  /// A row was taken, by click or by Return.
  var onPick: ((ClaudeCommand) -> Void)?

  private let table = NSTableView()
  private let scroll = NSScrollView()
  private var commands: [ClaudeCommand] = []
  private static let rowHeight: CGFloat = 34
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
    table.rowHeight = Self.rowHeight
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

  var selected: ClaudeCommand? {
    let row = table.selectedRow
    return commands.indices.contains(row) ? commands[row] : nil
  }

  /// Show `commands` under `anchor` (the composer, in its window's coordinates). Hides itself
  /// when there is nothing to show, so the caller can hand over an empty list rather than having
  /// to decide twice.
  func present(_ commands: [ClaudeCommand], below anchor: NSView) {
    guard !commands.isEmpty, let host = anchor.window else {
      dismiss()
      return
    }
    self.commands = commands
    table.reloadData()
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    table.scrollRowToVisible(0)

    let rows = min(commands.count, Self.visibleRows)
    let frame = anchor.convert(anchor.bounds, to: nil)
    let origin = host.convertPoint(toScreen: frame.origin)
    let size = NSSize(width: max(frame.width, 320), height: CGFloat(rows) * Self.rowHeight + 8)
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
  var report: String {
    guard isVisible else { return "closed" }
    guard !commands.isEmpty else { return "empty" }
    let selected = table.selectedRow
    return commands.enumerated().map { index, command in
      let mark = index == selected ? "▸" : " "
      let hint = command.argumentHint.isEmpty ? "" : " \(command.argumentHint)"
      return "\(mark) /\(command.name)\(hint)"
    }.joined(separator: "\n")
  }

  /// Move the selection, wrapping at both ends — a list this short is quicker to walk round than
  /// to walk back.
  func move(_ delta: Int) {
    guard !commands.isEmpty else { return }
    let row = (table.selectedRow + delta + commands.count) % commands.count
    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    table.scrollRowToVisible(row)
  }

  @objc private func rowClicked() {
    guard let command = selected else { return }
    onPick?(command)
  }
}

extension CommandCompletionPanel: NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in tableView: NSTableView) -> Int { commands.count }

  func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
    guard commands.indices.contains(row) else { return nil }
    let command = commands[row]
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

    // The row is pinned to the column's width and the text truncates inside it. Left to their
    // own intrinsic sizes the labels are as wide as a skill's description — a paragraph written
    // for the model to route on — and a stack that wide is laid out from a leading edge off the
    // side of the panel, which takes the row's left inset with it: the names lose their margin
    // exactly on the rows whose description is longest. So the two that may truncate are told to
    // give way, and the stack is held to the row rather than to its contents.
    for label in [hint, detail] {
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    let row = NSView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
      stack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
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
