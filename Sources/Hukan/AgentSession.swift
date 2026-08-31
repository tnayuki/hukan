import AppKit
import Foundation

/// One choice offered by an `AskUserQuestion`.
struct QuestionOption {
  let label: String
  let description: String
  /// What choosing this would look like — a sketch the agent draws, in practice a few lines of
  /// monospaced ASCII. Where `description` says what the option means, this shows it, which is
  /// why the card gives it a block of its own rather than another line of prose. Usually empty.
  let preview: String
}

/// One question the agent is asking, with its options.
struct AgentQuestion {
  let header: String
  let question: String
  let options: [QuestionOption]
  /// Whether more than one option may be chosen. The picks come back as one comma-joined
  /// answer, so the line the model reads is the same shape either way.
  let multiSelect: Bool

  /// The ticked options' labels, in the order the agent offered them rather than the order they
  /// were ticked, so the answer reads the way the question did. Shared by the card's own Done
  /// and by a composer line answering as "Other", which carries the ticks along with it.
  func labels(ticked: Set<Int>) -> [String] {
    options.indices.filter(ticked.contains).map { options[$0].label }
  }
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
  /// The card's work in progress — which options are ticked, and which previews are open. It
  /// lives here rather than in the card because the running column rebuilds its cards on every
  /// state change, and an FSEvents batch arriving mid-answer would otherwise clear the ticks
  /// under you. Both are indexes into the current question's options, so both reset as the set
  /// advances (see `answerQuestion`).
  var ticked: Set<Int> = []
  var previewsOpen: Set<Int> = []
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

/// A line typed ahead while the agent was mid-turn, held as the pair the send handed over —
/// its text and whatever was attached to it, not one flattened string. Flattening was the bug:
/// a pasted screenshot became a `/var/folders` path in the message body, so the agent got a
/// path to read instead of the picture, and the path outlived the temp file in the transcript.
struct QueuedMessage {
  let text: String
  let attachments: [Attachment]

  /// Text with the attachment paths appended — the lossy form, and the only place it is still
  /// used: restorable state keeps strings, so a line that has to survive a quit carries its
  /// files as paths, which for a real file still opens next launch.
  var flattened: String {
    guard !attachments.isEmpty else { return text }
    return [text, attachments.map(\.path).joined(separator: "\n")]
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }
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

  /// How long ago `date` was, at the coarsest unit that still says something — `12s`, `3m`, `5h`,
  /// `2d` — or nil for the distant past, which is a session nobody has instructed yet. The rail's
  /// rows and `hukan status` share it, so a row and its line in a dump never disagree.
  static func age(since date: Date, at now: Date = Date()) -> String? {
    guard date != .distantPast else { return nil }
    let seconds = max(Int(now.timeIntervalSince(date)), 0)
    switch seconds {
    case ..<60: return "\(seconds)s"
    case ..<3600: return "\(seconds / 60)m"
    case ..<86400: return "\(seconds / 3600)h"
    default: return "\(seconds / 86400)d"
    }
  }
  /// A restored UUID has not been reattached with `claude --resume` yet. Showing it with
  /// the same face as a live session would be a lie, so keep them distinct.
  var isDetached = false

  /// Where this session's conversation is branched from, until the branch has been taken.
  ///
  /// A fork is a one-shot launch shape, not a standing property: the first `start` hands it to
  /// the engine, which writes the copied conversation into *this* session's transcript, and from
  /// then on it is an ordinary session that resumes its own file. Clearing it on that first
  /// launch is what keeps a later restart from branching the source a second time on top of the
  /// work already done here.
  var forkOrigin: ClaudeSession.ForkPoint?

  /// Where this session's own conversation is to be cut back to, until the cut has been made.
  ///
  /// Like `forkOrigin`, a one-shot launch shape: the engine resumes the transcript truncated at
  /// this record and writes what follows as a new branch of the same file, so every later launch
  /// loads the rolled-back conversation on its own and this must not be passed again. Nothing is
  /// deleted — the abandoned messages stay in the jsonl, simply no longer reachable from its tip
  /// (see `ClaudeSessionStore.liveBranch`).
  var rollbackAnchor: String?

  /// The uuid of the last transcript record the engine reported writing — the point a fork
  /// started from the next message would truncate at. Nil until the session has answered
  /// something: a conversation with nothing above it has no branch point, which is exactly the
  /// case where forking would produce an empty session rather than a branch.
  private(set) var lastRecordUUID: String?

  /// This conversation's user messages in order, each with its own uuid and the record it hangs
  /// off. A fork names the record *before* a message (that is what `--resume-session-at` keeps)
  /// while a rewind names the message itself, so one has to be looked up from the other — and
  /// the `…` menu only ever carries the anchor.
  ///
  /// Filled from both directions: the engine replays every message hukan sends, and a restored
  /// conversation carries the uuids off disk. Kept in order rather than as a map because a
  /// rollback has to leave the *preceding* message as the newest one, which a map cannot say.
  private var userMessages: [(anchor: String?, uuid: String)] = []

  /// The newest user message hukan knows of, which is what the engine wants as proof that no
  /// later turn is being cut away unseen. Nil before the first message of the session.
  private var lastUserMessageUUID: String? { userMessages.last?.uuid }

  /// This row came off Claude Code's registry rather than off a transcript — a `claude` started
  /// outside this window, listed while its process was alive and before it had written anything
  /// (see `Workspace.adoptRegisteredSessions`). It marks the two things nothing else answers
  /// for: once the hold lifts, a row that left no transcript behind was never a conversation and
  /// goes with its process — where a New Session opened here by hand is someone's intent and
  /// stays — and until the transcript arrives there is nobody to read a name off, so the row is
  /// what `syncTranscriptWatcher()` is waiting for.
  var isRegistryBorn = false

  /// A live pid in another process — a second hukan, a terminal `claude --resume`, or a crash
  /// orphan whose pid is still alive — that already owns this session id. Spawning a second
  /// engine on the same transcript would be two claudes writing one file, so hukan refuses:
  /// a held session shows greyed and unstartable, though its transcript still reads and searches
  /// from disk. Set by `markHeldElsewhere`; cleared on the holder's exit (watched directly, so
  /// the hold lifts on its own) or on a successful start of our own. The rail and scripting read
  /// it; they never set it.
  private(set) var heldByPID: pid_t?
  /// Fired whenever `heldByPID` changes, so the rail can re-grey the row. Distinct from
  /// `onStateChange`, which is wired only on a session the window has attached — the held state
  /// must show on a session nobody has selected, so this is wired on every session.
  var onHeldChange: (() -> Void)?
  /// Watches `heldByPID` for exit. Kept alive for the duration of the hold, cancelled when it
  /// lifts. A `DispatchSourceProcess.exit` fires on the holder's death whether it exits cleanly
  /// or crashes — it is the kernel's notification, not a file being removed — which is exactly
  /// the release edge the registry-directory watch would miss on a crash.
  private var holderExitSource: DispatchSourceProcess?

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
  /// The same counts split by the model that produced them (resolved id → totals), for the
  /// tooltip's per-model breakdown. Empty until history loads.
  var costTokensByModel: [String: ClaudeSessionStore.TokenTotals] = [:]

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

