import AppKit

/// A session's panel, drawn above its conversation: the parts its last render declared, standard
/// AppKit controls throughout (see `docs/panels.md`). The view holds nothing the panel does not —
/// it is rebuilt from the `SessionPanel` whenever that changes — save the popover a send-back's
/// reason is typed into, which closes with the rebuild that its Send causes.
///
/// **Height is what the panel is short of; width is what it has.** It stands over the
/// conversation, so every line it takes is a line of transcript gone, while the column is wide.
/// So it is laid out across rather than down: badges and the panel-wide buttons ride the title row,
/// which a folded panel keeps; fields flow side by side and wrap; a list's groups stand as columns,
/// and a list of one group is split into as many columns as the width holds; a document to decide
/// on is one compact chip; a band is one line, its whole text in the tooltip.
final class PanelView: NSView {
  var onPress: (PanelContent.Button) -> Void = { _ in }
  var onConfirm: (Bool) -> Void = { _ in }
  var onDecide: (_ document: String, _ approve: Bool, _ reason: String?) -> Void = { _, _, _ in }
  var onOpen: (PanelContent.Target) -> Void = { _ in }
  var onToggleCollapsed: () -> Void = {}

  /// The height of the title row: what a folded panel keeps.
  static let headerHeight: CGFloat = 30

  private static let inset: CGFloat = 14
  private static let font = NSFont.systemFont(ofSize: 12)
  /// The narrowest a list's column gets before the list takes one column fewer.
  static let columnWidth: CGFloat = 260

  private let stack = NSStackView()
  private let scroll = NSScrollView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let disclosure = NSButton()
  private let spinner = NSProgressIndicator()
  private let headerBadges = NSStackView()
  private let headerButtons = NSStackView()
  private var buttons: [ObjectIdentifier: () -> Void] = [:]
  private var reasonPopover: NSPopover?

