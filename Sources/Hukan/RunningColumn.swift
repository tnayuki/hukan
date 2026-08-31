import AppKit

final class RunningColumnViewController: NSViewController {
  var workspace: Workspace?

  /// Names the conversation on screen, so the pane says what it is rather than leaving you to
  /// read it off the rail selection. The toolbar carries the worktree (repo/branch); this
  /// carries the session, which is the other half — what the agent is actually working on.
  private let titleLabel = NSTextField(labelWithString: "")
  /// The session's estimated cost, sitting at the trailing edge of the header. A subscription
  /// bills no dollars, so this is the "if it were API-metered" figure (see `AgentSession.costUSD`).
  /// Empty (and so invisible) until a session with priceable usage is on screen.
  private let costLabel = NSTextField(labelWithString: "")
  /// How much of this session's context window is gone. Hidden until the engine has answered
  /// once — a session that has never connected has no window to be a fraction of.
  private let contextLabel = NSTextField(labelWithString: "")
  private let scrollView: NSScrollView
  private let textView: TranscriptTextView
  private let input = ComposerInput()
  var inputField: NSView { input.focusTarget }
  /// The composer itself, for the `completions` scripting verb.
  var composerForScripting: ComposerInput { input }
  private let bottomArea = NSView()
  private let body = NSView()
  /// Pins the top of the composer stack; swapped to sit below the approval card when one shows.
  private var inputTopConstraint: NSLayoutConstraint!
  /// The cards above the composer, top-down: the agent's task list, then whichever decision is
  /// up (an approval or an AskUserQuestion). The decision sits nearest the field because it is
  /// the one stopped on you; the task list is state, and stays out of the way above it.
  private var cards: [NSView] = []
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

  /// What the `…` on a message offers. The column only knows which session is on screen and where
  /// the message begins; branching and going back are the window's, which owns session creation
  /// and the confirmations.
  var onForkSession: ((AgentSession, String, NSRange) -> Void)?
  var onRollBackSession: ((AgentSession, String, NSRange) -> Void)?
  /// A link clicked in the transcript. The column knows a URL was pressed and nothing else —
  /// which worktree's desk it belongs on, and whether it belongs in hukan at all, is the
  /// window's, the way forking and rolling back are.
  var onOpenURL: ((URL) -> Bool)?
  /// Ask the window for the whole width, or to put the other columns back — the desk's
  /// `onSetMaximized` for the column beside it. The columns are the window's, so maximizing is
  /// asked for here, never done here.
  var onSetMaximized: ((Bool) -> Void)?

  /// Whether the window is showing this column alone right now. Set by the window controller once
  /// the columns have moved, and read back by the header's double-click so it knows which way it
  /// is toggling.
  var isMaximized = false

  init() {
    (scrollView, textView) = makeTranscriptTextView()
    super.init(nibName: nil, bundle: nil)
    // Set once, not per attached session: where a link goes does not depend on which
    // conversation is on screen (the mirror, set in `attach`, is the thing that does).
    transcriptClickDelegate(of: textView)?.onOpenURL = { [weak self] url in
      self?.onOpenURL?(url) ?? false
    }
    (textView as? TranscriptTextView)?.messageActions = [
      TranscriptTextView.MessageAction(title: "Fork Before This Message") {
        [weak self] anchor, range in
        guard let self, let session = self.attached else { return }
        self.onForkSession?(session, anchor, range)
      },
      TranscriptTextView.MessageAction(
        title: "Roll Back to Before This Message",
        isEnabled: { [weak self] in self?.attached?.canRollBack ?? false },
        perform: { [weak self] anchor, range in
          guard let self, let session = self.attached else { return }
          self.onRollBackSession?(session, anchor, range)
        }),
    ]
  }

  required init?(coder: NSCoder) { fatalError() }

