import AppKit
import XCTest

@testable import Hukan

/// The panel's look, drawn offscreen from a posed `SessionPanel` under the dark appearance, at a
/// narrow and a wide column. `TEST_RUNNER_HUKAN_PREVIEW=panel` writes
/// /tmp/hukan-preview-panel-{560,900}.png and /tmp/hukan-preview-panel-list-{560,900}.png; with
/// no preview asked for, the case is skipped — the look is not pinned until it settles.
final class PanelSnapshotTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-panel-snap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "# Approach\n".write(
      to: root.appendingPathComponent("approach.md"), atomically: true, encoding: .utf8)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  static let json = """
    {"title": "Backport loop", "items": [
      {"type": "badge", "text": "Working", "tone": "info"},
      {"type": "fields", "items": [
        {"label": "Source", "value": [{"tag": "PR: #58886 <https://github.com/o/r/pull/58886>"}, " Fix the reader's line"]},
        {"label": "Ticket", "value": [{"tag": "JIRA: ABC-123 <https://example.atlassian.net/browse/ABC-123>"}]},
        {"label": "Branch", "value": [{"text": "release/4.2", "mono": true}]},
        {"label": "Last probe", "symbol": "clock", "value": [{"time": "TIME_3M"}]}]},
      {"type": "list", "groups": [
        {"title": "Needs you", "rows": [
          {"title": [{"tag": "PR: #58901 <https://github.com/o/r/pull/58901>"}, " release/4.2"],
           "subtitle": [{"text": "conflict in Reader.swift", "tone": "warning"}],
           "status": {"text": "Conflict", "tone": "warning"},
           "buttons": [{"label": "Open", "symbol": "arrow.up.forward", "send": "Resolve the conflict"}]},
          {"title": [{"tag": "PR: #58902 <https://github.com/o/r/pull/58902>"}, " release/4.1"],
           "subtitle": [{"text": "checks failed "}, {"time": "TIME_12M"}],
           "status": {"text": "Failed", "tone": "danger"},
           "buttons": [{"label": "Retry", "symbol": "arrow.clockwise", "command": "probe", "args": {"pr": 58902}}]}]},
        {"title": "Waiting", "rows": [
          {"title": [{"tag": "PR: #58903 <https://github.com/o/r/pull/58903>"}, " release/4.0"],
           "subtitle": [{"text": "checks running "}, {"time": "TIME_3M"}], "status": {"text": "Running", "tone": "info"}},
          {"title": [{"tag": "PR: #58904 <https://github.com/o/r/pull/58904>"}, " release/3.9"],
           "subtitle": "review requested", "status": {"text": "Review", "tone": "neutral"}}]},
        {"title": "Done", "rows": [
          {"title": [{"tag": "PR: #58899 <https://github.com/o/r/pull/58899>"}, " release/4.3"],
           "subtitle": [{"text": "merged "}, {"time": "TIME_2H"}], "status": {"text": "Merged", "tone": "success"}},
          {"title": [{"tag": "PR: #58898 <https://github.com/o/r/pull/58898>"}, " release/4.4"],
           "subtitle": [{"text": "merged "}, {"time": "TIME_5H"}], "status": {"text": "Merged", "tone": "success"}}]}]},
      {"type": "approval", "document": "approach.md", "label": "Approach"},
      {"type": "button", "label": "Carry On", "symbol": "play.fill", "send": "Carry on with the next item."}
    ]}
    """

  /// One list of a single group: its rows dealt into as many columns as the width holds.
  static let listJSON = """
    {"title": "Flaky tests", "items": [
      {"type": "badge", "text": "12 open", "tone": "danger"},
      {"type": "list", "limit": 10, "rows": [
        ROWS
      ]}
    ]}
    """

  private func fill(_ json: String) -> String {
    let now = Date()
    let iso = ISO8601DateFormatter()
    var json = json
    for (key, minutes) in [("TIME_3M", 3), ("TIME_12M", 12), ("TIME_2H", 120), ("TIME_5H", 300)] {
      json = json.replacingOccurrences(
        of: key, with: iso.string(from: now.addingTimeInterval(-Double(minutes) * 60)))
    }
    let tests = [
      "testTheReadersLineHoldsAcrossAWindowResize", "testGrantCard", "testRailSnapshot",
      "testCommitTab", "testFilesPanelDrop", "testHistoryPaging", "testBrowserChrome",
      "testEditorGutter", "testTaskCard", "testQuestionCard", "testForkKeepsAnchor",
      "testRollbackCutsBranch",
    ]
    let rows = tests.enumerated().map { index, name in
      let tone = index % 3 == 0 ? "danger" : index % 3 == 1 ? "warning" : "neutral"
      return #"{"title": [{"text": "\#(name)", "mono": true}], "subtitle": "\#(index + 1) in 8", "#
        + #""status": {"text": "x", "tone": "\#(tone)"}, "url": "https://example.com/\#(index)"}"#
    }
    return json.replacingOccurrences(of: "ROWS", with: rows.joined(separator: ",\n"))
  }

  func testPreviewPanel() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["HUKAN_PREVIEW"] == "panel", "no preview asked for")
    let definition = try PanelDefinition(json: [
      "render": ["run": ["/bin/cat"]],
      "commands": ["probe": ["run": ["/bin/echo", "{pr}"], "args": ["pr": "\\d+"]]],
    ])
    for (name, json) in [("panel", Self.json), ("panel-list", Self.listJSON)] {
      let panel = SessionPanel(definition: definition, seal: try definition.seal())
      panel.worktreeURL = { [root] in root }
      panel.poseForSnapshot(content: try PanelContent(data: Data(fill(json).utf8)))
      for width in [560, 900] as [CGFloat] {
        let view = PanelView()
        view.show(panel, collapsed: false, waitingOnPerson: false)
        try pngOfView(view, width: width).write(
          to: URL(fileURLWithPath: "/tmp/hukan-preview-\(name)-\(Int(width)).png"))
      }
    }
  }

  private func pngOfView(_ view: NSView, width: CGFloat) -> Data {
    let appearance = NSAppearance(named: .darkAqua)!
    NSApplication.shared.appearance = appearance
    view.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 2000))
    container.wantsLayer = true
    container.appearance = appearance
    container.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      view.topAnchor.constraint(equalTo: container.topAnchor),
    ])
    let window = SnapshotSurface.window(contentRect: container.frame, appearance: appearance)
    window.contentView = container
    container.layoutSubtreeIfNeeded()
    let height = (view as? PanelView)?.fittingHeight(width: width) ?? 400
    view.heightAnchor.constraint(equalToConstant: height).isActive = true
    window.setContentSize(NSSize(width: width, height: height))
    appearance.performAsCurrentDrawingAppearance {
      container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    container.layoutSubtreeIfNeeded()
    let bounds = container.bounds
    return SnapshotSurface.png(size: bounds.size, appearance: appearance) { context in
      container.displayIgnoringOpacity(bounds, in: context)
    }
  }
}
