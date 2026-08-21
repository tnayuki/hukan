import AppKit
import Foundation

/// Buffer identity is (Worktree, relative path). Keying on the absolute path splits the same
/// file in two worktrees of one repository into two unrelated buffers, which kills
/// "put main and feature side by side". Practically impossible to retrofit later.
struct BufferKey: Hashable {
  let worktreeID: UUID
  let relativePath: String
}

enum RunState: String {
  case idle
  case running
  case needsAttention
  /// The engine failed to initialize because the account is signed out. Terminal like `.idle`
  /// (no turn is running), but it is not a state the agent can leave on its own — the fix is
  /// `/login`, which the composer intercepts and runs in a real terminal.
  case signedOut

  var badge: String {
    switch self {
    case .idle: return "✓"
    case .running: return "⏳"
    case .needsAttention: return "!"
    case .signedOut: return "⚠"
    }
  }
}

/// How much of the agent's turn reaches the approval card. This is the lever the whole
/// design turns on: in a general editor it is a convenience, but here it decides which of the
/// parallel sessions interrupt you. An agent you trust on its task should not be generating
/// approvals at all.
///
/// These are Claude Code's own modes, passed at launch as `--permission-mode` and switched
/// live with a `set_permission_mode` control_request. `manual` is deliberately absent — it
/// fails tools instead of prompting, which is not an approval channel (see the charter).
///
/// `auto` is the engine's newer decide-per-tool mode. It sits behind a rollout gate: when the
/// gate is off the engine answers `set_permission_mode:auto` by falling back to `default`
/// (verified in the 2.1.212 dispatch). Offering it is safe either way — it works where the gate
/// is on and degrades to Ask where it is not.
enum PermissionMode: String, CaseIterable {
  case `default`
  case acceptEdits
  case auto
  case plan
  case bypassPermissions

  /// Short label for the picker. Wording tracks Claude Code so the mode reads the same here
  /// as in the CLI's own indicator.
  var label: String {
    switch self {
    case .default: return "Ask"
    case .acceptEdits: return "Auto-accept edits"
    case .auto: return "Auto"
    case .plan: return "Plan"
    case .bypassPermissions: return "Bypass"
    }
  }
}

/// A git repository: the open/close unit. Its identity is the path git's common dir sits under
/// (what `Git.repository(at:)` returns), shared by every worktree of it — grouping on the
/// display name alone would merge two different repositories that happen to be called the same
/// thing. The worktrees are enumerated from git and arrive with the repository; the type holds
/// nothing git does not, so there is no second copy of anything that can drift from git.
final class Repository {
  let id: String
  var worktrees: [Worktree] = []

  init(id: String) { self.id = id }

  var name: String { (id as NSString).lastPathComponent }
}

final class Worktree {
  let id: UUID
  let url: URL
  var branch: String?
  /// The repository this worktree belongs to. A back-reference, not a copy: the id and name
  /// read straight off it, so two worktrees of one repository can never disagree on either.
  /// Unowned because the repository owns the worktree (`Repository.worktrees`) and outlives it.
  unowned let repository: Repository
  var repositoryID: String { repository.id }
  var repositoryName: String { repository.name }

  /// Working tree changes. The diffstat belongs to the worktree, not to a session.
  var changedFiles: [ChangedFile] = []
  var trackedFiles: [String] = []
  var hasLoadedFiles = false

  init(id: UUID = UUID(), url: URL, branch: String? = nil, repository: Repository) {
    self.id = id
    self.url = url
    self.branch = branch
    self.repository = repository
  }

  var displayName: String { branch ?? url.lastPathComponent }

  var diffstat: (added: Int, removed: Int) {
    changedFiles.reduce(into: (0, 0)) { total, file in
      total.0 += file.added
      total.1 += file.removed
    }
  }
}

struct ChangedFile: Equatable {
  let path: String
  let added: Int
  let removed: Int
  var name: String { (path as NSString).lastPathComponent }
}

/// One node in the sidebar. Flat in Changed mode, hierarchical in All mode.
final class FileNode: NSObject {
  let name: String
  let relativePath: String
  let isDirectory: Bool
  var added: Int?
  var removed: Int?
  var children: [FileNode] = []

  init(
    name: String, relativePath: String, isDirectory: Bool, added: Int? = nil, removed: Int? = nil
  ) {
    self.name = name
    self.relativePath = relativePath
    self.isDirectory = isDirectory
    self.added = added
    self.removed = removed
  }

  /// Build a hierarchy from a list of paths, attaching diffstats to changed files.
  static func tree(paths: [String], changed: [String: ChangedFile]) -> [FileNode] {
    let treeRoot = FileNode(name: "", relativePath: "", isDirectory: true)
    for path in paths {
      var current = treeRoot
      let components = path.split(separator: "/").map(String.init)
      for (index, component) in components.enumerated() {
        let isLeaf = index == components.count - 1
        if let existing = current.children.first(where: {
          $0.name == component && $0.isDirectory != isLeaf
        }) {
          current = existing
          continue
        }
        let relativePath = components[0...index].joined(separator: "/")
        let node = FileNode(
          name: component, relativePath: relativePath, isDirectory: !isLeaf,
          added: isLeaf ? changed[relativePath]?.added : nil,
          removed: isLeaf ? changed[relativePath]?.removed : nil)
        current.children.append(node)
        current = node
      }
    }
    treeRoot.sortRecursively()
    return treeRoot.children
  }

  private func sortRecursively() {
    children.sort { left, right in
      if left.isDirectory != right.isDirectory { return left.isDirectory }
      return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }
    for child in children { child.sortRecursively() }
  }
}

/// One choice offered by an `AskUserQuestion`.
struct QuestionOption {
  let label: String
  let description: String
}

/// One question the agent is asking, with its options.
struct AgentQuestion {
  let header: String
  let question: String
  let options: [QuestionOption]
}

/// An `AskUserQuestion` in flight. The questions are shown one at a time and answers accumulate;
/// once the last is answered the whole set goes back to the model at once. It arrives as a
/// `can_use_tool` request (stdio has no real dialog channel), so it is a distinct kind of pending
/// decision from a plain tool approval — options, not allow/deny.
struct PendingQuestion {
  let requestID: String
  let questions: [AgentQuestion]
  var answers: [(header: String, label: String)] = []
  var index: Int = 0
  var current: AgentQuestion { questions[index] }
}

/// A tool call the agent is blocked on, waiting for a decision from you.
struct PendingApproval {
  let requestID: String
  let toolName: String
  let title: String
  let detail: String
  /// Echoed back verbatim on allow. The protocol allows editing the call before it runs,
  /// which is where an "edit and allow" affordance would attach.
  let input: [String: Any]
}

/// One agent running under `claude -p`.
final class AgentSession {
  /// The permission mode a fresh session launches in. `auto` lets the engine decide per tool,
  /// which is what keeps parallel agents moving without a card for every step; it degrades to
  /// Ask where the engine's rollout gate is off (see `PermissionMode`). The save filter keys
  /// on this so a session left at the default is not needlessly persisted.
  static let defaultPermissionMode: PermissionMode = .auto

  let id: UUID
  /// When the agent creates a worktree mid-session its working location moves,
  /// so this cannot be fixed at creation time.
  var worktreeID: UUID
  var state: RunState = .idle

  /// When this session last emitted anything — a fragment of output (`append`) or an
  /// approval/question landing. Seeded from the transcript's modification time on discovery,
  /// then bumped on genuine activity. No longer the rail's sort key (that is `lastInstructedAt`);
  /// it picks the fallback session when a selection is lost (`selectedSession`), orders the
  /// search-results list, and stamps the status readout's "… ago".
  var updatedAt = Date.distantPast

  /// When you last gave this session an instruction (a composer send). This — not `updatedAt` —
  /// orders the rail and assigns its time bucket, so the order reflects what you most recently
  /// delegated and holds still while an agent works, instead of churning as the chattiest one
  /// streams. The cost, accepted deliberately: a session you instructed long ago but which is
  /// working or waiting now sinks by its instruction time and can fall into the collapsed
  /// "Older" bucket — `Cmd+Return` is how you reach a waiting session, not its rail position.
  /// Seeded from the transcript mtime for a restored session (a proxy until you send), then set
  /// precisely on each send. `/login` and a dropped signed-out send do not count.
  var lastInstructedAt = Date.distantPast
  /// A restored UUID has not been reattached with `claude --resume` yet. Showing it with
  /// the same face as a live session would be a lie, so keep them distinct.
  var isDetached = false

  /// What the session is for, taken from the first thing asked of it. The session is what
  /// the rail lists, so it needs a name of its own — the worktree is only where it happens
  /// to be working.
  var title: String?

  /// Estimated USD spent by this session, summed from the transcript's recorded token `usage`
  /// via `Pricing`. Nil until history loads or a turn ends with priceable usage. On a
  /// subscription no dollars are actually billed — this is the "if it were API-metered" figure,
  /// shown in the conversation header. Set from `history.costUSD` on load and recomputed from
  /// disk at each turn's `result` (the engine writes usage per assistant record as it goes).
  var costUSD: Double?
  /// True when the estimate omitted a real message whose model `Pricing` couldn't price, so the
  /// figure is a floor — shown with a `~` prefix. False in the common all-known-models case.
  var costApproximate = false
  /// Token counts behind the cost, shown in the header's tooltip. Nil until history loads.
  var costTokens: ClaudeSessionStore.TokenTotals?

