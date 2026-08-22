import XCTest

@testable import Hukan

/// The `get_usage` reply, read the way the toolbar reads it. The payloads here are captured from
/// a real engine, trimmed to the fields the parser looks at plus enough of their neighbours to
/// prove it picks the right ones.
final class ClaudeUsageTests: XCTestCase {
  private func payload(_ json: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    return try XCTUnwrap(object as? [String: Any])
  }

  /// A Max account: the rolling session window, the "all models" week, and one model-scoped week.
  /// The scoped bar takes its model's name, which is what the toolbar shows instead of an icon.
  func testReadsTheNormalizedLimits() throws {
    let snapshot = try XCTUnwrap(
      ClaudeUsage.parse(
        payload(
          """
          {
            "subscription_type": "max",
            "rate_limits_available": true,
            "rate_limits": {
              "five_hour": { "utilization": 35, "resets_at": "2026-08-26T22:19:59.898770+00:00" },
              "limits": [
                { "kind": "session", "group": "session", "percent": 35,
                  "resets_at": "2026-08-26T22:19:59.898770+00:00", "scope": null },
                { "kind": "weekly_all", "group": "weekly", "percent": 31,
                  "resets_at": "2026-09-01T07:59:59.898790+00:00", "scope": null },
                { "kind": "weekly_scoped", "group": "weekly", "percent": 21,
                  "resets_at": "2026-09-01T07:59:59.899038+00:00",
                  "scope": { "model": { "display_name": "Fable", "id": null } } }
              ]
            }
          }
          """)))

    XCTAssertEqual(snapshot.session?.percent, 35)
    XCTAssertEqual(snapshot.session?.label, "session")
    XCTAssertEqual(snapshot.weekly.map(\.label), ["all models", "Fable"])
    XCTAssertEqual(snapshot.weekly.map(\.percent), [31, 21])
  }

  /// `resets_at` carries fractional seconds, which `ISO8601DateFormatter` refuses by default —
  /// the whole reading would come back with no reset times at all.
  func testParsesFractionalSecondTimestamps() throws {
    let withFraction = try XCTUnwrap(
      ClaudeUsage.date(fromISO8601: "2026-08-26T22:19:59.898770+00:00"))
    let without = try XCTUnwrap(ClaudeUsage.date(fromISO8601: "2026-08-26T22:19:59+00:00"))
    XCTAssertEqual(withFraction.timeIntervalSince1970, without.timeIntervalSince1970, accuracy: 1)
  }

  /// An API-key, Bedrock or Vertex session: the responses carry no rate-limit headers, so there
  /// are no plan limits to show and the toolbar item must stay hidden rather than read zero.
  func testNoPlanLimitsReadsAsNothing() throws {
    XCTAssertNil(
      ClaudeUsage.parse(
        try payload(#"{ "rate_limits_available": false, "rate_limits": { "limits": [] } }"#)))
    XCTAssertNil(ClaudeUsage.parse(try payload(#"{ "session": { "total_cost_usd": 0 } }"#)))
  }

  /// A window the parser does not know about is skipped rather than mislabelled — the engine
  /// tracks several that come and go, and a new `group` must not land in the weekly row.
  func testUnknownGroupsAreSkipped() throws {
    let snapshot = try XCTUnwrap(
      ClaudeUsage.parse(
        payload(
          """
          {
            "rate_limits_available": true,
            "rate_limits": { "limits": [
              { "kind": "session", "group": "session", "percent": 4, "resets_at": null },
              { "kind": "something_new", "group": "monthly", "percent": 99, "resets_at": null }
            ] }
          }
          """)))
    XCTAssertEqual(snapshot.session?.percent, 4)
    XCTAssertNil(snapshot.session?.resetsAt)
    XCTAssertTrue(snapshot.weekly.isEmpty)
  }
}