  override init(frame: NSRect) {
    super.init(frame: frame)
    titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.init(rawValue: 200), for: .horizontal)
    titleLabel.setContentHuggingPriority(.required, for: .horizontal)
    disclosure.bezelStyle = .disclosure
    disclosure.setButtonType(.onOff)
    disclosure.title = ""
    disclosure.target = self
    disclosure.action = #selector(toggleCollapsed)
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    for row in [headerBadges, headerButtons] {
      row.orientation = .horizontal
      row.spacing = 6
    }
    headerButtons.spacing = 8
    let header = NSStackView(views: [
      disclosure, titleLabel, headerBadges, Self.flexible(), spinner, headerButtons,
    ])
    header.orientation = .horizontal
    header.spacing = 6
    header.setCustomSpacing(10, after: titleLabel)
    header.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: Self.inset)

    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 0, left: Self.inset, bottom: 10, right: Self.inset)
    let document = FlippedView()
    document.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.autohidesScrollers = true
    document.translatesAutoresizingMaskIntoConstraints = false

    for view in [header, scroll] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: topAnchor),
      header.leadingAnchor.constraint(equalTo: leadingAnchor),
      header.trailingAnchor.constraint(equalTo: trailingAnchor),
      header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
      scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
      document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  /// The height the parts want at `width`, title row included — what an unfolded panel opens at,
  /// capped by the column. Laid out at that width first, since how many columns a list takes,
  /// and so how tall it is, is decided by the width.
  func fittingHeight(width: CGFloat) -> CGFloat {
    setFrameSize(NSSize(width: width, height: max(frame.height, 400)))
    for _ in 0..<3 { layoutSubtreeIfNeeded() }
    let parts = stack.arrangedSubviews.isEmpty ? 0 : stack.fittingSize.height
    return Self.headerHeight + parts
  }

  func show(_ panel: SessionPanel, collapsed: Bool, waitingOnPerson: Bool) {
    reasonPopover?.close()
    reasonPopover = nil
    buttons = [:]
    times = []
    defer { startClock() }
    titleLabel.stringValue = panel.title
    disclosure.state = collapsed ? .off : .on
    scroll.isHidden = collapsed
    if panel.runningCommand != nil {
      spinner.startAnimation(nil)
    } else {
      spinner.stopAnimation(nil)
    }
    for view in stack.arrangedSubviews + headerBadges.arrangedSubviews
      + headerButtons.arrangedSubviews
    {
      view.removeFromSuperview()
    }
    let enabled = panel.brokenFile == nil && panel.runningCommand == nil
    let sendEnabled = !waitingOnPerson

    if let broken = panel.brokenFile {
      add(
        band(
          "\((broken as NSString).lastPathComponent) changed since the panel was approved. "
            + "Nothing runs until the agent installs it again.", tone: .warning))
    }
    if let confirmation = panel.confirmation { add(confirmationStrip(confirmation)) }
    if let notice = panel.notice { add(band(notice.text, tone: notice.tone)) }
    guard let content = panel.content else {
      if panel.notice == nil { add(Self.secondary("Drawing\u{2026}"), fill: false) }
      return
    }
    // Neighbouring documents to decide on share one flowing row.
    var approvals: [NSView] = []
    func flushApprovals() {
      guard !approvals.isEmpty else { return }
      add(FlowView(approvals, spacing: NSSize(width: 8, height: 6)))
      approvals = []
    }
    for part in content.parts {
      if case .approval(let document, let label) = part {
        approvals.append(approval(document: document, label: label, panel: panel, enabled: enabled))
        continue
      }
      flushApprovals()
      switch part {
      case .badge(let text, let tone):
        headerBadges.addArrangedSubview(Pill(text, tone: tone))
      case .button(let button):
        headerButtons.addArrangedSubview(
          control(button, enabled: enabled, sendEnabled: sendEnabled))
      case .text(let text):
        // Plain words wrap like a paragraph; words with chips in them are one line of pieces.
        if text.spans.allSatisfy({ if case .text = $0 { return true } else { return false } }) {
          let label = NSTextField(wrappingLabelWithString: text.plain)
          label.font = Self.font
          label.textColor = .secondaryLabelColor
          add(label)
        } else {
          add(inline(text, font: Self.font, color: .secondaryLabelColor), fill: false)
        }
      case .fields(let fields):
        add(FlowView(fields.map(field), spacing: NSSize(width: 18, height: 4)))
      case .list(let groups, let limit, let empty):
        add(list(groups, limit: limit, empty: empty, enabled: enabled, sendEnabled: sendEnabled))
      case .notice(let text, let tone):
        add(band(text, tone: tone))
      case .divider:
        let box = NSBox()
        box.boxType = .separator
        add(box)
      case .approval:
        break
      }
    }
    flushApprovals()
  }

  /// Put a part on the panel, across its width.
  private func add(_ view: NSView, fill: Bool = true) {
    stack.addArrangedSubview(view)
    let width = view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Self.inset * 2)
    if fill {
      width.isActive = true
    } else {
      view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -Self.inset * 2)
        .isActive = true
    }
  }

  // MARK: Parts

  /// A field: its label and value on one line, a pair among the others flowing beside it.
  private func field(_ field: PanelContent.Field) -> NSView {
    let label = NSTextField(labelWithString: field.label)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    let value = inline(
      field.value, font: .systemFont(ofSize: 12, weight: .medium), color: .labelColor)
    value.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
    var views: [NSView] = []
    if let symbol = field.symbol { views.append(Self.symbolView(symbol, tone: nil)) }
    views += [label, value]
    let pair = NSStackView(views: views)
    pair.orientation = .horizontal
    pair.alignment = .centerY
    pair.spacing = 5
    return pair
  }

  /// A list across the width: its groups side by side, or one group's rows split into as many
  /// columns as fit — read down each column, then across.
  private func list(
    _ groups: [PanelContent.Group], limit: Int?, empty: String?, enabled: Bool, sendEnabled: Bool
  ) -> NSView {
    if groups.allSatisfy({ $0.rows.isEmpty }) {
      return Self.secondary(empty ?? "Nothing here.")
    }
    var remaining = limit ?? Int.max
    var shown: [(title: String?, count: Int, rows: [NSView])] = []
    for group in groups where remaining > 0 {
      let rows = group.rows.prefix(remaining).map {
        row($0, enabled: enabled, sendEnabled: sendEnabled)
      }
      remaining -= group.rows.count
      shown.append((group.title, group.rows.count, rows))
    }
    let hidden = max(0, groups.reduce(0) { $0 + $1.rows.count } - (limit ?? Int.max))
    if hidden > 0 { shown[shown.count - 1].rows.append(Self.secondary("\(hidden) more")) }

    if shown.count == 1 && shown[0].title == nil {
      return ColumnsView(shown[0].rows, minWidth: Self.columnWidth, splitting: true)
    }
    let columns = shown.map { group -> NSView in
      var views: [NSView] = []
      if let title = group.title {
        let heading = NSTextField(labelWithString: "\(title)  \(group.count)")
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        views.append(heading)
      }
      views += group.rows
      let column = NSStackView(views: views)
      column.orientation = .vertical
      column.alignment = .leading
      column.spacing = 0
      for view in group.rows {
        view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
      }
      if let heading = views.first, group.title != nil {
        column.setCustomSpacing(2, after: heading)
      }
      return column
    }
    return ColumnsView(columns, minWidth: Self.columnWidth, splitting: false)
  }

  private func row(_ row: PanelContent.Row, enabled: Bool, sendEnabled: Bool) -> NSView {
    var views: [NSView] = []
    if let status = row.status {
      let dot = Dot(tone: status.tone)
      dot.toolTip = status.text
      views.append(dot)
    }
    if let symbol = row.symbol { views.append(Self.symbolView(symbol, tone: nil)) }
    let title = inline(row.title, font: Self.font, color: .labelColor, target: row.target)
    title.toolTip = row.title.plain
    title.setContentCompressionResistancePriority(.init(rawValue: 230), for: .horizontal)
    views.append(title)
    if let subtitle = row.subtitle {
      let label = inline(
        subtitle, font: .systemFont(ofSize: 11), color: .secondaryLabelColor,
        truncation: .byTruncatingTail)
      label.setContentCompressionResistancePriority(.init(rawValue: 220), for: .horizontal)
      views.append(label)
    }
    views.append(Self.flexible())
    if let status = row.status, status.tone == .neutral {
      let label = Self.secondary(status.text)
      label.font = .systemFont(ofSize: 11)
      label.setContentCompressionResistancePriority(.init(rawValue: 250), for: .horizontal)
      views.append(label)
    }
    for button in row.buttons {
      views.append(control(button, enabled: enabled, sendEnabled: sendEnabled, compact: true))
    }
    let line = NSStackView(views: views)
    line.orientation = .horizontal
    line.spacing = 6
    line.alignment = .centerY
    line.heightAnchor.constraint(equalToConstant: 24).isActive = true
    return line
  }

  private func control(
    _ button: PanelContent.Button, enabled: Bool, sendEnabled: Bool, compact: Bool = false
  ) -> NSButton {
    let control = NSButton(title: button.label, target: nil, action: nil)
    if let symbol = button.symbol,
      let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    {
      control.image = image
      control.imagePosition = .imageLeading
    }
    control.bezelStyle = .push
    control.controlSize = compact ? .mini : .small
    control.font = .systemFont(
      ofSize: compact ? NSFont.smallSystemFontSize - 1 : NSFont.smallSystemFontSize)
    if case .send = button.action {
      control.isEnabled = enabled && sendEnabled
      if !sendEnabled { control.toolTip = "The session is waiting on you." }
    } else {
      control.isEnabled = enabled
    }
    control.setContentCompressionResistancePriority(.required, for: .horizontal)
    bind(control) { [weak self] in self?.onPress(button) }
    return control
  }

  /// A document to decide on, as one chip: its name, where it stands, and the two answers.
  private func approval(
    document: String, label: String?, panel: SessionPanel, enabled: Bool
  ) -> NSView {
    let icon = NSImageView(
      image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Document")!)
    icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
    icon.contentTintColor = .secondaryLabelColor
    let name = LinkLabel(label ?? document)
    name.font = .systemFont(ofSize: 12, weight: .medium)
    name.lineBreakMode = .byTruncatingMiddle
    name.toolTip = document
    name.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
    name.onClick = { [weak self] in self?.onOpen(.document(document)) }
    var views: [NSView] = [icon, name]
    if let decision = panel.latestDecision(on: document) {
      let state: String
      let tone: PanelContent.Tone
      switch (decision.approval.verdict, decision.current) {
      case (.approved, true): (state, tone) = ("Approved", .success)
      case (.approved, false): (state, tone) = ("Changed", .warning)
      case (.rejected, _): (state, tone) = ("Sent back", .danger)
      }
      let mark = Pill(state, tone: tone)
      mark.toolTip = decision.approval.reason
      views.append(mark)
    }
    let sendBack = NSButton(title: "Send Back\u{2026}", target: nil, action: nil)
    let approve = NSButton(title: "Approve", target: nil, action: nil)
    for button in [sendBack, approve] {
      button.bezelStyle = .push
      button.controlSize = .mini
      button.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
      button.isEnabled = enabled
    }
    bind(approve) { [weak self] in self?.onDecide(document, true, nil) }
    bind(sendBack) { [weak self, weak sendBack] in
      guard let self, let sendBack else { return }
      self.askReason(for: document, from: sendBack)
    }
    views += [sendBack, approve]
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    row.setCustomSpacing(10, after: views[views.count - 3])
    row.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 4)
    let chip = LayerSurface()
    chip.wantsLayer = true
    chip.layer?.cornerRadius = 7
    chip.layer?.cornerCurve = .continuous
    chip.paintLayer = { $0.backgroundColor = NSColor.quaternarySystemFill.cgColor }
    row.translatesAutoresizingMaskIntoConstraints = false
    chip.addSubview(row)
    row.pin(to: chip)
    return chip
  }

  /// A send-back needs its reason: a popover, not a sheet, since nothing modal goes over the
  /// window's other sessions.
  private func askReason(for document: String, from anchor: NSView) {
    let prompt = NSTextField(labelWithString: "What should change?")
    prompt.font = .systemFont(ofSize: 12, weight: .semibold)
    let field = NSTextField()
    field.placeholderString = "The reason goes to the session with the document."
    field.widthAnchor.constraint(equalToConstant: 300).isActive = true
    let send = NSButton(title: "Send Back", target: nil, action: nil)
    send.bezelStyle = .push
    send.keyEquivalent = "\r"
    bind(send) { [weak self, weak field] in
      guard let self, let reason = field?.stringValue,
        !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return }
      self.reasonPopover?.close()
      self.onDecide(document, false, reason)
    }
    let buttons = NSStackView(views: [Self.flexible(), send])
    buttons.orientation = .horizontal
    let column = NSStackView(views: [prompt, field, buttons])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 8
    column.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    buttons.widthAnchor.constraint(equalTo: field.widthAnchor).isActive = true
    let controller = NSViewController()
    controller.view = column
    let popover = NSPopover()
    popover.contentViewController = controller
    popover.behavior = .transient
    reasonPopover = popover
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    popover.contentViewController?.view.window?.makeFirstResponder(field)
  }

  /// An outward command's preview on one line: what is asked, the argv, and the two answers.
  private func confirmationStrip(_ confirmation: SessionPanel.Confirmation) -> NSView {
    let question = NSTextField(labelWithString: "Run \u{201C}\(confirmation.label)\u{201D}?")
    question.font = .systemFont(ofSize: 12, weight: .semibold)
    question.setContentCompressionResistancePriority(.required, for: .horizontal)
    let command = confirmation.argv.joined(separator: " ")
    let argv = NSTextField(labelWithString: command)
    argv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    argv.textColor = .secondaryLabelColor
    argv.lineBreakMode = .byTruncatingMiddle
    argv.toolTip = command
    argv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    let run = NSButton(title: "Run", target: nil, action: nil)
    for button in [cancel, run] {
      button.bezelStyle = .push
      button.controlSize = .small
      button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    }
    run.bezelColor = .controlAccentColor
    bind(cancel) { [weak self] in self?.onConfirm(false) }
    bind(run) { [weak self] in self?.onConfirm(true) }
    let line = NSStackView(views: [question, argv, Self.flexible(), cancel, run])
    line.orientation = .horizontal
    line.spacing = 8
    return tinted(line, tone: .warning, symbol: "exclamationmark.triangle.fill")
  }

  // MARK: Inline text

  /// The labels showing a relative time, and the time each shows, kept current by `clock`.
  private var times: [(label: NSTextField, date: Date)] = []
  private var clock: Timer?

  /// A run of spans as one line of pieces: words, links, the rail's tag chips, times, symbols.
  /// With `target`, the plain words are themselves a link to it — a row that opens something.
  /// A run of plain words is one label, so it truncates like one.
  private func inline(
    _ inline: PanelContent.Inline, font: NSFont, color: NSColor,
    target: PanelContent.Target? = nil, truncation: NSLineBreakMode = .byTruncatingMiddle
  ) -> NSView {
    var pieces: [NSView] = []
    for span in inline.spans {
      switch span {
      case .text(let text, let mono, let strong, let tone):
        let base: NSFont =
          mono ? .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) : font
        let label: NSTextField
        if let target {
          let link = LinkLabel(text)
          link.onClick = { [weak self] in self?.onOpen(target) }
          label = link
        } else {
          label = NSTextField(labelWithString: text)
          label.textColor = tone.map(Self.color) ?? color
          label.isSelectable = true
        }
        label.font = strong ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
        label.lineBreakMode = truncation
        label.setContentCompressionResistancePriority(.init(rawValue: 240), for: .horizontal)
        pieces.append(label)
      case .link(let text, let linkTarget):
        let link = LinkLabel(text)
        link.font = font
        link.lineBreakMode = .byTruncatingMiddle
        link.onClick = { [weak self] in self?.onOpen(linkTarget) }
        link.setContentCompressionResistancePriority(.init(rawValue: 240), for: .horizontal)
        pieces.append(link)
      case .tag(let tag):
        let chip = TagChip(tag: tag) { [weak self] url in self?.onOpen(.url(url)) }
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        chip.setContentHuggingPriority(.required, for: .horizontal)
        pieces.append(chip)
      case .time(let date):
        let label = NSTextField(labelWithString: PanelContent.Inline.relative(date))
        label.font = font
        label.textColor = color
        label.toolTip = DateFormatter.localizedString(
          from: date, dateStyle: .medium, timeStyle: .short)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        times.append((label, date))
        pieces.append(label)
      case .symbol(let name, let tone):
        pieces.append(Self.symbolView(name, tone: tone))
      }
    }
    if pieces.count == 1 { return pieces[0] }
    let line = NSStackView(views: pieces)
    line.orientation = .horizontal
    line.alignment = .centerY
    line.spacing = 4
    return line
  }

  private static func symbolView(_ name: String, tone: PanelContent.Tone?) -> NSView {
    let image = NSImageView(
      image: NSImage(systemSymbolName: name, accessibilityDescription: nil)
        ?? NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: nil)!)
    image.symbolConfiguration = .init(pointSize: 11, weight: .regular)
    image.contentTintColor = tone.map(color) ?? .secondaryLabelColor
    image.setContentHuggingPriority(.required, for: .horizontal)
    image.setContentCompressionResistancePriority(.required, for: .horizontal)
    return image
  }

  /// Keep the relative times true while the panel is up: each half minute, not each second — the
  /// coarsest unit shown is a minute.
  private func startClock() {
    clock?.invalidate()
    clock = nil
    guard !times.isEmpty else { return }
    let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
      guard let self else { return }
      for (label, date) in self.times { label.stringValue = PanelContent.Inline.relative(date) }
    }
    RunLoop.main.add(timer, forMode: .common)
    clock = timer
  }

  // MARK: Pieces

  static func color(_ tone: PanelContent.Tone) -> NSColor {
    switch tone {
    case .neutral: return .secondaryLabelColor
    case .info: return .systemBlue
    case .success: return .systemGreen
    case .warning: return .systemOrange
    case .danger: return .systemRed
    }
  }

  private static func symbol(_ tone: PanelContent.Tone) -> String {
    switch tone {
    case .neutral, .info: return "info.circle.fill"
    case .success: return "checkmark.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .danger: return "xmark.octagon.fill"
    }
  }

  static func flexible() -> NSView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
    spacer.setContentCompressionResistancePriority(.init(rawValue: 1), for: .horizontal)
    return spacer
  }

  /// A band on one line; the whole of a longer one is in its tooltip.
  private func band(_ text: String, tone: PanelContent.Tone) -> NSView {
    let label = NSTextField(labelWithString: text)
    label.font = Self.font
    label.lineBreakMode = .byTruncatingTail
    label.toolTip = text
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return tinted(label, tone: tone, symbol: Self.symbol(tone))
  }

  /// A strip in a tone's colour with its symbol leading — the notice band, a stopped panel, an
  /// outward command's preview.
  private func tinted(_ content: NSView, tone: PanelContent.Tone, symbol: String) -> NSView {
    let box = LayerSurface()
    box.wantsLayer = true
    box.layer?.cornerRadius = 6
    box.layer?.cornerCurve = .continuous
    let color = Self.color(tone)
    box.paintLayer = { $0.backgroundColor = color.withAlphaComponent(0.12).cgColor }
    let icon = NSImageView(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
    icon.contentTintColor = color
    icon.setContentHuggingPriority(.required, for: .horizontal)
    let row = NSStackView(views: [icon, content])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 7
    row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 6)
    row.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(row)
    row.pin(to: box)
    return box
  }

  static func secondary(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = font
    label.textColor = .secondaryLabelColor
    return label
  }

  private func bind(_ button: NSButton, _ action: @escaping () -> Void) {
    buttons[ObjectIdentifier(button)] = action
    button.target = self
    button.action = #selector(pressed(_:))
  }

  @objc private func pressed(_ sender: NSButton) { buttons[ObjectIdentifier(sender)]?() }

  @objc private func toggleCollapsed() { onToggleCollapsed() }
}

