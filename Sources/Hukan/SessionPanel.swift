import Foundation

/// One decision the person made on a document from a panel: approved at this hash, or sent back
/// with a reason. Kept with the panel, handed to every render, and told to the session.
struct PanelApproval: Equatable, Codable {
  enum Verdict: String, Codable { case approved, rejected }
  /// The document's path, relative to the worktree.
  let document: String
  /// The SHA-256 of what was on disk when the button was pressed — what the decision is about.
  let hash: String
  let verdict: Verdict
  let reason: String?
  let at: Date
}

/// A session's panel: the installed definition, what its last good render drew, and the actions
/// its buttons take. The panel shows this session and nothing else — what it reads is what its
/// render command reads, in this session's worktree — and it acts only through the definition.
///
/// It redraws when a watched file changes, when a turn of the session ends, and when the session's
/// tags or the panel's approvals move; a burst of those is one render. A render that fails or
/// times out leaves the last drawing standing and says why in the notice band: a panel that went
/// blank on every slow run would be no use to look at.
final class SessionPanel {
  struct Stored: Codable, Equatable {
    var source: String
    var seal: PanelSeal
    var approvals: [PanelApproval]
  }

  /// What the person is asked before an outward command runs, each time.
  struct Confirmation: Equatable {
    let label: String
    let name: String
    let argv: [String]
  }

  let definition: PanelDefinition
  let seal: PanelSeal
  private(set) var approvals: [PanelApproval]
  /// The last render that succeeded.
  private(set) var content: PanelContent?
  /// What went wrong last, or what last finished — the band under the panel's title.
  private(set) var notice: (text: String, tone: PanelContent.Tone)?
  /// Set when a file the approval is pinned to changed: nothing runs until it is approved again.
  private(set) var brokenFile: String?
  private(set) var confirmation: Confirmation?
  private(set) var runningCommand: String?

  /// The session's worktree, asked at each run: an agent's `EnterWorktree` moves it.
  var worktreeURL: () -> URL? = { nil }
  /// The facts of the session a render is handed.
  var sessionFacts: () -> [String: Any] = { [:] }
  /// A message for the session (what the engine reads) and the note its transcript shows.
  var deliver: (_ text: String, _ shown: String) -> Void = { _, _ in }
  var onChange: () -> Void = {}
  /// Counts the changes, so a view redrawn for some other reason can tell it has nothing new.
  private(set) var generation = 0
  /// Whether the window has given this panel its closures yet (`WorkspaceWindow.wirePanel`).
  var isWired = false

  private func changed() {
    generation += 1
    onChange()
  }
  var onStoredChange: () -> Void = {}

  static let renderTimeout: TimeInterval = 10
  static let commandTimeout: TimeInterval = 300
  static let approvalLimit = 200

  private var watcher: DirectoryWatcher?
  private var watchedURL: URL?
  private var renderPending = false
  private var rendering = false
  private var renderScheduled = false

  init(definition: PanelDefinition, seal: PanelSeal, approvals: [PanelApproval] = []) {
    self.definition = definition
    self.seal = seal
    self.approvals = approvals
  }

  convenience init?(stored: Stored) {
    guard let definition = try? PanelDefinition(source: stored.source) else { return nil }
    self.init(definition: definition, seal: stored.seal, approvals: stored.approvals)
  }

  var stored: Stored { Stored(source: definition.source, seal: seal, approvals: approvals) }

  var title: String { content?.title ?? "Panel" }

  /// The panel as the scripting dictionary reads it (`panel`): one line a part, in the order drawn.
  var scriptingText: String {
    var lines = [title]
    if let brokenFile { lines.append("stopped: \(brokenFile) changed") }
    if let confirmation { lines.append("confirm: \(confirmation.argv.joined(separator: " "))") }
    if let notice { lines.append("notice (\(notice.tone.rawValue)): \(notice.text)") }
    func button(_ button: PanelContent.Button) -> String { "[\(button.label)]" }
    for part in content?.parts ?? [] {
      switch part {
      case .badge(let text, let tone): lines.append("badge (\(tone.rawValue)): \(text)")
      case .text(let text): lines.append("text: \(text.plain)")
      case .fields(let fields):
        lines += fields.map { "field: \($0.label) = \($0.value.plain)" }
      case .list(let groups, _, let empty):
        if groups.allSatisfy({ $0.rows.isEmpty }) { lines.append("list: \(empty ?? "empty")") }
        for group in groups {
          if let title = group.title { lines.append("group: \(title)") }
          for row in group.rows {
            let status = row.status.map { "(\($0.text)) " } ?? ""
            let buttons = row.buttons.map(button).joined(separator: " ")
            lines.append(
              "row: \(status)\(row.title.plain)" + (buttons.isEmpty ? "" : " \(buttons)"))
          }
        }
      case .button(let value): lines.append("button: \(button(value))")
      case .approval(let document, _):
        let state = latestDecision(on: document).map {
          $0.approval.verdict == .approved ? ($0.current ? "approved" : "changed") : "sent back"
        }
        lines.append("approval: \(document)" + (state.map { " (\($0))" } ?? ""))
      case .notice(let text, let tone): lines.append("notice (\(tone.rawValue)): \(text)")
      case .divider: lines.append("---")
      }
    }
    return lines.joined(separator: "\n")
  }

