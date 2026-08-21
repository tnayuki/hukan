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
  private var pending = Data()

  /// stdin is written from both the main thread (sends, approvals) and the stdout reader
  /// thread, so every write is funnelled through here. `isInitialized` and `outbox` are
  /// only ever touched on this queue.
  private let writeQueue = DispatchQueue(label: "dev.tnayuki.hukan.claude-write")
  private var isInitialized = false
  private var outbox: [[String: Any]] = []

  var onEvent: ((ClaudeEvent) -> Void)?
  var onExit: ((Int32) -> Void)?
  /// The model roster carried by the initialize reply. Fires once, on the main thread.
  var onModels: (([ClaudeModel]) -> Void)?
  /// The `initialize` reply came back an error, so the engine never became ready — most often
  /// because the account is signed out (the OAuth token expired or `/logout` was run elsewhere).
  /// Carries the engine's message. Fires on the main thread; the session is dead after this.
  var onInitializeFailed: ((String) -> Void)?

  init(id: UUID = UUID(), worktree: URL) {
    self.id = id
    self.worktree = worktree
  }

  var isRunning: Bool { process.isRunning }

  /// - Parameters:
  ///   - tools: an empty array becomes `--tools ""`, disabling every tool. That covers
  ///     "plain Claude, not Claude Code", so there is no need for a second backend hitting
  ///     the Messages API directly — one subscription covers auth and billing.
  ///   - resume: true passes `--resume <id>`, used to reattach a conversation after
  ///     window restoration.
  func start(
    model: String = "default", permissionMode: String = "default", effort: String = "default",
    tools: [String]? = nil, resume: Bool = false
  ) throws {
    var arguments = [
      "claude", "-p",
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
    arguments += resume ? ["--resume", id.uuidString] : ["--session-id", id.uuidString]
    if let tools {
      arguments += ["--tools", tools.joined(separator: ",")]
    }

    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = worktree
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = FileHandle.nullDevice

    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.consume(data)
    }
    process.terminationHandler = { [weak self] process in
      self?.stdoutPipe.fileHandleForReading.readabilityHandler = nil
      let status = process.terminationStatus
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
      let event = ClaudeEvent(type: type, subtype: object["subtype"] as? String, payload: object)
      DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
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
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/sessions")
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)
    else { return nil }
    for url in entries where url.pathExtension == "json" {
      guard let data = try? Data(contentsOf: url),
        let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let sessionID = record["sessionId"] as? String,
        sessionID.caseInsensitiveCompare(id.uuidString) == .orderedSame,
        let pid = record["pid"] as? Int
      else { continue }
      if kill(pid_t(pid), 0) == 0 { return pid_t(pid) }
    }
    return nil
  }

  /// Last write time of the transcript. Usable as an ordering key in the overview.
  static func lastModified(id: UUID, worktree: URL) -> Date? {
    let path = transcriptURL(id: id, worktree: worktree).path
    return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  }

  /// The name of a session, without reading the whole conversation.
  ///
  /// The rail is the thing being scanned at a glance, so every session needs a name whether
  /// or not anyone has opened it — but reading every transcript in full to get one is the
  /// I/O storm that lazy loading exists to avoid. Claude Code writes `ai-title` early, right
  /// after the opening exchange, so this stops at the first one and gives up after
  /// `titleScanLimit` records, falling back to the first thing the user typed.
  static func title(id: UUID, worktree: URL) -> String? {
    let url = transcriptURL(id: id, worktree: worktree)
    guard let data = try? Data(contentsOf: url) else { return nil }

    var fallback: String?
    for (index, line) in data.split(separator: 0x0a).enumerated() {
      if index >= titleScanLimit { break }
      guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        record["isSidechain"] as? Bool != true
      else { continue }

      switch record["type"] as? String {
      case "ai-title":
        if let title = (record["aiTitle"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        {
          return title
        }
      case "user":
        guard fallback == nil, record["isMeta"] as? Bool != true,
          let message = record["message"] as? [String: Any]
        else { continue }
        fallback = userTexts(in: message["content"]).first
      default:
        continue
      }
    }
    return fallback
  }

  private static let titleScanLimit = 200

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

    func emit(_ kind: HistoryRecord.Kind, at stamp: Date?) {
      records.append(HistoryRecord(kind: kind, stamp: stamp))
      if stamp != nil { lastStamp = stamp }
    }

    for line in data.split(separator: 0x0a) {
      guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        // Subagent chatter, which the live stream never surfaces either.
        record["isSidechain"] as? Bool != true
      else { continue }
      let at = stamp(of: record)

      switch record["type"] as? String {
      case "ai-title":
        title = record["aiTitle"] as? String

      case "user":
        guard record["isMeta"] as? Bool != true,
          let message = record["message"] as? [String: Any]
        else { continue }
        for text in userTexts(in: message["content"]) {
          emit(.userText(text), at: at)
        }

      case "assistant":
        guard let message = record["message"] as? [String: Any],
          let blocks = message["content"] as? [[String: Any]]
        else { continue }
        let priced = priced(record)
        if priced.usd > 0 { costUSD = (costUSD ?? 0) + priced.usd }
        if priced.unpriced { costApproximate = true }
        if let t = tokens(of: record) { totals.add(t) }
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
      cost: CostEstimate(usd: costUSD, approximate: costApproximate, tokens: totals))
  }

  /// Estimated cost for a session, re-read from its transcript without building the styled
  /// conversation — cheap enough to call at each turn's end to refresh the header figure.
  /// `usd` is nil when the transcript is missing or has no priceable usage. Mirrors `history`'s
  /// parse (sidechain records skipped), summing each assistant record's `usage` via `Pricing`.
  static func cost(id: UUID, worktree: URL) -> CostEstimate {
    let url = transcriptURL(id: id, worktree: worktree)
    guard let data = try? Data(contentsOf: url) else {
      return CostEstimate(usd: nil, approximate: false, tokens: TokenTotals())
    }

    var total: Double?
    var approximate = false
    var totals = TokenTotals()
    for line in data.split(separator: 0x0a) {
      guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        record["isSidechain"] as? Bool != true,
        record["type"] as? String == "assistant"
      else { continue }
      let priced = priced(record)
      if priced.usd > 0 { total = (total ?? 0) + priced.usd }
      if priced.unpriced { approximate = true }
      if let t = tokens(of: record) { totals.add(t) }
    }
    return CostEstimate(usd: total, approximate: approximate, tokens: totals)
  }

  /// The conversation as one lowercased blob for substring search, without styling it.
  ///
  /// The rail's full-text filter needs to look inside sessions nobody has opened, whose only
  /// copy is this jsonl (the same reasoning as `title` and `history`). It mirrors `history`'s
  /// parse — user text plus the assistant's text blocks, sidechain and command markup dropped —
  /// but collects plain strings, so a search matches exactly what the transcript would show.
  /// Tool calls and results are deliberately left out: they are not what someone searches for.
  static func searchableText(id: UUID, worktree: URL) -> String {
    let url = transcriptURL(id: id, worktree: worktree)
    guard let data = try? Data(contentsOf: url) else { return "" }

    var parts: [String] = []
    for line in data.split(separator: 0x0a) {
      guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        record["isSidechain"] as? Bool != true
      else { continue }

      switch record["type"] as? String {
      case "user":
        guard record["isMeta"] as? Bool != true,
          let message = record["message"] as? [String: Any]
        else { continue }
        parts.append(contentsOf: userTexts(in: message["content"]))
      case "assistant":
        guard let message = record["message"] as? [String: Any],
          let blocks = message["content"] as? [[String: Any]]
        else { continue }
        for block in blocks where block["type"] as? String == "text" {
          if let text = block["text"] as? String { parts.append(text) }
        }
      default:
        continue
      }
    }
    return parts.joined(separator: "\n").lowercased()
  }

  /// What the person actually typed. Content is either a bare string or a block list that
  /// also carries tool results, and slash commands expand into markup nobody typed.
  private static func userTexts(in content: Any?) -> [String] {
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