  /// The worktree this session last ran/loaded in, kept so the `result` handler can recompute
  /// `costUSD` from disk without the window threading a URL through. A move updates it.
  private var lastKnownWorktree: URL?

  /// Per-session choices shown in the composer. Both apply at launch (`--model`,
  /// `--permission-mode`) and can be changed on a live session, so a picker is honest at any
  /// point in the conversation, not just before the first message.
  var model = "default"
  var permissionMode: PermissionMode = AgentSession.defaultPermissionMode
  /// The model the engine reported running (a resolved id like `claude-sonnet-5`), from
  /// system/init. Drives the picker's display so it shows what is actually running — in
  /// particular the model the engine remembered across a resume, which our default would not.
  var reportedModel: String?
  /// Reasoning effort passed as `--effort`. Launch-only (no runtime control), so a change lands
  /// the next time the session starts — which the app's restart makes easy.
  var effort = "default"

  /// The models the engine advertised for this session (from its initialize reply). Empty until
  /// the session has connected; the picker falls back to a small fixed list until then.
  private(set) var availableModels: [ClaudeModel] = []

  /// Type-ahead held while the agent is mid-turn. Writing a `user` message into a turn the
  /// engine is still working would race it; instead these queue and flush one at a time as
  /// each turn ends. Shown above the composer so a queued line is never invisible.
  private(set) var queuedMessages: [String] = []

  /// The composer's unsent text, held per session so switching conversations swaps the draft
  /// with the transcript and a restart puts it back. The controller owns the field and mirrors
  /// every edit here; the session only stores it (and it rides the same disk path as the queue).
  var draft: String = ""

  /// True from the moment a message is delivered until the engine's `result`. This is the
  /// queue gate, and it is deliberately *not* `state == .running`: `start()` sets `.running`
  /// optimistically before any turn exists, so gating on it would trap the first message
  /// forever. A turn is active only once something has actually been sent.
  private(set) var isTurnActive = false

  /// Set while an interrupt we asked for is in flight, so the `error_during_execution` result
  /// the engine ends the cut turn with reads as "we stopped it", not "it crashed".
  private var interruptedTurn = false

  /// True once a user message has actually gone to the engine. A New Session is started eagerly
  /// just to read the model roster, before anything is sent; until this flips it has written no
  /// transcript, so a launch-only change (effort) can respawn it fresh rather than wait.
  private(set) var hasSent = false

  /// Set between asking the current process to exit and its `onExit`, when that exit is a
  /// deliberate respawn to pick up a launch-only setting on a not-yet-sent session — not a real
  /// termination. Keeps `onExit` from marking the session detached (there is no transcript to
  /// `--resume`), so the next send opens a fresh `--session-id` carrying the new setting.
  private var pendingEffortRestart = false

  /// Full history, replayed into the view when you switch away and come back.
  let transcript = NSMutableAttributedString()
  /// Receives only the appended fragment. Replacing the whole text per event is O(n²).
  var onAppend: ((NSAttributedString) -> Void)?
  var onStateChange: (() -> Void)?
  /// The whole transcript changed rather than grew, so the view has to re-read it.
  var onReload: (() -> Void)?
  /// A span already on screen was rewritten in place — streamed text swapped for its
  /// formatted version. Replacing just the span keeps this off the length of the transcript.
  var onReplace: ((NSRange, NSAttributedString) -> Void)?
  /// A fold toggled somewhere in the middle of the transcript (see `editTranscript`). Unlike
  /// `onReplace` this must not scroll — the reader is looking at the fold, not the tail.
  var onEdit: ((NSRange, NSAttributedString) -> Void)?
  /// The agent moved into a worktree via EnterWorktree, so its location changed.
  var onEnterWorktree: ((URL) -> Void)?
  /// The composer sent `/login` or `/logout` (the bare verb, without the slash). These need a
  /// real TTY for their OAuth/browser flow and cannot run over stream-json, so the window runs
  /// them in a terminal and reconnects the session afterwards.
  var onLoginRequested: ((String) -> Void)?
  /// This session wants to send but has no live process — a new session never started, or a
  /// restored one only ever looked at. The window resolves the worktree and spawns `claude`.
  /// Start is deferred to here (the first send), so creating or selecting a session never spawns
  /// a process nobody is talking to yet.
  var onNeedsStart: (() -> Void)?

  /// Set while the agent sits blocked on a `can_use_tool` request. Something must always clear
  /// it — `resolveApproval`, the turn's `result`, process exit, or sign-out — or the agent
  /// waits forever.
  private(set) var pendingApproval: PendingApproval?

  /// Set while the agent is asking an `AskUserQuestion`. Mutually exclusive with
  /// `pendingApproval` — a `can_use_tool` is one or the other. Must be answered (even a skip
  /// replies), or the agent waits forever, same as an approval.
  private(set) var pendingQuestion: PendingQuestion?

  /// Where the assistant's current text block started, so its rendered span can be replaced in
  /// place as more of it streams in.
  private var streamStart: Int?
  /// The raw markdown streamed so far for the current block. Kept because formatting needs the
  /// whole run, not one token — the span is re-rendered from this on every delta.
  private var streamSource = ""

  /// When the last block went in, for deciding whether the conversation paused.
  private var lastStamp: Date?

  /// Write a timestamp if this is the first block or the conversation paused before it.
  /// Called at block boundaries, never per streamed token — a separator between two halves
  /// of one sentence would be nonsense.
  private func markTime(_ date: Date = Date()) {
    if lastStamp.map({ date.timeIntervalSince($0) >= Transcript.timeGap }) ?? true {
      append(Transcript.timeSeparator(date))
    }
    lastStamp = date
  }

  /// tool_use id to tool name. Results arrive as separate events, so this is what
  /// correlates a result back to the call it belongs to.
  private var pendingTools: [String: String] = [:]

  private var runner: ClaudeSession?
  var isRunning: Bool { runner?.isRunning ?? false }

  init(id: UUID = UUID(), worktreeID: UUID, isDetached: Bool = false) {
    self.id = id
    self.worktreeID = worktreeID
    self.isDetached = isDetached
  }

  private var hasLoadedHistory = false

