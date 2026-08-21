import AppKit

final class RunningColumnViewController: NSViewController {
  var workspace: Workspace?

  private let tabs = NSSegmentedControl()
  /// Names the conversation on screen, so the pane says what it is rather than leaving you to
  /// read it off the rail selection. The toolbar carries the worktree (repo/branch); this
  /// carries the session, which is the other half — what the agent is actually working on.
  private let titleLabel = NSTextField(labelWithString: "")
  /// The session's estimated cost, sitting at the trailing edge of the header. A subscription
  /// bills no dollars, so this is the "if it were API-metered" figure (see `AgentSession.costUSD`).
  /// Empty (and so invisible) until a session with priceable usage is on screen.
  private let costLabel = NSTextField(labelWithString: "")
  private let scrollView: NSScrollView
  private let textView: NSTextView
  private let input = ComposerInput()
  var inputField: NSView { input.focusTarget }
  private let bottomArea = NSView()
  private let body = NSView()
  /// Pins the top of the composer stack; swapped to sit below the approval card when one shows.
  private var inputTopConstraint: NSLayoutConstraint!
  /// The decision card above the composer: an approval or an AskUserQuestion, whichever is up.
  private var approvalCard: NSView?
  private var emptyState: EmptyStateView?

  /// A "Thinking" indicator floating at the foot of the transcript, centred — the conversation
  /// itself shows the agent is working, which the composer's corner never managed to say
  /// legibly. Shown while a turn is actually in flight; the pulsing dot inside it comes from
  /// `setThinkingPulse`.
  private let thinkingPill = ArrowCursorView()
  private let thinkingDot = NSImageView()

  /// Shown when new transcript content arrived while you were scrolled up reading — so the view
  /// never yanks you to the bottom mid-read, but you can still see something came in and jump
  /// down. Hidden whenever you are already at (or scroll back to) the bottom.
  private let jumpButton = NSView()
  /// The jump pill's two homes: at the foot of the transcript normally, or riding just above
  /// the thinking pill when that is showing — both are bottom-centre, so they would collide.
  private var jumpAtBottom: NSLayoutConstraint!
  private var jumpAbovePill: NSLayoutConstraint!
  /// How near the bottom still counts as "pinned", in points. A turn's own layout jitter and the
  /// reserved thinking strip mean the clip rarely sits exactly at the end.
  private static let pinTolerance: CGFloat = 24

  /// Per-session controls, sitting in the header next to the cost. Model, mode and effort are
  /// decisions made while looking at this one agent's conversation, so they live on its header
  /// rather than in an app menu — and above the field, not stacked over it. Each is an icon-led
  /// `HeaderPicker` that spells its value only when it leaves the default, so the header does not
  /// carry "Default Auto Default" at rest.
  private let modelPicker = HeaderPicker(symbol: "sparkles")
  private let modePicker = HeaderPicker(symbol: "shield.lefthalf.filled")
  private let effortPicker = HeaderPicker(symbol: "gauge.medium")
  /// Reasoning effort choices. `default` passes no `--effort` (the model's own default).
  private let efforts: [(title: String, id: String)] = [
    ("Default", "default"), ("Low", "low"), ("Medium", "medium"),
    ("High", "high"), ("xHigh", "xhigh"), ("Max", "max"),
  ]
  /// Type-ahead lines waiting for the turn to end, shown so a queued message is never invisible.
  private let queuedStack = NSStackView()
  /// The bordered card the whole queue rides inside. Hidden, with the stack, when nothing waits.
  private let queuedCard = NSView()
  /// The card's top and bottom padding around the stack. Collapsed to zero while the queue is
  /// empty so the hidden card reserves no height above the field (a plain view's `isHidden`
  /// stops it drawing but not laying out); restored to `queuedCardPadding` once a line waits.
  private var queuedCardTopInset: NSLayoutConstraint!
  private var queuedCardBottomInset: NSLayoutConstraint!
  private let queuedCardPadding: CGFloat = 6
  /// Popup titles paired with the model id sent to the engine.
  /// Fallback model list, used only until the engine advertises its own roster. Kept to
  /// known-good aliases; the real list (Fable, 1M variants, the recommended default) arrives
  /// from the session's initialize reply.
  private let fallbackModels: [(title: String, id: String)] = [
    ("Default", "default"), ("Opus", "opus"), ("Sonnet", "sonnet"), ("Haiku", "haiku"),
  ]
  /// The model list currently in the popup — the engine roster if known, else the fallback.
  /// The change action reads the id from here, so it stays correct as the list is rebuilt.
  private var modelChoices: [(title: String, id: String)] = []

