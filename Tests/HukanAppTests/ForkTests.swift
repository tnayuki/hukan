import XCTest

@testable import Hukan

/// Branching a conversation, which is three separable facts: the flags that ask the engine for a
/// branch, the anchor the parse hands the transcript, and the mark the transcript carries so a
/// right-click can find it again.
final class ForkTests: XCTestCase {
  // MARK: launch shape

  func testForkLaunchesWithTheBlessedFlagCombination() {
    let branch = UUID()
    let source = UUID()
    let arguments = ClaudeSession.conversationArguments(
      id: branch, resume: false,
      fork: ClaudeSession.ForkPoint(source: source, anchor: "anchor-uuid"))
    XCTAssertEqual(
      arguments,
      [
        "--resume", ClaudeSessionStore.name(source),
        "--resume-session-at", "anchor-uuid",
        "--fork-session",
        "--session-id", ClaudeSessionStore.name(branch),
      ],
      "the CLI refuses --session-id alongside --resume unless --fork-session is there too")
  }

  func testWithoutAForkTheShapeIsUnchanged() {
    let id = UUID()
    XCTAssertEqual(
      ClaudeSession.conversationArguments(id: id, resume: false, fork: nil),
      ["--session-id", ClaudeSessionStore.name(id)])
    XCTAssertEqual(
      ClaudeSession.conversationArguments(id: id, resume: true, fork: nil),
      ["--resume", ClaudeSessionStore.name(id)])
  }

  func testRollbackResumesOurOwnConversationTruncated() {
    let id = UUID()
    XCTAssertEqual(
      ClaudeSession.conversationArguments(id: id, resume: true, fork: nil, rollbackTo: "a1"),
      ["--resume", ClaudeSessionStore.name(id), "--resume-session-at", "a1"],
      "no --session-id and no --fork-session: the cut lands in this session's own transcript")
  }

  /// There is nothing to cut back on a session that has never run, and `--session-id` alongside
  /// `--resume-session-at` is exactly the combination the CLI refuses outside a fork.
  func testRollbackIsIgnoredWithoutAResume() {
    let id = UUID()
    XCTAssertEqual(
      ClaudeSession.conversationArguments(id: id, resume: false, fork: nil, rollbackTo: "a1"),
      ["--session-id", ClaudeSessionStore.name(id)])
  }

  /// A fork wins over resume rather than combining with it: the branch has no transcript of its
  /// own to resume, and `--resume` already names the source.
  func testForkBeatsResume() {
    let branch = UUID()
    let source = UUID()
    let arguments = ClaudeSession.conversationArguments(
      id: branch, resume: true, fork: ClaudeSession.ForkPoint(source: source, anchor: "a"))
    XCTAssertEqual(arguments.filter { $0 == "--resume" }.count, 1)
    XCTAssertTrue(arguments.contains("--fork-session"))
  }

  // MARK: anchors out of a transcript

  func testAnchorIsTheRecordBeforeTheMessage() throws {
    let history = try parse(
      """
      {"type":"user","uuid":"u1","message":{"role":"user","content":"first"}}
      {"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"one"}]}}
      {"type":"user","uuid":"u2","parentUuid":"a1","message":{"role":"user","content":"second"}}
      {"type":"assistant","uuid":"a2","parentUuid":"u2","message":{"role":"assistant","content":[{"type":"text","text":"two"}]}}
      """)
    let asked = history.records.filter {
      if case .userText = $0.kind { return true } else { return false }
    }
    XCTAssertEqual(asked.count, 2)
    XCTAssertNil(
      asked[0].forkAnchor, "the first message has nothing above it, so there is nothing to branch")
    XCTAssertEqual(
      asked[1].forkAnchor, "a1", "rewinding past the second message keeps the first answer")
  }

  /// A rollback names the message, where a fork names the record before it — so the same record
  /// has to yield both, or a restored conversation could be forked but not rewound.
  func testRecordsCarryTheirOwnUUIDForARewind() throws {
    let history = try parse(
      """
      {"type":"user","uuid":"u1","message":{"role":"user","content":"first"}}
      {"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"one"}]}}
      {"type":"user","uuid":"u2","parentUuid":"a1","message":{"role":"user","content":"second"}}
      """)
    let asked = history.records.filter {
      if case .userText = $0.kind { return true } else { return false }
    }
    XCTAssertEqual(asked.map(\.messageUUID), ["u1", "u2"])
    XCTAssertEqual(
      asked[1].forkAnchor, "a1",
      "the two identifiers are different records: the anchor is what a fork keeps")
    XCTAssertNil(
      history.records.first(where: {
        if case .assistantText = $0.kind { return true } else { return false }
      })?.messageUUID, "only a message someone sent can be rewound to")
  }

