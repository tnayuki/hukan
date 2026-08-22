import Foundation

/// Account-wide Claude subscription usage — the same figures claude.ai and Claude Code's own
/// `/usage` show: how much of the plan's rolling session window and weekly limits are spent.
///
/// This is *not* a dollar cost and *not* per-session — a Max/Pro plan bills no dollars, and the
/// limits are account-scoped. It is read with the `get_usage` control_request, which a live
/// session answers off the rate-limit headers it has already seen, so asking costs a line on a
/// stream that is open anyway.
///
/// It was `claude -p --output-format json "/usage"` first, and both halves of that were wrong.
/// The spawn cost ~2.6s and, because a slash command is a user message, every probe left a
/// session transcript behind: 2400 files in `~/.claude/projects` over six days, from a poll that
/// runs while the window is up. And the numbers had to be recovered from English prose
/// ("Current session: 18% used · resets Aug 21 at 9:29am"), which is Claude Code's own
/// undocumented rendering and would break on a wording change. The control_request answers with
/// the figures already normalized, so both the process and the regexes are gone.
enum ClaudeUsage {
  /// One limit bar: its label (`session` is implicit; weekly bars carry "all models", a model
  /// name, …), percent consumed, and when the window resets.
  struct Limit {
    let label: String
    let percent: Int
    /// Nil for a window the engine reports without a reset time. Kept as a date rather than as
    /// the CLI's formatted string, so the view decides how to say it.
    let resetsAt: Date?
  }

  /// A reading of the account's limits. `weekly` is in the engine's own order (the "all models"
  /// bar first, then per-model). Either half may be empty if that window is not tracked.
  struct Snapshot {
    let session: Limit?
    let weekly: [Limit]
  }

  /// Read a `get_usage` reply. Nil when the account has no plan limits to report — an API-key,
  /// Bedrock or Vertex session, whose responses carry no rate-limit headers at all — which is
  /// the case the toolbar hides the indicator for.
  ///
  /// The `limits` array is the engine's own normalization of the several windows it tracks, so
  /// it is read in preference to the `five_hour`/`seven_day` fields beside it: those are one
  /// shape per window, while this is one shape for all of them, already in display order.
  static func parse(_ payload: [String: Any]) -> Snapshot? {
    guard let rateLimits = payload["rate_limits"] as? [String: Any] else { return nil }
    guard payload["rate_limits_available"] as? Bool != false else { return nil }
    guard let rows = rateLimits["limits"] as? [[String: Any]] else { return nil }

    var session: Limit?
    var weekly: [Limit] = []
    for row in rows {
      guard let percent = (row["percent"] as? NSNumber)?.intValue else { continue }
      let resetsAt = (row["resets_at"] as? String).flatMap(date(fromISO8601:))
      switch row["group"] as? String {
      case "session":
        session = Limit(label: "session", percent: percent, resetsAt: resetsAt)
      case "weekly":
        // A scoped window names what it is scoped to — a model, most often — and that name is
        // real information rather than a generic label, so it becomes the bar's own.
        let scope = row["scope"] as? [String: Any]
        let model = scope?["model"] as? [String: Any]
        let label = model?["display_name"] as? String ?? "all models"
        weekly.append(Limit(label: label, percent: percent, resetsAt: resetsAt))
      default:
        continue
      }
    }
    if session == nil && weekly.isEmpty { return nil }
    return Snapshot(session: session, weekly: weekly)
  }

  /// The engine stamps `resets_at` with fractional seconds; a formatter without that option
  /// returns nil for every one of them, so both spellings are tried.
  static func date(fromISO8601 text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }
}