  init() {
    (scrollView, textView) = makeTranscriptTextView()
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func loadView() {
    tabs.segmentCount = 1
    tabs.setLabel("agent", forSegment: 0)
    tabs.selectedSegment = 0
    tabs.controlSize = .small
    // The tab bar is how you switch between the agent and this worktree's terminals. With no
    // terminals yet there is nothing to switch to, so a lone "agent" tab is just noise — hide
    // it until a terminal exists.
    tabs.isHidden = true

    input.translatesAutoresizingMaskIntoConstraints = false
    input.onSend = { [weak self] text, attachments in
      self?.attached?.send(text, attachments: attachments)
    }
    // Keep the attached session's unsent draft in step with the field, so switching sessions
    // swaps the text with the conversation and a restart puts it back (see `attach`).
    // Marking restorable state dirty on each edit is what makes a restart actually restore the
    // latest text: AppKit only re-encodes an invalidated window, so without this a draft typed
    // with no later invalidate before quit saves stale — "the input reverts a bit, sometimes".
    input.onChange = { [weak self] in
      guard let self else { return }
      self.attached?.draft = self.input.stringValue
      self.view.window?.invalidateRestorableState()
    }
    // Route the in-field stop through the same path as the old toolbar button, so an approval
    // on screen is escaped first and only then the turn is interrupted.
    input.onStop = { [weak self] in
      guard let self else { return }
      NSApp.sendAction(
        #selector(WorkspaceWindowController.interruptSession(_:)), to: nil, from: self)
    }

    // The model value ("Opus", a 1M variant) is the widest and least essential to read in full,
    // so it yields first when the header is tight.
    modelPicker.setContentCompressionResistancePriority(.init(rawValue: 240), for: .horizontal)
    modelPicker.onSelect = { [weak self] index in self?.selectModel(index) }
    modePicker.onSelect = { [weak self] index in self?.selectMode(index) }
    effortPicker.onSelect = { [weak self] index in self?.selectEffort(index) }
    // Mode and effort lists are fixed; the model list is filled from the session roster (or the
    // fallback) in refreshComposerAccessories, which also selects the value the session is on.
    // Auto is a fresh session's mode (AgentSession.defaultPermissionMode), so it is the quiet,
    // text-free state — the shield spells a mode only once it leaves that default.
    modePicker.setTitles(
      PermissionMode.allCases.map(\.label),
      defaultAt: PermissionMode.allCases.firstIndex(of: AgentSession.defaultPermissionMode) ?? 0)
    effortPicker.setTitles(
      efforts.map(\.title), defaultAt: efforts.firstIndex(where: { $0.id == "default" }) ?? 0)

    queuedStack.orientation = .vertical
    queuedStack.alignment = .leading
    queuedStack.spacing = 4
    queuedStack.translatesAutoresizingMaskIntoConstraints = false

    // The whole queue rides inside one bordered card — the same look the composer and the
    // approval/question cards carry — so however many lines are held, they read as a single
    // block waiting above the field rather than loose text. The card collapses (`isHidden`)
    // with the stack when nothing is queued.
    queuedCard.wantsLayer = true
    queuedCard.layer?.cornerRadius = 6
    queuedCard.layer?.borderWidth = 1
    queuedCard.layer?.borderColor = NSColor.separatorColor.cgColor
    queuedCard.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
    queuedCard.isHidden = true
    queuedCard.translatesAutoresizingMaskIntoConstraints = false
    queuedCard.addSubview(queuedStack)
    let insets = queuedStack.pin(
      to: queuedCard, insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6))
    queuedCardTopInset = insets[2]
    queuedCardBottomInset = insets[3]

    for child in [queuedCard, input] { bottomArea.addSubview(child) }
    // The composer stacks top-down: the queued type-ahead card, then the field. The
    // model/mode/effort controls now ride in the header (next to the cost), not here. The top
    // of this card is what the approval card displaces, so it is the tracked one.
    inputTopConstraint = queuedCard.topAnchor.constraint(
      equalTo: bottomArea.topAnchor, constant: 10)
    NSLayoutConstraint.activate([
      queuedCard.leadingAnchor.constraint(equalTo: bottomArea.leadingAnchor, constant: 12),
      queuedCard.trailingAnchor.constraint(equalTo: bottomArea.trailingAnchor, constant: -12),
      inputTopConstraint,

      input.leadingAnchor.constraint(equalTo: bottomArea.leadingAnchor, constant: 12),
      input.trailingAnchor.constraint(equalTo: bottomArea.trailingAnchor, constant: -12),
      input.topAnchor.constraint(equalTo: queuedCard.bottomAnchor, constant: 6),
      input.bottomAnchor.constraint(equalTo: bottomArea.bottomAnchor, constant: -12),
    ])

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    body.addSubview(scrollView)
    scrollView.pin(to: body)
    // A little breathing room under the last line, and somewhere for the jump pill to sit.
    // While the agent thinks, the strip deepens so the thinking pill floats below the last
    // line instead of over it (see refreshComposerAccessories).
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)

    // "Thinking" pill: floats bottom-centre at the foot of the transcript while a turn is in
    // flight — the state reads in the conversation itself, where the eye already is. Rounded,
    // bordered, on a near-opaque wash so it stays legible over the text edge.
    thinkingDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
    thinkingDot.contentTintColor = .systemBlue
    thinkingDot.symbolConfiguration = .init(pointSize: 7, weight: .semibold)
    let thinkingLabel = NSTextField(labelWithString: "Thinking")
    thinkingLabel.font = .systemFont(ofSize: 11, weight: .medium)
    thinkingLabel.textColor = .secondaryLabelColor
    let pillStack = NSStackView(views: [thinkingDot, thinkingLabel])
    pillStack.orientation = .horizontal
    pillStack.spacing = 5
    pillStack.translatesAutoresizingMaskIntoConstraints = false
    thinkingPill.wantsLayer = true
    thinkingPill.layer?.cornerRadius = 10
    thinkingPill.layer?.backgroundColor =
      NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
    thinkingPill.layer?.borderWidth = 1
    thinkingPill.layer?.borderColor = NSColor.separatorColor.cgColor
    thinkingPill.translatesAutoresizingMaskIntoConstraints = false
    thinkingPill.isHidden = true
    thinkingPill.addSubview(pillStack)
    pillStack.pin(to: thinkingPill, insets: NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10))
    body.addSubview(thinkingPill)
    NSLayoutConstraint.activate([
      thinkingPill.centerXAnchor.constraint(equalTo: body.centerXAnchor),
      thinkingPill.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -6),
    ])

    // "New below" pill: floats at the foot of the transcript, centered. Tapping it jumps to the
    // latest; it hides itself the moment you are back at the bottom (see transcriptScrolled /
    // scrollTranscriptToBottom). Built as a padded view rather than a button so the label and
    // arrow keep clear of the rounded ends.
    jumpButton.wantsLayer = true
    jumpButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    jumpButton.layer?.cornerRadius = 11
    let jumpLabel = NSTextField(labelWithString: "新着")
    jumpLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    jumpLabel.textColor = .white
    let jumpArrow = NSImageView()
    jumpArrow.image = NSImage(
      systemSymbolName: "arrow.down", accessibilityDescription: "Jump to latest")
    jumpArrow.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
    jumpArrow.contentTintColor = .white
    let jumpStack = NSStackView(views: [jumpLabel, jumpArrow])
    jumpStack.orientation = .horizontal
    jumpStack.spacing = 4
    jumpStack.translatesAutoresizingMaskIntoConstraints = false
    jumpButton.addSubview(jumpStack)
    jumpStack.pin(to: jumpButton, insets: NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 11))
    jumpButton.addGestureRecognizer(
      NSClickGestureRecognizer(target: self, action: #selector(jumpToBottomTapped)))
    jumpButton.translatesAutoresizingMaskIntoConstraints = false
    jumpButton.isHidden = true
    body.addSubview(jumpButton)
    // Both pills are bottom-centre, so the jump pill hops up above the thinking pill while
    // that is showing (the constraint pair is swapped in refreshComposerAccessories).
    jumpAtBottom = jumpButton.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -6)
    jumpAbovePill = jumpButton.bottomAnchor.constraint(
      equalTo: thinkingPill.topAnchor, constant: -6)
    NSLayoutConstraint.activate([
      jumpButton.centerXAnchor.constraint(equalTo: body.centerXAnchor),
      jumpAtBottom,
    ])

    // Watch the clip view so the pill self-hides once the reader returns to the bottom.
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(transcriptScrolled),
      name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = .labelColor
    titleLabel.lineBreakMode = .byTruncatingTail
    // The title truncates before the trailing controls do — a long session name must eat its own
    // tail, not push the model/mode/effort pickers off the header. So it sits below the pickers'
    // resistance (the model's is 240; the rest default-low at 250).
    titleLabel.setContentCompressionResistancePriority(.init(rawValue: 200), for: .horizontal)
    costLabel.font = .systemFont(ofSize: 11, weight: .regular)
    costLabel.textColor = .secondaryLabelColor
    costLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    let header = HeaderBar(
      views: [titleLabel], trailing: [costLabel, modelPicker, modePicker, effortPicker, tabs])
    let container = NSView()
    for child in [header, body, bottomArea] {
      child.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(child)
    }
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      header.topAnchor.constraint(equalTo: container.topAnchor),

      body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      body.topAnchor.constraint(equalTo: header.bottomAnchor),

      bottomArea.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      bottomArea.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      bottomArea.topAnchor.constraint(equalTo: body.bottomAnchor),
      bottomArea.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    view = container
  }

  /// The session on screen. The append hook is swapped per session, so track who that is.
  private weak var attached: AgentSession?

  /// The rail's active search terms, mirrored here so an opened session shows *where* it matched:
  /// every occurrence is background-highlighted and the view lands on the first one instead of the
  /// bottom. Set by the window whenever the query changes or a session is opened. Lowercased
  /// already (the match is case-insensitive regardless).
  var highlightTerms: [String] = []
  /// A translucent wash rather than an opaque find-yellow, so the transcript's own text colour
  /// stays legible over it in both light and dark — no foreground override to undo on clear.
  private static let matchHighlight = NSColor.systemYellow.withAlphaComponent(0.38)

  /// Re-highlight the current transcript for the live terms, scrolling to the first hit. Called
  /// when the query changes while a session is already open (no reattach, so `attach`'s own
  /// highlight pass does not run).
  func refreshHighlight() {
    loadViewIfNeeded()
    applyTranscriptHighlight(scrollToFirst: true)
  }

  /// What the last highlight pass painted: how many occurrences, and the character offset of the
  /// first (the one it scrolled to), or -1 when there is no match. Surfaced to scripting so the
  /// highlight is checkable without a screenshot — the app's screen-recording grant is not always
  /// there on an ad-hoc-signed dev build, and this proves the marking ran on the real transcript.
  private(set) var transcriptMatchCount = 0
  private(set) var transcriptFirstMatchOffset = -1

  /// A "jump to this offset" from a clicked search hit, held until the transcript is laid out. A
  /// just-opened detached session loads its history asynchronously, so the jump waits for
  /// `onReload` when the text is not there yet.
  private var pendingScrollOffset: Int?
  private var pendingScrollLength = 0

  /// Jump the transcript to a search hit: select the occurrence and scroll it into view. Deferred
  /// via `pendingScrollOffset` when the session's transcript has not loaded yet.
  func jumpToOffset(_ offset: Int, length: Int) {
    loadViewIfNeeded()
    pendingScrollOffset = offset
    pendingScrollLength = length
    applyPendingScroll()
  }

  /// Consume the pending jump once the storage covers it. Left pending (an early return) when the
  /// offset is past the current text — the history has not landed — so `onReload` can retry.
  @discardableResult
  private func applyPendingScroll() -> Bool {
    guard let offset = pendingScrollOffset, let storage = textView.textStorage else { return false }
    let length = max(1, pendingScrollLength)
    guard offset >= 0, offset + length <= storage.length else { return false }
    pendingScrollOffset = nil
    let range = NSRange(location: offset, length: length)
    if let layout = textView.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
    textView.setSelectedRange(range)
    textView.scrollRangeToVisible(range)
    jumpButton.isHidden = true
    return true
  }

  /// Paint `highlightTerms` across the view's storage and, when asked, bring the first match into
  /// view. Returns whether it scrolled to a match, so the caller can fall back to the bottom when
  /// there is nothing to jump to. View-only: it never touches the session's transcript, and the
  /// wash rides in `.backgroundColor`, which the transcript's own block fills (a private key) do
  /// not use — so clearing is a plain attribute removal, and the next reload wipes it anyway.
  @discardableResult
  private func applyTranscriptHighlight(scrollToFirst: Bool) -> Bool {
    transcriptMatchCount = 0
    transcriptFirstMatchOffset = -1
    guard let storage = textView.textStorage else { return false }
    let whole = NSRange(location: 0, length: storage.length)
    storage.removeAttribute(.backgroundColor, range: whole)
    guard !highlightTerms.isEmpty, storage.length > 0 else { return false }

    let text = storage.string as NSString
    var firstMatch: NSRange?
    for term in highlightTerms where !term.isEmpty {
      var scan = NSRange(location: 0, length: text.length)
      while scan.length > 0 {
        let found = text.range(of: term, options: .caseInsensitive, range: scan)
        guard found.location != NSNotFound else { break }
        storage.addAttribute(.backgroundColor, value: Self.matchHighlight, range: found)
        transcriptMatchCount += 1
        if firstMatch == nil || found.location < firstMatch!.location { firstMatch = found }
        let next = found.location + max(found.length, 1)
        scan = NSRange(location: next, length: text.length - next)
      }
    }

    guard let first = firstMatch else { return false }
    transcriptFirstMatchOffset = first.location
    if scrollToFirst {
      if let layout = textView.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
      textView.scrollRangeToVisible(first)
      jumpButton.isHidden = true
    }
    return true
  }

  private func attach(_ session: AgentSession?) {
    guard attached !== session else { return }
    // The draft belongs to the session being left, not the one arriving — snapshot it before
    // the field is repointed, then load the incoming session's own.
    attached?.draft = input.stringValue
    attached?.onAppend = nil
    attached?.onReload = nil
    attached?.onReplace = nil
    attached?.onEdit = nil
    attached = session
    // A different session invalidates any jump aimed at the previous one; a hit-click sets a
    // fresh one after this reload (see the window's onSelectMatch).
    pendingScrollOffset = nil
    // Fold toggles route through the session so its transcript and this storage stay at
    // identical offsets (see TranscriptClickDelegate).
    transcriptClickDelegate(of: textView)?.mirror = session
    input.stringValue = session?.draft ?? ""
    textView.textStorage?.setAttributedString(session?.transcript ?? NSAttributedString())
    // New content follows the reader only when they are already at the bottom. Scrolled up,
    // the view stays put and the "新着" pill appears instead — the pinned state is read before
    // the mutation, since appending is what moves the bottom.
    session?.onAppend = { [weak self] fragment in
      guard let self else { return }
      let wasPinned = self.isTranscriptPinnedToBottom
      self.textView.textStorage?.append(fragment)
      if wasPinned { self.scrollTranscriptToBottom() } else { self.jumpButton.isHidden = false }
    }
    session?.onReplace = { [weak self] range, formatted in
      guard let self, let storage = self.textView.textStorage,
        NSMaxRange(range) <= storage.length
      else { return }
      let wasPinned = self.isTranscriptPinnedToBottom
      storage.replaceCharacters(in: range, with: formatted)
      if wasPinned { self.scrollTranscriptToBottom() } else { self.jumpButton.isHidden = false }
    }
    session?.onEdit = { [weak self] range, replacement in
      guard let self, let storage = self.textView.textStorage,
        NSMaxRange(range) <= storage.length
      else { return }
      storage.replaceCharacters(in: range, with: replacement)
    }
    // A wholesale reload (history loaded, or an outside change) is like reopening the session:
    // land at the bottom — or, under an active search, on the first match instead (a detached
    // session's history arrives here, so this is where the highlight first has text to land on).
    session?.onReload = { [weak self, weak session] in
      guard let self, let session, self.attached === session else { return }
      self.textView.textStorage?.setAttributedString(session.transcript)
      // A pending hit-jump wins over scroll-to-first-match, which wins over the bottom.
      let hasJump = self.pendingScrollOffset != nil
      let matched = self.applyTranscriptHighlight(scrollToFirst: !hasJump)
      if hasJump {
        self.applyPendingScroll()
      } else if !matched {
        self.scrollTranscriptToBottom(ensuringLayout: true)
      }
    }
    let hasJump = pendingScrollOffset != nil
    let matched = applyTranscriptHighlight(scrollToFirst: !hasJump)
    if hasJump {
      applyPendingScroll()
    } else if !matched {
      scrollTranscriptToBottom(ensuringLayout: true)
    }

    // Opening a session is what pulls its history off disk.
    if let session, let worktree = workspace?.worktree(id: session.worktreeID) {
      session.loadHistoryIfNeeded(at: worktree.url)
    }
  }

  /// Whether the transcript is scrolled to (or within `pinTolerance` of) the bottom. The text
  /// view is flipped, so the latest content sits at the largest y; "at the bottom" is the clip's
  /// origin having reached the furthest it can scroll. Content shorter than the view is always
  /// pinned.
  private var isTranscriptPinnedToBottom: Bool {
    guard let document = scrollView.documentView else { return true }
    let clip = scrollView.contentView
    let maxOriginY = document.bounds.height + scrollView.contentInsets.bottom - clip.bounds.height
    if maxOriginY <= 0 { return true }
    return clip.bounds.origin.y >= maxOriginY - Self.pinTolerance
  }

  /// Scroll so the latest content is visible. `ensuringLayout` forces the whole document to lay
  /// out first: right after a bulk `setAttributedString` (opening a session, a reload) TextKit 2
  /// has laid out almost nothing, so `scrollToEndOfDocument` would stop at the end of that little
  /// — near the top of a long transcript, which is the "restart lands up high" bug. Streaming
  /// appends skip it: they lay out near the bottom already, and forcing a full pass per token
  /// would be O(n²).
  private func scrollTranscriptToBottom(ensuringLayout: Bool = false) {
    if ensuringLayout, let layout = textView.textLayoutManager {
      layout.ensureLayout(for: layout.documentRange)
    }
    textView.scrollToEndOfDocument(nil)
    jumpButton.isHidden = true
  }

  @objc private func jumpToBottomTapped() {
    scrollTranscriptToBottom()
  }

  /// The reader scrolled; drop the pill once they are back at the bottom (whether by this scroll
  /// or by tapping the pill, which scrolls there).
  @objc private func transcriptScrolled() {
    if isTranscriptPinnedToBottom { jumpButton.isHidden = true }
  }

  /// The header's cost figure: `$1.23`, `<$0.01` for a nonzero sub-cent estimate, empty (hidden)
  /// when there is no estimate (no session, unknown model, nothing sent yet). A `~` prefix marks
  /// an approximate total — one where a message on a model we can't price was omitted.
  private static func formatCost(_ cost: Double?, approximate: Bool) -> String {
    guard let cost, cost > 0 else { return "" }
    let prefix = approximate ? "~" : ""
    if cost < 0.01 { return "\(prefix)<$0.01" }
    return String(format: "\(prefix)$%.2f", cost)
  }

  private static let tokenFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter
  }()

  /// The token breakdown behind the cost, for the header label's tooltip — the counts the dollar
  /// figure is derived from. Nil (no tooltip) when there is nothing to show.
  private static func costTooltip(_ tokens: ClaudeSessionStore.TokenTotals?) -> String? {
    guard let tokens, !tokens.isEmpty else { return nil }
    func n(_ value: Int) -> String { tokenFormatter.string(from: value as NSNumber) ?? "\(value)" }
    return """
      Input \(n(tokens.input))
      Output \(n(tokens.output))
      Cache read \(n(tokens.cacheRead))
      Cache write \(n(tokens.cacheWrite))
      """
  }

  func reload() {
    loadViewIfNeeded()

    approvalCard?.removeFromSuperview()
    approvalCard = nil
    emptyState?.removeFromSuperview()
    emptyState = nil
    inputTopConstraint.isActive = true

    guard let workspace, let worktreeID = workspace.selectedWorktreeID,
      workspace.worktree(id: worktreeID) != nil
    else {
      attach(nil)
      scrollView.isHidden = true
      bottomArea.isHidden = true
      let empty = EmptyStateView(
        symbol: "square.stack.3d.up",
        title: "No repositories yet",
        message: "Add a repository to start running agents in its worktrees.",
        actionTitle: "Open Repository…",
        action: #selector(WorkspaceWindowController.openRepository(_:)))
      empty.translatesAutoresizingMaskIntoConstraints = false
      body.addSubview(empty)
      empty.pin(to: body)
      emptyState = empty
      return
    }

    scrollView.isHidden = false
    bottomArea.isHidden = false

    let terminals = workspace.terminals(inWorktree: worktreeID)
    tabs.isHidden = terminals.isEmpty
    tabs.segmentCount = 1 + terminals.count
    tabs.setLabel("agent", forSegment: 0)
    for (index, terminal) in terminals.enumerated() {
      tabs.setLabel(terminal.title, forSegment: index + 1)
    }
    if tabs.selectedSegment < 0 { tabs.selectedSegment = 0 }

    attach(workspace.selectedSession)
    input.isEnabled = attached != nil
    titleLabel.stringValue =
      attached?.title
      ?? (workspace.selectedSession == nil
        ? workspace.worktree(id: worktreeID)?.displayName ?? "" : "New session")
    costLabel.stringValue = Self.formatCost(
      attached?.costUSD, approximate: attached?.costApproximate ?? false)
    costLabel.toolTip = Self.costTooltip(attached?.costTokens)
    refreshComposerAccessories()

    // Only the session on screen, since the card sits above its own composer. Decisions
    // waiting in other sessions show as a badge in the rail and are reached with Cmd+Return.
    guard let session = attached else { return }
    let card: NSView
    if let question = session.pendingQuestion {
      card = QuestionCard(question: question) { [weak session] answer in
        session?.answerQuestion(answer)
      }
    } else if let approval = session.pendingApproval {
      card = ApprovalCard(approval: approval) { [weak session] allow in
        session?.resolveApproval(allow: allow)
      }
    } else {
      return
    }
    card.translatesAutoresizingMaskIntoConstraints = false
    bottomArea.addSubview(card)
    inputTopConstraint.isActive = false
    NSLayoutConstraint.activate([
      card.leadingAnchor.constraint(equalTo: bottomArea.leadingAnchor, constant: 12),
      card.trailingAnchor.constraint(equalTo: bottomArea.trailingAnchor, constant: -12),
      card.topAnchor.constraint(equalTo: bottomArea.topAnchor, constant: 10),
      queuedCard.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 8),
    ])
    approvalCard = card
  }

  /// Mirror the attached session's model, mode and queue into the composer controls. Called
  /// from `reload`, which runs on every state change, so the queue and a live mode switch both
  /// stay in step without their own observers.
  private func refreshComposerAccessories() {
    let session = attached
    modelPicker.isEnabled = session != nil
    modePicker.isEnabled = session != nil
    effortPicker.isEnabled = session != nil

    // The in-field stop shows for the whole turn — interrupt is meaningful throughout. The
    // thinking pill marks only the genuinely-working slice: `.running` excludes idle and the
    // fresh-but-unprompted session, and it is not the needs-you state (an approval card is up
    // then, not thinking).
    input.isRunning = session?.isTurnActive == true
    let thinking = session?.isTurnActive == true && session?.state == .running
    thinkingPill.isHidden = !thinking
    thinkingDot.setThinkingPulse(thinking)
    // The jump pill shares the bottom-centre spot; hop it above the thinking pill while that
    // is up. Deactivate both first — setting the new one active before the old is released
    // would leave the pair momentarily in conflict.
    jumpAtBottom.isActive = false
    jumpAbovePill.isActive = false
    (thinking ? jumpAbovePill : jumpAtBottom).isActive = true
    // Deepen the foot strip while the pill shows, so it floats below the last line instead of
    // over it. Only nudge the scroll when the reader is already pinned to the bottom — the
    // pill must never yank someone who is scrolled up reading.
    let reserved: CGFloat = thinking ? 38 : 10
    if scrollView.contentInsets.bottom != reserved {
      let wasPinned = isTranscriptPinnedToBottom
      scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: reserved, right: 0)
      if thinking, wasPinned { scrollTranscriptToBottom() }
    }

    // The engine roster if this session has connected, else the fallback aliases. Rebuild the
    // popup items only when the set changes, so an unrelated reload does not disturb it.
    let roster = session?.availableModels ?? []
    let choices =
      roster.isEmpty ? fallbackModels : roster.map { (title: $0.displayName, id: $0.value) }
    if choices.map(\.id) != modelChoices.map(\.id) {
      modelChoices = choices
      modelPicker.setTitles(
        choices.map(\.title), defaultAt: choices.firstIndex(where: { $0.id == "default" }) ?? 0)
    }
    if let session {
      // Show what is actually running: the engine's reported model (mapped from its resolved
      // id back to a roster value) when known, else the session's own model.
      let selectedModelID: String = {
        if let reported = session.reportedModel,
          let match = session.availableModels.first(where: {
            $0.resolvedModel == reported || $0.value == reported
          })
        {
          return match.value
        }
        return session.model
      }()
      if let index = modelChoices.firstIndex(where: { $0.id == selectedModelID }) {
        modelPicker.select(index)
      }
      if let index = PermissionMode.allCases.firstIndex(of: session.permissionMode) {
        modePicker.select(index)
      }
      if let index = efforts.firstIndex(where: { $0.id == session.effort }) {
        effortPicker.select(index)
      }
    }

    for view in queuedStack.arrangedSubviews { view.removeFromSuperview() }
    let queued = session?.queuedMessages ?? []
    for (index, text) in queued.enumerated() {
      let row = queuedRow(index: index, text: text)
      queuedStack.addArrangedSubview(row)
      // Activate the width match only once the row shares an ancestor with the stack,
      // i.e. after it is added — activating it inside queuedRow throws (no common ancestor).
      row.widthAnchor.constraint(equalTo: queuedStack.widthAnchor).isActive = true
    }
    queuedCard.isHidden = queued.isEmpty
    queuedCardTopInset.constant = queued.isEmpty ? 0 : queuedCardPadding
    queuedCardBottomInset.constant = queued.isEmpty ? 0 : -queuedCardPadding
  }

  /// One held type-ahead line: its text, then send-now / edit / delete. The buttons carry their
  /// index in `tag`; the rows are rebuilt on every queue change, so the tags never go stale.
  private func queuedRow(index: Int, text: String) -> NSView {
    let label = NSTextField(labelWithString: "⤷ " + text.replacingOccurrences(of: "\n", with: " "))
    label.font = .systemFont(ofSize: 13)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    // The label yields, so a long line truncates and the buttons keep their place.
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let send = queueButton(
      "paperplane.fill", tip: "Send now",
      action: #selector(queuedSendNow(_:)), index: index)
    let edit = queueButton(
      "pencil", tip: "Edit",
      action: #selector(queuedEdit(_:)), index: index)
    let delete = queueButton(
      "xmark", tip: "Delete",
      action: #selector(queuedDelete(_:)), index: index)

    let row = NSStackView(views: [label, send, edit, delete])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 2
    // The label absorbs the slack (it already hugs loosely), so the three buttons sit flush
    // against the trailing edge whatever the line's length — a fixed control cluster the eye
    // can go straight to, rather than trailing off wherever the text happens to end.
    row.distribution = .fill
    return row
  }

  private func queueButton(_ symbol: String, tip: String, action: Selector, index: Int) -> NSButton
  {
    let button = NSButton()
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
    button.symbolConfiguration = .init(pointSize: 10, weight: .regular)
    button.imagePosition = .imageOnly
    button.isBordered = false
    button.setButtonType(.momentaryChange)
    button.contentTintColor = .secondaryLabelColor
    button.target = self
    button.action = action
    button.tag = index
    button.toolTip = tip
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
  }

  @objc private func queuedSendNow(_ sender: NSButton) { attached?.sendQueuedNow(at: sender.tag) }
  @objc private func queuedDelete(_ sender: NSButton) { attached?.removeQueued(at: sender.tag) }

  @objc private func queuedEdit(_ sender: NSButton) {
    guard let text = attached?.takeQueued(at: sender.tag) else { return }
    // Reopen it in the composer, appending if something is already half-typed there.
    input.stringValue = input.stringValue.isEmpty ? text : input.stringValue + "\n" + text
    attached?.draft = input.stringValue  // the setter is programmatic, so mirror by hand
    // takeQueued already invalidated — but that fired *before* this draft change, and a
    // programmatic set does not run `onChange`. Without invalidating again the reopened text
    // saves stale, and the queued line it came from is already gone: quit here and it is lost.
    view.window?.invalidateRestorableState()
    view.window?.makeFirstResponder(input.focusTarget)
  }

  private func selectModel(_ index: Int) {
    guard let session = attached, modelChoices.indices.contains(index) else { return }
    session.setModel(modelChoices[index].id)
  }

  private func selectMode(_ index: Int) {
    let cases = PermissionMode.allCases
    guard let session = attached, cases.indices.contains(index) else { return }
    session.setPermissionMode(cases[index])
    // Persist the choice: encodeState reads it back off the live session at save time.
    view.window?.invalidateRestorableState()
  }

  private func selectEffort(_ index: Int) {
    guard let session = attached, efforts.indices.contains(index) else { return }
    session.setEffort(efforts[index].id)
    view.window?.invalidateRestorableState()
  }

}
