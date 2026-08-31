import Foundation

/// The prompts this person has typed, read back out of the transcripts.
///
/// There is no store here and no file of hukan's own: `~/.claude/projects` already holds every
/// message that was ever sent, so the history is derived the way the session list is (see
/// `ClaudeSessionStore.sessions(in:)`) — master data where it already is. `~/.claude/history.jsonl`
/// looks like the source and is not: the CLI writes it from its interactive REPL only, so nothing
/// hukan sends over `claude -p` reaches it (131 lines on this machine against 13,000 sends).
enum PromptHistory {
  /// Past prompts for `worktrees`, newest first, each text once.
  ///
  /// The scope is one repository's worktrees, the set git lists — which is the same set the rail
  /// shows. A worktree git has stopped listing takes its sessions off the rail with it, so its
  /// prompts leave the same way rather than outliving the work they belonged to.
  ///
  /// Reading is the whole cost, and it is paid once on a background queue: a repository's
  /// transcripts run to hundreds of megabytes while the prompts inside them are a hundred
  /// kilobytes. Nothing is written back — a cache would be a second copy of another tool's master
  /// data, for a read measured at 0.9s over 268MB.
  static func read(worktrees: [URL]) -> [String] {
    var newest: [String: Date] = [:]
    for worktree in worktrees {
      read(directory: ClaudeSessionStore.directory(for: worktree), into: &newest)
    }
    return newest.sorted { $0.value > $1.value }.map(\.key)
  }

  /// A candidate is one instruction, not a paste. The prompts actually typed here have a median
  /// length of 22 characters; past this a "message" is a crash log or a file dropped in as text,
  /// which nobody summons back by typing two letters at it and which would cost the index more
  /// than every real prompt put together.
  static let lengthLimit = 1000

  private static func read(directory: URL, into newest: inout [String: Date]) {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
      .filter { $0.hasSuffix(".jsonl") } ?? []
    for name in names {
      guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
        continue
      }
      read(transcript: data, into: &newest)
    }
  }

  private static func read(transcript: Data, into newest: inout [String: Date]) {
    // Only a fifth of a transcript's lines are the person's and the rest are the tool results
    // that make it hundreds of megabytes, so the line is found before it is parsed. Both scans
    // are Foundation's — a newline to end the line, then the key inside it — and that is the
    // whole reason this is not a byte loop: the same loop written in Swift runs at 236ms over
    // one repository's 268MB when it is optimised and 36.6 *seconds* when it is not, so the
    // Debug build would spend a minute on the read while a release spent a quarter second.
    // Handing both scans to Foundation costs 430ms and costs it in either build.
    //
    // The key is looked for anywhere in the line rather than at its head: `type` is not the
    // first key Claude Code writes, and no user record on this machine begins with it.
    var lineStart = transcript.startIndex
    while lineStart < transcript.endIndex {
      let lineEnd =
        transcript.range(of: newline, in: lineStart..<transcript.endIndex)?.lowerBound
        ?? transcript.endIndex
      let line = transcript[lineStart..<lineEnd]
      lineStart = lineEnd < transcript.endIndex ? transcript.index(after: lineEnd) : lineEnd
      guard !line.isEmpty, line.range(of: userKey) != nil,
        let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        record["type"] as? String == "user", record["isMeta"] as? Bool != true,
        record["isSidechain"] as? Bool != true,
        let message = record["message"] as? [String: Any]
      else { continue }
      let at = (record["timestamp"] as? String).flatMap(Self.timestamp) ?? .distantPast
      for text in ClaudeSessionStore.userTexts(in: message["content"]) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= lengthLimit, !isInjected(prompt) else { continue }
        if let seen = newest[prompt], seen >= at { continue }
        newest[prompt] = at
      }
    }
  }

  private static let userKey = Data(#""type":"user""#.utf8)
  private static let newline = Data([0x0a])

  /// The preambles the CLI writes as if they were the person: a resumed session's summary and the
  /// caveat it prefixes local command output with. `userTexts` already drops the `<…>` wrappers,
  /// which is what the rest of them look like; these two are prose and would otherwise read as
  /// something that was typed.
  private static func isInjected(_ prompt: String) -> Bool {
    prompt.hasPrefix("Caveat:") || prompt.hasPrefix("This session is being continued")
      || prompt.hasPrefix("[Request interrupted")
  }

  private static let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static func timestamp(_ text: String) -> Date? {
    formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
  }
}
