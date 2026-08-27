import XCTest

@testable import Hukan

/// The `get_context_usage` reply, read the way the conversation header reads it. The payload is
/// captured from a real engine.
final class ContextUsageTests: XCTestCase {
  private func usage(_ json: String) throws -> ContextUsage {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let payload = try XCTUnwrap(object as? [String: Any])
    return try XCTUnwrap(ContextUsage(payload: payload))
  }

  private let captured = """
    {
      "categories": [
        { "name": "System prompt", "tokens": 6487, "color": "promptBorder" },
        { "name": "System tools", "tokens": 14082, "color": "inactive" },
        { "name": "System tools (deferred)", "tokens": 15297, "color": "inactive",
          "isDeferred": true },
        { "name": "Skills", "tokens": 1973, "color": "warning" },
        { "name": "Messages", "tokens": 3634, "color": "purple" },
        { "name": "MCP tools", "tokens": 0, "color": "inactive" },
        { "name": "Free space", "tokens": 173825, "color": "promptBorder" }
      ],
      "totalTokens": 26177,
      "maxTokens": 200000,
      "rawMaxTokens": 200000,
      "autocompactSource": "auto",
      "percentage": 13
    }
    """

  func testReadsTheWindowAndItsBreakdown() throws {
    let usage = try usage(captured)
    XCTAssertEqual(usage.totalTokens, 26177)
    XCTAssertEqual(usage.maxTokens, 200_000)
    XCTAssertEqual(usage.percentage, 13)
    XCTAssertEqual(usage.categories.count, 7)
  }

  /// The tooltip lists what is *spent*, heaviest first — so the remainder goes (the percentage
  /// already says it, and it would otherwise be the biggest number at the top of a list about
  /// consumption) and so do the categories costing nothing.
  func testSpentDropsFreeSpaceAndEmptyRows() throws {
    let spent = try usage(captured).spent
    XCTAssertEqual(
      spent.map(\.name),
      [
        "System tools (deferred)", "System tools", "System prompt", "Messages", "Skills",
      ])
    XCTAssertEqual(
      spent.first?.name, "System tools (deferred)",
      "the engine's own label is shown as it stands, deferred marker and all")
  }

  /// The engine's own rounding is taken as given: it is measured against the raw maximum, which
  /// is not always the window reported beside it.
  func testThePercentageIsTheEnginesOwn() throws {
    let usage = try usage(
      """
      { "categories": [], "totalTokens": 100, "maxTokens": 1000,
        "rawMaxTokens": 200, "percentage": 50 }
      """)
    XCTAssertEqual(usage.percentage, 50, "not 10, which total over maxTokens would give")
  }

  /// A reply with no window in it says nothing about how full the window is, so it must not read
  /// as an empty one — the header shows the last good figure instead of jumping to zero.
  func testAReplyWithoutAWindowIsNoReading() {
    XCTAssertNil(ContextUsage(payload: ["totalTokens": 10]))
    XCTAssertNil(ContextUsage(payload: ["totalTokens": 10, "maxTokens": 0]))
    XCTAssertNil(ContextUsage(payload: [:]))
  }
}
