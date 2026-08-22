import AppKit

// MARK: - Shared pieces

extension NSView {
  @discardableResult
  func pin(to other: NSView, insets: NSEdgeInsets = NSEdgeInsets()) -> [NSLayoutConstraint] {
    translatesAutoresizingMaskIntoConstraints = false
    let constraints = [
      leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
      trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
      topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
      bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
    ]
    NSLayoutConstraint.activate(constraints)
    return constraints
  }
}

/// The header strip at the top of a column, with a hairline separator beneath it.
/// The rail's and the panel's field: one field, two operations told apart by the gesture that
/// runs them. Its placeholder names the one typing runs — filter — and `onFocusChange` lets the
/// column say what Return escalates to for as long as the field holds the focus that makes
/// Return mean anything.
///
/// The hint is not the placeholder, and cannot be: a placeholder assigned after the field is
/// built never takes on Tahoe's search field, which is a SwiftUI view underneath (measured, both
/// synchronously and a runloop later). It is not the field's own subview either — the field is a
/// toolbar item sized to its column, with no room to spare.
final class GestureSearchField: NSSearchField {
  var onFocusChange: ((Bool) -> Void)?

  override func becomeFirstResponder() -> Bool {
    let took = super.becomeFirstResponder()
    if took { onFocusChange?(true) }
    return took
  }

  override func textDidEndEditing(_ notification: Notification) {
    super.textDidEndEditing(notification)
    onFocusChange?(false)
  }
}

final class HeaderBar: NSView {
  /// A double-click on the bar itself — what the desk's tab strip carries, for a column whose
  /// tabs are one conversation. Nil where the gesture means nothing (the commit tab's header),
  /// which is also what keeps the bar from swallowing a click nobody handles.
  var onDoubleClick: (() -> Void)?

  init(views: [NSView], trailing: [NSView] = []) {
    super.init(frame: .zero)
    var arranged = views
    if !trailing.isEmpty {
      let spacer = NSView()
      spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
      spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      arranged.append(spacer)
      arranged.append(contentsOf: trailing)
    }
    let content = NSStackView(views: arranged)
    content.orientation = .horizontal
    content.alignment = .centerY
    content.spacing = 8
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)

    let hairline = NSBox()
    hairline.boxType = .custom
    hairline.borderWidth = 0
    hairline.fillColor = .separatorColor
    hairline.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hairline)

    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      trailing.isEmpty
        ? content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
        : content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      content.centerYAnchor.constraint(equalTo: centerYAnchor),
      heightAnchor.constraint(equalToConstant: 36),
      hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
      hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
      hairline.heightAnchor.constraint(equalToConstant: 1),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  /// A label is an NSControl too, and one that is neither editable nor selectable swallows the
  /// click it was handed instead of passing it on — so the title and the two figures beside it
  /// would be dead stripes across the gesture. They are treated as the bar itself; anything with
  /// something of its own to do with a click (the pickers, the commit tab's field) keeps it.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    guard onDoubleClick != nil, let label = hit as? NSTextField, !label.isEditable,
      !label.isSelectable
    else { return hit }
    return self
  }

  /// Only clicks that miss the pickers land here — never one on a picker that is about to open
  /// a menu.
  override func mouseDown(with event: NSEvent) {
    guard let onDoubleClick, event.clickCount == 2 else { return super.mouseDown(with: event) }
    onDoubleClick()
  }
}

/// A borderless, icon-led picker for a column header. It always shows an SF Symbol standing for
/// its dimension (model / permission mode / effort) and shows the selected value as text only
/// when that value departs from the default — so an all-default session reads as a row of quiet
/// glyphs rather than "Default Auto Default" eating the header strip. A click pops the choices as
/// a menu, giving the same single-selection an NSPopUpButton would, but without a combo box's
/// bezel or its always-visible title.
final class HeaderPicker: NSButton {
  /// Fires with the chosen index when the user picks from the menu.
  var onSelect: ((Int) -> Void)?

  private let symbolName: String
  private var titles: [String] = []
  private var selectedIndex = 0
  /// The index whose value is the default; its text is suppressed (glyph only) while it is current.
  private var defaultIndex = 0

