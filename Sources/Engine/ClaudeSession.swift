import AppKit  // NSBitmapImageRep, to encode an image attachment for the wire — no views

struct ClaudeEvent {
  let type: String
  let subtype: String?
  let payload: [String: Any]
}

/// A file pasted or dropped into the composer, sent with the message. An image goes as a native
/// image block; anything else goes as its path for the agent to read (see `ClaudeSession.send`).
struct Attachment: Equatable {
  let path: String
  let isImage: Bool
}

/// One model the engine advertises in its initialize reply. `value` is what goes to `--model` /
/// `set_model` (e.g. `opus`, `claude-fable-5[1m]`); `displayName` is the label ("Opus", "Fable").
/// Reading this roster instead of a fixed list keeps the picker in step with what the account can
/// actually use — Fable, 1M-context variants, the recommended default — and never offers a value
/// the engine would reject.
struct ClaudeModel {
  let value: String
  let displayName: String
  /// The concrete model the `value` resolves to (e.g. `claude-sonnet-5`). The system/init event
  /// reports the running model as a resolved id, so this is what maps it back to a picker entry.
  let resolvedModel: String

  /// Whether a bare model id — the resolved id the transcript records, or the engine's reported
  /// model — refers to this entry. `resolvedModel` carries a `[1m]` context-window suffix
  /// (`claude-opus-4-8[1m]`) that the transcript's id (`claude-opus-4-8`) does not, so a plain `==`
  /// silently misses; compare with the suffix stripped from both. `value` still matches exactly
  /// (it is an alias like `opus[1m]`, never a resolved id).
  func matches(_ id: String) -> Bool {
    value == id || Self.withoutContextSuffix(resolvedModel) == Self.withoutContextSuffix(id)
  }

  /// The label with its version number restored. The engine advertises `displayName` without one
  /// ("Opus", "Fable", "Sonnet", or "Opus (1M context)"), while `resolvedModel` carries the version
  /// — so on its own the UI reads "Opus", not "Opus 5". Splice the version back on; fall back to the
  /// bare name when the resolved id has no numeric version. `default` is left alone — it is "let the
  /// engine choose", not a model, so its resolved id must not read as "Default (recommended) 5".
  var numberedName: String {
    guard value != "default", let version = Self.version(fromResolved: resolvedModel)
    else { return displayName }
    // Before a trailing parenthetical, not after it, so "Opus (1M context)" reads
    // "Opus 5 (1M context)" rather than "Opus (1M context) 5".
    if displayName.hasSuffix(")"), let open = displayName.lastIndex(of: "(") {
      let head = displayName[..<open].trimmingCharacters(in: .whitespaces)
      return "\(head) \(version) \(displayName[open...])"
    }
    return "\(displayName) \(version)"
  }

  /// A resolved id minus its `[1m]`-style context-window suffix.
  static func withoutContextSuffix(_ id: String) -> String {
    guard let bracket = id.firstIndex(of: "[") else { return id }
    return String(id[..<bracket])
  }

  /// The dotted version pulled from a resolved id: `claude-opus-4-8[1m]` → "4.8",
  /// `claude-fable-5` → "5", `claude-haiku-4-5-20251001` → "4.5" (a trailing date snapshot is
  /// dropped). Nil when the id carries no numeric version (an unversioned or unexpected id).
  static func version(fromResolved resolved: String) -> String? {
    let base = withoutContextSuffix(resolved)
    var numbers: [String] = []
    for part in base.split(separator: "-") where part.allSatisfy(\.isNumber) {
      if part.count >= 6 { break }  // an 8-digit date snapshot (20251001), not a version component
      numbers.append(String(part))
    }
    return numbers.isEmpty ? nil : numbers.joined(separator: ".")
  }
}

/// One slash command the engine advertises in its initialize reply — its own built-ins (`clear`,
/// `compact`, `model`) alongside every skill and user command it found on disk, in one list.
/// Reading it from the engine is the same stance as the model roster: the set of commands is the
/// engine's to know, and a table here would be a second copy that goes stale the moment a skill
/// is added.
struct ClaudeCommand {
  let name: String
  let description: String
  /// The engine's own hint at what follows the name (`<model>`, `[interval] [prompt]`), shown
  /// beside the completion. Empty for a command that takes no argument.
  let argumentHint: String
  /// Alternate names that resolve to the same command (`/cost` and `/stats` both reach `/usage`).
  /// Matched by the completion, but never listed on their own — an alias is a second way to say
  /// one thing, not a second thing.
  let aliases: [String]

  /// Whether this belongs in a completion list at all. The engine's list carries a few entries
  /// that exist for a host it is embedded in rather than for a person to type — a leading `__`
  /// marks them — and hukan's own interception of `/login` and `/logout` means those two are
  /// added by hand rather than read from here.
  var isTypeable: Bool { !name.hasPrefix("__") }
}

/// Keeps `claude -p` resident and talks to it both ways over stream-json.
///
/// No PTY. stream-json is a pipe protocol, and the CLI itself treats a non-TTY stdout
/// as non-interactive mode. A PTY would mix echo and control sequences into the JSON
/// stream. The PTY path is only needed for the terminal.
final class ClaudeSession {
  let id: UUID
  let worktree: URL

  private let process = Process()
  private let stdinPipe = Pipe()
  private let stdoutPipe = Pipe()
  private let stderrPipe = Pipe()
  private var pending = Data()

  /// The tail of what the engine wrote to stderr, kept so a failed exit can say why. Only the
  /// tail: stderr carries ordinary noise too (`Shell cwd was reset to …` follows a perfectly
  /// good run), so this is never shown on its own — `lastError` picks the part that reads as a
  /// reason, and only an abnormal exit asks for it.
  private var stderrTail = Data()
  private let stderrQueue = DispatchQueue(label: "dev.tnayuki.hukan.claude-stderr")

  /// stdin is written from both the main thread (sends, approvals) and the stdout reader
  /// thread, so every write is funnelled through here. `isInitialized` and `outbox` are
  /// only ever touched on this queue.
  private let writeQueue = DispatchQueue(label: "dev.tnayuki.hukan.claude-write")
  private var isInitialized = false
  private var outbox: [[String: Any]] = []

  /// Callers waiting on a control_response, keyed by the request id they sent. Written from
  /// whichever thread asked and read from the stdout reader, hence the lock. Every entry is
  /// removed exactly once — by its reply, or by `finishPendingReplies` when the engine goes —
  /// so nothing here waits forever on a process that has exited.
  private var pendingReplies: [String: ([String: Any]?) -> Void] = [:]
  private let pendingRepliesLock = NSLock()