  /// The slash commands the engine advertised for this session, from the same reply — its
  /// built-ins and every skill and user command it found, in one list. Empty until the session
  /// has connected, which is why the window keeps the last one it saw and seeds it in: the moment
  /// a completion is most wanted is the first `/` typed into a session that has not started yet.
  private(set) var availableCommands: [ClaudeCommand] = []

  /// Type-ahead held while the agent is mid-turn. Writing a `user` message into a turn the
  /// engine is still working would race it; instead these queue and flush one at a time as
  /// each turn ends. Shown above the composer so a queued line is never invisible.
  private(set) var queuedMessages: [QueuedMessage] = []

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
  /// Set between `restart()`'s terminate and its `onExit`: the exit is a deliberate cycle, so the
  /// session comes straight back (resuming the transcript it just flushed) instead of settling
  /// idle. Unlike `pendingEffortRestart` this leaves the session detached — there is a transcript,
  /// so the respawn must `--resume`.
  private var pendingRestart = false
  /// Set between `stop()`'s terminate and its `onExit`: the exit is one we asked for, so `onExit`
  /// stays quiet instead of reporting the SIGTERM/SIGKILL status (143/137) as if the engine had
  /// crashed. The rail's state already shows the session went idle.
  private var deliberateStop = false

  /// Full history, replayed into the view when you switch away and come back.
  let transcript = NSMutableAttributedString()
  /// Receives only the appended fragment. Replacing the whole text per event is O(n²).
  var onAppend: ((NSAttributedString) -> Void)?
  var onStateChange: (() -> Void)?
  /// The whole transcript changed rather than grew, so the view has to re-read it.
  var onReload: (() -> Void)?
  /// Earlier conversation arrived at the *front* of the transcript — the argument is what was
  /// inserted at offset 0. Unlike `onReload` this must not reset the view: the reader is mid-
  /// scroll near the top, and the view's job is to slide the insertion in under them.
  var onPrepend: ((NSAttributedString) -> Void)?
  /// A span already on screen was rewritten in place — streamed text swapped for its
  /// formatted version. Replacing just the span keeps this off the length of the transcript.
  var onReplace: ((NSRange, NSAttributedString) -> Void)?
  /// A fold toggled somewhere in the middle of the transcript (see `editTranscript`). Unlike
  /// `onReplace` this must not scroll — the reader is looking at the fold, not the tail.
  var onEdit: ((NSRange, NSAttributedString) -> Void)?
  /// The agent moved into a worktree via EnterWorktree, so its location changed.
  var onEnterWorktree: ((URL) -> Void)?
  /// The agent left its worktree via ExitWorktree, so it is back where it was started. The
  /// argument is the engine's original working directory as the result reports it.
  var onExitWorktree: ((URL) -> Void)?
  /// The composer sent `/login` or `/logout` (the bare verb, without the slash). These need a
  /// real TTY for their OAuth/browser flow and cannot run over stream-json, so the window runs
  /// them in a terminal and reconnects the session afterwards.
  var onLoginRequested: ((String) -> Void)?
  /// The engine reported its slash commands. The window keeps them so every other session —
  /// including one that has never started — can complete against the same list.
  var onCommands: (([ClaudeCommand]) -> Void)?

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

  /// The agent's own task list, as last read from Claude Code's own store. Nothing of hukan's
  /// keeps it — `refreshTasks` re-reads the directory, which is what makes it survive a restart
  /// without being saved anywhere. Internal so tests can seed it.
  var tasks: [AgentTask] = []

  /// Whether the task card is open. UI state, but it belongs to the session and not to the card:
  /// the running column rebuilds its cards on every state change, so a view holding this would
  /// fold itself back the moment the agent did anything. Not saved — each launch starts folded.
  var tasksExpanded = false

  /// Whether there is a task card to show at all. A finished list is not one to show: the work a
  /// list describes ends with every task completed, so the card leaves when the work does — and
  /// a card still standing once the turn ended is the sign the work stopped half-done.
  var hasOpenTasks: Bool { tasks.contains { $0.status != .completed } }

  /// Re-read the task list from the engine's store. A no-op when nothing moved, which is what
  /// makes it safe to call from the same paths `onStateChange` drives: the change would
  /// otherwise reload the column, which reads the session again, which reads the store again.
  func refreshTasks() {
    let latest = ClaudeSessionStore.tasks(id: id)
    guard latest != tasks else { return }
    tasks = latest
    onStateChange?()
  }

  /// Where the assistant's current text block started, so its rendered span can be replaced in
  /// place as more of it streams in.
  private var streamStart: Int?
  /// Deltas received and not yet rendered. Rendering per SSE chunk re-parsed the accumulated
  /// message per token — O(n²) over a long reply, and enough main-thread time near the end of
  /// one to make scrolling stutter — so deltas pool here and land together, at most every
  /// `streamFlushInterval`. Anything that reads or moves the transcript between flushes calls
  /// `flushStreamRender` first, so the two copies' offsets never see a half-applied run.
  private var pendingStreamText = ""
  private var streamFlushScheduled = false
  /// The incremental renderer's carry, and how much of the streamed span it has settled — a
  /// length relative to `streamStart`, so an edit above the run shifts both together.
  private var streamState = Transcript.MarkdownStreamState()
  private var streamStableLength = 0
  /// ~2 deltas per flush at the API's usual chunk rate, and well under what a reader notices.
  static let streamFlushInterval: TimeInterval = 1.0 / 30.0

  private func scheduleStreamFlush() {
    guard !streamFlushScheduled else { return }
    streamFlushScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.streamFlushInterval) { [weak self] in
      guard let self else { return }
      self.streamFlushScheduled = false
      self.flushStreamRender()
    }
  }

