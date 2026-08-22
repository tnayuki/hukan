import AppKit

// MARK: - Middle: what is running (transcript / terminal)

/// Approvals are never modal. A modal hides the other sessions, which defeats the point
/// of watching them in parallel.
/// A block of text shown inside a card — an approval's plan, a session's task list — rendered
/// into a real, scrollable text view (which the transcript's own NSTextView cannot host — macOS
/// never realizes attachment views, see the charter — but a card is a plain view, so it can).
/// Grows to fit short content and caps at `maxHeight`, scrolling internally past that, so a long
/// plan reads in place without shoving the composer off screen.
final class ScrollBox: NSView {
  private let content: NSAttributedString
  private let maxHeight: CGFloat
  private let inset: NSSize
  private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: maxHeight)

  init(
    content: NSAttributedString, maxHeight: CGFloat = 200, bordered: Bool = true,
    inset: NSSize = NSSize(width: 14, height: 12)
  ) {
    self.content = content
    self.maxHeight = maxHeight
    self.inset = inset
    let (scrollView, textView) = makeTranscriptTextView()
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    // A box inside a card that already has a border needs none of its own; a plan, standing
    // apart from the card's own text, does.
    if bordered {
      layer?.cornerRadius = 6
      layer?.borderWidth = 1
      layer?.borderColor = NSColor.separatorColor.cgColor
    }
    textView.textContainerInset = inset
    textView.textStorage?.setAttributedString(content)
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scrollView)
    _ = scrollView.pin(to: self)
    heightConstraint.isActive = true
  }

  /// The markdown form — what an `ExitPlanMode` approval decides on.
  convenience init(plan: String, maxHeight: CGFloat = 200) {
    self.init(content: Transcript.markdown(plan), maxHeight: maxHeight)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    // The text view's own inset, plus the default lineFragmentPadding of 5 on each side.
    let width = bounds.width - (inset.width * 2 + 5 * 2)
    guard width > 1 else { return }
    let rect = content.boundingRect(
      with: NSSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading])
    let target = min(ceil(rect.height) + inset.height * 2, maxHeight)
    if abs(heightConstraint.constant - target) > 0.5 { heightConstraint.constant = target }
  }
}

final class ApprovalCard: NSView {
  private let onDecision: (Bool) -> Void