  /// hukan leaves thinking and tool results out of the transcript, but they are still records the
  /// finished turn is made of — anchoring past them would drop them from the branch.
  func testAnchorCountsRecordsTheTranscriptDoesNotShow() throws {
    let history = try parse(
      """
      {"type":"user","uuid":"u1","message":{"role":"user","content":"first"}}
      {"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"one"}]}}
      {"type":"user","uuid":"r1","parentUuid":"a1","isMeta":true,"message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}
      {"type":"attachment","uuid":"t1","parentUuid":"r1"}
      {"type":"user","uuid":"u2","parentUuid":"t1","message":{"role":"user","content":"second"}}
      """)
    let asked = history.records.filter {
      if case .userText = $0.kind { return true } else { return false }
    }
    XCTAssertEqual(asked.count, 2)
    XCTAssertEqual(
      asked[1].forkAnchor, "t1",
      "the anchor is the last record on disk before the message, shown or not")
  }

  /// A subagent's chatter is not part of this conversation, so it must not become a branch point.
  func testSidechainRecordsAreNotAnchors() throws {
    let history = try parse(
      """
      {"type":"user","uuid":"u1","message":{"role":"user","content":"first"}}
      {"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"one"}]}}
      {"type":"assistant","uuid":"s1","parentUuid":"a1","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"sub"}]}}
      {"type":"user","uuid":"u2","parentUuid":"a1","message":{"role":"user","content":"second"}}
      """)
    let asked = history.records.filter {
      if case .userText = $0.kind { return true } else { return false }
    }
    XCTAssertEqual(asked[1].forkAnchor, "a1")
  }

  // MARK: the live branch

  /// Rolling back re-parents the next message onto an earlier one and leaves what was abandoned
  /// in the file. Reading the jsonl line by line would show messages the agent has forgotten.
  func testAbandonedBranchesAreNotPartOfTheConversation() throws {
    let history = try parse(
      """
      {"type":"user","uuid":"u1","message":{"role":"user","content":"first"}}
      {"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"one"}]}}
      {"type":"user","uuid":"u2","parentUuid":"a1","message":{"role":"user","content":"abandoned"}}
      {"type":"assistant","uuid":"a2","parentUuid":"u2","message":{"role":"assistant","content":[{"type":"text","text":"forgotten"}]}}
      {"type":"user","uuid":"u3","parentUuid":"a1","message":{"role":"user","content":"kept"}}
      {"type":"assistant","uuid":"a3","parentUuid":"u3","message":{"role":"assistant","content":[{"type":"text","text":"remembered"}]}}
      """)
    let said = history.records.compactMap { record -> String? in
      switch record.kind {
      case .userText(let text): return text
      case .assistantText(let text): return text
      case .toolUse: return nil
      }
    }
    XCTAssertEqual(said, ["first", "one", "kept", "remembered"])
  }

  /// A transcript carries records that hang off nothing and can be written last — a content
  /// replacement, for one. Mistaking one of those for the conversation's tip would empty the pane.
  func testRecordsOutsideTheConversationAreNotItsTip() throws {
    let history = try parse(
      """
      {"type":"user","uuid":"u1","message":{"role":"user","content":"first"}}
      {"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"one"}]}}
      {"type":"content-replacement","uuid":"c1","replacements":[]}
      {"type":"last-prompt"}
      """)
    XCTAssertEqual(history.records.count, 2)
  }

  // MARK: the mark the transcript carries

  func testRenderedUserMessagesCarryTheirAnchor() {
    let rendered = Transcript.render([
      HistoryRecord(kind: .userText("first"), stamp: nil),
      HistoryRecord(kind: .assistantText("one"), stamp: nil),
      HistoryRecord(kind: .userText("second"), stamp: nil, forkAnchor: "a1"),
    ])
    let points = Transcript.forkPoints(in: rendered)
    XCTAssertEqual(points.count, 1, "only the message with something above it is a fork point")
    XCTAssertEqual(points[0].anchor, "a1")
    XCTAssertEqual(
      Transcript.forkAnchor(in: rendered, at: points[0].range.location)?.anchor, "a1")
    XCTAssertNil(
      Transcript.forkAnchor(in: rendered, at: 0),
      "the first message is not a fork point, so a right-click on it offers nothing")
  }