  /// Land the pooled deltas: render the accumulated run so far and replace the part of the
  /// streamed span that could still change. The run is rendered as markdown while it streams so
  /// formatting shows before the block closes — a lone token can't be formatted ("**bo" is not
  /// bold yet), but the run so far can: unclosed markup renders literally until it closes, then
  /// snaps to formatted, the usual streaming look. `markdownStream` keeps the re-rendered part
  /// to the open tail, so a flush costs the tail and not the message.
  func flushStreamRender() {
    guard !pendingStreamText.isEmpty else { return }
    let delta = pendingStreamText
    // Cleared before `markTime`: the separator lands through `append`, which flushes first,
    // and must not find this flush's own text still pending.
    pendingStreamText = ""
    if streamStart == nil {
      markTime()
      streamStart = transcript.length
      streamState = Transcript.MarkdownStreamState()
      streamStableLength = 0
    }
    touch()  // streaming is activity; keep the rail's recency fresh
    let location = streamStart! + streamStableLength
    guard location <= transcript.length else {
      // The transcript moved under the run without the run being reset — nothing sane to
      // replace. Drop the pool; the buffered `assistant` event carries the whole text anyway.
      streamStart = nil
      return
    }
    let range = NSRange(location: location, length: transcript.length - location)
    let (stable, volatile) = Transcript.markdownStream(&streamState, appending: delta)
    let formatted = NSMutableAttributedString(attributedString: stable)
    formatted.append(volatile)
    transcript.replaceCharacters(in: range, with: formatted)
    onReplace?(range, formatted)
    streamStableLength += stable.length
  }

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
  /// The engine's pid while one is running, for the footprint gauge's split.
  var enginePID: pid_t? { runner?.processID }
  var isRunning: Bool { runner?.isRunning ?? false }

  init(id: UUID = UUID(), worktreeID: UUID, isDetached: Bool = false) {
    self.id = id
    self.worktreeID = worktreeID
    self.isDetached = isDetached
  }

  private var hasLoadedHistory = false

  /// Where this session's transcript has been read to, so what the holder writes next can be
  /// picked up without reading the file again — see `follow(at:)`. Nil until the history has
  /// been read, which is what makes "opened" the condition for following at all.
  private var historyCursor: ClaudeSessionStore.HistoryCursor?
  /// One tail read at a time. The file moves while the read is on its way, and a second read
  /// launched from the same cursor would take the same lines twice.
  private var isFollowing = false

  /// How much history renders at once: the tail shown on open, and the slice prepended per
  /// backward load. Renders and lays out in well under a frame's worth of anything a reader
  /// notices (~200 ms for a heavy 300), where a long conversation rendered whole costs seconds
  /// of main-thread layout — the freeze this bound exists to remove.
  static let historySliceCount = 300

  /// The records parsed but not yet rendered: everything above what the transcript shows,
  /// oldest first. Consumed from the end by `loadEarlierIfNeeded` as the reader scrolls up,
  /// and empty for a conversation short enough to render whole. Internal so tests can seed it.
  var pendingPrefix: [HistoryRecord] = []
  var hasPendingPrefix: Bool { !pendingPrefix.isEmpty }
  private var isLoadingEarlier = false

  /// The last stamp of the not-yet-rendered records — what the next slice's render inherits, so
  /// slices concatenate to exactly the whole-file render (see `Transcript.render`).
  private static func lastStamp(of records: [HistoryRecord]) -> Date? {
    records.reversed().compactMap(\.stamp).first
  }

