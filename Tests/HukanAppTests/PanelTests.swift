import AppKit
import XCTest

@testable import Hukan

/// A session's panel (`panel_install`): the definition is the whole of what it may run, pinned by
/// hash to the files it names; the render's output is data in a closed set of parts; and what the
/// render does not deliver leaves the last drawing standing.
final class PanelTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-panel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func script(_ name: String, _ body: String) throws -> String {
    let url = root.appendingPathComponent(name)
    try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
  }

  // MARK: Definition

  func testADefinitionTypesEveryHoleInItsCommands() throws {
    let definition = try PanelDefinition(json: [
      "render": ["run": ["/bin/cat"], "watch": ["approach.md", ".loop/*.json"]],
      "commands": [
        "prReady": [
          "run": ["gh", "pr", "ready", "{pr}"], "args": ["pr": "^\\d+$"], "outward": true,
        ]
      ],
    ])
    XCTAssertEqual(definition.commands["prReady"]?.outward, true)
    XCTAssertEqual(
      try definition.argv(for: "prReady", arguments: ["pr": "42"]), ["gh", "pr", "ready", "42"])
    XCTAssertEqual(
      try definition.argv(for: "prReady", arguments: ["pr": 42]), ["gh", "pr", "ready", "42"])
    // The pattern is matched against the whole value, whatever its own anchors say.
    XCTAssertThrowsError(try definition.argv(for: "prReady", arguments: ["pr": "42 --admin"]))
    XCTAssertThrowsError(try definition.argv(for: "prReady", arguments: [:]))
    XCTAssertThrowsError(try definition.argv(for: "prReady", arguments: ["pr": "1", "x": "2"]))
    XCTAssertThrowsError(try definition.argv(for: "merge", arguments: [:]))
  }

  func testADefinitionIsRefusedForWhatItCannotDoYet() {
    let render: [String: Any] = ["run": ["/bin/cat"]]
    for (key, value) in [("schedules", [Any]()), ("mcp", [String: Any]())] as [(String, Any)] {
      XCTAssertThrowsError(try PanelDefinition(json: ["render": render, key: value])) {
        XCTAssertTrue("\($0)".contains("not supported yet"), "\($0)")
      }
    }
    XCTAssertThrowsError(try PanelDefinition(json: ["render": render, "extra": 1]))
    XCTAssertThrowsError(try PanelDefinition(json: ["commands": [:]]))
  }

  func testADefinitionIsRefusedWhenItsArgumentsDoNotLineUp() {
    let render: [String: Any] = ["run": ["/bin/cat"]]
    XCTAssertThrowsError(
      try PanelDefinition(json: ["render": render, "commands": ["a": ["run": ["echo", "{x}"]]]]))
    XCTAssertThrowsError(
      try PanelDefinition(json: [
        "render": render, "commands": ["a": ["run": ["echo"], "args": ["x": ".*"]]],
      ]))
    XCTAssertThrowsError(
      try PanelDefinition(json: [
        "render": render, "commands": ["a": ["run": ["echo", "{x}"], "args": ["x": "("]]],
      ]))
    XCTAssertThrowsError(try PanelDefinition(json: ["render": ["run": ["/bin/cat", "{x}"]]]))
    XCTAssertThrowsError(try PanelDefinition(json: ["render": render, "files": ["rel.py"]]))
    XCTAssertThrowsError(
      try PanelDefinition(json: ["render": ["run": ["/bin/cat"], "watch": ["../up"]]]))
  }

  /// The seal covers the definition and every file named by absolute path, in argv or `files`;
  /// a rewrite of one breaks it.
  func testTheSealBreaksWhenANamedFileChanges() throws {
    let render = try script("render.sh", "echo '{}'\n")
    let module = root.appendingPathComponent("lib.sh")
    try "x=1\n".write(to: module, atomically: true, encoding: .utf8)
    let definition = try PanelDefinition(json: [
      "render": ["run": ["/bin/sh", render]], "files": [module.path],
    ])
    XCTAssertEqual(Set(definition.namedFiles), [render, module.path, "/bin/sh"])
    let seal = try definition.seal()
    XCTAssertNil(seal.firstBroken())
    try "x=2\n".write(to: module, atomically: true, encoding: .utf8)
    XCTAssertEqual(seal.firstBroken(), module.path)
    try FileManager.default.removeItem(at: module)
    XCTAssertThrowsError(try definition.seal())
  }

  func testADefinitionReadsBackFromWhatWasKept() throws {
    let definition = try PanelDefinition(json: [
      "render": ["run": ["/bin/cat"], "watch": ["a.md"]],
      "commands": ["probe": ["run": ["echo", "{n}"], "args": ["n": "\\d+"]]],
    ])
    XCTAssertEqual(try PanelDefinition(source: definition.source), definition)
  }

  // MARK: Output

  func testTheOutputIsAClosedSetOfParts() throws {
    let json = """
      {"title": "Loop", "items": [
        {"type": "badge", "text": "running", "tone": "info"},
        {"type": "fields", "items": [{"label": "PR", "value": "#42"}]},
        {"type": "list", "groups": [{"title": "Open", "rows": [
          {"title": "Fix it", "status": {"text": "red", "tone": "danger"},
           "url": "https://example.com/1",
           "buttons": [{"label": "Ready", "command": "prReady", "args": {"pr": 42}}]}]}],
         "limit": 10, "empty": "None"},
        {"type": "approval", "document": "approach.md"},
        {"type": "button", "label": "Go", "send": "go on"},
        {"type": "divider"}
      ]}
      """
    let content = try PanelContent(data: Data(json.utf8))
    XCTAssertEqual(content.title, "Loop")
    XCTAssertEqual(content.parts.count, 6)
    guard case .list(let groups, let limit, let empty) = content.parts[2] else {
      return XCTFail("not a list")
    }
    XCTAssertEqual(limit, 10)
    XCTAssertEqual(empty, "None")
    XCTAssertEqual(groups.first?.rows.first?.target, .url(URL(string: "https://example.com/1")!))
    XCTAssertEqual(
      groups.first?.rows.first?.buttons.first?.action,
      .command(name: "prReady", args: ["pr": "42"]))
    XCTAssertEqual(content.parts[4], .button(.init(label: "Go", action: .send("go on"))))
  }

  func testTheOutputRefusesWhatItCannotDraw() {
    for json in [
      "not json",
      "[]",
      #"{"items": [{"type": "html", "html": "<b>"}]}"#,
      #"{"items": [{"type": "list", "rows": [{"title": "x", "url": "file:///etc/passwd"}]}]}"#,
      #"{"items": [{"type": "approval", "document": "../outside.md"}]}"#,
      #"{"items": [{"type": "button", "label": "x"}]}"#,
      #"{"items": [{"type": "badge", "text": "x", "tone": "pink"}]}"#,
    ] {
      XCTAssertThrowsError(try PanelContent(data: Data(json.utf8)), json)
    }
  }

  // MARK: Running

  func testARunReadsStdinAndIsStoppedAtItsTimeout() throws {
    let echo = expectation(description: "echo")
    PanelRunner.run(["/bin/cat"], in: root, input: Data("hello".utf8), timeout: 5) { outcome in
      XCTAssertEqual(try? outcome.get().stdout, Data("hello".utf8))
      echo.fulfill()
    }
    let slow = expectation(description: "slow")
    PanelRunner.run(["/bin/sleep", "10"], in: root, timeout: 0.5) { outcome in
      XCTAssertEqual(try? outcome.get().timedOut, true)
      slow.fulfill()
    }
    let missing = expectation(description: "missing")
    PanelRunner.run(["no-such-command-hukan"], in: root, timeout: 5) { outcome in
      if case .success = outcome { XCTFail("a missing command ran") }
      missing.fulfill()
    }
    wait(for: [echo, slow, missing], timeout: 20)
  }

  /// A render is handed the session's facts and the approvals; a failed render keeps the last
  /// drawing and says why.
  func testAFailedRenderKeepsTheLastDrawing() throws {
    let render = try script(
      "render.sh",
      """
      input=$(cat)
      if [ -f fail ]; then echo boom >&2; exit 3; fi
      case "$input" in *'"state":"working"'*) state=working;; *) state=other;; esac
      printf '{"title":"T","items":[{"type":"text","text":"%s"}]}' "$state"

      """)
    let definition = try PanelDefinition(json: ["render": ["run": [render]]])
    let panel = SessionPanel(definition: definition, seal: try definition.seal())
    panel.worktreeURL = { [root] in root }
    panel.sessionFacts = { ["state": "working", "tags": [String]()] }
    var drawn = expectation(description: "drawn")
    panel.onChange = { drawn.fulfill() }
    panel.setNeedsRender()
    wait(for: [drawn], timeout: 10)
    XCTAssertEqual(panel.content?.parts, [.text("working")])
    XCTAssertNil(panel.notice)

    FileManager.default.createFile(atPath: root.appendingPathComponent("fail").path, contents: nil)
    drawn = expectation(description: "failed")
    panel.setNeedsRender()
    wait(for: [drawn], timeout: 10)
    XCTAssertEqual(panel.content?.parts, [.text("working")])
    XCTAssertEqual(panel.notice?.tone, .danger)
    XCTAssertTrue(panel.notice?.text.contains("boom") ?? false)
  }

  /// A command runs only as declared, its result going to the session; a changed script stops it.
  func testACommandRunsAsDeclaredAndStopsWhenItsScriptChanges() throws {
    let render = try script("render.sh", "echo '{\"items\":[]}'\n")
    let probe = try script("probe.sh", "echo \"probed $1\" > out.txt\necho done\n")
    let definition = try PanelDefinition(json: [
      "render": ["run": [render]],
      "commands": ["probe": ["run": [probe, "{n}"], "args": ["n": "\\d+"]]],
    ])
    let panel = SessionPanel(definition: definition, seal: try definition.seal())
    panel.worktreeURL = { [root] in root }
    var told: [String] = []
    let delivered = expectation(description: "delivered")
    panel.deliver = { text, _ in
      told.append(text)
      delivered.fulfill()
    }
    panel.press(.init(label: "Probe", action: .command(name: "probe", args: ["n": "7; rm"])))
    XCTAssertEqual(panel.notice?.tone, .danger)
    XCTAssertNil(panel.runningCommand)
    panel.press(.init(label: "Probe", action: .command(name: "probe", args: ["n": "7"])))
    wait(for: [delivered], timeout: 10)
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("out.txt"), encoding: .utf8), "probed 7\n")
    XCTAssertTrue(told.first?.contains("finished") ?? false, told.first ?? "")

    try "#!/bin/sh\necho changed\n".write(toFile: probe, atomically: true, encoding: .utf8)
    panel.press(.init(label: "Probe", action: .command(name: "probe", args: ["n": "8"])))
    XCTAssertEqual(panel.brokenFile, probe)
    XCTAssertNil(panel.runningCommand)
  }

  func testAnOutwardCommandWaitsForItsPreview() throws {
    let definition = try PanelDefinition(json: [
      "render": ["run": ["/bin/cat"]],
      "commands": ["say": ["run": ["/bin/echo", "{x}"], "args": ["x": "\\w+"], "outward": true]],
    ])
    let panel = SessionPanel(definition: definition, seal: try definition.seal())
    panel.worktreeURL = { [root] in root }
    panel.press(.init(label: "Say", action: .command(name: "say", args: ["x": "hi"])))
    XCTAssertEqual(panel.confirmation?.argv, ["/bin/echo", "hi"])
    XCTAssertNil(panel.runningCommand)
    panel.confirm(false)
    XCTAssertNil(panel.confirmation)
    XCTAssertNil(panel.runningCommand)
  }

  /// An approval is pinned to the document's hash at the press, and a send-back needs a reason.
  func testAnApprovalIsPinnedToTheDocumentAsItStood() throws {
    let definition = try PanelDefinition(json: ["render": ["run": ["/bin/cat"]]])
    let panel = SessionPanel(definition: definition, seal: try definition.seal())
    panel.worktreeURL = { [root] in root }
    var told: [String] = []
    panel.deliver = { text, _ in told.append(text) }
    let document = root.appendingPathComponent("approach.md")
    try "plan\n".write(to: document, atomically: true, encoding: .utf8)
    panel.decide(document: "approach.md", approve: false, reason: "  ")
    XCTAssertTrue(panel.approvals.isEmpty)
    panel.decide(document: "approach.md", approve: true)
    XCTAssertEqual(panel.approvals.last?.hash, PanelDefinition.digest(Data("plan\n".utf8)))
    XCTAssertEqual(panel.latestDecision(on: "approach.md")?.current, true)
    XCTAssertTrue(told.last?.contains(panel.approvals.last!.hash) ?? false)
    try "plan 2\n".write(to: document, atomically: true, encoding: .utf8)
    XCTAssertEqual(panel.latestDecision(on: "approach.md")?.current, false)
    panel.decide(document: "approach.md", approve: false, reason: "too vague")
    XCTAssertEqual(panel.approvals.last?.verdict, .rejected)
    XCTAssertEqual(panel.approvals.last?.reason, "too vague")
    panel.decide(document: "../escape.md", approve: true)
    XCTAssertEqual(panel.approvals.count, 2)
  }

  func testWatchGlobsMatchFilesNotFolders() throws {
    let definition = try PanelDefinition(json: [
      "render": ["run": ["/bin/cat"], "watch": ["approach.md", ".loop/*.json"]]
    ])
    let panel = SessionPanel(definition: definition, seal: try definition.seal())
    XCTAssertTrue(panel.watches("approach.md"))
    XCTAssertTrue(panel.watches(".loop/state.json"))
    XCTAssertFalse(panel.watches(".loop/deep/state.json"))
    XCTAssertFalse(panel.watches("other.md"))
  }

  /// The install card shows every named file in full, and the panel is kept with the window.
  func testTheReviewShowsEveryNamedFileAndThePanelIsKept() throws {
    let render = try script("render.sh", "echo secret-sauce\n")
    let definition = try PanelDefinition(json: ["render": ["run": ["/bin/sh", render]]])
    let review = WorkspaceWindowController.panelReview(definition)
    XCTAssertTrue(review.contains(definition.source))
    XCTAssertTrue(review.contains("echo secret-sauce"))
    let panel = SessionPanel(definition: definition, seal: try definition.seal())
    let data = try JSONEncoder().encode(panel.stored)
    let back = SessionPanel(stored: try JSONDecoder().decode(SessionPanel.Stored.self, from: data))
    XCTAssertEqual(back?.definition, definition)
    XCTAssertEqual(back?.seal, panel.seal)
  }

  func testPanelInstallIsOffered() {
    XCTAssertTrue(HukanMCP.toolList.contains { $0["name"] as? String == HukanMCP.panelInstallTool })
  }
}