  /// Set what a render would have, for a snapshot to draw without running one.
  func poseForSnapshot(content: PanelContent, notice: (String, PanelContent.Tone)? = nil) {
    self.content = content
    self.notice = notice
  }

  // MARK: Rendering

  /// Ask for a redraw. Requests landing within a moment of each other are one render, and one
  /// arriving while a render runs is answered by a second after it rather than lost.
  func setNeedsRender() {
    guard !renderScheduled else { return }
    renderScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self else { return }
      self.renderScheduled = false
      self.renderNow()
    }
  }

  private func renderNow() {
    if rendering {
      renderPending = true
      return
    }
    guard let directory = worktreeURL() else { return }
    rewatch(directory)
    guard checkSeal() else { return }
    rendering = true
    let input = renderInput(directory: directory)
    PanelRunner.run(
      definition.render.run, in: directory, input: input, timeout: Self.renderTimeout,
      environment: ["HUKAN_PANEL": "1"]
    ) { [weak self] outcome in
      guard let self else { return }
      self.rendering = false
      self.rendered(outcome)
      if self.renderPending {
        self.renderPending = false
        self.setNeedsRender()
      }
    }
  }

  private func rendered(_ outcome: Result<PanelRunner.Result, Error>) {
    switch outcome {
    case .failure(let error):
      notice = ("The render did not run: \(error)", .danger)
    case .success(let result) where result.timedOut:
      notice = ("The render took longer than \(Int(Self.renderTimeout))s and was stopped.", .danger)
    case .success(let result) where result.status != 0:
      let tail = result.stderrTail
      notice = (
        "The render exited with \(result.status)" + (tail.isEmpty ? "." : ": \(tail)"), .danger
      )
    case .success(let result):
      do {
        content = try PanelContent(data: result.stdout)
        if notice?.tone == .danger { notice = nil }
      } catch {
        notice = ("The render's output was not a panel: \(error)", .danger)
      }
    }
    changed()
  }

  /// What a render reads on stdin: the session's facts, and the approvals made on this panel.
  func renderInput(directory: URL) -> Data {
    var input = sessionFacts()
    input["worktree"] = directory.path
    input["approvals"] = approvals.map { approval -> [String: Any] in
      var entry: [String: Any] = [
        "document": approval.document, "hash": approval.hash,
        "verdict": approval.verdict.rawValue,
        "at": ISO8601DateFormatter().string(from: approval.at),
      ]
      if let reason = approval.reason { entry["reason"] = reason }
      return entry
    }
    return (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
  }

  /// Whether what was approved is still what is on disk. A changed file stops the panel — its
  /// drawing stays, its buttons do not — until the definition is installed and approved again.
  @discardableResult
  private func checkSeal() -> Bool {
    if let broken = seal.firstBroken() {
      if brokenFile != broken {
        brokenFile = broken
        changed()
      }
      return false
    }
    return true
  }

  // MARK: Watching

  private func rewatch(_ directory: URL) {
    guard watchedURL != directory else { return }
    watchedURL = directory
    watcher = nil
    guard !definition.render.watch.isEmpty else { return }
    let root = directory.standardizedFileURL.path
    watcher = DirectoryWatcher(
      url: directory, excluding: [directory.appendingPathComponent(".git")]
    ) {
      [weak self] paths in
      guard let self else { return }
      let relative = paths.compactMap { path -> String? in
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standard.hasPrefix(root + "/") else { return nil }
        return String(standard.dropFirst(root.count + 1))
      }
      if relative.contains(where: { self.watches($0) }) { self.setNeedsRender() }
    }
  }

  /// Whether a path relative to the worktree is one the definition watches. The watcher reports
  /// files, not the folders holding them, so a glob is matched against the file itself; `*` stops
  /// at a slash, as a shell's does.
  func watches(_ path: String) -> Bool {
    definition.render.watch.contains { fnmatch($0, path, FNM_PATHNAME) == 0 }
  }

  // MARK: Actions

  /// A button was pressed.
  func press(_ button: PanelContent.Button) {
    guard checkSeal(), runningCommand == nil else { return }
    switch button.action {
    case .send(let text):
      deliver(text, "Panel \u{00B7} \(button.label): \(text)")
    case .command(let name, let args):
      let argv: [String]
      do {
        argv = try definition.argv(for: name, arguments: args)
      } catch {
        notice = ("\(button.label): \(error)", .danger)
        changed()
        return
      }
      if definition.commands[name]?.outward == true {
        confirmation = Confirmation(label: button.label, name: name, argv: argv)
        changed()
      } else {
        run(name: name, label: button.label, argv: argv)
      }
    }
  }

  /// The person's answer to an outward command's preview.
  func confirm(_ yes: Bool) {
    guard let confirmation else { return }
    self.confirmation = nil
    if yes, checkSeal() {
      run(name: confirmation.name, label: confirmation.label, argv: confirmation.argv)
    } else {
      changed()
    }
  }

  private func run(name: String, label: String, argv: [String]) {
    guard let directory = worktreeURL() else { return }
    runningCommand = name
    notice = ("Running \(label)…", .info)
    changed()
    PanelRunner.run(argv, in: directory, timeout: Self.commandTimeout) { [weak self] outcome in
      guard let self else { return }
      self.runningCommand = nil
      let shownArgv = argv.joined(separator: " ")
      let summary: String
      let tone: PanelContent.Tone
      var detail = ""
      switch outcome {
      case .failure(let error):
        summary = "\(label) did not run: \(error)"
        tone = .danger
      case .success(let result):
        let out = String(decoding: result.stdout.suffix(2000), as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let err = result.stderrTail
        detail = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
        if result.timedOut {
          summary = "\(label) was stopped after \(Int(Self.commandTimeout))s"
          tone = .danger
        } else if result.status != 0 {
          summary = "\(label) exited with \(result.status)"
          tone = .danger
        } else {
          summary = "\(label) finished"
          tone = .success
        }
      }
      self.notice = (summary, tone)
      self.changed()
      self.deliver(
        "The user ran the panel's `\(name)` command (`\(shownArgv)`): \(summary)."
          + (detail.isEmpty ? "" : "\nOutput:\n\(detail)"),
        "Panel \u{00B7} \(summary)")
      self.setNeedsRender()
    }
  }

  /// Approve a document, or send it back with a reason, at what it holds now.
  func decide(document: String, approve: Bool, reason: String? = nil) {
    guard PanelContent.isRelative(document), let directory = worktreeURL() else { return }
    let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
    if !approve, reason?.isEmpty ?? true { return }
    guard
      let data = FileManager.default.contents(
        atPath: directory.appendingPathComponent(document).path)
    else {
      notice = ("\(document) cannot be read.", .danger)
      changed()
      return
    }
    let hash = PanelDefinition.digest(data)
    approvals.append(
      PanelApproval(
        document: document, hash: hash, verdict: approve ? .approved : .rejected,
        reason: approve ? nil : reason, at: Date()))
    if approvals.count > Self.approvalLimit {
      approvals.removeFirst(approvals.count - Self.approvalLimit)
    }
    onStoredChange()
    let short = String(hash.prefix(12))
    if approve {
      deliver(
        "The user approved `\(document)` on the panel, as it stands now (sha256 \(hash)).",
        "Panel \u{00B7} approved \(document) (\(short))")
    } else {
      deliver(
        "The user sent `\(document)` back on the panel (sha256 \(hash)), saying: \(reason ?? "")",
        "Panel \u{00B7} sent back \(document): \(reason ?? "")")
    }
    setNeedsRender()
  }

  /// The latest decision on a document, and whether it is about what is on disk now.
  func latestDecision(on document: String) -> (approval: PanelApproval, current: Bool)? {
    guard let approval = approvals.last(where: { $0.document == document }) else { return nil }
    guard let directory = worktreeURL(),
      let data = FileManager.default.contents(
        atPath: directory.appendingPathComponent(document).path)
    else { return (approval, false) }
    return (approval, PanelDefinition.digest(data) == approval.hash)
  }
}