  var onEvent: ((ClaudeEvent) -> Void)?
  var onExit: ((Int32) -> Void)?
  /// The model roster carried by the initialize reply. Fires once, on the main thread.
  var onModels: (([ClaudeModel]) -> Void)?
  /// The slash-command list carried by the same reply. Fires once, on the main thread.
  var onCommands: (([ClaudeCommand]) -> Void)?
  /// The `initialize` reply came back an error, so the engine never became ready — most often
  /// because the account is signed out (the OAuth token expired or `/logout` was run elsewhere).
  /// Carries the engine's message. Fires on the main thread; the session is dead after this.
  var onInitializeFailed: ((String) -> Void)?

  init(id: UUID = UUID(), worktree: URL) {
    self.id = id
    self.worktree = worktree
  }

  /// The engine is launched through the user's login shell, which is the whole of how the agent
  /// gets a PATH.
  ///
  /// launchd gives a Dock-, Finder- or Spotlight-launched app `/usr/bin:/bin:/usr/sbin:/sbin` and
  /// nothing else, and a child inherits it: not only was `claude` itself not on that PATH, but
  /// every command the agent then ran through its own Bash was missing `brew`, `gh`, and a `node`
  /// under a version manager. Claude Code pins the PATH it was launched with — its shell snapshot
  /// sources the rc for functions and aliases and then re-exports the inherited PATH over
  /// whatever the rc built — so this can only be fixed on the way in, and naming install
  /// locations here fixes it for one binary while leaving the agent's own shell as bare as it
  /// was.
  ///
  /// `-i` as well as `-l`, because which file builds PATH is not a matter of principle: Homebrew's
  /// `shellenv` is written into `~/.zshrc` by its own installer, and a login-but-not-interactive
  /// zsh does not read that file — `-lc` alone comes back without `/opt/homebrew/bin`. This is
  /// the guess every editor that does this makes (Zed spawns `-l -i -c` too), and it costs about
  /// 1.4s per launch against 0.1s for `-lc`, spent on the rc's completion setup. That is the
  /// price of the decision, paid on every start, restart and fork.
  ///
  /// The shell is asked to *run* the engine rather than to report its PATH, which is what keeps
  /// this to one line: nothing has to be parsed out of whatever the profile prints, and there is
  /// no environment to carry around. What the profile prints goes to stdout ahead of the stream,
  /// where `consume` drops it for want of a `type` — the one thing that would land in the
  /// protocol is output with no trailing newline. The shell starts in the worktree, so a
  /// directory-sensitive rc (direnv, asdf) sees the directory the agent is about to work in.
  private static var shell: String {
    ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
  }

  /// What that shell is asked to do: hand its PATH to `claude` and get out of the way.
  ///
  /// `exec`, so the shell is replaced rather than left waiting in the middle: the pid hukan holds
  /// is the engine's, and the SIGTERM that stops a session reaches it rather than a wrapper that
  /// would have to pass it on. It is also why nothing is written back to the history file — the
  /// interactive shell never reaches an exit.
  ///
  /// The arguments arrive as argv (`"$@"`) rather than spliced into this string. A launch carries
  /// a whole system prompt, so quoting them into a command line would be a second escaping layer
  /// with nothing to buy it.
  ///
  /// The `command -v` guard exists only for the message. Without it a missing engine is zsh's own
  /// `command not found` and a bare 127, and the one fact that makes that actionable — which PATH
  /// was searched — is exactly the fact a GUI launch cannot be asked for by hand.
  private static let launchScript = """
    command -v claude >/dev/null 2>&1 || {
      printf 'claude was not found on PATH: %s\\n' "$PATH" >&2
      exit 127
    }
    exec claude "$@"
    """

  /// How much of stderr to keep. Enough for a message and the lines around it, far short of a
  /// verbose engine's whole output.
  private static let stderrTailLimit = 4096

  /// The most this will put in the transcript, in lines. A reason is a sentence or two; past
  /// that it is a stack trace, and the transcript is not where that is read.
  private static let stderrTailLines = 5

  /// What the engine last wrote to stderr, trimmed to the final few lines, or nil if it wrote
  /// nothing. Verbatim — no line is picked out as "the real one". stderr carries ordinary notices
  /// next to real errors and telling them apart means matching on the engine's own wording, which
  /// is the kind of thing that goes quietly stale on an upgrade. Showing the tail as it stands is
  /// honest about which part hukan understands: none of it.
  var lastError: String? {
    let text = stderrQueue.sync { String(decoding: stderrTail, as: UTF8.self) }
    let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !lines.isEmpty else { return nil }
    return lines.suffix(Self.stderrTailLines).joined(separator: "\n")
  }

  var isRunning: Bool { process.isRunning }
  /// The engine's pid while it runs — what tells its process apart from the rest of hukan's
  /// subtree when the footprint is split.
  var processID: pid_t? { process.isRunning ? process.processIdentifier : nil }

  /// - Parameters:
  ///   - tools: an empty array becomes `--tools ""`, disabling every tool. That covers
  ///     "plain Claude, not Claude Code", so there is no need for a second backend hitting
  ///     the Messages API directly — one subscription covers auth and billing.
  /// Where a new session's conversation comes from when it is a branch of another one.
  ///
  /// The engine does the copying: `--resume <source> --fork-session` replays the source's
  /// transcript into a *new* session rather than appending to it, and `--resume-session-at`
  /// truncates that replay at `anchor` (inclusive) first. So the branch opens holding the
  /// conversation as it stood just after `anchor`, and the source is only read — its jsonl is
  /// left exactly as it was.
  ///
  /// `--session-id` is what keeps this in hukan's world: the CLI otherwise mints the branch's id
  /// itself, and hukan keys a session on the UUID it chose. The combination is explicitly
  /// blessed — the CLI refuses `--session-id` alongside `--resume` *unless* `--fork-session` is
  /// there too. `--resume-session-at` is undocumented and absent from `--help` (like
  /// `--permission-prompt-tool` above) and only takes effect under `-p`, which is the only way
  /// hukan ever launches; re-verify both on upgrades.
  struct ForkPoint {
    /// The session whose conversation is being branched.
    let source: UUID
    /// The last transcript record the branch keeps — the uuid of the record before the message
    /// being rewound past.
    let anchor: String
  }

  /// The flags that decide where the conversation comes from: a fresh one, our own transcript,
  /// our own transcript cut back to a record, or a branch of another session's. Split out so the
  /// shapes can be asserted without spawning.
  ///
  /// `rollbackTo` is the same truncation a fork uses, without the branch: resuming our own id at
  /// an earlier record makes the engine write what follows as a new branch of the same file, so
  /// the conversation is cut back where a fork would have copied it away. It is only honoured on
  /// a resume — there is nothing to cut back on a session that has never run — and never travels
  /// with `--session-id`, which the CLI refuses alongside `--resume` outside a fork.
  static func conversationArguments(
    id: UUID, resume: Bool, fork: ForkPoint?, rollbackTo: String? = nil
  ) -> [String] {
    if let fork {
      return [
        "--resume", fork.source.uuidString,
        "--resume-session-at", fork.anchor,
        "--fork-session",
        "--session-id", id.uuidString,
      ]
    }
    guard resume else { return ["--session-id", id.uuidString] }
    guard let rollbackTo else { return ["--resume", id.uuidString] }
    return ["--resume", id.uuidString, "--resume-session-at", rollbackTo]
  }