  /// Pull the past conversation in from disk the first time this session is opened.
  ///
  /// Reading every transcript up front would mean an I/O storm on launch for sessions
  /// nobody looks at, so it happens on open — the same reasoning as lazy resume.
  func loadHistoryIfNeeded(at worktreeURL: URL) {
    lastKnownWorktree = worktreeURL
    guard !hasLoadedHistory else { return }
    hasLoadedHistory = true
    let id = self.id
    DispatchQueue.global(qos: .userInitiated).async {
      guard let history = ClaudeSessionStore.history(id: id, worktree: worktreeURL),
        !history.records.isEmpty
      else { return }
      let rendered = Transcript.render(history.records)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        // Inserted at the front, not appended: a session that resumed on the same
        // click may already have produced live output while this was being read.
        self.transcript.insert(rendered, at: 0)
        if let title = history.title { self.title = title }
        self.costUSD = history.cost.usd
        self.costApproximate = history.cost.approximate
        self.costTokens = history.cost.tokens
        // Only when nothing live has happened yet, or this would drag the clock
        // backwards and suppress the separator the next message deserves.
        if self.lastStamp == nil { self.lastStamp = history.lastStamp }
        self.onReload?()
        self.onStateChange?()
      }
    }
  }

  /// Re-read the transcript's estimated cost after a turn ends. Off the main thread (a full-file
  /// scan), and only fires `onStateChange` when the figure actually moved, so a no-op turn does
  /// not churn the UI. The engine has flushed this turn's assistant usage to disk by `result`.
  private func refreshCostEstimate() {
    guard let worktree = lastKnownWorktree else { return }
    let id = self.id
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let estimate = ClaudeSessionStore.cost(id: id, worktree: worktree)
      DispatchQueue.main.async {
        guard let self,
          estimate.usd != self.costUSD || estimate.approximate != self.costApproximate
        else { return }
        self.costUSD = estimate.usd
        self.costApproximate = estimate.approximate
        self.costTokens = estimate.tokens
        self.onStateChange?()
      }
    }
  }

  /// `holdIdle` starts the process without flipping to `.running`, for a New Session brought up
  /// only to read the roster: no turn exists yet, so the rail row stays idle until the first send.
  func start(at url: URL, tools: [String]? = nil, holdIdle: Bool = false) {
    lastKnownWorktree = url
    guard runner == nil else { return }
    // `runner == nil` only guards this process. The registry Claude Code itself maintains
    // (~/.claude/sessions/<pid>.json) also sees a terminal `claude --resume`, a second window
    // on the same repository, and an orphan left by a crash — any of which plus a fresh spawn
    // would be two claudes writing one transcript. Refuse while that owner is alive; the
    // refusal clears itself the moment it exits (reselect the session to start it then).
    if let owner = ClaudeSessionStore.liveProcessOwning(id: id) {
      append(
        Transcript.error(
          "Not started — this session is already open in another process (pid \(owner)). "
            + "Close it there, then send again."))
      onStateChange?()
      return
    }
    let session = ClaudeSession(id: id, worktree: url)
    session.onEvent = { [weak self] event in self?.apply(event) }
    session.onModels = { [weak self] models in
      self?.availableModels = models
      self?.onStateChange?()
    }
    session.onInitializeFailed = { [weak self] _ in self?.handleSignedOut() }
    session.onExit = { [weak self] status in
      guard let self else { return }
      self.runner = nil
      self.pendingApproval = nil
      self.pendingQuestion = nil
      // The turn is over and nothing can deliver what was queued, so drop it rather than
      // firing it into a fresh process on the next start.
      self.isTurnActive = false
      self.queuedMessages.removeAll()
      // A deliberate respawn of a not-yet-sent session to pick up a launch-only setting (effort):
      // reset to the un-started state and let the next send bring it back. Crucially NOT detached —
      // it wrote no transcript, so that next start must be a fresh `--session-id`, not a `--resume`.
      if self.pendingEffortRestart {
        self.pendingEffortRestart = false
        self.state = .idle
        self.onStateChange?()
        return
      }
      // A signed-out session exits right after the init error; keep that state and its note
      // rather than overwriting them with a generic "claude exited", which explains nothing.
      if self.state == .signedOut {
        self.onStateChange?()
        return
      }
      self.state = .idle
      // The process is gone but the conversation is on disk, so this session is detached
      // again: the next send must `--resume` it, not open a fresh `--session-id` on top of an
      // id that already has a transcript. (The signed-out branch above returned early — it
      // never initialized, so there is nothing to resume.)
      self.isDetached = true
      if status != 0 {
        self.append(Transcript.error("claude exited (status \(status))"))
      }
      self.onStateChange?()
    }
    do {
      try session.start(
        model: model, permissionMode: permissionMode.rawValue, effort: effort,
        tools: tools, resume: isDetached)
      runner = session
      isDetached = false
      if !holdIdle { state = .running }
      onStateChange?()
    } catch {
      append(Transcript.error("Could not launch claude: \(error.localizedDescription)"))
      onStateChange?()
    }
  }

  /// The engine's `initialize` came back an error, so it will never take input. Surface it as
  /// its own terminal state with an actionable note, rather than the silent dead pane a bare
  /// log leaves. The only way out is `/login`, which the composer intercepts.
  private func handleSignedOut() {
    // Nothing is running, and anything queued would sit in an outbox that never drains.
    isTurnActive = false
    queuedMessages.removeAll()
    pendingApproval = nil
    pendingQuestion = nil
    state = .signedOut
    append(Transcript.error("Not signed in — type /login and press Enter to authenticate."))
    onStateChange?()
  }

  /// Append an out-of-band note to the transcript. Used by the window for events that originate
  /// outside the engine's own stream — launching a `/login` terminal, for one.
  func note(_ text: String) {
    append(Transcript.note(text))
  }

  /// Take a line from the composer. Delivered straight through when the agent is idle.
  ///
  /// Mid-turn, what happens turns on whether type-ahead is already stacked. Nothing queued
  /// means this send is a redirect, not another line of work to do after: interrupt the running
  /// turn and let this line open the next one the moment the interrupt lands, rather than
  /// holding it until the turn finishes on its own. With a queue already building, the send is
  /// deliberate type-ahead, so it joins the queue as before.
  func send(_ text: String, attachments: [Attachment] = []) {
    // `/login` and `/logout` are interactive built-in commands: their OAuth/browser flow needs
    // a real TTY, so sending them over stream-json would just hang on a turn that never ends.
    // Hand the bare verb to the window to run in a terminal instead — this is the one path out
    // of `.signedOut`, but it is intercepted in any state so a deliberate `/logout` works too.
    let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if command == "/login" || command == "/logout" {
      onLoginRequested?(String(command.dropFirst()))
      return
    }
    // A signed-out session cannot take a turn — the engine is gone. Drop the line rather than
    // opening a turn that would never be answered; the note already says to run /login.
    if state == .signedOut { return }
    // The send is the instruction that orders the rail. Stamp it here — for the immediate
    // deliver, a queued type-ahead line, and a redirect alike — so ordering tracks when you
    // last engaged this session, not the agent's own chatter. `/login` and the signed-out drop
    // returned above, so neither reorders anything.
    lastInstructedAt = Date()
    // Start is deferred to the first send, so a new or merely-viewed session spawns no `claude`
    // until you actually talk to it. Bring the process up now; bail if it could not start —
    // already owned by another process, in which case `start` left a note. The engine's outbox
    // holds this turn's text until it finishes initializing, so delivering right after is safe.
    if runner == nil {
      onNeedsStart?()
      guard runner != nil else { return }
    }
    if isTurnActive {
      // The turn is only truly waiting on you once the agent has asked — a permission prompt
      // or a question. Blocked like that it never ends on its own, so a queued line would
      // wait forever: take the send as the reply, resolve the prompt, and let this line open
      // the next turn now. While the agent is merely working, a send is type-ahead and joins
      // the queue — which is the whole point of the queue; interrupting there would mean it
      // never fills. A queued line is stored as plain text, so any attachments fold back into
      // it as paths (the native-image path is for the immediate send).
      if pendingApproval != nil || pendingQuestion != nil {
        queuedMessages.insert(textWithAttachmentPaths(text, attachments), at: 0)
        interrupt(resending: true)
        return
      }
      queuedMessages.append(textWithAttachmentPaths(text, attachments))
      onStateChange?()
      return
    }
    deliver(text, attachments: attachments)
  }

  /// Fold attachment paths into the message text — the queue fallback, and how a non-immediate
  /// send still carries its files.
  private func textWithAttachmentPaths(_ text: String, _ attachments: [Attachment]) -> String {
    guard !attachments.isEmpty else { return text }
    return [text, attachments.map(\.path).joined(separator: "\n")].filter { !$0.isEmpty }.joined(
      separator: "\n\n")
  }

  /// Record a message in the transcript and hand it to the engine. Shared by the paths that
  /// open a turn (`deliver`) and the one that jumps a queued line straight to the engine
  /// mid-turn (`sendQueuedNow`), which is why it does not touch turn state itself.
  private func recordAndSend(_ text: String, attachments: [Attachment] = []) {
    if title == nil {
      let source = title(from: text) ?? (attachments.isEmpty ? "" : "画像")
      let firstLine = source.split(separator: "\n").first.map(String.init) ?? source
      title = firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }
    hasSent = true
    markTime()
    append(Transcript.userMessage(text, imagePaths: attachments.filter(\.isImage).map(\.path)))
    runner?.send(text, attachments: attachments)
  }

  private func title(from text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Actually hand a message to the engine and open a turn. Only reached when no turn is in
  /// flight — from `send` directly, or from `flushQueue` as each turn ends.
  private func deliver(_ text: String, attachments: [Attachment] = []) {
    recordAndSend(text, attachments: attachments)
    state = .running
    isTurnActive = true
    onStateChange?()
  }

  /// Put type-ahead back after a restart. Drafts only: this does not open a turn, so nothing is
  /// sent until you press "send now" or the session's next turn ends and flushes the queue.
  func restoreQueue(_ messages: [String]) {
    guard queuedMessages.isEmpty, !messages.isEmpty else { return }
    queuedMessages = messages
  }

  /// One turn ended. Send the next queued line if there is one, which opens the next turn;
  /// otherwise the session is genuinely idle and ready for fresh input.
  private func flushQueue() {
    isTurnActive = false
    guard !queuedMessages.isEmpty else { return }
    deliver(queuedMessages.removeFirst())
  }

  // MARK: - Queue controls (the buttons on each type-ahead line)

  /// Send a queued line to the engine right now instead of waiting for the turn to end. The
  /// engine takes it into its own input queue and runs it after the current turn, so it jumps
  /// ahead of everything still held here without a mid-turn write racing the active turn.
  func sendQueuedNow(at index: Int) {
    guard queuedMessages.indices.contains(index) else { return }
    recordAndSend(queuedMessages.remove(at: index))
    onStateChange?()
  }

  /// Drop a queued line — it was typed ahead and is no longer wanted.
  func removeQueued(at index: Int) {
    guard queuedMessages.indices.contains(index) else { return }
    queuedMessages.remove(at: index)
    onStateChange?()
  }

  /// Pull a queued line back out for editing: it leaves the queue and its text is returned so
  /// the composer can reopen it. Re-sending it queues it afresh at the end.
  func takeQueued(at index: Int) -> String? {
    guard queuedMessages.indices.contains(index) else { return nil }
    let text = queuedMessages.remove(at: index)
    onStateChange?()
    return text
  }

  /// Change the model. Applied live if the session is running, and remembered either way so
  /// the next launch uses it. The picker calls this; nothing else should touch `model`.
  func setModel(_ model: String) {
    self.model = model
    // The user's explicit pick supersedes what the engine last reported, so the picker follows
    // the choice rather than snapping back to the reported model on the next refresh.
    reportedModel = nil
    runner?.setModel(model)
    onStateChange?()
  }

  /// Change how much reaches the approval card. Live when running, remembered for next launch.
  func setPermissionMode(_ mode: PermissionMode) {
    guard mode != permissionMode else { return }
    permissionMode = mode
    runner?.setPermissionMode(mode.rawValue)
    onStateChange?()
  }

  /// Change reasoning effort. Remembered and applied at the next launch (no runtime control),
  /// so a running session keeps its current effort until it restarts.
  func setEffort(_ effort: String) {
    guard effort != self.effort else { return }
    self.effort = effort
    // Effort is launch-only. A New Session is started eagerly just to read the roster; if nothing
    // has been sent yet, tear that process down so the next send respawns it with the new effort
    // (it wrote no transcript, so the respawn is clean). Once a message has gone — or the session
    // is not running — the change simply waits for the next natural start.
    if runner != nil && !hasSent {
      pendingEffortRestart = true
      runner?.terminate()
    }
    onStateChange?()
  }

  /// Show a remembered roster on a session that has not connected yet — a restored one, or a
  /// freshly created one in the instant before its own initialize returns. Never overwrites a live
  /// roster: the session's own reply wins the moment it arrives.
  func seedModels(_ models: [ClaudeModel]) {
    guard availableModels.isEmpty, !models.isEmpty else { return }
    availableModels = models
  }

  /// Answer the approval on screen. Denying ends the agent's turn rather than the session.
  func resolveApproval(allow: Bool) {
    guard let approval = pendingApproval else { return }
    pendingApproval = nil
    runner?.respond(requestID: approval.requestID, allow: allow, updatedInput: approval.input)
    // Allow leaves no trace — the tool runs and its result is the record, the way the CLI does
    // it. Deny does: the tool did NOT run, which a bare gap would read as nothing happening.
    if !allow { append(Transcript.note("→ denied \(approval.toolName)")) }
    state = .running
    onStateChange?()
  }

  /// Answer the question on screen with the chosen option label, or nil to skip it. Advances to
  /// the next question; once the last is answered, all the choices go back to the model at once.
  func answerQuestion(_ optionLabel: String?) {
    guard var question = pendingQuestion else { return }
    question.answers.append((question.current.header, optionLabel ?? "(skipped)"))
    let next = question.index + 1
    if next < question.questions.count {
      question.index = next
      pendingQuestion = question
      onStateChange?()
      return
    }
    pendingQuestion = nil
    // The answer is both sent to the model and shown in the transcript — one text, the way the
    // CLI does it, so what you chose is on the record instead of a bare "answered".
    let answer = Self.answerMessage(question.answers)
    runner?.respondDeny(requestID: question.requestID, message: answer)
    append(Transcript.userMessage(answer))
    state = .running
    onStateChange?()
  }

  /// The answer the model reads in place of a dialog result, and the same text shown in the
  /// transcript: one line per question in the `[User answered <header>]: <choice>` shape the
  /// engine recognises as direct user intent — its system prompt trusts that exact prefix.
  static func answerMessage(_ answers: [(header: String, label: String)]) -> String {
    answers
      .map { "[User answered \($0.header.isEmpty ? "AskUserQuestion" : $0.header)]: \($0.label)" }
      .joined(separator: "\n")
  }

  /// Read the `questions` array out of an `AskUserQuestion` tool input.
  static func parseQuestions(_ input: [String: Any]) -> [AgentQuestion] {
    guard let raw = input["questions"] as? [[String: Any]] else { return [] }
    return raw.map { entry in
      let options = (entry["options"] as? [[String: Any]] ?? []).map {
        QuestionOption(
          label: $0["label"] as? String ?? "",
          description: $0["description"] as? String ?? "")
      }
      return AgentQuestion(
        header: entry["header"] as? String ?? "",
        question: entry["question"] as? String ?? "",
        options: options)
    }
  }

  /// Stop the running turn. From the stop button (`resending: false`) this drops any type-ahead
  /// behind it — flushing it into the interrupted turn would be a surprise. From a redirecting
  /// send (`resending: true`) the single queued line *is* the redirect and must survive, so it
  /// opens the next turn the moment the engine's cut-turn `result` lands and `flushQueue` runs.
  func interrupt(resending: Bool = false) {
    if !resending { queuedMessages.removeAll() }
    isTurnActive = false
    interruptedTurn = true
    // Leaving either kind of request unanswered would strand the engine, so reply first.
    if pendingApproval != nil { resolveApproval(allow: false) }
    if let question = pendingQuestion {
      pendingQuestion = nil
      runner?.respondDeny(
        requestID: question.requestID, message: "The user dismissed the question.")
    }
    runner?.interrupt()
    onStateChange?()
  }

  func stop() { runner?.terminate() }

  /// The app-quit teardown drives the close-wait-SIGTERM-SIGKILL sequence itself, across every
  /// session on one shared deadline — the background waiters `stop()` spawns would die with
  /// the process before ever escalating. These expose the three ends of that sequence; the
  /// final SIGKILL is what keeps a mid-turn engine from being orphaned to launchd on our exit.
  func beginStop() { runner?.closeInput() }
  func forceStop() { runner?.forceTerminate() }
  func killStop() { runner?.forceKill() }

  /// Pull the path out of "Created worktree at <path> on branch <branch>. …".
  /// The wording differs when entering an existing worktree, so give up if it does not match.
  static func worktreePath(fromToolResult text: String) -> URL? {
    guard let start = text.range(of: "worktree at ") else { return nil }
    let rest = text[start.upperBound...]
    let end = rest.range(of: " on branch ") ?? rest.range(of: ". ")
    let path = String(end.map { rest[..<$0.lowerBound] } ?? rest)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard path.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: path)
  }

  /// Recency moved. Distinct from onStateChange (a full window reload): activity happens per
  /// fragment while a turn runs, and the only thing that depends on it is the rail's order, so
  /// the subscriber can throttle and reload just that.
  var onRecencyChange: (() -> Void)?

  /// Bump the rail's sort key: this session just did something. The one way `updatedAt` moves.
  private func touch() {
    updatedAt = Date()
    onRecencyChange?()
  }

  private func append(_ fragment: NSAttributedString) {
    // Fresh content is the session speaking, so it counts as activity for the rail's order.
    // History replayed from disk uses `insert`, not this, so loading the past never reorders.
    touch()
    transcript.append(fragment)
    onAppend?(fragment)
  }

  /// An in-place edit that did not come from the engine: a tool call folding open or closed.
  /// The transcript here and the view's storage mirror each other by offset — every streaming
  /// replace assumes it — so the edit must land in both (via `onEdit`), and `streamStart`,
  /// itself an offset into this transcript, shifts with any edit made before it.
  /// (`TranscriptStorageMirror`: this is what the Kit's click delegate routes fold edits through.)
  func editTranscript(in range: NSRange, with replacement: NSAttributedString) {
    guard NSMaxRange(range) <= transcript.length else { return }
    if let start = streamStart, NSMaxRange(range) <= start {
      streamStart = start + replacement.length - range.length
    }
    transcript.replaceCharacters(in: range, with: replacement)
    onEdit?(range, replacement)
  }

  /// Render an event into the transcript.
  ///
  /// Text comes from `content_block_delta` so it streams token by token; the buffered
  /// `assistant` text repeats it and is dropped to avoid printing twice. Tool calls go the
  /// other way: `content_block_start` has empty arguments, so the buffered `assistant`
  /// block — which has them filled in — is the one used.
  private func apply(_ event: ClaudeEvent) {
    switch event.type {
    case "stream_event":
      guard let inner = event.payload["event"] as? [String: Any] else { return }
      if inner["type"] as? String == "content_block_delta",
        let delta = inner["delta"] as? [String: Any],
        delta["type"] as? String == "text_delta",
        let text = delta["text"] as? String
      {
        // Render the accumulated run as markdown on every delta so formatting shows while
        // it streams, not only once the block closes. A lone token can't be formatted
        // ("**bo" is not bold yet), but the whole run so far can: unclosed markup renders
        // literally until it closes, then snaps to formatted — the usual streaming look.
        if streamStart == nil {
          markTime()
          streamStart = transcript.length
          streamSource = ""
        }
        streamSource += text
        touch()  // streaming is activity; keep the rail's recency fresh
        let range = NSRange(location: streamStart!, length: transcript.length - streamStart!)
        let formatted = Transcript.markdown(streamSource)
        transcript.replaceCharacters(in: range, with: formatted)
        onReplace?(range, formatted)
      }

    case "assistant":
      guard let message = event.payload["message"] as? [String: Any],
        let blocks = message["content"] as? [[String: Any]]
      else { return }

      // The buffered message is the first point the whole text exists, so it is where
      // the plain streamed span gets replaced by its formatted self.
      let text =
        blocks
        .filter { $0["type"] as? String == "text" }
        .compactMap { $0["text"] as? String }
        .joined()
      if let start = streamStart, transcript.length > start, !text.isEmpty {
        let range = NSRange(location: start, length: transcript.length - start)
        let formatted = Transcript.markdown(text)
        transcript.replaceCharacters(in: range, with: formatted)
        onReplace?(range, formatted)
      }
      streamStart = nil

      for block in blocks where block["type"] as? String == "tool_use" {
        let name = block["name"] as? String ?? "tool"
        let input = block["input"] as? [String: Any] ?? [:]
        if let id = block["id"] as? String { pendingTools[id] = name }
        // AskUserQuestion is surfaced as its own question card, so a raw "▸ AskUserQuestion"
        // line would just be noise duplicating it.
        guard name != "AskUserQuestion" else { continue }
        markTime()
        append(Transcript.toolUse(name: name, input: input))
      }

    case "user":
      // A move into a worktree is only visible in the EnterWorktree result. The agent
      // that created it is the only one who knows, so read it out of the result text.
      guard let message = event.payload["message"] as? [String: Any],
        let blocks = message["content"] as? [[String: Any]]
      else { return }
      for block in blocks where block["type"] as? String == "tool_result" {
        guard let id = block["tool_use_id"] as? String,
          let name = pendingTools.removeValue(forKey: id),
          name == "EnterWorktree",
          let text = block["content"] as? String,
          let path = Self.worktreePath(fromToolResult: text)
        else { continue }
        append(Transcript.note("→ worktree: \(path.path)"))
        onEnterWorktree?(path)
      }

    // The engine blocks until this is answered, so every branch here must reply — either
    // now, or via the approval card the user resolves later.
    case "control_request":
      guard let requestID = event.payload["request_id"] as? String,
        let request = event.payload["request"] as? [String: Any]
      else { return }
      guard request["subtype"] as? String == "can_use_tool" else {
        // `request_user_dialog` and friends have no surface here yet. Cancelling is
        // the reply that lets the agent carry on instead of hanging.
        runner?.declineControlRequest(id: requestID, cancelled: true)
        return
      }
      let toolName = request["tool_name"] as? String ?? "tool"
      let input = request["input"] as? [String: Any] ?? [:]
      // AskUserQuestion arrives here too (stdio has no dialog channel), but it is a set of
      // choices, not an allow/deny. Surface it as a question card; everything else is an
      // approval.
      if toolName == "AskUserQuestion" {
        let questions = Self.parseQuestions(input)
        if !questions.isEmpty {
          pendingQuestion = PendingQuestion(requestID: requestID, questions: questions)
          state = .needsAttention
          touch()  // needing you is activity; float it up so it is easy to find
          onStateChange?()
          return
        }
      }
      pendingApproval = PendingApproval(
        requestID: requestID,
        toolName: toolName,
        // ExitPlanMode isn't a tool to name on the card — it's the "ready to proceed?"
        // checkpoint. Ask the question the CLI asks; the plan itself is in the transcript.
        title: toolName == "ExitPlanMode"
          ? "Would you like to proceed?"
          : (request["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? toolName,
        detail: Transcript.summarize(tool: toolName, input: input),
        input: input)
      state = .needsAttention
      touch()  // needing you is activity; float it up so it is easy to find
      onStateChange?()

    case "result":
      pendingApproval = nil
      pendingQuestion = nil
      state = .idle
      if interruptedTurn {
        // We asked for this: the engine ends the turn it cut with an error result. That is
        // not a failure to report — a redirect's next turn (if any) follows immediately.
        interruptedTurn = false
        append(Transcript.note("Interrupted"))
      } else if event.subtype != "success" {
        append(Transcript.error("Stopped (\(event.subtype ?? "unknown"))"))
      } else {
        append(Transcript.text("\n"))
      }
      // Delivers the next type-ahead line, if any, which reopens `state`/`isTurnActive`.
      flushQueue()
      onStateChange?()
      refreshCostEstimate()

    case "system" where event.subtype == "init":
      // The starting point, before any worktree the agent may create. Moves are detected separately.
      state = .running
      // The engine reports the model and permission mode it actually started with, so the
      // pickers reflect reality — the model it remembered across --resume, and the mode as it
      // stands (which the engine forgets on resume, so it reads back as default until we
      // re-apply). `reportedModel` is a resolved id; the picker maps it via the roster.
      if let reported = event.payload["model"] as? String {
        reportedModel = reported
        // Also fold it into `model` (mapped from the resolved id to a picker value) so the
        // value is remembered and shown instantly on the next launch — without this, the
        // picker flashes the default until this event arrives after a resume.
        if let match = availableModels.first(where: {
          $0.resolvedModel == reported || $0.value == reported
        }) {
          model = match.value
        }
      }
      if let raw = event.payload["permissionMode"] as? String,
        let mode = PermissionMode(rawValue: raw)
      {
        permissionMode = mode
      }
      onStateChange?()

    default:
      break
    }
  }
}

/// The Kit's click delegate routes fold edits through this, keeping the session's transcript
/// and the view's storage in step (see `editTranscript`).
extension AgentSession: TranscriptStorageMirror {}

/// One shell running under a PTY. Not a peer of AgentSession — both are children of a Worktree.
final class TerminalSession {
  let id: UUID
  let worktreeID: UUID
  var title: String

  init(id: UUID = UUID(), worktreeID: UUID, title: String = "zsh") {
    self.id = id
    self.worktreeID = worktreeID
    self.title = title
  }
}

enum FileSidebarMode: String {
  case changed
  case all
}

/// One window is one Workspace, holding several worktrees.
final class Workspace {
  /// The open repositories, each owning the worktrees git enumerates for it. This is the one
  /// list; `worktrees` is a flattening of it, so the two can never fall out of step.
  var repositories: [Repository] = []
  var worktrees: [Worktree] { repositories.flatMap(\.worktrees) }
  var sessions: [AgentSession] = []
  var terminals: [TerminalSession] = []

  /// Something arrived that the rail is showing — a session title read in the background,
  /// for instance. Set by the window that owns this workspace.
  var onSessionsChanged: (() -> Void)?

  /// A worktree's files moved on disk (an agent edit, a terminal command, an external editor)
  /// and the working set actually changed. Carries the worktree id so the window can refresh
  /// just that one's rail badge, and the file column too when it is the one on screen. Set by
  /// the window that owns this workspace.
  var onWorktreeFilesChanged: ((UUID) -> Void)?

  /// One filesystem watcher per open worktree, keyed by worktree id. Reconciled against the
  /// worktree list by `syncWatchers()` rather than started at each call site, so however a
  /// worktree arrives — opened, restored, or enumerated on focus — it ends up watched exactly
  /// once, the same way `worktrees` is just a flattening of `repositories`.
  private var watchers: [UUID: WorktreeWatcher] = [:]

  var selectedWorktreeID: UUID?
  var selectedSessionID: UUID?
  var isOverview = false
  var fileSidebarMode: FileSidebarMode = .changed

  /// The rail's disclosure state, held here (not on the rail view) so it survives a restart the
  /// same way the column widths and selection do — it is display state a reload rebuilds, so the
  /// choices have to outlive both the reload and the process. `collapsedRepositories` is keyed by
  /// repository id; the two bucket sets record buckets flipped away from their default (a key in
  /// neither follows the default), keyed by bucket id.
  var collapsedRepositories: Set<String> = []
  var bucketsCollapsedByUser: Set<String> = []
  var bucketsExpandedByUser: Set<String> = []

  /// How wide each column was left: rail, running agent, and the file column's own sidebar.
  /// Empty until the layout has been arranged once.
  ///
  /// This rides in the window's restorable state rather than a split view `autosaveName`,
  /// for the same reason the open repositories do: an autosave name is one global setting,
  /// so a second window could not hold a different arrangement, and the widths would drift
  /// away from the frame and Space that AppKit restores alongside them.
  var columnWidths: [Double] = []

  /// Per-session composer choices: the permission mode and reasoning effort the engine does not
  /// remember across --resume, plus the model — which the engine does remember, so it is kept
  /// for display continuity only, never forced (see `applyRestoredPrefs`).
  /// Restored from disk keyed by session id string and applied as discovery rebuilds the
  /// sessions, so a session set to Bypass comes back as Bypass. This is a preference map, never
  /// the session list — sessions stay disk-derived — so it cannot corrupt what git and Claude
  /// Code own, and a stale entry for a gone session is simply ignored.
  private var restoredPrefs: [String: (mode: PermissionMode, effort: String, model: String)] = [:]
  /// Type-ahead restored from disk, keyed by session id, applied as discovery rebuilds the
  /// sessions. Same disposable, disk-derived-list philosophy as the prefs map.
  private var restoredQueues: [String: [String]] = [:]
  /// Unsent composer drafts restored from disk, keyed by session id. Same philosophy again.
  private var restoredDrafts: [String: String] = [:]
  /// The model roster each session last saw the engine advertise, keyed by session id. Held per
  /// session, not shared — so a restored session that has not connected yet shows the list it
  /// itself saw, and seeds its own picker with it (see `applyRestoredPrefs`) rather than borrowing
  /// another session's. A New Session eager-starts and learns its own; a session's live reply wins
  /// the moment it arrives (`seedModels` never overwrites it).
  private var restoredRosters: [String: [ClaudeModel]] = [:]

  /// Set a freshly-discovered session's mode/effort/model from what was restored, if anything
  /// was. The model is display continuity only — it is shown until the engine confirms the real
  /// one on resume; it is never forced onto the engine (the engine remembers the model itself).
  /// Restored type-ahead rides along here too: put back as drafts, never re-sent on its own.
  func applyRestoredPrefs(to session: AgentSession) {
    if let prefs = restoredPrefs[session.id.uuidString] {
      session.permissionMode = prefs.mode
      session.effort = prefs.effort
      if !prefs.model.isEmpty { session.model = prefs.model }
    }
    if let queue = restoredQueues[session.id.uuidString] {
      session.restoreQueue(queue)
    }
    if let draft = restoredDrafts[session.id.uuidString] {
      session.draft = draft
    }
    // Show this session's own last-seen roster until it connects and reports a fresh one (a
    // restored session stays lazy, so without this its picker would flash the fallback until the
    // first send).
    if let roster = restoredRosters[session.id.uuidString] {
      session.seedModels(roster)
    }
  }

  init() {}

  func worktree(id: UUID) -> Worktree? { worktrees.first { $0.id == id } }
  func sessions(inWorktree worktreeID: UUID) -> [AgentSession] {
    sessions.filter { $0.worktreeID == worktreeID }
  }

  /// A worktree can carry several sessions, including restored detached ones. With no explicit
  /// selection (the restored one may be gone), fall back to the most recently active — after a
  /// restart the array runs newest-to-oldest, so `.last` here would resurrect the worktree's
  /// oldest husk. Explicit selection still wins: creating a session sets `selectedSessionID`
  /// before its first activity, so a just-created session never loses to an older one.
  var selectedSession: AgentSession? {
    guard let worktreeID = selectedWorktreeID else { return nil }
    let candidates = sessions(inWorktree: worktreeID)
    if let id = selectedSessionID, let session = candidates.first(where: { $0.id == id }) {
      return session
    }
    return candidates.max { $0.updatedAt < $1.updatedAt }
  }

  func terminals(inWorktree worktreeID: UUID) -> [TerminalSession] {
    terminals.filter { $0.worktreeID == worktreeID }
  }

  /// One row per session. The session is what is being supervised; the worktree it currently
  /// sits in is an attribute of it, not a level of the hierarchy. A worktree with no session is
  /// not a row — the repository heading (and its `+`) is where a first session is started, so a
  /// session-less worktree would only be noise in a rail that exists to watch running agents.
  struct RailEntry {
    let session: AgentSession
    let worktree: Worktree
  }

  var groupedEntries: [(repositoryID: String, repositoryName: String, entries: [RailEntry])] {
    var order: [String] = []
    var names: [String: String] = [:]
    var buckets: [String: [RailEntry]] = [:]

    for worktree in worktrees {
      let key = worktree.repositoryID
      // Every worktree registers its repository so the heading shows even before a first
      // session — that heading's `+` is how the first one is started.
      if buckets[key] == nil {
        order.append(key)
        names[key] = worktree.repositoryName
        buckets[key] = []
      }
      buckets[key]?.append(
        contentsOf: sessions(inWorktree: worktree.id).map {
          RailEntry(session: $0, worktree: worktree)
        })
    }
    // Within each repository the rows sit most-recently-active first, so an agent that just
    // spoke rises to the top of its group and the rail reads top-down as "what moved last".
    // The repository order itself stays put — reshuffling the headings on every message would
    // be more disorienting than helpful. Ties break on id to keep the order stable across
    // reloads (a wobble there would animate for no reason).
    return order.map { key in
      let sorted = (buckets[key] ?? []).sorted { lhs, rhs in
        let (l, r) = (Self.recency(lhs), Self.recency(rhs))
        if l.date != r.date { return l.date > r.date }
        return l.tiebreak < r.tiebreak
      }
      return (key, names[key] ?? key, sorted)
    }
  }

  /// The rail's sort key for one row: when you last instructed it, plus a stable id to break ties.
  private static func recency(_ entry: RailEntry) -> (date: Date, tiebreak: String) {
    (entry.session.lastInstructedAt, entry.session.id.uuidString)
  }

  /// When you last instructed a session, coarsened to a bucket. The rail folds a long tail of
  /// finished conversations under "Older" (collapsed by default) so a worktree that has carried
  /// many attempts still reads at a glance — the point of the whole view. Bucketing is derived
  /// from `lastInstructedAt` on the fly, so no bucket assignment is stored that could disagree.
  enum TimeBucket: Int, CaseIterable {
    case today, yesterday, thisWeek, older
    var title: String {
      switch self {
      case .today: return "Today"
      case .yesterday: return "Yesterday"
      case .thisWeek: return "This week"
      case .older: return "Older"
      }
    }
    /// "Older" is the only bucket the rail hides until asked. A session instructed long ago can
    /// sit there even while it works or waits — accepted deliberately (see `lastInstructedAt`):
    /// `Cmd+Return`, not rail position, is how you reach a waiting session.
    var collapsedByDefault: Bool { self == .older }
  }

  static func bucket(for date: Date, now: Date = Date(), calendar: Calendar = .current)
    -> TimeBucket
  {
    if calendar.isDateInToday(date) { return .today }
    if calendar.isDateInYesterday(date) { return .yesterday }
    if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date >= weekAgo {
      return .thisWeek
    }
    return .older
  }

  /// A repository's sessions split into time buckets by when each last spoke. Buckets come out
  /// newest-first and empty ones are dropped, so the rail only ever shows a heading that has
  /// rows under it — or a bare repository heading when nothing has run there yet.
  struct RailSection {
    let repositoryID: String
    let repositoryName: String
    let buckets: [(bucket: TimeBucket, entries: [RailEntry])]
  }

  var groupedSections: [RailSection] {
    let now = Date()
    return groupedEntries.map { group in
      var buckets: [TimeBucket: [RailEntry]] = [:]
      for entry in group.entries {
        buckets[Self.bucket(for: entry.session.lastInstructedAt, now: now), default: []].append(
          entry)
      }
      let sections = TimeBucket.allCases.compactMap {
        bucket -> (bucket: TimeBucket, entries: [RailEntry])? in
        guard let entries = buckets[bucket], !entries.isEmpty else { return nil }
        return (bucket, entries)
      }
      return RailSection(
        repositoryID: group.repositoryID, repositoryName: group.repositoryName,
        buckets: sections)
    }
  }

  /// Close a repository: drop it and every worktree of it from the window, stopping any
  /// agent still attached. Nothing on disk is touched — the worktrees stay in git and the
  /// transcripts stay where Claude Code put them, so reopening brings it all back.
  func closeRepository(_ repositoryID: String) {
    guard let repo = repositories.first(where: { $0.id == repositoryID }) else { return }
    let doomed = Set(repo.worktrees.map(\.id))
    for session in sessions where doomed.contains(session.worktreeID) { session.stop() }
    sessions.removeAll { doomed.contains($0.worktreeID) }
    repositories.removeAll { $0.id == repositoryID }
    syncWatchers()
    if let selected = selectedWorktreeID, doomed.contains(selected) {
      selectedWorktreeID = worktrees.first?.id
      selectedSessionID = nil
    }
  }

  /// The repository with this id, created and registered if it is the first worktree of it to
  /// arrive. Worktrees intern their repository through here, so every worktree of one
  /// repository shares a single object and the id/name are computed in exactly one place.
  private func repository(forID id: String) -> Repository {
    if let existing = repositories.first(where: { $0.id == id }) { return existing }
    let repository = Repository(id: id)
    repositories.append(repository)
    return repository
  }

  /// Open a repository: register its checkout and pull in whatever git and Claude Code
  /// already know about it. Adding is the only moment worth paying for the git queries —
  /// doing it on every redraw would spawn processes constantly.
  @discardableResult
  func openRepository(_ url: URL) -> Worktree {
    let worktree = addWorktree(url)
    discoverSessions()
    return worktree
  }

  /// Never add the same path twice. Appending command-line worktrees to restored ones grew the
  /// list on every launch (which is exactly what happened). Also covers picking the same
  /// folder twice from the open panel.
  @discardableResult
  func addWorktree(_ url: URL) -> Worktree {
    // However the return is reached — a fresh worktree or one already open — leave the watcher
    // set matching the worktree set. Idempotent, so the already-open branch is a no-op.
    defer { syncWatchers() }
    let path = url.standardizedFileURL.path
    if let existing = worktrees.first(where: { $0.url.standardizedFileURL.path == path }) {
      if selectedWorktreeID == nil { selectedWorktreeID = existing.id }
      return existing
    }
    let repo = repository(forID: Git.repository(at: url) ?? path)
    let worktree = Worktree(url: url, branch: Git.currentBranch(at: url), repository: repo)
    repo.worktrees.append(worktree)
    if selectedWorktreeID == nil { selectedWorktreeID = worktree.id }
    return worktree
  }

  // MARK: - Restoration

  /// Only "which worktrees are open" and a little UI state are ours to keep. Worktrees belong
  /// to git and sessions belong to Claude Code; storing either here would create a second
  /// copy that can disagree with the real one — and storing sessions is exactly what let a
  /// failed restore write an empty list back over the good one.
  ///
  /// What is left is paths and strings, which is what AppKit's restorable state handles
  /// well. Keeping it here rather than in our own file means window geometry, Space
  /// assignment and contents all restore together, and a second window can hold a
  /// different set of worktrees without any of them fighting over one global file.
  private enum Key {
    static let worktreePaths = "worktrees.paths"
    static let worktreeIDs = "worktrees.ids"
    static let selectedWorktreeID = "selectedWorktreeID"
    static let selectedSessionID = "selectedSessionID"
    static let isOverview = "isOverview"
    static let fileSidebarMode = "fileSidebarMode"
    static let columnWidths = "columnWidths"
    static let collapsedRepositories = "rail.collapsedRepositories"
    static let bucketsCollapsed = "rail.bucketsCollapsed"
    static let bucketsExpanded = "rail.bucketsExpanded"
    // Per-session composer choices: mode and effort the engine forgets across --resume, plus
    // the model for display continuity. Parallel arrays because secure restorable state only
    // keeps strings, numbers and arrays.
    static let prefSessionIDs = "sessionPrefs.ids"
    static let prefModes = "sessionPrefs.modes"
    static let prefEfforts = "sessionPrefs.efforts"
    static let prefModels = "sessionPrefs.models"
    static let queueSessionIDs = "queue.ids"
    static let queueMessages = "queue.messages"
    static let draftSessionIDs = "draft.ids"
    static let draftTexts = "draft.texts"
    // Each session's last-seen model roster, keyed by session id like the choices above — not one
    // shared list. `ids` names the sessions; the three field arrays are nested (one inner array per
    // session), the same shape `queue.messages` uses (secure restorable state keeps only strings,
    // numbers and arrays).
    static let rosterSessionIDs = "roster.ids"
    static let rosterValues = "roster.values"
    static let rosterNames = "roster.names"
    static let rosterResolved = "roster.resolved"
  }

  func encodeState(to coder: NSCoder) {
    coder.encode(worktrees.map(\.url.path) as NSArray, forKey: Key.worktreePaths)
    coder.encode(worktrees.map(\.id.uuidString) as NSArray, forKey: Key.worktreeIDs)
    coder.encode(selectedWorktreeID?.uuidString ?? "", forKey: Key.selectedWorktreeID)
    // The session being looked at is as much "where you were" as the worktree it sits in.
    // The session itself stays disk-derived; only the pointer is stored, and one that no
    // longer resolves after a restart falls back to the most recently active session.
    coder.encode(selectedSessionID?.uuidString ?? "", forKey: Key.selectedSessionID)
    coder.encode(isOverview, forKey: Key.isOverview)
    coder.encode(fileSidebarMode.rawValue, forKey: Key.fileSidebarMode)
    coder.encode(columnWidths.map(NSNumber.init(value:)) as NSArray, forKey: Key.columnWidths)
    coder.encode(Array(collapsedRepositories) as NSArray, forKey: Key.collapsedRepositories)
    coder.encode(Array(bucketsCollapsedByUser) as NSArray, forKey: Key.bucketsCollapsed)
    coder.encode(Array(bucketsExpandedByUser) as NSArray, forKey: Key.bucketsExpanded)

    // Sessions worth storing: a non-default mode/effort, or one that has run (so its model is
    // known and can be shown instantly next launch instead of flashing the default). This is a
    // preference map, not the session list — sessions stay disk-derived — so a stale entry for
    // a session that is gone is simply ignored.
    let customised = sessions.filter {
      $0.permissionMode != AgentSession.defaultPermissionMode || $0.effort != "default"
        || $0.reportedModel != nil
    }
    coder.encode(customised.map(\.id.uuidString) as NSArray, forKey: Key.prefSessionIDs)
    coder.encode(customised.map(\.permissionMode.rawValue) as NSArray, forKey: Key.prefModes)
    coder.encode(customised.map(\.effort) as NSArray, forKey: Key.prefEfforts)
    coder.encode(customised.map(\.model) as NSArray, forKey: Key.prefModels)

    // Type-ahead the agent has not consumed yet: kept per session so a restart does not throw
    // away lines you queued while it was working. Restored as drafts, not re-sent (see
    // applyRestoredPrefs) — nested arrays because a queued line can itself contain newlines.
    let withQueue = sessions.filter { !$0.queuedMessages.isEmpty }
    coder.encode(withQueue.map(\.id.uuidString) as NSArray, forKey: Key.queueSessionIDs)
    coder.encode(
      withQueue.map { $0.queuedMessages as NSArray } as NSArray, forKey: Key.queueMessages)

    // The composer draft you were part-way through typing, kept per session so a restart does
    // not lose it. Parallel string arrays, same map-not-list rule as everything above.
    let withDraft = sessions.filter { !$0.draft.isEmpty }
    coder.encode(withDraft.map(\.id.uuidString) as NSArray, forKey: Key.draftSessionIDs)
    coder.encode(withDraft.map(\.draft) as NSArray, forKey: Key.draftTexts)

    // Each session's own last-seen roster, so next launch its picker shows the real list before it
    // reconnects. Kept per session (not one shared list), nested arrays keyed by session id — a
    // stale entry for a session that is gone is simply ignored on restore.
    let withRoster = sessions.filter { !$0.availableModels.isEmpty }
    coder.encode(withRoster.map(\.id.uuidString) as NSArray, forKey: Key.rosterSessionIDs)
    coder.encode(
      withRoster.map { $0.availableModels.map(\.value) as NSArray } as NSArray,
      forKey: Key.rosterValues)
    coder.encode(
      withRoster.map { $0.availableModels.map(\.displayName) as NSArray } as NSArray,
      forKey: Key.rosterNames)
    coder.encode(
      withRoster.map { $0.availableModels.map(\.resolvedModel) as NSArray } as NSArray,
      forKey: Key.rosterResolved)
  }

  func decodeState(from coder: NSCoder) {
    let paths = strings(coder, Key.worktreePaths)
    let ids = strings(coder, Key.worktreeIDs)
    var seen = Set<String>()
    repositories = []
    for (path, idString) in zip(paths, ids) {
      guard let id = UUID(uuidString: idString) else { continue }
      let url = URL(fileURLWithPath: path)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        isDirectory.boolValue,
        seen.insert(url.standardizedFileURL.path).inserted
      else { continue }
      let repo = repository(forID: Git.repository(at: url) ?? url.standardizedFileURL.path)
      repo.worktrees.append(
        Worktree(id: id, url: url, branch: Git.currentBranch(at: url), repository: repo))
    }

    // Restored worktrees are built inline above rather than through addWorktree, so reconcile
    // watchers here too — otherwise the set opened last session would come back unwatched.
    syncWatchers()

    if let selected = coder.decodeObject(of: NSString.self, forKey: Key.selectedWorktreeID)
      as String?,
      let id = UUID(uuidString: selected)
    {
      selectedWorktreeID = id
    }
    // Sessions do not exist yet at this point — discovery builds them later. The pointer is
    // held anyway; `selectedSession` matches it once the session list is rebuilt.
    if let selected = coder.decodeObject(of: NSString.self, forKey: Key.selectedSessionID)
      as String?,
      let id = UUID(uuidString: selected)
    {
      selectedSessionID = id
    }
    columnWidths =
      (coder.decodeArrayOfObjects(ofClass: NSNumber.self, forKey: Key.columnWidths) ?? [])
      .map(\.doubleValue)
    isOverview = coder.decodeBool(forKey: Key.isOverview)
    if let mode = coder.decodeObject(of: NSString.self, forKey: Key.fileSidebarMode) as String?,
      let parsed = FileSidebarMode(rawValue: mode)
    {
      fileSidebarMode = parsed
    }
    collapsedRepositories = Set(strings(coder, Key.collapsedRepositories))
    bucketsCollapsedByUser = Set(strings(coder, Key.bucketsCollapsed))
    bucketsExpandedByUser = Set(strings(coder, Key.bucketsExpanded))

    // Hold the per-session preferences until discoverSessions builds the sessions to apply them
    // to (via applyRestoredPrefs). Kept as a map so it survives repeated discovery.
    let prefIDs = strings(coder, Key.prefSessionIDs)
    let prefModes = strings(coder, Key.prefModes)
    let prefEfforts = strings(coder, Key.prefEfforts)
    let prefModels = strings(coder, Key.prefModels)
    restoredPrefs = [:]
    for (index, idString) in prefIDs.enumerated() {
      let mode =
        index < prefModes.count ? PermissionMode(rawValue: prefModes[index]) ?? .default : .default
      let effort = index < prefEfforts.count ? prefEfforts[index] : "default"
      let model = index < prefModels.count ? prefModels[index] : ""
      restoredPrefs[idString] = (mode, effort, model)
    }

    let queueIDs = strings(coder, Key.queueSessionIDs)
    let queueBlocks =
      (coder.decodeObject(of: [NSArray.self, NSString.self], forKey: Key.queueMessages)
        as? [[String]]) ?? []
    restoredQueues = [:]
    for (index, idString) in queueIDs.enumerated() where index < queueBlocks.count {
      restoredQueues[idString] = queueBlocks[index]
    }

    let draftIDs = strings(coder, Key.draftSessionIDs)
    let draftTexts = strings(coder, Key.draftTexts)
    restoredDrafts = [:]
    for (index, idString) in draftIDs.enumerated() where index < draftTexts.count {
      restoredDrafts[idString] = draftTexts[index]
    }

    // Rebuild each session's roster before discovery, so `applyRestoredPrefs` can seed it into that
    // session's own picker. Nested arrays keyed by session id; a short field going missing falls
    // back to the value string.
    let rosterIDs = strings(coder, Key.rosterSessionIDs)
    let rosterValues = nestedStrings(coder, Key.rosterValues)
    let rosterNames = nestedStrings(coder, Key.rosterNames)
    let rosterResolved = nestedStrings(coder, Key.rosterResolved)
    restoredRosters = [:]
    for (index, idString) in rosterIDs.enumerated() where index < rosterValues.count {
      let values = rosterValues[index]
      let names = index < rosterNames.count ? rosterNames[index] : []
      let resolved = index < rosterResolved.count ? rosterResolved[index] : []
      restoredRosters[idString] = values.enumerated().map { i, value in
        ClaudeModel(
          value: value,
          displayName: i < names.count ? names[i] : value,
          resolvedModel: i < resolved.count ? resolved[i] : value)
      }
    }

    // The session list is never stored — it is read back off disk every time.
    discoverSessions()
  }

  private func strings(_ coder: NSCoder, _ key: String) -> [String] {
    (coder.decodeArrayOfObjects(ofClass: NSString.self, forKey: key) ?? []).map { $0 as String }
  }

  /// An array of string arrays — the shape used for per-session nested values (queued lines, each
  /// session's roster fields). Decoding the outer and inner `NSArray`/`NSString` in one call.
  private func nestedStrings(_ coder: NSCoder, _ key: String) -> [[String]] {
    (coder.decodeObject(of: [NSArray.self, NSString.self], forKey: key) as? [[String]]) ?? []
  }
}

extension Workspace {
  /// Rebuild the session list from what is on disk: for every open worktree, ask git for its
  /// worktrees, then list the transcripts recorded against each one.
  ///
  /// Nothing is imported and nothing is stored on our side, so there is no list to corrupt
  /// and no husks to accumulate. A worktree that gets landed or discarded takes its
  /// sessions out of the rail with it. Old sessions are not dropped — they fold into the
  /// "Older" time bucket (collapsed by default), which is what keeps the rail glanceable
  /// without hiding history; a base checkout that has carried many sessions is exactly the
  /// long tail that bucket exists to hold.
  func discoverSessions() {
    let live = sessions.filter { $0.isRunning }
    var known = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var rebuilt: [AgentSession] = []
    var visited = Set<String>()

    for worktree in worktrees {
      for worktree in Git.worktrees(at: worktree.url) {
        let path = worktree.standardizedFileURL.path
        guard visited.insert(path).inserted else { continue }

        let found = ClaudeSessionStore.sessions(in: worktree)

        // git lists it, so it exists — register it even with no sessions. Hiding a
        // session-less worktree would leave a state git disagrees with, and one created
        // behind the app's back (`git worktree add` in a terminal) would never surface.
        // It contributes no rail row of its own — only its repository heading, so the
        // heading's `+` is there to start a first session — and leaves only by landing.
        // A worktree holding sessions likewise becomes a worktree of its own, which is how
        // it reappears in the rail after a restart without us recording anything.
        let owner = self.worktree(atPath: path) ?? addWorktree(worktree)
        for entry in found {
          let session: AgentSession
          if let existing = known.removeValue(forKey: entry.id) {
            // Already live/known — keep its current mode/effort (may hold a live change).
            session = existing
          } else {
            session = AgentSession(id: entry.id, worktreeID: owner.id, isDetached: true)
            applyRestoredPrefs(to: session)
            // Seed both recency keys from the transcript's mtime, so a restored session
            // already sits in the right place before it has said anything or been sent to.
            session.updatedAt = entry.modified
            session.lastInstructedAt = entry.modified
          }
          session.worktreeID = owner.id
          rebuilt.append(session)
        }
      }
    }

    // A session created moments ago has no transcript yet; keep anything still attached.
    for session in live where !rebuilt.contains(where: { $0.id == session.id }) {
      rebuilt.append(session)
    }
    sessions = rebuilt
    loadTitles()
  }

  /// Name every session that does not have one yet.
  ///
  /// The rail is what gets scanned at a glance, so a column of identical "New session" rows
  /// defeats the point of it. Reading happens off the main thread and lands as it arrives —
  /// nothing waits on it, and a session that has already been named is skipped, so repeated
  /// discovery costs nothing.
  private func loadTitles() {
    let requests = sessions.compactMap { session -> (UUID, URL)? in
      guard session.title == nil, let worktree = worktree(id: session.worktreeID) else {
        return nil
      }
      return (session.id, worktree.url)
    }
    guard !requests.isEmpty else { return }

    DispatchQueue.global(qos: .utility).async { [weak self] in
      let found = requests.compactMap { id, url in
        ClaudeSessionStore.title(id: id, worktree: url).map { (id, $0) }
      }
      guard !found.isEmpty else { return }
      DispatchQueue.main.async {
        guard let self else { return }
        var changed = false
        for (id, title) in found {
          guard let session = self.sessions.first(where: { $0.id == id }), session.title == nil
          else { continue }
          session.title = title
          changed = true
        }
        if changed { self.onSessionsChanged?() }
      }
    }
  }

  func worktree(atPath path: String) -> Worktree? {
    worktrees.first { $0.url.standardizedFileURL.path == path }
  }

  /// git queries spawn processes, so keep them off the main thread.
  /// Re-read git state that can change behind the app's back — most visibly the current branch
  /// after a `git checkout` in a terminal, which the rail and top bar show but only cached at
  /// open time. Run when the window reactivates, not on every redraw (the reason branch was
  /// cached at all), and off the main thread since each read spawns a process. A branch move
  /// also shifts what the diff is measured against, so the files are marked stale to reload.
  func refreshGitState(completion: @escaping (_ changed: Bool) -> Void) {
    let targets = worktrees
    // One representative checkout per repository. Every worktree of a repository enumerates
    // the same set, so `git worktree list` at each repository's main checkout once is enough.
    let repositories = Set(targets.map { $0.repositoryID }).map { URL(fileURLWithPath: $0) }
    DispatchQueue.global(qos: .userInitiated).async {
      let branches = targets.map { ($0, Git.currentBranch(at: $0.url)) }
      let listed = repositories.flatMap { Git.worktrees(at: $0) }
      DispatchQueue.main.async {
        var changed = false
        for (worktree, branch) in branches where branch != worktree.branch {
          worktree.branch = branch
          worktree.hasLoadedFiles = false
          changed = true
        }
        // A worktree added behind the app's back should surface on return, the same way a
        // branch move does — git's enumeration is the authority, so anything it lists that
        // we do not know yet joins the rail (grouped under its repository by addWorktree).
        for url in listed {
          let path = url.standardizedFileURL.path
          guard !self.worktrees.contains(where: { $0.url.standardizedFileURL.path == path })
          else { continue }
          self.addWorktree(url)
          changed = true
        }
        completion(changed)
      }
    }
  }

  func loadFiles(worktreeID: UUID, completion: @escaping () -> Void) {
    guard let worktree = worktree(id: worktreeID) else { return completion() }
    let url = worktree.url
    DispatchQueue.global(qos: .userInitiated).async {
      // Uncommitted work only: measured against HEAD, the same for the main checkout and a
      // linked worktree. "Changed" is what has not been committed yet, not the whole branch.
      let changed = Git.changedFiles(at: url, since: "HEAD")
      let tracked = Git.trackedFiles(at: url)
      DispatchQueue.main.async {
        worktree.changedFiles = changed
        worktree.trackedFiles = tracked
        worktree.hasLoadedFiles = true
        completion()
      }
    }
  }

  /// Start a watcher for every open worktree and drop watchers whose worktree has left.
  /// Idempotent: a worktree already watched keeps its watcher, so calling this after any path
  /// that adds or removes worktrees is cheap and cannot double-watch. Dropping a watcher
  /// releases it, and its deinit stops the FSEvents stream.
  func syncWatchers() {
    let live = Set(worktrees.map(\.id))
    watchers = watchers.filter { live.contains($0.key) }
    for worktree in worktrees where watchers[worktree.id] == nil {
      let id = worktree.id
      watchers[id] = WorktreeWatcher(url: worktree.url) { [weak self] in
        self?.refreshFiles(worktreeID: id)
      }
    }
  }

  /// A file moved under a watched worktree — re-query git and, only if the working set
  /// actually shifted, adopt it and tell the window. Unlike `loadFiles` this ignores
  /// `hasLoadedFiles`: its whole point is to refresh a worktree that was already loaded. The
  /// equality check is what keeps a churning build — whose ignored files never reach git —
  /// from reloading the UI at all, so watching broadly costs nothing when nothing git-visible
  /// changed.
  func refreshFiles(worktreeID: UUID) {
    guard let worktree = worktree(id: worktreeID) else { return }
    let url = worktree.url
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let changed = Git.changedFiles(at: url, since: "HEAD")
      let tracked = Git.trackedFiles(at: url)
      DispatchQueue.main.async {
        guard let self, let worktree = self.worktree(id: worktreeID) else { return }
        guard worktree.changedFiles != changed || worktree.trackedFiles != tracked else { return }
        worktree.changedFiles = changed
        worktree.trackedFiles = tracked
        worktree.hasLoadedFiles = true
        self.onWorktreeFilesChanged?(worktreeID)
      }
    }
  }
}

