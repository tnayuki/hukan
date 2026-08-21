import Foundation

/// Per-model token prices, used only to turn a transcript's recorded `usage` into an *estimated*
/// dollar figure. On a subscription (Max/Pro) no dollars are actually billed — this is the
/// "if it were API-metered" number, the same thing Claude Code's own `total_cost_usd` reports.
///
/// Rates are approximate and pinned here because Claude Code does not write a price into the
/// transcript (only token counts). They will drift as Anthropic changes pricing or ships models,
/// so this is deliberately coarse: an unknown model yields no estimate rather than a wrong one.
/// Cache prices follow Anthropic's standard multipliers off the input rate — writes cost 1.25×
/// (5-minute TTL) or 2× (1-hour TTL), reads cost 0.1×.
struct ModelPricing {
  /// USD per 1M input tokens.
  let input: Double
  /// USD per 1M output tokens.
  let output: Double
}

enum Pricing {
  /// Standard cache multipliers relative to the input rate.
  private static let cacheRead = 0.1
  private static let cacheWrite5m = 1.25
  private static let cacheWrite1h = 2.0

  /// Resolve a model id (a resolved id like `claude-opus-4-8`, or an alias) to its rate.
  /// Matched by family substring so it survives point releases; unknown → nil (no estimate).
  /// The 1M-context variants carry a long-context premium above 200k tokens that this ignores.
  static func rate(forModel id: String) -> ModelPricing? {
    let m = id.lowercased()
    if m.contains("fable") || m.contains("mythos") { return ModelPricing(input: 10, output: 50) }
    if m.contains("opus") { return ModelPricing(input: 5, output: 25) }
    if m.contains("sonnet") { return ModelPricing(input: 3, output: 15) }
    if m.contains("haiku") { return ModelPricing(input: 1, output: 5) }
    return nil
  }

  /// Estimated USD for one assistant message's `usage` object, or nil if the model is unknown.
  /// `usage` is the raw dictionary as recorded in the transcript / streamed by the engine.
  static func cost(model: String, usage: [String: Any]) -> Double? {
    guard let rate = rate(forModel: model) else { return nil }
    let input = (usage["input_tokens"] as? NSNumber)?.doubleValue ?? 0
    let output = (usage["output_tokens"] as? NSNumber)?.doubleValue ?? 0
    let read = (usage["cache_read_input_tokens"] as? NSNumber)?.doubleValue ?? 0

    // Cache writes: the newer breakdown splits 5m vs 1h (priced differently); the older flat
    // `cache_creation_input_tokens` is billed at the 5m rate.
    var write5m = 0.0
    var write1h = 0.0
    if let creation = usage["cache_creation"] as? [String: Any] {
      write5m = (creation["ephemeral_5m_input_tokens"] as? NSNumber)?.doubleValue ?? 0
      write1h = (creation["ephemeral_1h_input_tokens"] as? NSNumber)?.doubleValue ?? 0
    } else {
      write5m = (usage["cache_creation_input_tokens"] as? NSNumber)?.doubleValue ?? 0
    }

    let tokens =
      input * rate.input
      + output * rate.output
      + read * rate.input * cacheRead
      + write5m * rate.input * cacheWrite5m
      + write1h * rate.input * cacheWrite1h
    return tokens / 1_000_000
  }
}