/// Views side by side in columns at least `minWidth` wide, as many as the width holds. With
/// `splitting`, the views are one list's rows, dealt down the first column and on into the next,
/// so the list reads in order; without, each view is a column of its own (a group) and the ones
/// that do not fit start a new line of columns. Laid out by hand, since how many columns there are
/// is a question of the width the view is given, which constraints cannot ask.
final class ColumnsView: NSView {
  private let items: [NSView]
  private let minWidth: CGFloat
  private let splitting: Bool
  private let gutter: CGFloat = 20
  private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)

  init(_ items: [NSView], minWidth: CGFloat, splitting: Bool) {
    self.items = items
    self.minWidth = minWidth
    self.splitting = splitting
    super.init(frame: .zero)
    for item in items {
      item.translatesAutoresizingMaskIntoConstraints = true
      addSubview(item)
    }
    heightConstraint.isActive = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  /// How many columns `width` holds.
  func columnCount(for width: CGFloat) -> Int {
    let fit = Int((width + gutter) / (minWidth + gutter))
    return max(1, min(fit, splitting ? items.count : max(items.count, 1)))
  }

  override func layout() {
    super.layout()
    let width = bounds.width
    guard width > 0 else { return }
    let count = columnCount(for: width)
    let columnWidth = (width - gutter * CGFloat(count - 1)) / CGFloat(count)
    func height(of view: NSView) -> CGFloat {
      view.setFrameSize(NSSize(width: columnWidth, height: view.frame.height))
      view.layoutSubtreeIfNeeded()
      return view.fittingSize.height
    }
    var total: CGFloat = 0
    if splitting {
      let perColumn = max(Int((Double(items.count) / Double(count)).rounded(.up)), 1)
      var tops = [CGFloat](repeating: 0, count: count)
      for (index, item) in items.enumerated() {
        let column = min(index / perColumn, count - 1)
        let h = height(of: item)
        item.frame = NSRect(
          x: CGFloat(column) * (columnWidth + gutter), y: tops[column], width: columnWidth,
          height: h)
        tops[column] += h
        total = max(total, tops[column])
      }
    } else {
      var y: CGFloat = 0
      for start in stride(from: 0, to: items.count, by: count) {
        let line = items[start..<min(start + count, items.count)]
        var lineHeight: CGFloat = 0
        for (offset, item) in line.enumerated() {
          let h = height(of: item)
          item.frame = NSRect(
            x: CGFloat(offset) * (columnWidth + gutter), y: y, width: columnWidth, height: h)
          lineHeight = max(lineHeight, h)
        }
        y += lineHeight + 10
      }
      total = max(0, y - 10)
    }
    if abs(heightConstraint.constant - total) > 0.5 { heightConstraint.constant = total }
  }
}

