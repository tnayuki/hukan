import XCTest

@testable import Hukan

/// Following a conversation another process is writing. The whole file is walked once, when the
/// session is opened; from then on only what has been appended is read, which is the difference
/// between keeping up with an agent and re-parsing tens of megabytes every few seconds.
final class TranscriptTailTests: XCTestCase {
  private var worktree: URL!

  override func setUpWithError() throws {
    worktree = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-tail-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: ClaudeSessionStore.directory(for: worktree), withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: ClaudeSessionStore.directory(for: worktree))
    try? FileManager.default.removeItem(at: worktree)
  }

  // MARK: fixtures

  private func line(_ uuid: String, parent: String?, role: String, text: String) -> String {
    var record: [String: Any] = [
      "uuid": uuid, "type": role, "timestamp": "2026-09-01T00:00:00.000Z",
      "message": [
        "role": role,
        "content": role == "user" ? text : [["type": "text", "text": text]],
      ] as [String: Any],
    ]
    if let parent { record["parentUuid"] = parent }
    let data = try! JSONSerialization.data(withJSONObject: record)
    return String(data: data, encoding: .utf8)! + "\n"
  }

  private func write(_ text: String, id: UUID, appending: Bool = false) throws {
    let url = ClaudeSessionStore.transcriptURL(id: id, worktree: worktree)
    if appending, let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(text.utf8))
    } else {
      try Data(text.utf8).write(to: url)
    }
  }

  private func texts(of records: [HistoryRecord]) -> [String] {
    records.compactMap {
      switch $0.kind {
      case .userText(let text): return text
      case .assistantText(let text): return text
      case .toolUse(let name, _): return name
      }
    }
  }

  // MARK: reading on from where the file was left

  func testOnlyWhatWasAppendedIsRead() throws {
    let id = UUID()
    try write(line("a", parent: nil, role: "user", text: "one"), id: id)
    let history = try XCTUnwrap(ClaudeSessionStore.history(id: id, worktree: worktree))
    XCTAssertEqual(texts(of: history.records), ["one"])

    try write(
      line("b", parent: "a", role: "assistant", text: "two")
        + line("c", parent: "b", role: "user", text: "three"), id: id, appending: true)

    guard
      case .appended(let records, let cursor, _) = ClaudeSessionStore.historyTail(
        id: id, worktree: worktree, since: history.cursor)
    else { return XCTFail("the file grew, so there is a tail to read") }
    XCTAssertEqual(texts(of: records), ["two", "three"], "and only the tail — not the first line")

    guard
      case .unchanged = ClaudeSessionStore.historyTail(id: id, worktree: worktree, since: cursor)
    else { return XCTFail("nothing has been written since") }
  }

  /// The engine may be midway through a line when the read lands. Stopping at the last newline is
  /// what keeps the rest of that line from being skipped when it arrives.
  func testAHalfWrittenLineWaitsForTheRestOfItself() throws {
    let id = UUID()
    try write(line("a", parent: nil, role: "user", text: "one"), id: id)
    let history = try XCTUnwrap(ClaudeSessionStore.history(id: id, worktree: worktree))

    let whole = line("b", parent: "a", role: "assistant", text: "two")
    let cut = whole.index(whole.startIndex, offsetBy: whole.count / 2)
    try write(String(whole[..<cut]), id: id, appending: true)

    guard
      case .unchanged = ClaudeSessionStore.historyTail(
        id: id, worktree: worktree, since: history.cursor)
    else { return XCTFail("half a line is not a record yet") }

    try write(String(whole[cut...]), id: id, appending: true)
    guard
      case .appended(let records, _, _) = ClaudeSessionStore.historyTail(
        id: id, worktree: worktree, since: history.cursor)
    else { return XCTFail("the line is whole now") }
    XCTAssertEqual(texts(of: records), ["two"], "and it is read exactly once, in full")
  }

  /// A rollback re-parents the next message onto an earlier record rather than appending to the
  /// tail, so what is in the file is a different branch — not more of this one. Reading it as an
  /// append would show a conversation the agent has forgotten, so the tail refuses and the caller
  /// walks the file again.
  func testARollbackIsRefusedRatherThanAppended() throws {
    let id = UUID()
    try write(
      line("a", parent: nil, role: "user", text: "one")
        + line("b", parent: "a", role: "assistant", text: "two"), id: id)
    let history = try XCTUnwrap(ClaudeSessionStore.history(id: id, worktree: worktree))
    XCTAssertEqual(texts(of: history.records), ["one", "two"])

    // Sent again from before "two": the new record hangs off "a", not off the tip.
    try write(line("c", parent: "a", role: "user", text: "instead"), id: id, appending: true)
    guard
      case .rewritten = ClaudeSessionStore.historyTail(
        id: id, worktree: worktree, since: history.cursor)
    else { return XCTFail("the branch moved; this is not an append") }

    // And the whole-file read is the honest answer: the abandoned reply is gone from it.
    let again = try XCTUnwrap(ClaudeSessionStore.history(id: id, worktree: worktree))
    XCTAssertEqual(texts(of: again.records), ["one", "instead"])
  }

  /// A subagent's lines sit in the same file with their own parents. The whole-file walk passes
  /// over them, and so must the tail — otherwise the first one taken would read as a broken chain
  /// and throw away the follow.
  func testASubagentsLinesDoNotBreakTheChain() throws {
    let id = UUID()
    try write(line("a", parent: nil, role: "user", text: "one"), id: id)
    let history = try XCTUnwrap(ClaudeSessionStore.history(id: id, worktree: worktree))

    var sidechain = line("s", parent: "somewhere-else", role: "assistant", text: "subagent")
    sidechain = sidechain.replacingOccurrences(
      of: "{", with: "{\"isSidechain\":true,", options: [], range: sidechain.range(of: "{"))
    try write(
      sidechain + line("b", parent: "a", role: "assistant", text: "two"), id: id, appending: true)

    guard
      case .appended(let records, _, _) = ClaudeSessionStore.historyTail(
        id: id, worktree: worktree, since: history.cursor)
    else { return XCTFail("the conversation did carry on") }
    XCTAssertEqual(texts(of: records), ["two"], "the subagent's line is passed over, not counted")
  }

  /// The name Claude Code gives a session is written into the same file, so a conversation being
  /// followed is renamed by the same read that carries its new records — which matters because the
  /// rows that are followed are exactly the ones that went up without a name.
  func testTheNameComesOffTheSameRead() throws {
    let id = UUID()
    try write(line("a", parent: nil, role: "user", text: "one"), id: id)
    let history = try XCTUnwrap(ClaudeSessionStore.history(id: id, worktree: worktree))
    XCTAssertNil(history.title)

    let named = try JSONSerialization.data(withJSONObject: [
      "type": "ai-title", "aiTitle": "端末で走っている作業",
    ])
    try write(
      String(data: named, encoding: .utf8)! + "\n"
        + line("b", parent: "a", role: "assistant", text: "two"), id: id, appending: true)

    guard
      case .appended(_, _, let title) = ClaudeSessionStore.historyTail(
        id: id, worktree: worktree, since: history.cursor)
    else { return XCTFail("there is a tail") }
    XCTAssertEqual(title, "端末で走っている作業")
  }
}