  /// The one line hukan appends to the engine's own system prompt. A session's worktree is read
  /// off `EnterWorktree` and `ExitWorktree` results (`AgentSession`), and nothing steers the model
  /// toward those tools by itself: their descriptions never say "rather than `git worktree add`",
  /// and `EnterWorktree` is a deferred tool the model sees only by name until it goes looking. A
  /// worktree made in Bash does reach the rail — git lists it — but the engine's working directory
  /// never moves, so the session stays drawn under the worktree it left, with the desk measuring
  /// the wrong checkout. Stated as a fact about the tools, not as a way of working, and with no
  /// word about what hukan is: identity is not an instruction, and the only behaviour it could add
  /// is the agent driving the app — what the guarded scripting verbs exist to stop.
  static let worktreeInstruction =
    "To create or enter a git worktree use the EnterWorktree tool, and leave it with ExitWorktree: "
    + "a `git worktree add` run in Bash does not move this session's working directory."

  /// The engine's argv after the binary, in one place so a test can read it without launching
  /// anything. `conversationArguments` is the resume/fork/rollback slice of the same list.
  static func launchArguments(
    id: UUID, model: String = "default", permissionMode: String = "default",
    effort: String = "default", tools: [String]? = nil, resume: Bool = false,
    fork: ForkPoint? = nil, rollbackTo: String? = nil
  ) -> [String] {
    var arguments = [
      "-p",
      "--verbose",  // required by stream-json (it exits at startup without it)
      "--input-format", "stream-json",  // makes it a resident session instead of one-shot
      "--output-format", "stream-json",
      "--include-partial-messages",  // text arrives token by token
      "--replay-user-messages",  // sends come back as acknowledgements
      // Routes every permission decision to us as a `can_use_tool` control_request
      // instead of the CLI deciding alone. Undocumented and absent from --help, so
      // re-verify on upgrades. This is what makes the approval card real.
      "--permission-prompt-tool", "stdio",
      // Which tools reach the approval card at all: acceptEdits lets edits through, plan
      // blocks writes, bypassPermissions asks nothing. `manual` is *not* one of these —
      // it fails the tool instead of prompting (see the charter). The four real modes
      // combine with the stdio prompt tool above. Unlike the model, the engine does not
      // remember the mode across --resume, so it is re-passed every launch.
      "--permission-mode", permissionMode,
    ]
    // The engine remembers a session's model across --resume, so forcing --model on a resume
    // would clobber the remembered choice with our default. Pass it only for a fresh session;
    // on resume, let the engine's memory stand and read it back from the system/init event.
    // "default" is our word for "let the engine pick its own recommended model" — same shape
    // as effort's default below — so it too passes no flag rather than a literal alias.
    if !resume && model != "default" {
      arguments += ["--model", model]
    }
    // Reasoning effort is a launch-only setting — there is no runtime control for it (unlike
    // model and permission mode), so it takes effect the next time the session starts.
    if effort != "default" && !effort.isEmpty {
      arguments += ["--effort", effort]
    }
    arguments += Self.conversationArguments(
      id: id, resume: resume, fork: fork, rollbackTo: rollbackTo)
    if let tools {
      arguments += ["--tools", tools.joined(separator: ",")]
    }
    // Every launch, resume included: the engine rebuilds its system prompt each time and
    // remembers nothing of this one.
    arguments += ["--append-system-prompt", Self.worktreeInstruction]
    return arguments
  }

  ///   - resume: true passes `--resume <id>`, used to reattach a conversation after
  ///     window restoration.
  ///   - fork: branch another session's conversation into this one instead of opening an empty
  ///     conversation or resuming our own. Mutually exclusive with `resume`; see `ForkPoint`.
  ///   - rollbackTo: resume our own conversation cut back to this record, discarding what came
  ///     after it from the conversation (not from the file).
  func start(
    model: String = "default", permissionMode: String = "default", effort: String = "default",
    tools: [String]? = nil, resume: Bool = false, fork: ForkPoint? = nil,
    rollbackTo: String? = nil
  ) throws {
    let arguments = Self.launchArguments(
      id: id, model: model, permissionMode: permissionMode, effort: effort, tools: tools,
      resume: resume, fork: fork, rollbackTo: rollbackTo)

    process.executableURL = URL(fileURLWithPath: Self.shell)
    process.arguments = ["-ilc", Self.launchScript, "hukan"] + arguments
    process.currentDirectoryURL = worktree
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let self else { return }
      // async, not sync: this runs on Foundation's reader queue, and blocking that to take a
      // lock is both needless and a way to tie two queues together.
      self.stderrQueue.async {
        self.stderrTail.append(data)
        if self.stderrTail.count > Self.stderrTailLimit {
          self.stderrTail.removeFirst(self.stderrTail.count - Self.stderrTailLimit)
        }
      }
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.consume(data)
    }
    process.terminationHandler = { [weak self] process in
      self?.stdoutPipe.fileHandleForReading.readabilityHandler = nil
      self?.stderrPipe.fileHandleForReading.readabilityHandler = nil
      let status = process.terminationStatus
      self?.finishPendingReplies()
      DispatchQueue.main.async { self?.onExit?(status) }
    }

    try process.run()