  init(symbol: String) {
    symbolName = symbol
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    isBordered = false
    imagePosition = .imageLeft
    font = .systemFont(ofSize: 11)
    // A departed-from-default value truncates its own text rather than pushing the header wider;
    // the header pins its trailing edge, so the session title yields first.
    (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    target = self
    action = #selector(pop)
    refreshDisplay()
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Replace the choice list. `defaultAt` is the index whose value is "default" — the one shown as
  /// a glyph alone. Selection resets to that default; call `select` afterwards to reflect state.
  func setTitles(_ titles: [String], defaultAt: Int) {
    self.titles = titles
    defaultIndex = titles.indices.contains(defaultAt) ? defaultAt : 0
    selectedIndex = defaultIndex
    refreshDisplay()
  }

  func select(_ index: Int) {
    guard titles.indices.contains(index) else { return }
    selectedIndex = index
    refreshDisplay()
  }

  private func refreshDisplay() {
    image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    if titles.isEmpty || selectedIndex == defaultIndex {
      // Default value: the glyph alone carries it, no word.
      title = ""
      imagePosition = .imageOnly
      contentTintColor = .secondaryLabelColor
    } else {
      // A value away from default earns full-strength text so it reads as a deliberate choice.
      title = titles[selectedIndex]
      imagePosition = .imageLeft
      contentTintColor = .labelColor
    }
  }

  @objc private func pop() {
    guard !titles.isEmpty else { return }
    let menu = NSMenu()
    for (index, title) in titles.enumerated() {
      let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
      item.target = self
      item.tag = index
      item.state = index == selectedIndex ? .on : .off
      menu.addItem(item)
    }
    menu.popUp(
      positioning: menu.item(at: selectedIndex), at: NSPoint(x: 0, y: bounds.height), in: self)
  }

  @objc private func choose(_ sender: NSMenuItem) {
    select(sender.tag)
    onSelect?(sender.tag)
  }
}

/// Shown when there is nothing to display.
final class EmptyStateView: NSView {
  init(symbol: String, title: String, message: String, actionTitle: String?, action: Selector?) {
    super.init(frame: .zero)

    let image = NSImageView()
    image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    image.symbolConfiguration = .init(pointSize: 38, weight: .light)
    image.contentTintColor = .tertiaryLabelColor

    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    titleLabel.textColor = .secondaryLabelColor

    let messageLabel = NSTextField(wrappingLabelWithString: message)
    messageLabel.font = .systemFont(ofSize: 12)
    messageLabel.textColor = .tertiaryLabelColor
    messageLabel.alignment = .center
    messageLabel.preferredMaxLayoutWidth = 260

    var views: [NSView] = [image, titleLabel, messageLabel]
    if let actionTitle, let action {
      let button = NSButton(title: actionTitle, target: nil, action: action)
      button.bezelStyle = .rounded
      views.append(button)
    }

    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8
    stack.setCustomSpacing(16, after: image)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }
}

let monospace = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

/// Match the diff view's colors. Monochrome digits are far harder to read at a glance.
func diffstatText(added: Int, removed: Int, size: CGFloat = 10) -> NSAttributedString {
  let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
  let text = NSMutableAttributedString()
  if added > 0 {
    text.append(
      NSAttributedString(
        string: "+\(added)", attributes: [.foregroundColor: NSColor.systemGreen, .font: font]))
  }
  if removed > 0 {
    if added > 0 { text.append(NSAttributedString(string: " ", attributes: [.font: font])) }
    text.append(
      NSAttributedString(
        string: "−\(removed)", attributes: [.foregroundColor: NSColor.systemRed, .font: font]))
  }
  return text
}

extension RunState {
  var symbolName: String {
    switch self {
    case .idle: return "checkmark.circle.fill"
    // A solid blue dot, distinct from the green check and orange !, so "thinking" reads at a
    // glance even in the instant between the pulse animation's restarts on a rail rebuild.
    case .running: return "circle.fill"
    case .needsAttention: return "exclamationmark.circle.fill"
    case .signedOut: return "person.crop.circle.badge.exclamationmark"
    // A crossed-out circle, distinct from both the green check and the signed-out badge, so a
    // failed turn reads as a failure and not a "done".
    case .failed: return "xmark.circle.fill"
    }
  }

  var tint: NSColor {
    switch self {
    case .idle: return .systemGreen
    case .running: return .systemBlue
    case .needsAttention: return .systemOrange
    case .signedOut: return .systemRed
    case .failed: return .systemRed
    }
  }

  var label: String {
    switch self {
    case .idle: return "done"
    case .running: return "thinking"
    case .needsAttention: return "needs you"
    case .signedOut: return "signed out"
    case .failed: return "failed"
    }
  }
}

extension NSView {
  /// A slow opacity breathe, used to mark a session that is actively thinking. An explicit
  /// layer animation rather than an SF Symbol effect: the symbol effect never reliably started
  /// here (the view is handed the effect before it is in a window), whereas this animates as
  /// soon as the layer draws. The guard keeps a sustained pulse smooth — re-applying the same
  /// animation every reload would reset it to full opacity each time.
  func setThinkingPulse(_ on: Bool) {
    wantsLayer = true
    let key = "thinkingPulse"
    if on {
      guard layer?.animation(forKey: key) == nil else { return }
      let pulse = CABasicAnimation(keyPath: "opacity")
      pulse.fromValue = 1.0
      pulse.toValue = 0.25
      pulse.duration = 0.6
      pulse.autoreverses = true
      pulse.repeatCount = .infinity
      pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer?.add(pulse, forKey: key)
    } else {
      layer?.removeAnimation(forKey: key)
    }
  }
}