  override func loadView() {
    input.translatesAutoresizingMaskIntoConstraints = false
    input.onSend = { [weak self] text, attachments in
      self?.attached?.send(text, attachments: attachments)
    }
    input.onSendEmpty = { [weak self] in self?.attached?.sendLastQueuedNow() }
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

    // Watch the clip view so the pill self-hides once the reader returns to the bottom, and so
    // the reader's place is recorded as a character offset before anything can relayout under it.
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(transcriptScrolled),
      name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    // The view says when it has re-wrapped — from its own layout, not a frame notification, which
    // `NSTextView` stops posting at the first live resize (see `onRewrap`).
    textView.onRewrap = { [weak self] in self?.putReaderBack() }

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
    contextLabel.font = .systemFont(ofSize: 11, weight: .regular)
    contextLabel.textColor = .secondaryLabelColor
    contextLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    // Beside the cost, not in the toolbar: both are this session's own consumption, while the
    // toolbar's two readings are the account's plan and the app's footprint. And it lands next
    // to the model picker, which is what you reach for when the window is filling up.
    let header = HeaderBar(
      views: [titleLabel],
      trailing: [contextLabel, costLabel, modelPicker, modePicker, effortPicker])
    // The header is to this column what the tab strip is to the desk: it names what is showing,
    // it survives the fold, and so it is where the maximize gesture goes. A conversation has no
    // preview state to leave, so the first double-click is already the maximize.
    header.onDoubleClick = { [weak self] in
      guard let self, self.attached != nil else { return }
      self.onSetMaximized?(!self.isMaximized)
    }
    let container = NSView()
    for child in [header, body, bottomArea] {
      child.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(child)
    }
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      // The column already hangs below the toolbar (`ToolbarInsetViewController`), so this is
      // the same as the top — kept as the safe area for the cases AppKit adds one anyway.
      header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),

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

  /// ⌘F and its family in the conversation, once the focus says the transcript is what is being
  /// read (see `WorkspaceWindowController.find`). Opening the bar pulls in everything the view is
  /// holding back first — the history above, which otherwise arrives a slice at a time as the
  /// reader climbs, and every folded tool call — because the bar can only find what is in the
  /// storage, and an answer drawn from part of a conversation is not the conversation's answer.
  func performFind(_ sender: Any?) {
    loadViewIfNeeded()
    guard NSFindPanelAction(rawValue: UInt((sender as? NSMenuItem)?.tag ?? 1)) == .showFindPanel
    else {
      textView.performFindPanelAction(sender)
      return
    }
    if let attached, attached.hasPendingPrefix {
      // The prefix lands asynchronously; `onPrepend` finishes the job when it does.
      unfoldsWhenPrefixLands = true
      attached.loadEarlierIfNeeded(all: true)
    } else {
      expandFolds()
    }
    view.window?.makeFirstResponder(textView)
    textView.performFindPanelAction(sender)
  }

  /// Set while the history above is being pulled in for a find, so the unfold runs once, after it.
  private var unfoldsWhenPrefixLands = false

  /// Open every folded tool call, leaving the reader where they were — the folds that opened
  /// above them move their offset, which is what `expandAllFolds` hands back. The rail's
  /// highlight is repainted because the wash sits in the storage the unfold just rewrote.
  private func expandFolds() {
    guard let delegate = transcriptClickDelegate(of: textView) else { return }
    let anchor = TranscriptScrollAnchor.capture(in: scrollView, of: textView)
    isRestoringAnchor = true
    let moved = delegate.expandAllFolds(in: textView, preserving: anchor?.offset ?? 0)
    if let anchor {
      TranscriptScrollAnchor(offset: moved, within: anchor.within)
        .restoreAfterPrefixGrowth(in: scrollView, of: textView)
    }
    isRestoringAnchor = false
    scrollAnchor = TranscriptScrollAnchor.capture(in: scrollView, of: textView)
    applyTranscriptHighlight(scrollToFirst: false)
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
  /// Where the reader is, as a character offset into the conversation. A scroll position in
  /// points names a different part of the text once the column has been re-wrapped, so this is
  /// what a width change has to leave alone — and the only way to assert that without pixels.
  var transcriptReaderOffset: Int {
    TranscriptScrollAnchor.capture(in: scrollView, of: textView)?.offset ?? 0
  }

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
    // The offset was measured against a full render (the rail searches the file, not the view),
    // so with history still unrendered above, the same number names a different character. Pull
    // the rest in — the jump retries from `onPrepend` when it lands.
    if let attached, attached.hasPendingPrefix {
      attached.loadEarlierIfNeeded(all: true)
      return false
    }
    let length = max(1, pendingScrollLength)
    guard offset >= 0, offset + length <= storage.length else { return false }
    pendingScrollOffset = nil
    let range = NSRange(location: offset, length: length)
    TranscriptScrollAnchor.layOutWholeDocument(of: textView)
    textView.setSelectedRange(range)
    textView.scrollRangeToVisible(range)
    recordReader(pinned: isTranscriptPinnedToBottom)
    jumpButton.isHidden = true
    return true
  }