/// Views left to right at their own widths, wrapping onto a new line when the width runs out —
/// fields, documents to decide on.
final class FlowView: NSView {
  private let items: [NSView]
  private let spacing: NSSize
  private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)

  init(_ items: [NSView], spacing: NSSize) {
    self.items = items
    self.spacing = spacing
    super.init(frame: .zero)
    for item in items {
      item.translatesAutoresizingMaskIntoConstraints = true
      addSubview(item)
    }
    heightConstraint.isActive = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    let width = bounds.width
    guard width > 0 else { return }
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    for item in items {
      item.layoutSubtreeIfNeeded()
      var size = item.fittingSize
      size.width = min(size.width, width)
      if x > 0, x + size.width > width {
        x = 0
        y += lineHeight + spacing.height
        lineHeight = 0
      }
      item.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
      x += size.width + spacing.width
      lineHeight = max(lineHeight, size.height)
    }
    let total = y + lineHeight
    if abs(heightConstraint.constant - total) > 0.5 { heightConstraint.constant = total }
  }
}

/// A status's mark in a row: a dot in its tone, the status's own word in its tooltip.
private final class Dot: NSView {
  private let tone: PanelContent.Tone

  init(tone: PanelContent.Tone) {
    self.tone = tone
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    widthAnchor.constraint(equalToConstant: 7).isActive = true
    heightAnchor.constraint(equalToConstant: 7).isActive = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    PanelView.color(tone).setFill()
    NSBezierPath(ovalIn: bounds).fill()
  }
}