  init(approval: PendingApproval, onDecision: @escaping (Bool) -> Void) {
    self.onDecision = onDecision
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.5).cgColor
    layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.08).cgColor

    let icon = NSImageView()
    icon.image = NSImage(
      systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Needs approval")
    icon.contentTintColor = .systemOrange
    icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)

    let title = NSTextField(labelWithString: approval.title)
    title.font = .systemFont(ofSize: 12, weight: .semibold)
    title.lineBreakMode = .byTruncatingTail
    // The split items hold their width at priority ~260, so any content that resists
    // compression harder than that (the default is 750) drags the whole pane wider when the
    // card appears. Dropping below the holding priority makes the text truncate instead.
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let deny = NSButton(title: "Deny", target: self, action: #selector(denyClicked))
    deny.bezelStyle = .rounded
    deny.controlSize = .small
    let allow = NSButton(title: "Allow", target: self, action: #selector(allowClicked))
    allow.bezelStyle = .rounded
    allow.controlSize = .small

    let header = NSStackView(views: [icon, title, spacer, deny, allow])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 6

    let stack = NSStackView(views: [header])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    addSubview(stack)
    stack.pin(to: self, insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
    header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

    // ExitPlanMode's "what am I approving?" is the plan itself, so show it in a scrollable box
    // rather than a one-line detail. Every other tool keeps the compact truncating label.
    if approval.toolName == "ExitPlanMode",
      let plan = (approval.input["plan"] as? String)?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      !plan.isEmpty
    {
      let box = ScrollBox(plan: plan)
      stack.addArrangedSubview(box)
      box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    } else {
      let body = NSTextField(
        labelWithString: approval.detail.isEmpty ? approval.toolName : approval.detail)
      body.font = monospace
      body.textColor = .secondaryLabelColor
      body.lineBreakMode = .byTruncatingTail
      // Same reason as the title: a long detail (a full command, say) must truncate within the
      // pane, never widen it.
      body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      stack.addArrangedSubview(body)
      // Cap the body to the card so a leading-aligned label truncates against a real width
      // rather than reaching for its full intrinsic length.
      body.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func allowClicked() { onDecision(true) }
  @objc private func denyClicked() { onDecision(false) }
}

/// The agent's own question (`AskUserQuestion`), shown one at a time as its options rather than a
/// generic allow/deny. A click answers with the option label; Skip answers with nothing. Like the
/// approval card, it sits above the composer and never blocks the other sessions.
///
/// A `multiSelect` question is the same card with the options as checkboxes and a Done beside the
/// Skip — the click cannot answer for you once a second tick is allowed, so the send has to become
/// its own act. An option's `preview` — the sketch of what choosing it would look like — folds
/// under it, because a card standing over the composer must not open at the height of every
/// option's mockup at once; opened, several stay open, which is what makes two of them comparable.
/// The third answer, your own words, has no control here at all: the composer directly below is
/// already a field, and typing into it answers the question (see `AgentSession.send`).
///
/// The card is redrawn from the session on every state change, so what is ticked and what is
/// open live in `PendingQuestion` rather than in this view — a view holding them would lose them
/// to any refresh that landed mid-answer.
final class QuestionCard: NSView {
  private let onAnswer: ([String]) -> Void
  private let onToggleOption: (Int) -> Void
  private let onTogglePreview: (Int) -> Void
  private let optionLabels: [String]
  /// What Done sends: the ticks as they stood when the card was drawn. Held here because the
  /// checkboxes are only a picture of `PendingQuestion.ticked` — the click that changes one goes
  /// through the session and comes back as a fresh card.
  private let tickedLabels: [String]

  init(
    question: PendingQuestion, onAnswer: @escaping ([String]) -> Void,
    onToggleOption: @escaping (Int) -> Void, onTogglePreview: @escaping (Int) -> Void
  ) {
    self.onAnswer = onAnswer
    self.onToggleOption = onToggleOption
    self.onTogglePreview = onTogglePreview
    let current = question.current
    self.optionLabels = current.options.map(\.label)
    self.tickedLabels = current.labels(ticked: question.ticked)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
    layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor

    let total = question.questions.count
    let progress = total > 1 ? "Question \(question.index + 1)/\(total)" : "Question"
    let headerLabel = NSTextField(
      labelWithString: current.header.isEmpty ? progress : "\(progress) · \(current.header)")
    headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    headerLabel.textColor = .secondaryLabelColor
    headerLabel.lineBreakMode = .byTruncatingTail
    headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let questionLabel = NSTextField(wrappingLabelWithString: current.question)
    questionLabel.font = .systemFont(ofSize: 13, weight: .medium)
    questionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    var rows: [NSView] = [headerLabel, questionLabel]
    for (index, option) in current.options.enumerated() {
      rows.append(
        optionView(
          option, index: index, multiSelect: current.multiSelect,
          ticked: question.ticked.contains(index),
          previewOpen: question.previewsOpen.contains(index)))
    }
    // The one line of instruction on the card, and it earns its place: nothing else says that
    // the field below answers this too, and an option nobody offered is exactly the answer that
    // needs saying out loud.
    let other = NSTextField(labelWithString: "Other — type your own answer below")
    other.font = .systemFont(ofSize: 11)
    other.textColor = .tertiaryLabelColor
    other.lineBreakMode = .byTruncatingTail
    other.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    rows.append(other)

    let skip = NSButton(title: "Skip", target: self, action: #selector(skipClicked))
    skip.bezelStyle = .rounded
    skip.controlSize = .small

    var actions: [NSView] = [skip]
    if current.multiSelect {
      // Nothing ticked is what Skip already says, so the button that sends stays off until
      // there is something to send and the two never mean the same thing.
      let done = NSButton(title: "Done", target: self, action: #selector(doneClicked))
      done.bezelStyle = .rounded
      done.controlSize = .small
      done.isEnabled = !question.ticked.isEmpty
      actions.insert(done, at: 0)
    }
    let actionRow = NSStackView(views: actions)
    actionRow.orientation = .horizontal
    actionRow.spacing = 6

    let stack = NSStackView(views: rows + [actionRow])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    stack.pin(to: self, insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
    // Each option/label spans the card width so descriptions wrap and long labels truncate
    // within the pane instead of widening it (the split holds width at a low priority).
    for row in rows {
      row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
  }

  private func optionView(
    _ option: QuestionOption, index: Int, multiSelect: Bool, ticked: Bool, previewOpen: Bool
  ) -> NSView {
    let button: NSButton
    if multiSelect {
      button = NSButton(
        checkboxWithTitle: option.label, target: self, action: #selector(optionToggled(_:)))
      button.state = ticked ? .on : .off
    } else {
      button = NSButton(title: option.label, target: self, action: #selector(optionClicked(_:)))
      button.bezelStyle = .rounded
    }
    button.tag = index
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    var parts: [NSView] = [button]
    if !option.description.isEmpty {
      let description = NSTextField(wrappingLabelWithString: option.description)
      description.font = .systemFont(ofSize: 11)
      description.textColor = .secondaryLabelColor
      description.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      parts.append(description)
    }
    if !option.preview.isEmpty {
      let disclosure = NSButton(
        title: previewOpen ? "▾ Preview" : "▸ Preview", target: self,
        action: #selector(previewToggled(_:)))
      disclosure.isBordered = false
      disclosure.controlSize = .small
      disclosure.font = .systemFont(ofSize: 10)
      disclosure.contentTintColor = .tertiaryLabelColor
      disclosure.tag = index
      parts.append(disclosure)
      if previewOpen { parts.append(previewBox(option.preview)) }
    }
    guard parts.count > 1 else { return button }
    let group = NSStackView(views: parts)
    group.orientation = .vertical
    group.alignment = .leading
    group.spacing = 2
    return group
  }

  /// The sketch itself. Monospaced, because what the agent draws in one is a box or a tree that
  /// only lines up in a fixed pitch, and unwrapped for the same reason — a rewrapped diagram is
  /// noise, so a line wider than the column clips and the tooltip carries the whole of it. The
  /// same capped, scrolling box a plan gets, at a height that clears the widest of these seen.
  ///
  /// The font and nothing else. SF Mono carries no CJK, so a sketch with Japanese in it falls
  /// back to Hiragino for those runs, whose advance is 1.49 cells against SF Mono's one — and
  /// the box does not close. Putting every glyph back on the grid was built (sizing the fallback
  /// run up so its advance is exactly the two cells a terminal gives a wide glyph) and then
  /// taken out again, because it fixed nothing real: of the nine sketches in this machine's
  /// history that put Japanese inside box drawing, *none* are composed to a whole number of
  /// cells in the first place — four lean to the terminal's convention, one to counting
  /// characters, four to neither. A renderer cannot align what was not aligned when it was
  /// written, and the mechanism only paid off for art that had to be checked by script to
  /// compose. What is left is the half of the sketches that are pure ASCII, which line up in a
  /// monospaced font by themselves, and Japanese prose inside a sketch, which reads correctly
  /// as long as nothing is padded around it.
  private func previewBox(_ preview: String) -> NSView {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byClipping
    let text = NSAttributedString(
      string: preview,
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: paragraph,
      ])
    let box = ScrollBox(
      content: text, maxHeight: 220, bordered: true, inset: NSSize(width: 8, height: 6))
    box.toolTip = preview
    return box
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func optionClicked(_ sender: NSButton) {
    guard optionLabels.indices.contains(sender.tag) else { return }
    onAnswer([optionLabels[sender.tag]])
  }
  @objc private func optionToggled(_ sender: NSButton) { onToggleOption(sender.tag) }
  @objc private func previewToggled(_ sender: NSButton) { onTogglePreview(sender.tag) }
  @objc private func doneClicked() { onAnswer(tickedLabels) }
  @objc private func skipClicked() { onAnswer([]) }
}

/// The agent's own task list, read from the engine's own store (see `AgentTask`) rather than
/// from the calls that write it — which is also why the transcript carries no line for those
/// calls (see `Transcript.hasOwnCard`). Folded it is one row: how far the list has got, and what
/// is in flight. Opened it is what is *left* of the list, capped and scrolling past that like a
/// plan — the store keeps every task the session ever had, and a wall of finished work is not
/// what the card is for; the count carries the finished ones.
///
/// Quiet chrome on purpose. The cards below it — an approval, a question, the type-ahead — are
/// things stopped on you; this one is the agent saying what it is doing, so it borrows the
/// queued card's bordered grey rather than an orange or an accent that would read as a demand.
final class TaskCard: NSView {
  private let onToggle: () -> Void
  private let header = NSStackView()

  init(tasks: [AgentTask], expanded: Bool, onToggle: @escaping () -> Void) {
    self.onToggle = onToggle
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.separatorColor.cgColor
    layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor

    let chevron = NSTextField(labelWithString: expanded ? "▾" : "▸")
    chevron.font = .systemFont(ofSize: 9)
    chevron.textColor = .tertiaryLabelColor

    let done = tasks.filter { $0.status == .completed }.count
    let count = NSTextField(labelWithString: "\(done)/\(tasks.count)")
    count.font = .systemFont(ofSize: 11, weight: .semibold)
    count.textColor = .secondaryLabelColor

    let current = NSTextField(labelWithString: Self.currentLabel(of: tasks))
    current.font = .systemFont(ofSize: 11)
    current.textColor = .secondaryLabelColor
    current.lineBreakMode = .byTruncatingTail
    // Same as the approval card's title: the split holds the pane's width at a low priority, so
    // a long task name must truncate here rather than drag the whole column wider.
    current.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    header.setViews([chevron, count, current, spacer], in: .leading)
    header.orientation = .horizontal
    header.alignment = .firstBaseline
    header.spacing = 6

    let stack = NSStackView(views: [header])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    stack.pin(to: self, insets: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10))
    header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

    guard expanded else { return }
    let list = ScrollBox(
      content: Self.list(of: tasks), maxHeight: 180, bordered: false,
      inset: NSSize(width: 2, height: 4))
    stack.addArrangedSubview(list)
    list.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
  }

  required init?(coder: NSCoder) { fatalError() }

  /// The folded row's second half: what the agent is on now, in the present-tense phrasing the
  /// task carries for it — or, between tasks, what it will pick up next. Nothing to say once a
  /// list is finished, but a finished list has no card (see `AgentSession.hasOpenTasks`).
  static func currentLabel(of tasks: [AgentTask]) -> String {
    if let running = tasks.first(where: { $0.status == .inProgress }) { return running.label }
    return tasks.first { $0.status == .pending }?.label ?? ""
  }

  /// The ids of the tasks that cannot start yet: the ones waiting on something still unfinished.
  /// A `blockedBy` naming a task that has since landed is not a block, which is why this is
  /// resolved against the list rather than read off the field.
  static func blockedIDs(in tasks: [AgentTask]) -> Set<String> {
    let unfinished = Set(tasks.filter { $0.status != .completed }.map(\.id))
    return Set(tasks.filter { $0.blockedBy.contains(where: unfinished.contains) }.map(\.id))
  }

  /// The opened list: what is left to do, each task under its own glyph. Subjects, never the
  /// present-tense phrasing — that belongs to the folded row, and repeating it here would say
  /// the running task twice and move a line's text under it as it started.
  private static func list(of tasks: [AgentTask]) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    // A tab stop rather than a space after the glyph, so the subjects line up under each other
    // however wide the glyph in front of them is, and a wrapped one keeps that column.
    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
    paragraph.headIndent = 16
    paragraph.paragraphSpacing = 3
    paragraph.lineBreakMode = .byWordWrapping

    let blocked = blockedIDs(in: tasks)
    let result = NSMutableAttributedString()
    for task in tasks where task.status != .completed {
      let glyph: String
      let color: NSColor
      let font: NSFont
      switch task.status {
      case .inProgress:
        (glyph, color, font) = ("▸", .labelColor, .systemFont(ofSize: 11, weight: .semibold))
      case .pending where blocked.contains(task.id):
        // Waiting on another task, not on you: the glyph says so, so a list that looks stalled
        // reads as ordered rather than stuck.
        (glyph, color, font) = ("⊘", .tertiaryLabelColor, .systemFont(ofSize: 11))
      case .pending, .completed:
        (glyph, color, font) = ("☐", .secondaryLabelColor, .systemFont(ofSize: 11))
      }
      if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
      result.append(
        NSAttributedString(
          string: "\(glyph)\t\(task.subject)",
          attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
    }
    return result
  }

  /// The header is the disclosure — the whole of it, not a chevron to hit. A click inside the
  /// opened list never arrives here: the text view takes it, so the list stays selectable.
  override func mouseDown(with event: NSEvent) {
    onToggle()
  }

  override func resetCursorRects() {
    addCursorRect(convert(header.bounds, from: header), cursor: .pointingHand)
  }
}