  /// The prefix a branch inherits is everything before the message it rewinds past — so the
  /// message itself, and its answer, must not be in it.
  func testTheInheritedPrefixStopsAtTheForkPoint() {
    let rendered = Transcript.render([
      HistoryRecord(kind: .userText("keep me"), stamp: nil),
      HistoryRecord(kind: .assistantText("kept"), stamp: nil),
      HistoryRecord(kind: .userText("drop me"), stamp: nil, forkAnchor: "a1"),
      HistoryRecord(kind: .assistantText("dropped"), stamp: nil),
    ])
    let point = try? XCTUnwrap(Transcript.forkPoints(in: rendered).first)
    let prefix = rendered.attributedSubstring(
      from: NSRange(location: 0, length: point?.range.location ?? 0)
    ).string
    XCTAssertTrue(prefix.contains("keep me"))
    XCTAssertTrue(prefix.contains("kept"))
    XCTAssertFalse(prefix.contains("drop me"))
    XCTAssertFalse(prefix.contains("dropped"))
  }

  // MARK: the mark on screen

  /// The mark is drawn, not typed, so nothing in the storage says where it is — the click has to
  /// land in the same rectangle the drawing used. Lay a marked message out offscreen and ask the
  /// view what is under the block's trailing centre, and under everywhere else.
  func testTheMarkIsHitWhereItIsDrawn() throws {
    _ = NSApplication.shared
    let (scrollView, textView) = makeTranscriptTextView()
    scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    let rendered = Transcript.render([
      HistoryRecord(kind: .userText("first"), stamp: nil),
      HistoryRecord(kind: .assistantText("one"), stamp: nil),
      HistoryRecord(
        kind: .userText("second\nthird line\nfourth line"), stamp: nil, forkAnchor: "a1"),
    ])
    textView.textStorage!.setAttributedString(rendered)
    let view = try XCTUnwrap(textView as? TranscriptTextView)
    let layout = try XCTUnwrap(view.textLayoutManager)
    layout.ensureLayout(for: layout.documentRange)

    // The marked block's extent: from where its attribute starts to where it ends.
    let point = try XCTUnwrap(Transcript.forkPoints(in: rendered).first)
    let content = try XCTUnwrap(layout.textContentManager)
    let top = try XCTUnwrap(
      content.location(content.documentRange.location, offsetBy: point.range.location + 1))
    let bottom = try XCTUnwrap(
      content.location(content.documentRange.location, offsetBy: NSMaxRange(point.range) - 2))
    let topFrame = try XCTUnwrap(layout.textLayoutFragment(for: top)).layoutFragmentFrame
    let bottomFrame = try XCTUnwrap(layout.textLayoutFragment(for: bottom)).layoutFragmentFrame
    let middle = (topFrame.minY + bottomFrame.maxY) / 2 + view.textContainerOrigin.y
    let right = view.bounds.width - view.textContainerInset.width

    XCTAssertEqual(
      view.messageMark(at: NSPoint(x: right - 20, y: middle))?.anchor, "a1",
      "the block's trailing centre is the mark")
    XCTAssertNil(
      view.messageMark(at: NSPoint(x: 30, y: middle)),
      "the message's own text is not")
    XCTAssertNil(
      view.messageMark(at: NSPoint(x: right - 20, y: topFrame.minY + 2)),
      "nor is the block's trailing edge away from its centre")
    XCTAssertNil(
      view.messageMark(at: NSPoint(x: right - 20, y: 12)),
      "and the first message, with nothing above it, has no mark anywhere")
  }

  // MARK: what a held session allows

  /// A rollback is only real once an engine reloads from the anchor, and hukan will not start one
  /// against a session another process owns — so offering it would leave the pane cut and the
  /// conversation not.
  func testHeldSessionRefusesRollback() {
    let session = AgentSession(worktreeID: UUID())
    XCTAssertTrue(session.canRollBack)
    session.markHeldElsewhere(by: getpid())
    XCTAssertFalse(session.canRollBack)
    session.transcript.append(NSAttributedString(string: "kept and dropped"))
    session.rollBack(to: "a1", keeping: 4)
    XCTAssertEqual(
      session.transcript.string, "kept and dropped", "a refused rollback cuts nothing")
    XCTAssertNil(session.rollbackAnchor, "and leaves nothing to apply the moment it comes back")
  }

  // MARK: helper

  /// Write a transcript and read it back through the real parse, so these assert what the store
  /// actually does with a jsonl rather than a stand-in for it.
  private func parse(_ jsonl: String) throws -> ClaudeSessionStore.History {
    let id = UUID()
    let worktree = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-fork-\(id.uuidString)")
    let directory = ClaudeSessionStore.directory(for: worktree)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = ClaudeSessionStore.transcriptURL(id: id, worktree: worktree)
    try jsonl.write(to: url, atomically: true, encoding: .utf8)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return try XCTUnwrap(ClaudeSessionStore.history(id: id, worktree: worktree))
  }
}