  /// Whether the last pass left a wash in the storage. Clearing one touches every character, and
  /// an edit that wide relayouts the whole document — which moves a scrolled-up reader — so it
  /// must not run on a rail keystroke that has nothing to clear.
  private var hasPaintedHighlight = false

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
    if hasPaintedHighlight {
      storage.removeAttribute(.backgroundColor, range: whole)
      hasPaintedHighlight = false
    }
    guard !highlightTerms.isEmpty, storage.length > 0 else { return false }

    let text = storage.string as NSString
    var firstMatch: NSRange?
    for term in highlightTerms where !term.isEmpty {
      var scan = NSRange(location: 0, length: text.length)
      while scan.length > 0 {
        let found = text.range(of: term, options: .caseInsensitive, range: scan)
        guard found.location != NSNotFound else { break }
        storage.addAttribute(.backgroundColor, value: Self.matchHighlight, range: found)
        hasPaintedHighlight = true
        transcriptMatchCount += 1
        if firstMatch == nil || found.location < firstMatch!.location { firstMatch = found }
        let next = found.location + max(found.length, 1)
        scan = NSRange(location: next, length: text.length - next)
      }
    }

    guard let first = firstMatch else { return false }
    transcriptFirstMatchOffset = first.location
    if scrollToFirst {
      TranscriptScrollAnchor.layOutWholeDocument(of: textView)
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
    attached?.onPrepend = nil
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
    // Replacing the storage takes the wash with the text it rode on, so nothing is left to clear.
    hasPaintedHighlight = false
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
    // Earlier conversation arrived above the reader. Slide it in without moving them: capture
    // where they are first (the last scroll's anchor may already describe a mutated document),
    // insert, and put them back at the same character — now `inserted.length` further in. The
    // highlight pass re-runs so matches inside the new text get their wash too; it never
    // scrolls. Layout is bounded to the inserted slice (see `restoreAfterPrefixGrowth`), which
    // is what keeps a long upward scroll from re-buying the full-layout freeze slice by slice.
    session?.onPrepend = { [weak self] inserted in
      guard let self, let storage = self.textView.textStorage else { return }
      let anchor = TranscriptScrollAnchor.capture(in: self.scrollView, of: self.textView)
      self.isRestoringAnchor = true
      storage.insert(inserted, at: 0)
      self.applyTranscriptHighlight(scrollToFirst: false)
      if let anchor {
        TranscriptScrollAnchor(offset: anchor.offset + inserted.length, within: anchor.within)
          .restoreAfterPrefixGrowth(in: self.scrollView, of: self.textView)
      }
      self.isRestoringAnchor = false
      self.scrollAnchor = TranscriptScrollAnchor.capture(in: self.scrollView, of: self.textView)
      // A hit-jump that was waiting for the text above it may be satisfied now.
      self.applyPendingScroll()
      // ⌘F asked for the whole conversation and this was the rest of it; open its folds.
      if self.unfoldsWhenPrefixLands {
        self.unfoldsWhenPrefixLands = false
        self.expandFolds()
      }
    }
    // A wholesale reload (history loaded, or an outside change) is like reopening the session:
    // land at the bottom — or, under an active search, on the first match instead (a detached
    // session's history arrives here, so this is where the highlight first has text to land on).
    session?.onReload = { [weak self, weak session] in
      guard let self, let session, self.attached === session else { return }
      self.hasPaintedHighlight = false
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

    // Opening a session is what pulls its history off disk — and its task list, which is read
    // from the engine's store rather than restored from anything hukan saved. Unlike the
    // history this is not once-only: the store moves under a session nobody is watching (a
    // second window, an engine hukan does not own), so every open re-reads it.
    if let session, let worktree = workspace?.worktree(id: session.worktreeID) {
      session.loadHistoryIfNeeded(at: worktree.url)
      session.refreshTasks()
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
    if ensuringLayout { TranscriptScrollAnchor.layOutWholeDocument(of: textView) }
    textView.scrollToEndOfDocument(nil)
    recordReader(pinned: true)
    jumpButton.isHidden = true
  }

  @objc private func jumpToBottomTapped() {
    scrollTranscriptToBottom()
  }

  /// Where the reader is, as a character offset (see `TranscriptScrollAnchor`). Recorded on every
  /// scroll so it is always the pre-relayout truth by the time a relayout needs it — reading it
  /// afterwards would read a position the relayout has already moved.
  private var scrollAnchor: TranscriptScrollAnchor?
  /// Whether that scroll left the reader at the bottom. A relayout must send them back to the
  /// bottom, not to the line that happened to be at the top of the last viewport.
  private var anchorWasPinned = true
  /// Set while the anchor is being put back, so the scroll that does it is not mistaken for the
  /// reader's own and recorded over the anchor it is restoring.
  private var isRestoringAnchor = false
  /// The widths the reader was last placed or recorded at — the text's wrap width and the
  /// view's frame width, which under a live resize part company (see `TranscriptTextView`). Only
  /// a width change re-wraps the document, and so only a width change moves the reader's own
  /// text; an append grows the tail and leaves it alone.
  private var placedWidth: CGFloat = 0
  private var placedFrameWidth: CGFloat = 0

  /// Whether a scroll arriving now can be the reader's. Not while the anchor is being put back,
  /// and not while the view is between widths: the text is still wrapped to a width the reader
  /// was never placed at, or the frame has moved and the text has yet to follow it — and
  /// `NSTextView` answers the frame's move on its own, by re-estimating its height and shifting
  /// the viewport by what it thinks moved, a scroll nobody asked for that lands before the
  /// container has changed at all.
  private var isReaderScroll: Bool {
    !isRestoringAnchor && textView.wrapWidth == placedWidth
      && textView.frame.width == placedFrameWidth
  }

  /// The reader scrolled; drop the pill once they are back at the bottom (whether by this scroll
  /// or by tapping the pill, which scrolls there), and remember where they are in the text.
  @objc private func transcriptScrolled() {
    // A re-wrap arrives here as a scroll nobody asked for: the document is re-measured under the
    // clip view, which clamps its origin to the height it currently claims, and the view shifts
    // its viewport by what it estimates moved — and recording either would overwrite the very
    // place being restored to. Everything between one width and the next is the layout's own
    // doing (`isReaderScroll`); `putReaderBack` follows it, and the deliberate placements record
    // themselves (`recordReader`).
    guard isReaderScroll else { return }
    let pinned = isTranscriptPinnedToBottom
    if pinned { jumpButton.isHidden = true }
    recordReader(pinned: pinned)
    // Nearing the top of a tail-loaded transcript is the ask for what comes before it: within
    // two viewports, so the next slice is usually in place before the reader arrives. The
    // session ignores the call when nothing is pending or a load is already running.
    if scrollView.documentVisibleRect.minY < scrollView.contentView.bounds.height * 2 {
      attached?.loadEarlierIfNeeded()
    }
  }

  /// The transcript has been re-wrapped, so the clip view's point offset now names a different
  /// part of the conversation — put the reader back on their own text (or at the bottom, if that
  /// is where they were). Once per width the text is actually laid out at, which under a live
  /// resize is fewer times than the frame changes (see `TranscriptTextView.onRewrap`) — and each
  /// time the whole document is laid out and the view sized to it before the scroll, or the
  /// clip view clamps the scroll to a height that is still the old width's.
  private func putReaderBack() {
    isRestoringAnchor = true
    if anchorWasPinned {
      scrollTranscriptToBottom(ensuringLayout: true)
    } else {
      scrollAnchor?.restore(in: scrollView, of: textView)
    }
    isRestoringAnchor = false
    placedWidth = textView.wrapWidth
    placedFrameWidth = textView.frame.width
  }

  /// Where the reader now is, taken as theirs. The scroll notification is one way here; a
  /// deliberate placement — a jump to a search hit, a trip to the bottom — is the other, and it
  /// says so itself rather than waiting for a notification a re-wrap would have to swallow.
  private func recordReader(pinned: Bool) {
    anchorWasPinned = pinned
    scrollAnchor = TranscriptScrollAnchor.capture(in: scrollView, of: textView)
    placedWidth = textView.wrapWidth
    placedFrameWidth = textView.frame.width
  }

  /// The header's cost figure: `$1.23`, `<$0.01` for a nonzero sub-cent estimate, empty (hidden)
  /// when there is no estimate (no session, unknown model, nothing sent yet). A `~` prefix marks
  /// an approximate total — one where a message on a model we can't price was omitted.
  /// The context gauge: a dial glyph and the percentage, the same icon-and-digits idiom the
  /// toolbar's plan usage uses for the other budget being spent. No words — what it means is in
  /// the tooltip, which is where the toolbar puts its own.
  ///
  /// Amber past three quarters and red past nine tenths. The window is not a limit you are
  /// warned about and then stopped at — it compacts, and a compaction is the agent forgetting
  /// the middle of the conversation — so the point of the colour is to be noticed while
  /// `/compact` on your own terms, a fork, or a fresh session are still choices.
  private func applyContextUsage(_ usage: ContextUsage?) {
    guard let usage else {
      contextLabel.attributedStringValue = NSAttributedString()
      contextLabel.toolTip = nil
      return
    }
    let color: NSColor =
      switch usage.percentage {
      case ..<75: .secondaryLabelColor
      case ..<90: .systemOrange
      default: .systemRed
      }
    let line = NSMutableAttributedString()
    if let icon = Self.contextIcon(color) {
      let attachment = NSTextAttachment()
      attachment.image = icon
      let font = contextLabel.font ?? .systemFont(ofSize: 11)
      attachment.bounds = CGRect(
        x: 0, y: (font.capHeight - icon.size.height) / 2,
        width: icon.size.width, height: icon.size.height)
      line.append(NSAttributedString(attachment: attachment))
    }
    line.append(
      NSAttributedString(
        string: " \(usage.percentage)%",
        attributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
          .foregroundColor: color,
        ]))
    contextLabel.attributedStringValue = line

    var lines = ["Context: \(tokens(usage.totalTokens)) of \(tokens(usage.maxTokens)) tokens"]
    for category in usage.spent {
      lines.append("  \(category.name): \(tokens(category.tokens))")
    }
    contextLabel.toolTip = lines.joined(separator: "\n")
  }

  private func tokens(_ count: Int) -> String {
    Self.tokenFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
  }

  /// The dial, tinted to match the digits beside it.
  private static func contextIcon(_ color: NSColor) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
      .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: nil)?
      .withSymbolConfiguration(configuration)
  }

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

  /// The token breakdown behind the cost, for the header label's tooltip: a block per model that
  /// produced tokens (heaviest first) — a header line naming the model, then the four counts
  /// stacked under it — and a Total block below when more than one model contributed (with a single
  /// model its own block already is the total, but it still carries its name: which model burned
  /// the tokens is half of what the tooltip answers). The counts stack vertically rather than
  /// sitting on one line so a wide figure (thousands separators, cache reads in the millions) never
  /// overflows the tooltip's max width and wraps mid-line. Nil (no tooltip) when there is nothing
  /// to show. `byModel` is keyed by the resolved id the transcript records; `models` maps those
  /// back to the roster's display names when the session has connected.
  private static func costTooltip(
    byModel: [String: ClaudeSessionStore.TokenTotals],
    total: ClaudeSessionStore.TokenTotals?,
    models: [ClaudeModel]
  ) -> String? {
    guard let total, !total.isEmpty else { return nil }
    func n(_ value: Int) -> String { tokenFormatter.string(from: value as NSNumber) ?? "\(value)" }
    func block(_ header: String?, _ t: ClaudeSessionStore.TokenTotals) -> [String] {
      let indent = header == nil ? "" : "  "
      return (header.map { [$0] } ?? [])
        + [
          "\(indent)Input \(n(t.input))",
          "\(indent)Output \(n(t.output))",
          "\(indent)Cache read \(n(t.cacheRead))",
          "\(indent)Cache write \(n(t.cacheWrite))",
        ]
    }
    func name(for id: String) -> String {
      if id.isEmpty { return "Unknown model" }
      // `matches` tolerates the `[1m]` suffix the roster's resolvedModel carries but the
      // transcript id does not — otherwise every priced line fell through to the raw-id fallback.
      if let match = models.first(where: { $0.matches(id) }) {
        return match.numberedName
      }
      // No roster match (a detached session, or a model the engine never advertised): the raw id,
      // minus the noisy vendor prefix and any `[1m]` suffix.
      let bare = ClaudeModel.withoutContextSuffix(id)
      return bare.hasPrefix("claude-") ? String(bare.dropFirst("claude-".count)) : bare
    }
    func weight(_ t: ClaudeSessionStore.TokenTotals) -> Int {
      t.input + t.output + t.cacheRead + t.cacheWrite
    }
    let priced =
      byModel.filter { !$0.value.isEmpty }
      .sorted { weight($0.value) > weight($1.value) }
    // No per-model split (an old transcript parsed before models were recorded): the bare totals.
    guard !priced.isEmpty else { return block(nil, total).joined(separator: "\n") }
    var lines = priced.flatMap { block(name(for: $0.key), $0.value) }
    // A lone model's block already is the total, so no Total repeats it.
    if priced.count > 1 { lines += block("Total", total) }
    return lines.joined(separator: "\n")
  }

  func reload() {
    loadViewIfNeeded()

    for card in cards { card.removeFromSuperview() }
    cards = []
    emptyState?.removeFromSuperview()
    emptyState = nil
    inputTopConstraint.isActive = true

    guard let workspace, let worktreeID = workspace.selectedWorktreeID,
      workspace.worktree(id: worktreeID) != nil
    else {
      attach(nil)
      scrollView.isHidden = true
      bottomArea.isHidden = true
      // Open Recent beside the panel: an empty window is where the list is worth most, since
      // what it offers is exactly what this window has not got.
      let recent = RecentRepositoriesMenu(title: "Open Recent")
      recent.pullDownTitle = "Open Recent"
      let empty = EmptyStateView(
        symbol: "square.stack.3d.up",
        title: "No repositories yet",
        message: "Add a repository to start running agents in its worktrees.",
        actionTitle: "Open Repository…",
        action: #selector(WorkspaceWindowController.openRepository(_:)),
        secondary: recent)
      empty.translatesAutoresizingMaskIntoConstraints = false
      body.addSubview(empty)
      empty.pin(to: body)
      emptyState = empty
      return
    }

    scrollView.isHidden = false
    bottomArea.isHidden = false

    attach(workspace.selectedSession)
    // A held session is viewable but not sendable — another process owns its engine, so a send
    // would only be refused. Disable the field (the row is still selectable for reading/searching).
    input.isEnabled = attached != nil && attached?.heldByPID == nil
    // The engine's list, plus the two commands hukan runs itself and so is never told about. The
    // engine's half is empty until some engine in this window has answered — which is what the
    // seeded roster on a not-yet-started session is for — while hukan's own two are always
    // offered, because the session that has no engine list is exactly the signed-out one, where
    // `/login` is the only command that would help.
    input.commands = (attached?.availableCommands ?? []) + CommandCompletion.intercepted
    titleLabel.stringValue =
      attached?.title
      ?? (workspace.selectedSession == nil
        ? workspace.worktree(id: worktreeID)?.displayName ?? "" : "New session")
    costLabel.stringValue = Self.formatCost(
      attached?.costUSD, approximate: attached?.costApproximate ?? false)
    costLabel.toolTip = Self.costTooltip(
      byModel: attached?.costTokensByModel ?? [:],
      total: attached?.costTokens,
      models: attached?.availableModels ?? [])
    applyContextUsage(attached?.contextUsage)
    refreshComposerAccessories()

    // Only the session on screen, since the cards sit above its own composer. Decisions
    // waiting in other sessions show as a badge in the rail and are reached with Cmd+Return.
    guard let session = attached else { return }
    if session.hasOpenTasks {
      cards.append(
        TaskCard(tasks: session.tasks, expanded: session.tasksExpanded) {
          [weak self, weak session]
          in
          session?.tasksExpanded.toggle()
          self?.reload()
        })
    }
    if let question = session.pendingQuestion {
      cards.append(
        QuestionCard(
          question: question,
          onAnswer: { [weak session] answer in session?.answerQuestion(answer) },
          onToggleOption: { [weak session] index in session?.toggleQuestionOption(index) },
          onTogglePreview: { [weak session] index in session?.toggleQuestionPreview(index) }))
    } else if let approval = session.pendingApproval {
      cards.append(
        ApprovalCard(approval: approval) { [weak session] allow in
          session?.resolveApproval(allow: allow)
        })
    }
    guard !cards.isEmpty else { return }

    // The stack hangs off the top of the composer area and the queued card hangs off the last
    // of it, so however many cards are up they read as one column above the field.
    inputTopConstraint.isActive = false
    var above = bottomArea.topAnchor
    var gap: CGFloat = 10
    for card in cards {
      card.translatesAutoresizingMaskIntoConstraints = false
      bottomArea.addSubview(card)
      NSLayoutConstraint.activate([
        card.leadingAnchor.constraint(equalTo: bottomArea.leadingAnchor, constant: 12),
        card.trailingAnchor.constraint(equalTo: bottomArea.trailingAnchor, constant: -12),
        card.topAnchor.constraint(equalTo: above, constant: gap),
      ])
      above = card.bottomAnchor
      gap = 8
    }
    queuedCard.topAnchor.constraint(equalTo: above, constant: 8).isActive = true
  }

  /// Mirror the attached session's model, mode and queue into the composer controls. Called
  /// from `reload`, which runs on every state change, so the queue and a live mode switch both
  /// stay in step without their own observers.
  private func refreshComposerAccessories() {
    let session = attached
    // A held session cannot be started, so the launch-time pickers have nothing to act on — an
    // effort change would try to respawn an engine we are not allowed to spawn.
    let adjustable = session != nil && session?.heldByPID == nil
    modelPicker.isEnabled = adjustable
    modePicker.isEnabled = adjustable
    effortPicker.isEnabled = adjustable

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
    // `numberedName` splices the version off `resolvedModel` back onto the engine's numberless
    // label, so the picker reads "Opus 4.8" rather than a bare "Opus".
    let choices =
      roster.isEmpty ? fallbackModels : roster.map { (title: $0.numberedName, id: $0.value) }
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
          let match = session.availableModels.first(where: { $0.matches(reported) })
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
    for (index, message) in queued.enumerated() {
      let row = queuedRow(index: index, message: message)
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
  private func queuedRow(index: Int, message: QueuedMessage) -> NSView {
    let label = NSTextField(labelWithString: "⤷ " + queuedSummary(message))
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

  /// A queued line as one line of text. Attachments are counted rather than named — the paths
  /// are long and the chips already showed what they are — and a message that is nothing but a
  /// pasted screenshot reads as its count instead of as an empty row.
  private func queuedSummary(_ message: QueuedMessage) -> String {
    let line = message.text.replacingOccurrences(of: "\n", with: " ")
    guard !message.attachments.isEmpty else { return line }
    let count = "\(message.attachments.count) attached"
    return line.isEmpty ? count : "\(line)  (\(count))"
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
    guard let message = attached?.takeQueued(at: sender.tag) else { return }
    // Reopen it in the composer, appending if something is already half-typed there. Its
    // attachments come back as chips, so re-sending the line sends what it was queued with.
    let text = message.text
    input.stringValue = input.stringValue.isEmpty ? text : input.stringValue + "\n" + text
    input.attach(message.attachments.map(\.path))
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
