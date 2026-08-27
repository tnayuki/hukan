import Foundation

/// What a session's context window is spent on — the reading behind Claude Code's own `/context`,
/// read with the `get_context_usage` control_request.
///
/// Unlike `ClaudeUsage`, which is the account's plan and the same for every session, this *is*
/// the session's own: it is asked of the session on screen and answers for no other. The engine
/// computes it locally from the conversation it is holding, so asking costs no model turn and no
/// API call — which is what makes it affordable to re-read at the end of every turn.
struct ContextUsage {
  /// One row of the breakdown, in the engine's own order: the system prompt and its tools, the
  /// skills loaded, the conversation itself, and what is left. A row may be zero.
  struct Category {
    /// The engine's own label for the row, e.g. "Messages" or "System tools (deferred)". Shown
    /// as it stands: the engine is the one deciding how to name a category, and the deferred
    /// tools it has not loaded a schema for say so in the name themselves.
    let name: String
    let tokens: Int
  }

  let categories: [Category]
  let totalTokens: Int
  /// The window as the engine sizes it, which is model-dependent: 200k on Haiku, 1M on a
  /// 1M-context Opus. Reading it rather than assuming is the whole reason the percentage can be
  /// trusted across a `/model` switch.
  let maxTokens: Int
  /// The engine's own rounding of total over the window. Taken as given rather than recomputed:
  /// it is measured against the *raw* maximum, which is not always `maxTokens`, and it can run
  /// past 100.
  let percentage: Int

  init?(payload: [String: Any]) {
    guard let total = (payload["totalTokens"] as? NSNumber)?.intValue,
      let max = (payload["maxTokens"] as? NSNumber)?.intValue, max > 0
    else { return nil }
    totalTokens = total
    maxTokens = max
    percentage =
      (payload["percentage"] as? NSNumber)?.intValue ?? Int((Double(total) / Double(max)) * 100)
    categories = (payload["categories"] as? [[String: Any]] ?? []).compactMap { row in
      guard let name = row["name"] as? String,
        let tokens = (row["tokens"] as? NSNumber)?.intValue
      else { return nil }
      return Category(name: name, tokens: tokens)
    }
  }

  /// The rows worth showing: what is spent, heaviest first. "Free space" is dropped — it is the
  /// remainder, which the percentage already says, and leaving it in would put the largest number
  /// in the list at the top of a list about consumption. Zero rows go too; the engine sends them
  /// and there is nothing to report about a category that costs nothing.
  var spent: [Category] {
    categories
      .filter { $0.tokens > 0 && $0.name != "Free space" }
      .sorted { $0.tokens > $1.tokens }
  }
}