  /// Pull the past conversation in from disk the first time this session is opened.
  ///
  /// Reading every transcript up front would mean an I/O storm on launch for sessions
  /// nobody looks at, so it happens on open — the same reasoning as lazy resume. The whole
  /// file is parsed (the conversation is a chain read back through `parentUuid`, so there is
  /// no partial parse), but only the last `historySliceCount` records are rendered and laid
  /// out; the rest wait in `pendingPrefix` for the reader to scroll up. That bound is what
  /// keeps opening a year-long conversation from freezing the window.
  func loadHistoryIfNeeded(at worktreeURL: URL) {
    lastKnownWorktree = worktreeURL
    guard !hasLoadedHistory else { return }
    hasLoadedHistory = true
    let id = self.id
    DispatchQueue.global(qos: .userInitiated).async {
      guard let history = ClaudeSessionStore.history(id: id, worktree: worktreeURL),
        !history.records.isEmpty
      else { return }
      let records = history.records
      let cut = max(0, records.count - Self.historySliceCount)
      let prefix = Array(records[..<cut])
      let rendered = Transcript.render(
        Array(records[cut...]), previousStamp: Self.lastStamp(of: prefix))
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.pendingPrefix = prefix
        self.historyCursor = history.cursor
        self.noteUserMessageUUIDs(in: records)
        // Inserted at the front, not appended: a session that resumed on the same
        // click may already have produced live output while this was being read — in which
        // case the streamed span just moved down by the insertion.
        self.transcript.insert(rendered, at: 0)
        if let start = self.streamStart { self.streamStart = start + rendered.length }
        if let title = history.title { self.title = title }
        self.costUSD = history.cost.usd
        self.costApproximate = history.cost.approximate
        self.costTokens = history.cost.tokens
        self.costTokensByModel = history.cost.byModel
        // Only when nothing live has happened yet, or this would drag the clock
        // backwards and suppress the separator the next message deserves.
        if self.lastStamp == nil { self.lastStamp = history.lastStamp }
        self.onReload?()
        self.onStateChange?()
      }
    }
  }

  /// Whether there is a conversation to follow: one another live process is writing, that this
  /// window has already read once.
  ///
  /// Both halves matter. A session hukan runs says what it is doing over its own stream, so its
  /// pane is never behind; a session nobody has opened has no pane for new records to go after,
  /// and gets the whole file read when it is opened. What is left is the case in between — the
  /// `claude` in a terminal whose conversation is on screen here — where the file is the only
  /// thing it says anything through.
  var isFollowable: Bool { heldByPID != nil && hasLoadedHistory }

  /// Take on whatever the holder has written since the last read.
  ///
  /// Called when the transcript's own file is seen to move, never on a clock: an agent writes a
  /// line every few seconds and a poll fast enough to feel live would be a re-read per second of
  /// a file that has not changed.
  func follow(at worktreeURL: URL) {
    // No cursor yet means the first read is still on its way; it will land with a cursor that
    // covers everything up to its own read, so nothing written in the meantime is missed — the
    // next time the file moves, the tail starts from there.
    guard let cursor = historyCursor, !isFollowing else { return }
    isFollowing = true
    let id = self.id
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let tail = ClaudeSessionStore.historyTail(id: id, worktree: worktreeURL, since: cursor)
      DispatchQueue.main.async {
        guard let self else { return }
        self.isFollowing = false
        switch tail {
        case .unchanged:
          break
        case .appended(let records, let cursor, let title):
          self.historyCursor = cursor
          if let title, self.title != title {
            self.title = title
            self.onStateChange?()
          }
          guard !records.isEmpty else { return }
          self.appendFollowed(records)
        case .rewritten:
          // The branch moved under us: the process that owns this conversation rolled it back,
          // which re-parents the tail rather than extending it. Nothing short of walking the
          // file again is honest about what the agent now remembers.
          self.reloadHistory(at: worktreeURL)
        }
      }
    }
  }

  /// Put records read off the file after what is already shown. The same rendering the live path
  /// uses, threaded through `lastStamp` so a pause the holder took draws its separator exactly
  /// where a whole-file render would have put one.
  private func appendFollowed(_ records: [HistoryRecord]) {
    let rendered = Transcript.render(records, previousStamp: lastStamp)
    guard rendered.length > 0 else { return }
    append(rendered)
    if let stamp = records.compactMap(\.stamp).last { lastStamp = stamp }
    noteUserMessageUUIDs(in: records)
  }

  /// Read the conversation again from the top, replacing what is on screen. Only for the
  /// rollback case above — everything else extends what is there.
  private func reloadHistory(at worktreeURL: URL) {
    transcript.deleteCharacters(in: NSRange(location: 0, length: transcript.length))
    pendingPrefix = []
    userMessages.removeAll()
    streamStart = nil
    lastStamp = nil
    historyCursor = nil
    hasLoadedHistory = false
    onReload?()
    loadHistoryIfNeeded(at: worktreeURL)
  }

  /// Whether a `user` event is a prompt someone typed rather than the engine answering its own
  /// tool call. Both arrive as `user`; only the first is a message a rewind can be aimed at.
  private static func isUserPrompt(_ payload: [String: Any]) -> Bool {
    guard let message = payload["message"] as? [String: Any] else { return false }
    if message["content"] is String { return true }
    guard let blocks = message["content"] as? [[String: Any]] else { return false }
    return blocks.contains { $0["type"] as? String != "tool_result" }
  }

  /// Learn where each of a restored conversation's messages sits, so a rollback can name one to
  /// the engine. Only the records that carry both halves are of any use: an anchor to be found
  /// by, and the uuid to rewind to.
  private func noteUserMessageUUIDs(in records: [HistoryRecord]) {
    // Every record here predates anything live: the read is async, so a session that resumed on
    // the same click may already have sent a message while this was on its way. The restored
    // ones therefore go in front of whatever is already there, the same way their render does.
    let restored = records.compactMap { record in
      record.messageUUID.map { (anchor: record.forkAnchor, uuid: $0) }
    }
    userMessages.insert(contentsOf: restored, at: 0)
  }

  /// Render the next slice of unrendered history and put it in front of the transcript, through
  /// `onPrepend`. `all` renders the entire remaining prefix in one pass — a search-hit jump
  /// carries an offset measured against the full render, which is only meaningful once nothing
  /// is missing above it. One load at a time; a scroll that asks again while one is in flight
  /// is satisfied by the answer already coming.
  func loadEarlierIfNeeded(all: Bool = false) {
    guard !pendingPrefix.isEmpty, !isLoadingEarlier else { return }
    isLoadingEarlier = true
    let cut = all ? 0 : max(0, pendingPrefix.count - Self.historySliceCount)
    let remaining = Array(pendingPrefix[..<cut])
    let slice = Array(pendingPrefix[cut...])
    DispatchQueue.global(qos: .userInitiated).async {
      let rendered = Transcript.render(slice, previousStamp: Self.lastStamp(of: remaining))
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.pendingPrefix = remaining
        self.isLoadingEarlier = false
        self.transcript.insert(rendered, at: 0)
        // The reader is scrolled up, but the agent may still be streaming below them.
        if let start = self.streamStart { self.streamStart = start + rendered.length }
        self.onPrepend?(rendered)
      }
    }
  }

  /// A branch inherits what its source has not rendered yet, so scrolling up in the fork keeps
  /// walking into the same past its pane was seeded from (see `seedForkedConversation`).
  func inheritPendingPrefix(from source: AgentSession) {
    pendingPrefix = source.pendingPrefix
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
        self.costTokensByModel = estimate.byModel
        self.onStateChange?()
      }
    }
  }

  /// Adopt the name Claude Code has settled on, if it has moved.
  ///
  /// The engine writes `ai-title` to the transcript and never mentions it over the pipes, so a
  /// running session's name is otherwise frozen at whatever it was when the session was first
  /// seen — hukan's guess from the first line typed, for a session started here, and it never
  /// catches a later rename either. Same shape as `refreshCostEstimate`, and for the same
  /// reason: the file is the master copy, so re-read it off the main thread at each turn's end
  /// (the engine writes the name early in the first turn, so one turn is enough to be named)
  /// and stay silent when nothing moved.
  private func refreshTitle() {
    guard let worktree = lastKnownWorktree else { return }
    let id = self.id
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let named = ClaudeSessionStore.aiTitle(id: id, worktree: worktree) else { return }
      DispatchQueue.main.async {
        guard let self, named != self.title else { return }
        self.title = named
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
      // Only narrate the refusal on a fresh hold, so a second send does not spam the transcript.
      // The hold itself greys the row and disables the composer; it clears on its own when the
      // owner exits (watched via `markHeldElsewhere`), whereupon the next send resumes.
      if heldByPID != owner {
        append(
          Transcript.error(
            "Not started — this session is already open in another process (pid \(owner)). "
              + "Close it there; hukan resumes it automatically when that process exits."))
      }
      markHeldElsewhere(by: owner)
      return
    }
    // No live owner: drop any stale hold (the exit watch normally beat us to it) before spawning.
    clearHeldElsewhere()
    let session = ClaudeSession(id: id, worktree: url)
    session.onEvent = { [weak self] event in self?.apply(event) }
    session.onModels = { [weak self] models in
      self?.availableModels = models
      self?.onStateChange?()
    }
    session.onCommands = { [weak self] commands in
      self?.availableCommands = commands
      self?.onCommands?(commands)
      self?.onStateChange?()
    }
    session.onInitializeFailed = { [weak self] _ in self?.handleSignedOut() }
    session.onExit = { [weak self] status in
      guard let self else { return }
      // Read before the runner goes: the tail lives on it.
      let stderr = self.runner?.lastError
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
      // A deliberate restart: the engine we just tore down comes straight back, resuming from the
      // transcript it flushed on the way out. Detached (unlike the effort restart) precisely
      // because there is a transcript now, so the respawn must `--resume` rather than open a fresh
      // id on top of it.
      if self.pendingRestart {
        self.pendingRestart = false
        self.state = .idle
        // Resume only if there is a transcript to resume onto. A New Session cycled before its
        // first send wrote none, so it must come back as a fresh id, not `--resume` a file that
        // does not exist.
        if let url = self.lastKnownWorktree {
          self.isDetached = ClaudeSessionStore.isResumable(id: self.id, worktree: url)
        }
        self.onStateChange?()
        self.onNeedsStart?()
        return
      }
      // A signed-out session exits right after the init error; keep that state and its note
      // rather than overwriting them with a generic "claude exited", which explains nothing.
      if self.state == .signedOut {
        self.onStateChange?()
        return
      }
      self.state = .idle
      // The process is gone, so the next send must `--resume` this conversation rather than
      // open a fresh `--session-id` on top of an id that already has a transcript — but only if
      // there is one. An engine that died before writing anything (it could not be launched, it
      // exited on its own first flag) wrote no file, and `--resume` against a file that is not
      // there fails with a different error than the one that actually happened, so the session
      // would go on failing after its cause was fixed. Same question `pendingRestart` asks
      // above, for the same reason. (The signed-out branch already returned — it never
      // initialized, so there is nothing to resume either.)
      if let url = self.lastKnownWorktree {
        self.isDetached = ClaudeSessionStore.isResumable(id: self.id, worktree: url)
      } else {
        self.isDetached = true
      }
      // A non-zero status is worth surfacing only when the engine died on its own — a stop we
      // asked for exits with SIGTERM/SIGKILL (143/137), which is not a crash to report. What it
      // wrote to stderr on the way out is the only place the reason ever appears, so it rides
      // along; without it a status number is the whole of what a failure says.
      if status != 0 && !self.deliberateStop {
        var message = "claude exited (status \(status))"
        if let reason = stderr, !reason.isEmpty { message += "\n\(reason)" }
        self.append(Transcript.error(message))
      }
      self.deliberateStop = false
      self.onStateChange?()
    }
    do {
      try session.start(
        model: model, permissionMode: permissionMode.rawValue, effort: effort,
        tools: tools, resume: isDetached, fork: forkOrigin, rollbackTo: rollbackAnchor)
      runner = session
      // The branch has been taken, or the cut has been made: either way the engine has written
      // it into this session's own transcript, so every later launch resumes that file like any
      // other. Passing the same anchor twice would roll a second turn's work away.
      forkOrigin = nil
      rollbackAnchor = nil
      isDetached = false
      if !holdIdle { state = .running }
      onStateChange?()
      // Asked here rather than off the engine's `system/init`, which is a *turn* starting and so
      // never arrives for a session that is up but has not been spoken to. The request queues
      // behind the initialize handshake on its own, so this is simply "as soon as there is
      // anyone to ask" — and there already is something to report, since the window is most of
      // the way full of system prompt and tool schemas before a word is typed.
      refreshContextUsage()
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
    // And it is your decision about this session, not just a timestamp: a send is what takes an
    // archived one back out of the fold. Fired before the start below, so the row is already out
    // when the engine's first state change reloads the rail.
    onInstructed?()
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
      // never fills. A queued line keeps its attachments as attachments, so whenever it does
      // go out it takes the same route an immediate send does — an image as an image.
      // A question is the one thing a typed line can answer outright — it is a choice, and your
      // own words in place of an offered option are exactly the CLI's "Other", which is why the
      // card carries no field of its own: the composer directly below it is already one, and two
      // stacked would be the same box twice. An approval has no such third answer, so a send
      // there is still the dismissal below. Neither can an attachment ride an answer — it goes
      // back as one line of text — so a line carrying one takes the dismissal too, where an
      // image stays an image.
      if let question = pendingQuestion, attachments.isEmpty {
        answerQuestion(question.current.labels(ticked: question.ticked) + [command])
        return
      }
      if pendingApproval != nil || pendingQuestion != nil {
        queuedMessages.insert(QueuedMessage(text: text, attachments: attachments), at: 0)
        interrupt(resending: true)
        return
      }
      queuedMessages.append(QueuedMessage(text: text, attachments: attachments))
      onStateChange?()
      return
    }
    deliver(text, attachments: attachments)
  }

  /// Record a message in the transcript and hand it to the engine. Shared by the paths that
  /// open a turn (`deliver`) and the one that jumps a queued line straight to the engine
  /// mid-turn (`sendQueuedNow`), which is why it does not touch turn state itself.
  private func recordAndSend(_ text: String, attachments: [Attachment] = []) {
    if title == nil {
      // The same shape the store gives a title read back off disk, so a session's row does not
      // change form when it is restored (see `ClaudeSessionStore.titleLine`).
      let guess = ClaudeSessionStore.titleLine(from: text)
      title = guess.isEmpty ? (attachments.isEmpty ? "" : "画像") : guess
    }
    hasSent = true
    markTime()
    append(
      Transcript.userMessage(
        text, imagePaths: attachments.filter(\.isImage).map(\.path),
        forkAnchor: lastRecordUUID))
    runner?.send(text, attachments: attachments)
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
  /// Whether this conversation can be cut back where it stands.
  ///
  /// Not while another live process owns the session. A rollback is only real once the engine
  /// holding the conversation applies it, and the engine holding a held session is not hukan's
  /// to speak to — so the cut would sit unapplied while the holder went on appending to a
  /// conversation hukan had already stopped showing, and would then, whenever that process
  /// finally exited, throw away everything it had done in between. Forking is unaffected: it
  /// only reads the source, which is why the two verbs differ here.
  var canRollBack: Bool { heldByPID == nil }

  /// Cut this conversation back to just before one of its messages, and bring the engine with it.
  ///
  /// `keeping` is how much of the transcript survives — the same prefix a fork taken at the same
  /// point would inherit. A running engine cuts its own conversation in place, over the stream
  /// it is already listening to; it used to be cycled instead, which threw away a warm process
  /// and everything it had loaded in order to undo one exchange. The relaunch is still what a
  /// session that is *not* running takes, since there is nobody to ask — the cut rides in on
  /// `--resume-session-at` at its next start, which is the same thing later.
  ///
  /// This is where the two undo verbs stop sharing a mechanism: a fork is still a launch
  /// (`--fork-session` is the only way to get a second session out of one conversation), while a
  /// rollback is now a message. What they still share is that neither deletes anything — the
  /// messages after the cut leave the pane, not the disk, and stay in the jsonl unreachable
  /// rather than gone.
  func rollBack(to anchor: String, keeping prefixLength: Int) {
    guard canRollBack else { return }
    // A running engine is asked to cut its own conversation, which it does in place. Only when
    // there is nobody to ask — the engine is down, or hukan never learned the message's uuid —
    // does the cut have to ride in on a relaunch instead.
    if isRunning, let target = userMessages.last(where: { $0.anchor == anchor })?.uuid {
      let lastSeen = lastUserMessageUUID
      runner?.rewindConversation(to: target, lastSeen: lastSeen) { [weak self] response in
        guard let self else { return }
        guard response?["rewound"] as? Bool == true else {
          // The engine kept the conversation, so hukan must keep it too: cutting the pane here
          // would show a rollback that did not happen. Its reasons are all states that pass —
          // a turn in flight, queued input, a pending answer — so saying which one is what
          // makes "try again in a moment" the obvious next move.
          let reason = response?["error"] as? String
          self.append(
            Transcript.error(
              "Could not roll back: \(reason ?? "the engine did not answer").")
          )
          self.onStateChange?()
          return
        }
        self.applyRollBack(to: anchor, keeping: prefixLength)
      }
      return
    }
    rollbackAnchor = anchor
    applyRollBack(to: anchor, keeping: prefixLength)
  }

  /// Drop everything after the cut from the pane and move the branch point back with it. The
  /// messages leave the transcript, not the disk: they stay in the jsonl, unreachable rather
  /// than gone.
  private func applyRollBack(to anchor: String, keeping prefixLength: Int) {
    lastRecordUUID = anchor
    // The cut may take the streamed span with it; whatever streams next must open a fresh run
    // rather than replace through a document that no longer holds this one.
    streamStart = nil
    pendingStreamText = ""
    let length = min(max(prefixLength, 0), transcript.length)
    transcript.deleteCharacters(in: NSRange(location: length, length: transcript.length - length))
    // The cut message and everything after it are unreachable now, so their uuids would only
    // mislead a second rollback — and the one before the cut is what the engine must be told
    // has been seen next time.
    if let index = userMessages.lastIndex(where: { $0.anchor == anchor }) {
      userMessages.removeSubrange(index...)
    }
    onReload?()
    onStateChange?()
    // The conversation just got shorter, which is the other thing that moves the context figure.
    refreshContextUsage()
  }

  /// Show the conversation a branch inherits, before its engine has written a line of it.
  ///
  /// The engine does write it — that is what `--fork-session` is — but not until it launches,
  /// and a branch that opens to an empty pane reads as having lost the context it was made to
  /// keep. What is handed in is the source session's own rendered transcript, cut at the fork
  /// point, so the two panes agree to the character without re-reading or re-rendering anything.
  /// `anchor` becomes this session's branch point in turn, so a second fork taken before the
  /// first reply still has somewhere to cut.
  func seedForkedConversation(_ inherited: NSAttributedString, anchor: String) {
    transcript.setAttributedString(inherited)
    lastRecordUUID = anchor
    onReload?()
  }

  /// What was saved is `flattened` text, so a restored line's files are the paths inside it.
  func restoreQueue(_ messages: [String]) {
    guard queuedMessages.isEmpty, !messages.isEmpty else { return }
    queuedMessages = messages.map { QueuedMessage(text: $0, attachments: []) }
  }

  /// One turn ended. Send the next queued line if there is one, which opens the next turn;
  /// otherwise the session is genuinely idle and ready for fresh input.
  private func flushQueue() {
    isTurnActive = false
    guard !queuedMessages.isEmpty else { return }
    let next = queuedMessages.removeFirst()
    deliver(next.text, attachments: next.attachments)
  }

  // MARK: - Queue controls (the buttons on each type-ahead line)

  /// Send a queued line to the engine right now instead of waiting for the turn to end. The
  /// engine takes it into its own input queue and runs it after the current turn, so it jumps
  /// ahead of everything still held here without a mid-turn write racing the active turn.
  func sendQueuedNow(at index: Int) {
    guard queuedMessages.indices.contains(index) else { return }
    let message = queuedMessages.remove(at: index)
    recordAndSend(message.text, attachments: message.attachments)
    onStateChange?()
  }

  /// The last line queued, sent now — Return on the empty composer. A line typed mid-turn
  /// joins the queue on its first Return, and a second Return, with nothing left in the field,
  /// is the same hand saying it did not mean to wait: the send-now button of the row it just
  /// made, without reaching for it. The last row rather than the first, because the last is the
  /// one the hand just left; the ones before it were queued deliberately and stay queued.
  func sendLastQueuedNow() {
    sendQueuedNow(at: queuedMessages.count - 1)
  }

  /// Drop a queued line — it was typed ahead and is no longer wanted.
  func removeQueued(at index: Int) {
    guard queuedMessages.indices.contains(index) else { return }
    queuedMessages.remove(at: index)
    onStateChange?()
  }

  /// Pull a queued line back out for editing: it leaves the queue and is returned whole,
  /// attachments included, so the composer can reopen it as it was queued. Re-sending it queues
  /// it afresh at the end.
  func takeQueued(at index: Int) -> QueuedMessage? {
    guard queuedMessages.indices.contains(index) else { return nil }
    let message = queuedMessages.remove(at: index)
    onStateChange?()
    return message
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

  /// Ask this session's engine for the account's plan usage. The figures are account-wide, not
  /// this session's, so any running session answers for all of them — which is why the caller
  /// picks whichever one happens to be up rather than tracking a particular one. Nil when the
  /// engine is down or has no plan limits to report; the completion always runs.
  func requestUsage(completion: @escaping (ClaudeUsage.Snapshot?) -> Void) {
    guard let runner, runner.isRunning else {
      completion(nil)
      return
    }
    runner.requestUsage { completion($0.flatMap(ClaudeUsage.parse)) }
  }

  /// The context reading as of the last time it was asked for, so a reselect or a reload shows
  /// the last figure rather than blanking while a fresh one is on its way. Nil until the session
  /// has connected and answered once.
  private(set) var contextUsage: ContextUsage?

  /// Re-read what this session's context window is spent on. A no-op while one is in flight and
  /// while the engine is down — with nothing to ask, the last reading stands.
  ///
  /// Driven from the end of a turn rather than by a timer: the conversation is the only thing
  /// that moves the figure, and a turn ending is exactly when it has moved. The engine answers
  /// locally, so this costs a line on a stream that is already open.
  func refreshContextUsage() {
    guard let runner, runner.isRunning, !isContextUsageInFlight else { return }
    isContextUsageInFlight = true
    runner.requestContextUsage { [weak self] payload in
      guard let self else { return }
      self.isContextUsageInFlight = false
      guard let usage = payload.flatMap(ContextUsage.init(payload:)) else { return }
      self.contextUsage = usage
      self.onStateChange?()
    }
  }

  private var isContextUsageInFlight = false

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

  /// Show a command list this session has not been told yet — the one the window last heard from
  /// any of its sessions. Same rule as the roster: never overwrite a live list, because the
  /// engine's own answer is about *this* worktree and a seeded one is only a good guess.
  func seedCommands(_ commands: [ClaudeCommand]) {
    guard availableCommands.isEmpty, !commands.isEmpty else { return }
    availableCommands = commands
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

  /// Answer the question on screen with the chosen option labels — more than one only when the
  /// question is `multiSelect`, none at all when it is skipped. Advances to the next question;
  /// once the last is answered, all the choices go back to the model at once.
  func answerQuestion(_ optionLabels: [String]) {
    guard var question = pendingQuestion else { return }
    // Several picks are still one line: the `[User answered <header>]` prefix is per question,
    // not per choice, and that exact shape is what the engine reads as direct user intent.
    let label = optionLabels.isEmpty ? "(skipped)" : optionLabels.joined(separator: ", ")
    question.answers.append((question.current.header, label))
    let next = question.index + 1
    if next < question.questions.count {
      question.index = next
      question.ticked = []
      question.previewsOpen = []
      pendingQuestion = question
      onStateChange?()
      return
    }
    pendingQuestion = nil
    // The answer is both sent to the model and shown in the transcript — one text, the way the
    // CLI does it, so what you chose is on the record instead of a bare "answered".
    let answer = Self.answerMessage(question.answers)
    runner?.respondDeny(requestID: question.requestID, message: answer)
    append(Transcript.userMessage(answer, forkAnchor: lastRecordUUID))
    state = .running
    onStateChange?()
  }

  /// Tick or untick one option of a multi-select question. It goes through the session rather
  /// than staying in the card so that the state survives the card being rebuilt, which is also
  /// why this reports a change: the card is redrawn from it, ticks and all.
  func toggleQuestionOption(_ index: Int) {
    guard var question = pendingQuestion else { return }
    if question.ticked.contains(index) {
      question.ticked.remove(index)
    } else {
      question.ticked.insert(index)
    }
    pendingQuestion = question
    onStateChange?()
  }

  /// Open or fold one option's preview. Same reasoning as the ticks, and the same round trip.
  func toggleQuestionPreview(_ index: Int) {
    guard var question = pendingQuestion else { return }
    if question.previewsOpen.contains(index) {
      question.previewsOpen.remove(index)
    } else {
      question.previewsOpen.insert(index)
    }
    pendingQuestion = question
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
          description: $0["description"] as? String ?? "",
          preview: $0["preview"] as? String ?? "")
      }
      return AgentQuestion(
        header: entry["header"] as? String ?? "",
        question: entry["question"] as? String ?? "",
        options: options,
        multiSelect: entry["multiSelect"] as? Bool ?? false)
    }
  }

  /// The tools that move the task list, and so the ones whose results are worth re-reading the
  /// store after. `TaskStop` and `TaskOutput` share the prefix and are nothing to do with it —
  /// they drive background tasks — which is why this is a list and not a `hasPrefix`.
  static func writesTasks(tool name: String) -> Bool {
    name == "TaskCreate" || name == "TaskUpdate"
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

  func stop() {
    deliberateStop = true
    runner?.terminate()
  }

  /// Cycle the engine: stop it and bring it straight back, resuming the conversation. The "turn it
  /// off and on again" for a wedged session — unlike `stop()`, no send is needed to get it back.
  /// The respawn is deferred to `onExit` (via `pendingRestart`) so it lands only once the old
  /// process is truly gone, never two engines on one transcript. A session with no live engine has
  /// nothing to cycle, so this just brings it up.
  func restart() {
    guard runner != nil else {
      onNeedsStart?()
      return
    }
    pendingRestart = true
    runner?.terminate()
  }

  /// Record that another live process owns this session id, and watch that process so the hold
  /// lifts by itself the moment it exits. Idempotent for the same pid — a re-scan that finds the
  /// same holder does not re-arm the watch or re-notify.
  func markHeldElsewhere(by pid: pid_t) {
    guard heldByPID != pid else { return }
    holderExitSource?.cancel()
    heldByPID = pid
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    source.setEventHandler { [weak self] in self?.clearHeldElsewhere() }
    holderExitSource = source
    source.resume()
    onHeldChange?()
  }

  /// Drop the hold — the holder is gone (its `.exit` fired) or we are about to start it ourselves.
  func clearHeldElsewhere() {
    holderExitSource?.cancel()
    holderExitSource = nil
    guard heldByPID != nil else { return }
    heldByPID = nil
    onHeldChange?()
  }

  /// The app-quit teardown drives the close-wait-SIGTERM-SIGKILL sequence itself, across every
  /// session on one shared deadline — the background waiters `stop()` spawns would die with
  /// the process before ever escalating. These expose the three ends of that sequence; the
  /// final SIGKILL is what keeps a mid-turn engine from being orphaned to launchd on our exit.
  func beginStop() { runner?.closeInput() }
  func forceStop() { runner?.forceTerminate() }
  func killStop() { runner?.forceKill() }

  /// Pull the path out of "Created worktree at <path> on branch <branch>. …". Every way in says
  /// `worktree at <path>` — created, entered by `path`, switched from another — so the verb is
  /// not read; only the phrase and what follows it. Give up if it does not match.
  static func worktreePath(fromToolResult text: String) -> URL? {
    guard let start = text.range(of: "worktree at ") else { return nil }
    let rest = text[start.upperBound...]
    let end = rest.range(of: " on branch ") ?? rest.range(of: ". ")
    let path = String(end.map { rest[..<$0.lowerBound] } ?? rest)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard path.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: path)
  }

  /// Pull the directory the session went back to out of an `ExitWorktree` result. Every variant
  /// ends by saying where the session now is — "Session is now back in <path>." after a keep or a
  /// remove, or "…so the session is now in <path>." when the original directory was gone and the
  /// engine fell back — and that closing clause is the one thing read. Not `worktreePath`: a
  /// remove's result also says "removed worktree at <path>", and reading that would move the
  /// session *into* the worktree it just left.
  static func exitedCwd(fromToolResult text: String) -> URL? {
    let anchors = ["Session is now back in ", "so the session is now in "]
    guard let start = anchors.lazy.compactMap({ text.range(of: $0) }).first else { return nil }
    let rest = text[start.upperBound...]
    let path = String(rest.range(of: ".").map { rest[..<$0.lowerBound] } ?? rest)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard path.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: path)
  }

  /// Recency moved. Distinct from onStateChange (a full window reload): activity happens per
  /// fragment while a turn runs, and the only thing that depends on it is the rail's order, so
  /// the subscriber can throttle and reload just that.
  var onRecencyChange: (() -> Void)?

  /// You instructed this session. `onRecencyChange` is the agent speaking and fires per fragment;
  /// this is your send, and it fires once — which is what makes it the seam the archive flag hangs
  /// off (see `Workspace.noteInstruction`).
  var onInstructed: (() -> Void)?

  /// Bump the rail's sort key: this session just did something. The one way `updatedAt` moves.
  private func touch() {
    updatedAt = Date()
    onRecencyChange?()
  }

  private func append(_ fragment: NSAttributedString) {
    // Whatever this is, it goes after the streamed text, so the pooled deltas land first. A
    // no-op inside a flush's own `markTime`, whose separator belongs *before* the run.
    flushStreamRender()
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
    // The pooled deltas' replace and this edit shift each other's offsets — one document first.
    flushStreamRender()
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
  /// `assistant` text repeats it and only reformats what streamed, to avoid printing twice —
  /// unless nothing streamed at all, when it is appended as the sole copy. Tool calls go the
  /// other way: `content_block_start` has empty arguments, so the buffered `assistant`
  /// block — which has them filled in — is the one used.
  func apply(_ event: ClaudeEvent) {
    // Anything but another delta may read the transcript or land beside the streamed span, and
    // the pooled deltas' replace is computed against it — put them in first.
    if event.type != "stream_event" { flushStreamRender() }
    switch event.type {
    case "stream_event":
      guard let inner = event.payload["event"] as? [String: Any] else { return }
      if inner["type"] as? String == "content_block_delta",
        let delta = inner["delta"] as? [String: Any],
        delta["type"] as? String == "text_delta",
        let text = delta["text"] as? String
      {
        // Pooled, not rendered here: one render per SSE chunk cost the whole accumulated
        // run each time (see `flushStreamRender`, which is where the look of the streaming
        // render is decided).
        pendingStreamText += text
        scheduleStreamFlush()
      }

    case "assistant":
      // Every `assistant` event carries the uuid of the record the engine just wrote, and it is
      // the same uuid the transcript on disk gets — so the last one seen is where a fork started
      // from the *next* message typed here would truncate. Only `assistant` is trusted for this:
      // `system` events (init, for one) carry uuids that never reach the jsonl, and a branch
      // anchored on one of those would find no such message.
      if let uuid = event.payload["uuid"] as? String { lastRecordUUID = uuid }
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
      } else if !text.isEmpty {
        // Nothing streamed, so there is no span to replace and this event is the only place the
        // text exists: append it. That is how the engine delivers a message it synthesized itself
        // rather than received (`model: "<synthetic>"`) — an API error, a usage-limit notice —
        // which has no `content_block_delta` to have opened a run. Dropping it is why such a
        // line used to appear only after a restart re-read the jsonl, where the parse appends
        // every assistant text block unconditionally (`ClaudeSessionStore.history`).
        markTime()
        append(Transcript.markdown(text))
      }
      streamStart = nil

      for block in blocks where block["type"] as? String == "tool_use" {
        let name = block["name"] as? String ?? "tool"
        let input = block["input"] as? [String: Any] ?? [:]
        if let id = block["id"] as? String { pendingTools[id] = name }
        // A tool hukan answers with a card of its own — the question, the task list — would only
        // be duplicated by a transcript line. See `Transcript.hasOwnCard`, which is what keeps a
        // replayed conversation reading the same way as a live one.
        guard !Transcript.hasOwnCard(tool: name) else { continue }
        markTime()
        append(Transcript.toolUse(name: name, input: input))
      }

    case "user":
      // `--replay-user-messages` sends every message hukan wrote back with the uuid the engine
      // filed it under, which is the only place that uuid is ever said. It arrives before any
      // assistant record of this turn, so `lastRecordUUID` is still the anchor the transcript
      // block was given — which is what makes the two halves line up without either side
      // carrying the other's identifier.
      if event.payload["isReplay"] as? Bool == true,
        let uuid = event.payload["uuid"] as? String,
        Self.isUserPrompt(event.payload)
      {
        userMessages.append((anchor: lastRecordUUID, uuid: uuid))
      }

      // A tool's result is where two things become true. The store a task tool wrote is on disk
      // by now (the call going out says only that it is about to be), and a move into a worktree
      // is announced — the agent that created it is the only one who knows, so it is read out of
      // the result text.
      guard let message = event.payload["message"] as? [String: Any],
        let blocks = message["content"] as? [[String: Any]]
      else { return }
      for block in blocks where block["type"] as? String == "tool_result" {
        guard let id = block["tool_use_id"] as? String,
          let name = pendingTools.removeValue(forKey: id)
        else { continue }
        // The call is not the list; the directory is, so the answer is always to go and read it.
        if Self.writesTasks(tool: name) { refreshTasks() }
        guard let text = block["content"] as? String else { continue }
        switch name {
        case "EnterWorktree":
          guard let path = Self.worktreePath(fromToolResult: text) else { continue }
          append(Transcript.note("→ worktree: \(path.path)"))
          onEnterWorktree?(path)
        case "ExitWorktree":
          guard let path = Self.exitedCwd(fromToolResult: text) else { continue }
          append(Transcript.note("→ back in: \(path.path)"))
          onExitWorktree?(path)
        default:
          continue
        }
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
      // A turn cut short can end without the `assistant` close that normally retires the run;
      // left set, the next turn's first delta would replace from the dead run's start, taking
      // the notes appended below with it.
      streamStart = nil
      // A backstop for the card: a task tool whose result never reached the loop above (a turn
      // cut short, a shape the stream did not spell the usual way) still leaves the store right,
      // and the end of the turn is when a stale card would start to mislead.
      refreshTasks()
      if interruptedTurn {
        // We asked for this: the engine ends the turn it cut with an error result. That is
        // not a failure to report — a redirect's next turn (if any) follows immediately.
        interruptedTurn = false
        append(Transcript.note("Interrupted"))
      } else if event.subtype != "success" {
        // Not a redirect we asked for: the turn genuinely failed. Mark the session so the rail
        // shows it, rather than leaving the green check `.idle` set just above. `flushQueue`
        // below reopens `.running` if type-ahead is waiting, so this stands only when the turn
        // truly stopped here.
        state = .failed
        append(Transcript.error("Stopped (\(event.subtype ?? "unknown"))"))
      } else {
        append(Transcript.text("\n"))
      }
      // Delivers the next type-ahead line, if any, which reopens `state`/`isTurnActive`.
      flushQueue()
      onStateChange?()
      refreshCostEstimate()
      refreshTitle()
      refreshContextUsage()

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
        if let match = availableModels.first(where: { $0.matches(reported) }) {
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
