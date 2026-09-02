import AppKit
import XCTest

@testable import Hukan

/// Pixel snapshots of app *views* — the ones the transcript's PNG harness can't reach because
/// they are real AppKit views, not styled text. A view is captured by hosting it in an
/// offscreen window (a view never in a window gives an empty `cacheDisplay`) under the dark
/// appearance it is designed for.
///
/// Record with `TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test …`, then eyeball the PNGs before
/// committing them. References live next to this file, found via `#filePath`.
final class CardSnapshotTests: XCTestCase {
  private static let snapshotsDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Snapshots")

  /// The approval card for an ExitPlanMode with a plan long enough to scroll: the plan reads in
  /// the card's own scroll box, so the plan — not a bare tool name — is what you decide on.
  func testExitPlanApprovalCard() throws {
    let plan = """
      ## Cache rendered thumbnails

      - **Source**: render once per `(path, size)`, keyed by content hash in an LRU.
      - **Eviction**: cap at 256 entries; drop the oldest on overflow.
      - **Invalidation**: a file save clears its own entries, nothing else.
      - **Warmup**: prefill from the visible rows on scroll, never the whole tree.
      - **検証**: scroll a 1,000-file tree twice and compare the timings.

      | Item | Value |
      |---|---|
      | Store | new `ThumbnailCache.swift` |
      | Cap | 256 entries |

      The cap is a guess, tuned against the profiler once wired up.
      """
    let approval = PendingApproval(
      requestID: "r1", toolName: "ExitPlanMode",
      title: "Would you like to proceed?",
      detail: "Cache rendered thumbnails",
      input: ["plan": plan])
    let card = ApprovalCard(approval: approval, onDecision: { _ in })

    try compare(pngOfView(card, width: 380), named: "exit-plan-card")
  }

  /// The task card, opened: the count and what is in flight on the folded row, and under it
  /// what is left of the list — a glyph a state, the subjects aligned under each other however
  /// wide that glyph is, and the one waiting on unfinished work drawn as held up rather than
  /// stalled. Drawn at the pane's narrow end, where a long subject has to truncate.
  func testTaskCard() throws {
    let tasks = [
      AgentTask(
        id: "1", subject: "Inspect the existing module conventions",
        activeForm: "Inspecting the existing module conventions", status: .completed,
        blockedBy: []),
      AgentTask(
        id: "2", subject: "Create modules/security/github_oidc_provider",
        activeForm: "Creating the OIDC provider module", status: .completed, blockedBy: []),
      AgentTask(
        id: "3",
        subject: "Create modules/security/github_actions_batch_role and wire its trust policy",
        activeForm: "Creating the batch role module", status: .inProgress, blockedBy: []),
      AgentTask(
        id: "4", subject: "Point the batch job at the new role", activeForm: "", status: .pending,
        blockedBy: ["3"]),
      AgentTask(
        id: "5", subject: "検証: plan against staging", activeForm: "", status: .pending,
        blockedBy: []),
    ]
    let card = TaskCard(tasks: tasks, expanded: true, onToggle: {})

    try compare(pngOfView(card, width: 320), named: "task-card")
  }

  /// The question card at its fullest: a multi-select question, two options ticked, and two
  /// previews open — each sketch in its own monospaced box, unwrapped. The Other line under the
  /// options is the third answer, which has no control because the composer below the card is it.
  ///
  /// The second sketch is composed to a whole number of terminal cells and still does not close,
  /// because its Japanese falls back to a face 1.49 cells wide. That is the recorded behaviour,
  /// not a defect waiting on a fix: see `QuestionCard.previewBox` for why gridding it back was
  /// built and removed.
  func testQuestionCard() throws {
    let question = PendingQuestion(
      requestID: "r1",
      questions: [
        AgentQuestion(
          header: "Layout",
          question: "ターミナルをウィンドウのどこに置く？",
          options: [
            QuestionOption(
              label: "中央カラムのタブ",
              description: "agent と terminal をタブで排他切替。実装最小。",
              preview: """
                ┌──────┬──────────────┬──────────┐
                │ Rail │[agent][zsh]  │ Files    │
                │      │              │          │
                └──────┴──────────────┴──────────┘
                """),
            QuestionOption(
              label: "デスクの下半分に固定",
              description: "常に見えるが、ソースの高さを恒久的に削る。",
              preview: """
                ┌──────┬────────────┐
                │ Rail │ ソース     │
                │      ├────────────┤
                │      │ zsh        │
                └──────┴────────────┘
                ↑ 全角を二セルに数えて組んだ図
                """),
            QuestionOption(
              label: "別ウィンドウ",
              description: "Terminal.app に戻るのと変わらない。",
              preview: ""),
          ],
          multiSelect: true)
      ],
      answers: [], index: 0, ticked: [0, 2], previewsOpen: [0, 1])
    let card = QuestionCard(
      question: question, onAnswer: { _ in }, onToggleOption: { _ in }, onTogglePreview: { _ in })

    try compare(pngOfView(card, width: 380), named: "question-card")
  }

  // MARK: harness

  /// Host `view` in an offscreen window at `width`, on the app's own dark backdrop with `padding`
  /// around it (the card is a translucent orange over that background, so it washes out captured
  /// against nothing), laid out under the dark appearance, and capture it at its fitted height.
  private func pngOfView(_ view: NSView, width: CGFloat, padding: CGFloat = 16) -> Data {
    let appearance = NSAppearance(named: .darkAqua)!
    NSApplication.shared.appearance = appearance

    view.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width + padding * 2, height: 2000))
    container.wantsLayer = true
    container.appearance = appearance
    container.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
      view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
      view.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
    ])
    let window = SnapshotSurface.window(contentRect: container.frame, appearance: appearance)
    window.contentView = container
    // A ScrollBox sizes itself in layout(), so settle the width, then read the card's height.
    container.layoutSubtreeIfNeeded()
    container.layoutSubtreeIfNeeded()
    window.setContentSize(
      NSSize(width: width + padding * 2, height: view.frame.height + padding * 2))
    appearance.performAsCurrentDrawingAppearance {
      container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    container.layoutSubtreeIfNeeded()

    let bounds = container.bounds
    return SnapshotSurface.png(size: bounds.size, appearance: appearance) { context in
      container.displayIgnoringOpacity(bounds, in: context)
    }
  }

  private func compare(_ actual: Data, named name: String) throws {
    let reference = Self.snapshotsDir.appendingPathComponent("\(name).png")
    if ProcessInfo.processInfo.environment["HUKAN_RECORD"] == "1" {
      try FileManager.default.createDirectory(
        at: Self.snapshotsDir, withIntermediateDirectories: true)
      try actual.write(to: reference)
      XCTFail("recorded \(name) — run again without HUKAN_RECORD to verify")
      return
    }
    guard let expected = try? Data(contentsOf: reference) else {
      XCTFail("\(name): no reference — record with TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test")
      return
    }
    if pixels(expected) != pixels(actual) {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hukan-snapshots")
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let failed = dir.appendingPathComponent("\(name)-actual.png")
      try? actual.write(to: failed)
      XCTFail("\(name): differs from the reference (actual at \(failed.path))")
    }
  }

  private func pixels(_ png: Data) -> [Data] {
    guard let rep = NSBitmapImageRep(data: png), let data = rep.tiffRepresentation else {
      return [png]
    }
    return [Data("\(rep.pixelsWide)x\(rep.pixelsHigh)".utf8), data]
  }
}