    // The engine expects to be initialized before it takes any input, so this goes out
    // first and everything else queues behind its reply.
    write(
      [
        "type": "control_request",
        "request_id": Self.initializeRequestID,
        "request": ["subtype": "initialize", "hooks": [:]],
      ],
      waitForInitialize: false)
  }

  func send(_ text: String, attachments: [Attachment] = []) {
    var content: [[String: Any]] = []
    if !text.isEmpty { content.append(["type": "text", "text": text]) }
    for attachment in attachments {
      if attachment.isImage, let block = Self.imageBlock(path: attachment.path) {
        // A pasted or dropped image rides in as a native base64 image block, the same shape
        // Zed's ACP hands the SDK — so the agent sees the picture itself, not a path to read.
        content.append(block)
      } else {
        // A non-image file goes as its path in text, the way ACP passes a resource link; the
        // agent opens it with Read.
        content.append(["type": "text", "text": attachment.path])
      }
    }
    if content.isEmpty { content.append(["type": "text", "text": text]) }
    write(["type": "user", "message": ["role": "user", "content": content]])
  }

  /// Read an image file into a base64 image content block. Anything the Messages API does not take
  /// directly (tiff, heic…) is re-encoded to PNG, which it does.
  private static func imageBlock(path: String) -> [String: Any]? {
    let byExtension = [
      "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
      "gif": "image/gif", "webp": "image/webp",
    ]
    if let media = byExtension[(path as NSString).pathExtension.lowercased()],
      let data = FileManager.default.contents(atPath: path)
    {
      return block(data, media: media)
    }
    guard let image = NSImage(contentsOfFile: path), let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else { return nil }
    return block(png, media: "image/png")
  }

  private static func block(_ data: Data, media: String) -> [String: Any] {
    [
      "type": "image",
      "source": ["type": "base64", "media_type": media, "data": data.base64EncodedString()],
    ]
  }

  /// Switch the model mid-session. `set_model` / `set_permission_mode` are control_requests
  /// the engine accepts on the live stream — verified against the 2.1.212 binary's control
  /// dispatch (the subtype set is `set_model`, `set_permission_mode`, `interrupt`,
  /// `set_max_thinking_tokens`, `rename_session`). Re-verify on upgrades, as with the rest of
  /// this protocol. Fire-and-forget: the reply is a control_response we do not need to read.
  func setModel(_ model: String) {
    write([
      "type": "control_request",
      "request_id": nextControlRequestID(),
      "request": ["subtype": "set_model", "model": model],
    ])
  }

  func setPermissionMode(_ mode: String) {
    write([
      "type": "control_request",
      "request_id": nextControlRequestID(),
      "request": ["subtype": "set_permission_mode", "mode": mode],
    ])
  }

  /// Send a control_request and hand its reply back. Unlike `setModel`'s fire-and-forget writes
  /// this keeps the request id, so the matching `control_response` reaches the caller instead of
  /// falling through as an event nobody reads.
  ///
  /// The completion runs on the main thread and always runs: nil for an engine that answered
  /// `error`, and nil again if the process exits before answering. `nil` therefore means "no
  /// answer", never "still waiting" — which is what lets a caller show its last good reading
  /// rather than blanking.
  func ask(
    _ subtype: String, _ parameters: [String: Any] = [:],
    completion: @escaping ([String: Any]?) -> Void
  ) {
    var request: [String: Any] = ["subtype": subtype]
    for (key, value) in parameters { request[key] = value }
    let requestID = nextControlRequestID()
    pendingRepliesLock.lock()
    pendingReplies[requestID] = completion
    pendingRepliesLock.unlock()
    write(["type": "control_request", "request_id": requestID, "request": request])
  }

  /// Account plan usage, as the engine reads it off the API's rate-limit headers — the same
  /// figures `/usage` prints, but as numbers rather than as a sentence to parse.
  func requestUsage(completion: @escaping ([String: Any]?) -> Void) {
    ask("get_usage", completion: completion)
  }

  /// What this session's context window is spent on: the `/context` breakdown by category, with
  /// the window's size and how much of it is gone. Answered locally — no model turn, no API call.
  func requestContextUsage(completion: @escaping ([String: Any]?) -> Void) {
    ask("get_context_usage", completion: completion)
  }

  /// Cut the live conversation back to just before one of its user messages.
  ///
  /// `lastSeen` is the newest user message the caller has actually shown. The engine refuses a
  /// rewind that would drop a turn the host never displayed — `stale target` when this is
  /// omitted, `unseen later turn` when it is stale — which is a guard against cutting away work
  /// the person never got to see. It also refuses while a turn is in flight (`turn running`),
  /// while input is queued (`commands queued`) and while it is blocked on an answer
  /// (`prompt pending`).
  ///
  /// A success carries `prefillText` — the original prompt, ready to go back in the composer —
  /// and `precedingAssistantUuid`, the record the conversation now hangs from. Files are a
  /// separate `rewind_files` subtype that hukan never sends: this cuts the conversation, and the
  /// worktree is git's (see the model in CLAUDE.md).
  func rewindConversation(
    to target: String, lastSeen: String?, completion: @escaping ([String: Any]?) -> Void
  ) {
    var parameters: [String: Any] = ["target_message_uuid": target]
    if let lastSeen { parameters["last_seen_user_message_uuid"] = lastSeen }
    ask("rewind_conversation", parameters, completion: completion)
  }

  /// Answer a `can_use_tool` control_request. Until this is sent the engine sits blocked,
  /// so every path that shows an approval must end in exactly one of these.
  func respond(requestID: String, allow: Bool, updatedInput: [String: Any]) {
    let result: [String: Any] =
      allow
      ? ["behavior": "allow", "updatedInput": updatedInput]
      // The exact rejection the CLI hands the model, so it stops instead of retrying — a
      // vaguer message ("Denied in hukan.") left the agent guessing whether to try again.
      : [
        "behavior": "deny",
        "message":
          "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.",
      ]
    write(
      [
        "type": "control_response",
        "response": ["subtype": "success", "request_id": requestID, "response": result],
      ],
      waitForInitialize: false)
  }

  /// Deny a `can_use_tool` request while handing the model a message. This is how an
  /// `AskUserQuestion` is answered: stdio has no dialog channel, so the tool is denied and the
  /// user's choices ride back in the message the model then reads and acts on.
  func respondDeny(requestID: String, message: String) {
    write(
      [
        "type": "control_response",
        "response": [
          "subtype": "success", "request_id": requestID,
          "response": ["behavior": "deny", "message": message],
        ],
      ],
      waitForInitialize: false)
  }

  /// Decline a control_request we have no surface for, so the engine stops waiting on it.
  func declineControlRequest(id requestID: String, cancelled: Bool) {
    let response: [String: Any] =
      cancelled
      ? ["subtype": "success", "request_id": requestID, "response": ["behavior": "cancelled"]]
      : ["subtype": "error", "request_id": requestID, "error": "unsupported control request"]
    write(["type": "control_response", "response": response], waitForInitialize: false)
  }

  private func write(_ object: [String: Any], waitForInitialize: Bool = true) {
    writeQueue.async { [weak self] in
      guard let self else { return }
      if waitForInitialize && !self.isInitialized {
        self.outbox.append(object)
        return
      }
      self.writeNow(object)
    }
  }

  /// Must only be called on `writeQueue`.
  private func writeNow(_ object: [String: Any]) {
    guard var line = try? JSONSerialization.data(withJSONObject: object) else {
      NSLog("hukan: could not encode a message for claude: \(object)")
      return
    }
    line.append(0x0a)
    do {
      try stdinPipe.fileHandleForWriting.write(contentsOf: line)
    } catch {
      // Expected once the child is gone; the exit handler is what reports that.
      NSLog("hukan: write to claude failed: \(error.localizedDescription)")
    }
  }

  /// Stop the current turn without ending the session. A SIGINT (`process.interrupt()`) does
  /// end it — verified against the 2.1.212 binary: the process prints a `result` and exits
  /// status 0, so the next message would have nowhere to go. The `interrupt` control_request
  /// only aborts the turn: the process stays up, emits `result` (subtype
  /// `error_during_execution`) for the turn it cut, and takes the next `user` message straight
  /// away. Re-verify on upgrades, as with the rest of this protocol.
  func interrupt() {
    guard process.isRunning else { return }
    write([
      "type": "control_request",
      "request_id": nextControlRequestID(),
      "request": ["subtype": "interrupt"],
    ])
  }

  /// End the session gracefully, escalating only if it lingers — Unterm's shutdown sequence.
  ///
  /// stdin closes first: a stream-json engine begins its own clean shutdown on EOF, and that
  /// clean path is where it writes the transcript tail back to disk — an immediate SIGTERM
  /// was cutting the last entries off the `.jsonl`. Only if the engine is still up ~2s later
  /// (mid-turn, most likely) does SIGTERM go out (verified to make it exit), with SIGKILL as
  /// the backstop. The waiting runs on a background thread; `onExit` still arrives through
  /// the terminationHandler as usual.
  func terminate() {
    guard process.isRunning else { return }
    closeInput()
    let process = self.process
    DispatchQueue.global(qos: .utility).async {
      for _ in 0..<40 {  // ~2s for the stdin-EOF clean exit
        guard process.isRunning else { return }
        Thread.sleep(forTimeInterval: 0.05)
      }
      process.terminate()
      for _ in 0..<20 {  // ~1s for the SIGTERM exit
        guard process.isRunning else { return }
        Thread.sleep(forTimeInterval: 0.05)
      }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
  }

  /// Close the engine's stdin — EOF is the "please exit when ready" signal, and the engine
  /// flushes its transcript on the way out. Serialized on the write queue so it cannot race
  /// an in-flight write; a write attempted after the close fails and is logged, not crashed.
  func closeInput() {
    writeQueue.async { [stdinPipe] in
      try? stdinPipe.fileHandleForWriting.close()
    }
  }

  /// SIGTERM now, no grace. For the app-quit path, which cannot leave background waiters
  /// behind (they die with the process) and so runs its own shared deadline across sessions.
  func forceTerminate() {
    guard process.isRunning else { return }
    process.terminate()
  }

  /// SIGKILL now — the app-quit backstop for an engine that ignored both EOF and SIGTERM
  /// (mid-turn, most likely). Without it the still-running child is reparented to launchd on
  /// our exit and lives on as an orphan holding the session's transcript, which the next
  /// launch's `liveProcessOwning` guard then refuses to resume on top of. Losing the transcript
  /// tail of a stuck engine beats orphaning it. `terminate()` already escalates this far; this
  /// exposes the same last resort to the synchronous quit deadline.
  func forceKill() {
    guard process.isRunning else { return }
    kill(process.processIdentifier, SIGKILL)
  }

  /// stdout arrives split mid-line. Buffer until a newline, then parse one JSON per line.
  private func consume(_ data: Data) {
    pending.append(data)
    while let newlineIndex = pending.firstIndex(of: 0x0a) {
      let line = pending.subdata(in: pending.startIndex..<newlineIndex)
      pending.removeSubrange(pending.startIndex...newlineIndex)
      guard !line.isEmpty,
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        let type = object["type"] as? String
      else { continue }
      if type == "control_response", consumeInitializeReply(object) { continue }
      if type == "control_response", consumePendingReply(object) { continue }
      let event = ClaudeEvent(type: type, subtype: object["subtype"] as? String, payload: object)
      DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
  }

  /// True when this answered an `ask`, in which case its caller has been handed the payload and
  /// nothing further should see it. An `error` reply resolves the same call with nil: the caller
  /// asked a question and there is no answer, which is all it needs to know.
  private func consumePendingReply(_ object: [String: Any]) -> Bool {
    guard let response = object["response"] as? [String: Any],
      let requestID = response["request_id"] as? String
    else { return false }
    pendingRepliesLock.lock()
    let completion = pendingReplies.removeValue(forKey: requestID)
    pendingRepliesLock.unlock()
    guard let completion else { return false }
    let payload =
      response["subtype"] as? String == "success" ? response["response"] as? [String: Any] : nil
    DispatchQueue.main.async { completion(payload) }
    return true
  }

  /// Answer every outstanding `ask` with nil. The engine is gone, so no reply is coming, and a
  /// caller left holding a completion that never runs is a spinner that never stops.
  private func finishPendingReplies() {
    pendingRepliesLock.lock()
    let waiting = pendingReplies
    pendingReplies.removeAll()
    pendingRepliesLock.unlock()
    guard !waiting.isEmpty else { return }
    DispatchQueue.main.async { for completion in waiting.values { completion(nil) } }
  }

  /// True when this was the reply to our `initialize`, which releases the queued input.
  private func consumeInitializeReply(_ object: [String: Any]) -> Bool {
    guard let response = object["response"] as? [String: Any],
      response["request_id"] as? String == Self.initializeRequestID
    else { return false }
    if response["subtype"] as? String != "success" {
      let message = response["error"] as? String ?? "unknown"
      NSLog("hukan: claude initialize failed: \(message)")
      // The engine will not take any input now, so the queued outbox would sit forever. Tell
      // the session so it can surface the "not signed in" note instead of a silent dead pane.
      DispatchQueue.main.async { [weak self] in self?.onInitializeFailed?(message) }
    }
    // The advertised model roster is nested one deeper: control_response.response.response.
    // Each entry's `value` is the --model string, `displayName` the label.
    if let inner = response["response"] as? [String: Any],
      let raw = inner["models"] as? [[String: Any]]
    {
      let models = raw.compactMap { entry -> ClaudeModel? in
        guard let value = entry["value"] as? String,
          let name = entry["displayName"] as? String
        else { return nil }
        return ClaudeModel(
          value: value, displayName: name,
          resolvedModel: entry["resolvedModel"] as? String ?? value)
      }
      if !models.isEmpty {
        DispatchQueue.main.async { [weak self] in self?.onModels?(models) }
      }
    }
    // The slash-command list rides in the same reply, beside the roster. Built-ins and skills
    // arrive together and undistinguished, which is exactly what a completion list wants.
    if let inner = response["response"] as? [String: Any],
      let raw = inner["commands"] as? [[String: Any]]
    {
      let commands = raw.compactMap { entry -> ClaudeCommand? in
        guard let name = entry["name"] as? String else { return nil }
        return ClaudeCommand(
          name: name,
          description: entry["description"] as? String ?? "",
          argumentHint: entry["argumentHint"] as? String ?? "",
          aliases: entry["aliases"] as? [String] ?? [])
      }
      if !commands.isEmpty {
        DispatchQueue.main.async { [weak self] in self?.onCommands?(commands) }
      }
    }
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.isInitialized = true
      let queued = self.outbox
      self.outbox.removeAll()
      for item in queued { self.writeNow(item) }
    }
    return true
  }

  private static let initializeRequestID = "hukan-initialize"

  /// Unique ids for the control_requests we originate, kept apart from the initialize id so
  /// their replies fall through `consumeInitializeReply` and are ignored.
  private var controlRequestCounter = 0
  private func nextControlRequestID() -> String {
    controlRequestCounter += 1
    return "hukan-control-\(controlRequestCounter)"
  }
}