/// A short label on a capsule in its tone — a badge part, a document's decision.
private final class Pill: LayerSurface {
  init(_ text: String, tone: PanelContent.Tone) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
    let color = PanelView.color(tone)
    paintLayer = { $0.backgroundColor = color.withAlphaComponent(0.16).cgColor }
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 10, weight: .semibold)
    label.textColor = tone == .neutral ? .secondaryLabelColor : color
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      heightAnchor.constraint(equalToConstant: 16),
    ])
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  required init?(coder: NSCoder) { fatalError() }
}

/// Text that opens something when clicked: the link colour, and the pointing hand over it.
private final class LinkLabel: NSTextField {
  var onClick: () -> Void = {}

  init(_ text: String) {
    super.init(frame: .zero)
    stringValue = text
    isEditable = false
    isSelectable = false
    isBordered = false
    drawsBackground = false
    textColor = .linkColor
  }

  required init?(coder: NSCoder) { fatalError() }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

  override func mouseDown(with event: NSEvent) { onClick() }
}

private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// The rule between the panel and the conversation, and the handle that resizes the panel: drag
/// it down for more panel, up for more conversation.
final class PanelDivider: NSView {
  static let thickness: CGFloat = 5
  var onDrag: (CGFloat) -> Void = { _ in }
  private var lastY: CGFloat?

  override func draw(_ dirtyRect: NSRect) {
    NSColor.separatorColor.setFill()
    NSRect(x: 0, y: (bounds.height - 1) / 2, width: bounds.width, height: 1).fill()
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

  override func mouseDown(with event: NSEvent) { lastY = event.locationInWindow.y }

  override func mouseDragged(with event: NSEvent) {
    guard let lastY else { return }
    let y = event.locationInWindow.y
    // Window coordinates grow upward; the panel grows as the divider goes down.
    onDrag(lastY - y)
    self.lastY = y
  }

  override func mouseUp(with event: NSEvent) { lastY = nil }
}