/// git queries. Each one spawns a process, so callers should watch how often they run.
enum Git {
  /// Changes with line counts, measured against `base`. numstat reports "-" for binaries, so
  /// they read as 0.
  static func changedFiles(at url: URL, since base: String) -> [ChangedFile] {
    guard let output = run(["diff", "--numstat", base], at: url) else { return [] }
    return output.split(separator: "\n").compactMap { line in
      let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count == 3 else { return nil }
      return ChangedFile(
        path: String(parts[2]), added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0)
    }
  }

  /// The tracked list under git, otherwise a shallow walk of the real files. A Worktree is
  /// "a directory that may carry git information", so both cases have to work.
  static func trackedFiles(at url: URL) -> [String] {
    if let output = run(["ls-files"], at: url) {
      return output.split(separator: "\n").map(String.init)
    }
    let keys: [URLResourceKey] = [.isDirectoryKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [] }
    var paths: [String] = []
    let prefix = url.standardizedFileURL.path + "/"
    for case let fileURL as URL in enumerator {
      if (try? fileURL.resourceValues(forKeys: Set(keys)))?.isDirectory == true { continue }
      let path = fileURL.standardizedFileURL.path
      guard path.hasPrefix(prefix) else { continue }
      paths.append(String(path.dropFirst(prefix.count)))
      if paths.count >= 5000 { break }
    }
    return paths
  }

  static func diff(at url: URL, path: String, since base: String) -> String? {
    run(["diff", base, "--", path], at: url)
  }

  static func fileContents(at url: URL, path: String) -> String? {
    try? String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
  }
  static func currentBranch(at url: URL) -> String? {
    run(["rev-parse", "--abbrev-ref", "HEAD"], at: url)
  }

  /// The path every worktree of one repository has in common. Used as the repository's
  /// identity, with its last component as the display name.
  static func repository(at url: URL) -> String? {
    guard let common = run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: url)
    else { return nil }
    return URL(fileURLWithPath: common).deletingLastPathComponent().standardizedFileURL.path
  }

  static func worktrees(at url: URL) -> [URL] {
    guard let output = run(["worktree", "list", "--porcelain"], at: url) else { return [] }
    return output.split(separator: "\n").compactMap { line in
      line.hasPrefix("worktree ")
        ? URL(fileURLWithPath: String(line.dropFirst("worktree ".count))) : nil
    }
  }

  private static func run(_ arguments: [String], at url: URL) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = url
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }
}
