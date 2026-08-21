import Foundation

/// Account-wide Claude subscription usage — the same figures claude.ai and Claude Code's own
/// `/usage` show: how much of the plan's rolling session window and weekly limits are spent.
///
/// This is *not* a dollar cost and *not* per-session — a Max/Pro plan bills no dollars, and the
/// limits are account-scoped. It isn't in the transcript or the stream-json protocol either; the
/// only handle we have is `claude -p --output-format json "/usage"`, which returns the numbers as
/// plain text in its `result` field and costs nothing (no model turn — verified `num_turns: 0`,
/// `total_cost_usd: 0`). The format is Claude Code's own and undocumented, so the parse is
/// defensive: any line that doesn't match is skipped, and a run that yields nothing returns nil.
enum ClaudeUsage {
  /// One limit bar: its label (`session` is implicit; weekly bars carry "all models", a model
  /// name, …), percent consumed, and a human reset string as the CLI printed it.
  struct Limit {
    let label: String
    let percent: Int
    let resetsAt: String
  }

  /// A reading of the account's limits. `weekly` is in the CLI's own order (the "all models" bar
  /// first, then per-model). Either half may be empty if the CLI didn't print it.
  struct Snapshot {
    let session: Limit?
    let weekly: [Limit]
  }

  // Throttle/dedup state — touched only on the main thread (see `fetch`).
  private static var inFlight = false
  private static var lastFetched: Date?
  private static var cached: Snapshot?
  /// Spawning `claude` costs ~5s of process startup, so a fresh reading is worth at most this
  /// often; within the window `fetch` returns the cached snapshot instead of respawning.
  private static let minInterval: TimeInterval = 45

  /// Fetch the current usage snapshot. **Call on the main thread.** Coalesces: a fetch already in
  /// flight is dropped; a fetch within `minInterval` of the last returns the cached snapshot
  /// synchronously. `force` bypasses the interval (but still yields to an in-flight run). The
  /// completion runs on the main thread; nil means the CLI printed no plan limits (API-key user,
  /// signed out, or a format change) — the caller should hide the indicator.
  static func fetch(force: Bool = false, completion: @escaping (Snapshot?) -> Void) {
    if inFlight { return }
    if !force, let last = lastFetched, Date().timeIntervalSince(last) < minInterval {
      completion(cached)
      return
    }
    inFlight = true
    DispatchQueue.global(qos: .utility).async {
      let snapshot = run()
      DispatchQueue.main.async {
        inFlight = false
        lastFetched = Date()
        // Keep the last good reading on a transient failure rather than blinking to empty.
        if let snapshot { cached = snapshot }
        completion(snapshot ?? cached)
      }
    }
  }

  /// An empty scratch directory to spawn the usage probe in. Without a working directory of our
  /// own the probe inherits the app's — which is `/` when launched via `open` — and `claude`
  /// walks its cwd as the project, descending into `/Users/<me>/Downloads` (and Desktop,
  /// Documents) and tripping a TCC prompt every poll, attributed to the responsible app "Hukan".
  /// An empty directory has no protected children to scan, so the probe stays silent. Created
  /// lazily once and reused; the OS reaps `/tmp` on its own, so there is nothing to clean up.
  private static let scratchDirectory: URL? = {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("hukan-usage", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }()

  /// Spawn `claude -p --output-format json "/usage"` and return the parsed snapshot, or nil.
  /// Mirrors `ClaudeSession`'s `/usr/bin/env claude` launch so it resolves the same binary.
  private static func run() -> Snapshot? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["claude", "-p", "--output-format", "json", "/usage"]
    process.currentDirectoryURL = scratchDirectory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    // `readToEnd()` surfaces a read error as a catchable Swift throw; the older
    // `readDataToEndOfFile()` can raise an uncatchable NSException instead — treat any failure as
    // "no output" rather than a crash.
    let data = ((try? pipe.fileHandleForReading.readToEnd()) ?? nil) ?? Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let result = object["result"] as? String
    else { return nil }
    return parse(result)
  }

  /// Extract the limit lines from the CLI's `result` text. Exposed for a test that feeds a
  /// captured `/usage` output through the same parser the app uses.
  static func parse(_ text: String) -> Snapshot? {
    var session: Limit?
    var weekly: [Limit] = []
    for rawLine in text.split(separator: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      // The `count` guards are belt-and-suspenders: the patterns below have 2 and 3 groups, so a
      // match always fills them, but a future pattern edit shouldn't be able to index out of range.
      if let groups = firstMatch(sessionPattern, in: line), groups.count >= 2,
        let percent = Int(groups[0])
      {
        session = Limit(label: "session", percent: percent, resetsAt: groups[1])
      } else if let groups = firstMatch(weeklyPattern, in: line), groups.count >= 3,
        let percent = Int(groups[1])
      {
        weekly.append(Limit(label: groups[0], percent: percent, resetsAt: groups[2]))
      }
    }
    if session == nil && weekly.isEmpty { return nil }
    return Snapshot(session: session, weekly: weekly)
  }

  // e.g. "Current session: 18% used · resets Aug 21 at 9:29am (Asia/Tokyo)"
  private static let sessionPattern = #"^Current session: (\d+)% used · resets (.+)$"#
  // e.g. "Current week (all models): 44% used · resets Aug 25 at 4:59pm (Asia/Tokyo)"
  private static let weeklyPattern = #"^Current week \((.+?)\): (\d+)% used · resets (.+)$"#

  private static func firstMatch(_ pattern: String, in line: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(line.startIndex..., in: line)
    guard let match = regex.firstMatch(in: line, range: range) else { return nil }
    var groups: [String] = []
    for index in 1..<match.numberOfRanges {
      guard let r = Range(match.range(at: index), in: line) else { return nil }
      groups.append(String(line[r]))
    }
    return groups
  }
}
