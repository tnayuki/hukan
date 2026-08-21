import AppKit

// MARK: - Middle: what is running (transcript / terminal)

/// Approvals are never modal. A modal hides the other sessions, which defeats the point
/// of watching them in parallel.
/// A plan shown inside the approval card: the markdown rendered into a real, scrollable text view
/// (which the transcript's own NSTextView cannot host — macOS never realizes attachment views, see
/// the charter — but a card is a plain view, so it can). Grows to fit a short plan and caps at
/// `maxHeight`, scrolling internally past that, so a long plan reads in place without shoving the
/// composer off screen.
final class PlanBox: NSView {
  private let attributedPlan: NSAttributedString
  private let maxHeight: CGFloat
  private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: maxHeight)

  init(plan: String, maxHeight: CGFloat = 200) {
    attributedPlan = Transcript.markdown(plan)
    self.maxHeight = maxHeight
    let (scrollView, textView) = makeTranscriptTextView()
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.separatorColor.cgColor
    textView.textStorage?.setAttributedString(attributedPlan)
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scrollView)
    _ = scrollView.pin(to: self)
    heightConstraint.isActive = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    // makeTranscriptTextView's inset is 14, lineFragmentPadding the default 5.
    let width = bounds.width - (14 * 2 + 5 * 2)
    guard width > 1 else { return }
    let rect = attributedPlan.boundingRect(
      with: NSSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading])
    let target = min(ceil(rect.height) + 12 * 2, maxHeight)
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
      let box = PlanBox(plan: plan)
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
final class QuestionCard: NSView {
  private let onAnswer: (String?) -> Void
  private let optionLabels: [String]

  init(question: PendingQuestion, onAnswer: @escaping (String?) -> Void) {
    self.onAnswer = onAnswer
    let current = question.current
    self.optionLabels = current.options.map(\.label)
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
      rows.append(optionView(option, index: index))
    }
    let skip = NSButton(title: "Skip", target: self, action: #selector(skipClicked))
    skip.bezelStyle = .rounded
    skip.controlSize = .small

    let stack = NSStackView(views: rows + [skip])
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

  private func optionView(_ option: QuestionOption, index: Int) -> NSView {
    let button = NSButton(title: option.label, target: self, action: #selector(optionClicked(_:)))
    button.bezelStyle = .rounded
    button.tag = index
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    guard !option.description.isEmpty else { return button }
    let description = NSTextField(wrappingLabelWithString: option.description)
    description.font = .systemFont(ofSize: 11)
    description.textColor = .secondaryLabelColor
    description.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let group = NSStackView(views: [button, description])
    group.orientation = .vertical
    group.alignment = .leading
    group.spacing = 2
    return group
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func optionClicked(_ sender: NSButton) {
    guard optionLabels.indices.contains(sender.tag) else { return }
    onAnswer(optionLabels[sender.tag])
  }
  @objc private func skipClicked() { onAnswer(nil) }
}