/// Where Claude Code keeps its transcripts.
///
/// They live at `~/.claude/projects/<cwd flattened with dashes>/<session-id>.jsonl`.
/// A UUID without one cannot be resumed, so there is no point listing it in the overview.
enum ClaudeSessionStore {
  static func directory(for worktree: URL) -> URL {
    // /Users/x/src/github.com/y → -Users-x-src-github-com-y
    // Dots are flattened too, not just slashes (github.com becomes github-com).
    let encoded = worktree.standardizedFileURL.path
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ".", with: "-")
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/projects")
      .appendingPathComponent(encoded)
  }

  static func transcriptURL(id: UUID, worktree: URL) -> URL {
    directory(for: worktree).appendingPathComponent("\(id.uuidString).jsonl")
  }

  /// Delete a session for good: unlink its transcript. Because the list is derived from the
  /// transcripts on disk (see `sessions(in:)`), removing the file *is* removing the session —
  /// there is no hukan-side record to forget, and nothing short of this would stop the next scan
  /// finding it again. It is another tool's master data and there is no undo, so the caller is
  /// expected to have asked first. Returns whether the file is gone (true if it was already).
  @discardableResult
  static func delete(id: UUID, worktree: URL) -> Bool {
    let url = transcriptURL(id: id, worktree: worktree)
    guard FileManager.default.fileExists(atPath: url.path) else { return true }
    do {
      try FileManager.default.removeItem(at: url)
      return true
    } catch {
      NSLog("hukan: could not delete transcript \(url.path): \(error)")
      return false
    }
  }

  /// Whether `--resume` can reattach to this session.
  static func isResumable(id: UUID, worktree: URL) -> Bool {
    FileManager.default.fileExists(atPath: transcriptURL(id: id, worktree: worktree).path)
  }

  /// The live process, if any, that already has this session open — read from the per-process
  /// registry Claude Code itself maintains (`~/.claude/sessions/<pid>.json`, written on launch,
  /// removed on clean exit). Spawning a second engine on the same id would be two claudes
  /// writing one transcript, so `AgentSession.start` refuses while an owner lives. A stale
  /// entry (dead pid — crash leftovers) is skipped by the same `kill(pid, 0)` liveness probe
  /// Claude Code and Unterm use; pid reuse can fake "alive", but the entry clears itself the
  /// moment that unrelated process exits, so a refusal is at worst temporary.
  static func liveProcessOwning(id: UUID) -> pid_t? {
    liveProcessOwners()[id]
  }

  /// The whole registry, read once: which live process holds each session it names.
  ///
  /// Asking it one session at a time is what the rail used to do, and the rail asks about every
  /// session it lists — the registry was therefore re-listed and every record re-parsed once per
  /// row, which on this machine's own hukan checkout (121 sessions, 15 processes registered) cost
  /// 42 ms of the main thread per rescan, and a rescan runs on every FSEvents batch under
  /// `~/.claude/sessions` as well as on every discovery.
  static func liveProcessOwners() -> [UUID: pid_t] {
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/sessions")
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)
    else { return [:] }
    var owners: [UUID: pid_t] = [:]
    for url in entries where url.pathExtension == "json" {
      guard let data = try? Data(contentsOf: url),
        let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let sessionID = record["sessionId"] as? String, let id = UUID(uuidString: sessionID),
        let pid = record["pid"] as? Int, kill(pid_t(pid), 0) == 0
      else { continue }
      owners[id] = pid_t(pid)
    }
    return owners
  }

  /// Last write time of the transcript. Usable as an ordering key in the overview.
  static func lastModified(id: UUID, worktree: URL) -> Date? {
    let path = transcriptURL(id: id, worktree: worktree).path
    return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  }

  /// The name of a session, without reading the whole conversation.
  ///
  /// The rail is the thing being scanned at a glance, so every session needs a name whether
  /// or not anyone has opened it — but parsing every transcript in full to get one is the
  /// I/O storm that lazy loading exists to avoid. Claude Code renames itself once or twice
  /// during the opening exchange and re-appends `ai-title` as the session runs, so the name
  /// it settled on is the *last* such record — the one `history` takes too. Jumping to the
  /// last occurrence of the marker parses one line instead of the conversation, so there is
  /// no scan window to outgrow: a name written once at the top is still found. Only a
  /// session too young to have been named reads forward, for the fallback — the first thing
  /// the user typed.
  /// The one shape a session title has: its first line, capped.
  ///
  /// A title is a row on the rail, and the rail builds that row with `NSTextField(labelWithString:)`
  /// — which `sizeToFit`s, so it typesets the whole string on one line however long it is. The
  /// fallback below is the first message the user sent, which in a real project reaches hundreds
  /// of thousands of characters: one such row cost 256 ms of CoreText, and a rail holding fifteen
  /// of them cost 2.4 s *per session switch*, since switching reloads the rail and rebuilds every
  /// row. Capped, the same fifteen cost a millisecond.
  ///
  /// Applied to the engine's `ai-title` too, not just the fallback: that string comes from
  /// outside hukan, and one invariant that holds for every title is worth more than trusting it
  /// to be short. Sixty is what `AgentSession` has always cut its own live guess to — the point
  /// of putting it here is that the two can no longer disagree about what a title is.
  static func titleLine(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
    return firstLine.count > titleLimit ? String(firstLine.prefix(titleLimit)) + "…" : firstLine
  }

  private static let titleLimit = 60

  static func title(id: UUID, worktree: URL) -> String? {
    let url = transcriptURL(id: id, worktree: worktree)
    guard let data = try? Data(contentsOf: url) else { return nil }
    if let named = aiTitle(inTranscript: data) { return named }

    for line in data.split(separator: 0x0a) {
      guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        record["type"] as? String == "user", record["isMeta"] as? Bool != true,
        record["isSidechain"] as? Bool != true,
        let message = record["message"] as? [String: Any],
        let text = userTexts(in: message["content"]).first
      else { continue }
      let title = titleLine(from: text)
      return title.isEmpty ? nil : title
    }
    return nil
  }

  /// The name Claude Code itself gave the session, and only that — no fallback to the first
  /// thing typed.
  ///
  /// This is what a *named* session re-reads to notice a rename: the engine keeps appending
  /// `ai-title` as the conversation goes on and never mentions it over the pipes, so the name
  /// on the rail otherwise stays whatever was true when the session was first seen. The
  /// fallback is deliberately not part of it — a running session already carries hukan's own
  /// guess from the first line typed, and replacing that with the same line untruncated would
  /// be a worse row, not a fresher one.
  static func aiTitle(id: UUID, worktree: URL) -> String? {
    guard let data = try? Data(contentsOf: transcriptURL(id: id, worktree: worktree)) else {
      return nil
    }
    return aiTitle(inTranscript: data)
  }

  /// The last `ai-title` in a whole transcript. The marker is the value, not `"type":"ai-title"`,
  /// since key order is the writer's business. A line that merely mentions it parses to no name
  /// and the search carries on.
  private static func aiTitle(inTranscript data: Data) -> String? {
    var searched = data.startIndex..<data.endIndex
    while let marker = data.range(of: titleMarker, options: .backwards, in: searched) {
      if let title = aiTitle(in: data[lineBounds(of: marker, in: data)]) { return title }
      searched = data.startIndex..<marker.lowerBound
    }
    return nil
  }

  private static let titleMarker = Data(#""ai-title""#.utf8)

  /// The whole line `range` falls in — the newlines around it, or the ends of the file.
  private static func lineBounds(of range: Range<Data.Index>, in data: Data) -> Range<Data.Index> {
    let start =
      data[data.startIndex..<range.lowerBound].lastIndex(of: 0x0a)
      .map(data.index(after:)) ?? data.startIndex
    let end = data[range.upperBound...].firstIndex(of: 0x0a) ?? data.endIndex
    return start..<end
  }

  /// The name in one transcript line, or nil if it carries none. Empty and whitespace-only
  /// names read as unnamed, so a search keeps looking past them.
  private static func aiTitle(in line: Data.SubSequence) -> String? {
    guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
      record["type"] as? String == "ai-title",
      let named = (record["aiTitle"] as? String)
    else { return nil }
    let title = titleLine(from: named)
    return title.isEmpty ? nil : title
  }

  struct History {
    /// Claude Code names the session itself and records it as `ai-title`, which beats
    /// our guess from the first line the user typed.
    let title: String?
    /// The parsed conversation, ready for `Transcript.render` — the store returns structured
    /// events, never styled text, so it stays free of rendering.
    let records: [HistoryRecord]
    /// When the last thing in the transcript happened, so a message sent now is measured
    /// against the real conversation and not against the moment the file was read.
    let lastStamp: Date?
    /// Estimated USD for the whole conversation, summed from each assistant record's `usage`
    /// via `Pricing`. Nil when no priceable usage was found (unknown model, or nothing sent yet).
    /// A subscription bills no dollars — this is the "if it were API-metered" figure.
    let cost: CostEstimate
  }

  /// Summed token counts across a session's assistant messages — the breakdown behind the cost,
  /// shown in the header's tooltip. `cacheWrite` folds both cache-creation TTLs (and the older
  /// flat field) together.
  struct TokenTotals {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var isEmpty: Bool { input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 }

    mutating func add(_ other: TokenTotals) {
      input += other.input
      output += other.output
      cacheRead += other.cacheRead
      cacheWrite += other.cacheWrite
    }
  }

  /// A summed cost estimate. `approximate` is set when at least one assistant message carried
  /// real token usage but a model `Pricing` couldn't price (a family not in the table) — its
  /// tokens are omitted, so the dollar total is a floor (but `tokens` still counts them).
  /// Synthetic records (`<synthetic>`, zero tokens) never trip this.
  struct CostEstimate {
    let usd: Double?
    let approximate: Bool
    let tokens: TokenTotals
    /// The same token counts split by the model that produced them (the assistant record's
    /// `message.model`, a resolved id). A conversation can span models — a `/model` switch, a plan
    /// on one and edits on another — and the header tooltip shows the breakdown behind the total.
    let byModel: [String: TokenTotals]
  }

  /// The resolved model id an assistant record was produced by, or nil when absent.
  private static func model(of record: [String: Any]) -> String? {
    (record["message"] as? [String: Any])?["model"] as? String
  }

  /// Token counts for one parsed record, or nil for a record with no `usage` (non-assistant).
  private static func tokens(of record: [String: Any]) -> TokenTotals? {
    guard let usage = (record["message"] as? [String: Any])?["usage"] as? [String: Any]
    else { return nil }
    var totals = TokenTotals()
    totals.input = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
    totals.output = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
    totals.cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
    if let creation = usage["cache_creation"] as? [String: Any] {
      totals.cacheWrite =
        ((creation["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue ?? 0)
        + ((creation["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0)
    } else {
      totals.cacheWrite = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
    }
    return totals
  }

  /// Price one parsed record. Only assistant records carry `usage`. Returns the record's USD and
  /// whether it was real-but-unpriceable (nonzero tokens on a model the table doesn't know).
  private static func priced(_ record: [String: Any]) -> (usd: Double, unpriced: Bool) {
    guard let message = record["message"] as? [String: Any],
      let usage = message["usage"] as? [String: Any],
      let model = message["model"] as? String
    else { return (0, false) }
    if let cost = Pricing.cost(model: model, usage: usage) { return (cost, false) }
    // Unknown model: only a floor-lowering omission if it actually consumed tokens.
    let tokens =
      ((usage["input_tokens"] as? NSNumber)?.intValue ?? 0)
      + ((usage["output_tokens"] as? NSNumber)?.intValue ?? 0)
      + ((usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0)
      + ((usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0)
    return (0, tokens > 0)
  }

  /// Records carry an ISO 8601 `timestamp`. Fractional seconds are present in practice but
  /// not guaranteed, and ISO8601DateFormatter refuses the string when the option does not
  /// match what is there, so both spellings are tried.
  private static func stamp(of record: [String: Any]) -> Date? {
    guard let text = record["timestamp"] as? String else { return nil }
    return isoWithFraction.date(from: text) ?? isoPlain.date(from: text)
  }

  private static let isoWithFraction: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let isoPlain = ISO8601DateFormatter()

  /// The record types a conversation is made of, and the only ones that hang off each other.
  /// The same set the engine's own resume parses — which is what makes a uuid taken from here a
  /// `--resume-session-at` anchor the engine can actually find. Everything else a transcript
  /// carries (titles, modes, queue bookkeeping, content replacements) sits outside the chain, and
  /// some of it is appended last, so mistaking one of those for the conversation's tail would
  /// lose the conversation.
  private static let conversationTypes: Set<String> = [
    "user", "assistant", "system", "attachment", "progress",
  ]

  /// The records still in the conversation, oldest first.
  ///
  /// A transcript is a tree, not a list. Rolling a session back does not erase what came after —
  /// it re-parents the next message onto an earlier one and leaves the abandoned messages in the
  /// file — so reading the jsonl line by line shows messages the agent itself has forgotten. The
  /// branch that is still live is the chain from the last conversation record written back to the
  /// root through `parentUuid`, which is exactly what `--resume` loads. Following it is what
  /// makes hukan's transcript and the agent's memory the same conversation.
  ///
  /// Nothing is dropped from disk by a rollback, so nothing here is a deletion: the abandoned
  /// branch is still in the file, simply no longer reachable from its tip.
  private static func liveBranch(inTranscript data: Data) -> [[String: Any]] {
    var byUUID: [String: [String: Any]] = [:]
    var tip: String?
    for line in data.split(separator: 0x0a) {
      guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        // Subagent chatter, which the live stream never surfaces either.
        record["isSidechain"] as? Bool != true,
        let type = record["type"] as? String, conversationTypes.contains(type),
        let uuid = record["uuid"] as? String
      else { continue }
      byUUID[uuid] = record
      tip = uuid
    }
    guard var cursor = tip else { return [] }

    var chain: [[String: Any]] = []
    var seen = Set<String>()
    // `seen` only guards against a malformed file pointing a record at its own ancestor; a
    // transcript written by the engine cannot loop.
    while let record = byUUID[cursor], seen.insert(cursor).inserted {
      chain.append(record)
      guard let parent = record["parentUuid"] as? String else { break }
      cursor = parent
    }
    return chain.reversed()
  }

  /// Read a past conversation back out of its jsonl.
  ///
  /// `--resume` reattaches the conversation for the *agent*, but says nothing to the person
  /// looking at it, so without this a restored session opens to an empty pane. The
  /// transcript on disk is the only copy — nothing is mirrored on our side.
  ///
  /// Parsing deliberately mirrors what the live path shows, including what it leaves out
  /// (thinking, tool results), so a restored session and a running one look the same once
  /// `Transcript.render` styles these records. One record per rendered block, each carrying its
  /// timestamp, so the renderer can place separators exactly where the parse saw a pause.
  static func history(id: UUID, worktree: URL) -> History? {
    let url = transcriptURL(id: id, worktree: worktree)
    guard let data = try? Data(contentsOf: url) else { return nil }

    var records: [HistoryRecord] = []
    var title: String?
    var lastStamp: Date?
    var costUSD: Double?
    var costApproximate = false
    var totals = TokenTotals()
    var byModel: [String: TokenTotals] = [:]

    func emit(
      _ kind: HistoryRecord.Kind, at stamp: Date?, forkAnchor: String? = nil,
      messageUUID: String? = nil
    ) {
      records.append(
        HistoryRecord(
          kind: kind, stamp: stamp, forkAnchor: forkAnchor, messageUUID: messageUUID))
      if stamp != nil { lastStamp = stamp }
    }

    // The engine renames the session as it goes and never mentions it over the pipes, so the name
    // is the last `ai-title` anywhere in the file — outside the conversation chain, which is why
    // it is read separately rather than from the walk below.
    title = aiTitle(inTranscript: data)

    for record in liveBranch(inTranscript: data) {
      let at = stamp(of: record)
      // The point a fork taken before this record would truncate at is simply the record it
      // hangs off — by construction that is the one before it on the live branch, and it is the
      // last thing the branch keeps. Records hukan does not show (thinking, tool results) are on
      // the chain too, so anchoring this way never drops part of the finished turn above.
      let forkAnchor = record["parentUuid"] as? String

      switch record["type"] as? String {
      case "user":
        guard record["isMeta"] as? Bool != true,
          let message = record["message"] as? [String: Any]
        else { continue }
        for text in userTexts(in: message["content"]) {
          emit(
            .userText(text), at: at, forkAnchor: forkAnchor,
            messageUUID: record["uuid"] as? String)
        }

      case "assistant":
        guard let message = record["message"] as? [String: Any],
          let blocks = message["content"] as? [[String: Any]]
        else { continue }
        let priced = priced(record)
        if priced.usd > 0 { costUSD = (costUSD ?? 0) + priced.usd }
        if priced.unpriced { costApproximate = true }
        if let t = tokens(of: record) {
          totals.add(t)
          byModel[model(of: record) ?? "", default: TokenTotals()].add(t)
        }
        for block in blocks {
          switch block["type"] as? String {
          case "text":
            guard let text = block["text"] as? String else { continue }
            emit(.assistantText(text), at: at)
          case "tool_use":
            emit(
              .toolUse(
                name: block["name"] as? String ?? "tool",
                input: block["input"] as? [String: Any] ?? [:]), at: at)
          default:
            continue
          }
        }

      default:
        continue
      }
    }
    return History(
      title: title, records: records, lastStamp: lastStamp,
      cost: CostEstimate(
        usd: costUSD, approximate: costApproximate, tokens: totals, byModel: byModel))
  }

  /// Estimated cost for a session, re-read from its transcript without building the styled
  /// conversation — cheap enough to call at each turn's end to refresh the header figure.
  /// `usd` is nil when the transcript is missing or has no priceable usage. Sums each assistant
  /// record's `usage` via `Pricing`, sidechain records skipped.
  ///
  /// Unlike `history`, this reads every line rather than the live branch: a rollback un-says a
  /// message but does not un-spend it, and the figure is what the conversation cost, not what is
  /// left of it.
  static func cost(id: UUID, worktree: URL) -> CostEstimate {
    let url = transcriptURL(id: id, worktree: worktree)
    guard let data = try? Data(contentsOf: url) else {
      return CostEstimate(usd: nil, approximate: false, tokens: TokenTotals(), byModel: [:])
    }

    var total: Double?
    var approximate = false
    var totals = TokenTotals()
    var byModel: [String: TokenTotals] = [:]
    for line in data.split(separator: 0x0a) {
      guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        record["isSidechain"] as? Bool != true,
        record["type"] as? String == "assistant"
      else { continue }
      let priced = priced(record)
      if priced.usd > 0 { total = (total ?? 0) + priced.usd }
      if priced.unpriced { approximate = true }
      if let t = tokens(of: record) {
        totals.add(t)
        byModel[model(of: record) ?? "", default: TokenTotals()].add(t)
      }
    }
    return CostEstimate(usd: total, approximate: approximate, tokens: totals, byModel: byModel)
  }

  /// What the person actually typed. Content is either a bare string or a block list that
  /// also carries tool results, and slash commands expand into markup nobody typed.
  /// Not private: `PromptHistory` reads the same records for the same reason, and one rule for
  /// "what the person said" is what keeps the two from drifting apart.
  static func userTexts(in content: Any?) -> [String] {
    let candidates: [String]
    if let text = content as? String {
      candidates = [text]
    } else if let blocks = content as? [[String: Any]] {
      candidates = blocks.compactMap { block in
        block["type"] as? String == "text" ? block["text"] as? String : nil
      }
    } else {
      return []
    }
    return candidates.filter { !$0.hasPrefix("<") && !$0.isEmpty }
  }

  /// Every session recorded for this directory, newest first.
  ///
  /// This is what makes the session list derived rather than stored: the transcripts on
  /// disk are the list. Nothing is imported or copied, so nothing can drift out of sync,
  /// and sessions started from a terminal show up on their own.
  static func sessions(in worktree: URL) -> [(id: UUID, modified: Date)] {
    let directory = directory(for: worktree)
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
      return []
    }
    return names.compactMap { name -> (UUID, Date)? in
      guard name.hasSuffix(".jsonl"),
        let id = UUID(uuidString: String(name.dropLast(6))),
        let modified =
          (try? FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(name).path))?[.modificationDate] as? Date
      else { return nil }
      return (id, modified)
    }.sorted { $0.1 > $1.1 }
  }
}

// MARK: - Rendering events into transcript styling
