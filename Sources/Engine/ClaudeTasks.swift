import Foundation

/// One task on the agent's own list, as Claude Code keeps it: a file under
/// `~/.claude/tasks/<session-id>/`, written by `TaskCreate` and amended in place by `TaskUpdate`.
///
/// The store is the engine's master data, so hukan reads the directory rather than following the
/// calls that wrote it. Following them would mean replaying a create-then-update stream to work
/// out what the list says now — where the directory already *is* what it says now, and is still
/// there after a restart. (The tool this replaced, `TodoWrite`, sent the whole list on every
/// call and so could be read straight off the wire; it left Claude Code in mid-2026.)
struct AgentTask: Equatable {
  enum Status: String {
    case pending
    case inProgress = "in_progress"
    case completed
  }

  let id: String
  /// The task's one-line name, which is what the opened card lists.
  let subject: String
  /// The present-tense phrasing the agent gives a task while it is the one in flight
  /// ("Folding the file tree into the rail"), which is what the folded card shows.
  let activeForm: String
  let status: Status
  /// The tasks that must land before this one can start. Only the unfinished ones actually
  /// block, which is why the card resolves these against the list rather than trusting the
  /// field on its own.
  let blockedBy: [String]

  /// What to call the task on the card: its `activeForm` while it is the one running, since that
  /// is the phrasing written for exactly this, and its subject otherwise.
  var label: String {
    status == .inProgress && !activeForm.isEmpty ? activeForm : subject
  }
}

extension ClaudeSessionStore {
  /// The agent's task list for one session.
  ///
  /// The directory is named for the session id, in the one spelling `ClaudeSessionStore.name`
  /// decides — this used to try two, hukan having spelt its own ids in a case the CLI never uses.
  static func tasks(id: UUID) -> [AgentTask] {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/tasks")
      .appendingPathComponent(name(id))
    return tasks(in: directory)
  }

  /// The parse behind `tasks(id:)`, over a directory of task files — separate so a test can
  /// point it at one it wrote itself.
  ///
  /// Ordered by id, numerically where the ids are numbers: they are (`1.json`…`n.json`), and
  /// that is creation order, which is the order the agent means them in. A file with no subject
  /// is skipped rather than shown as a blank row. Cheap enough to re-read on every open and at
  /// each task tool's result instead of being cached: the longest list on this machine is 21
  /// files of a few hundred bytes.
  static func tasks(in directory: URL) -> [AgentTask] {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    let tasks = entries.filter { $0.pathExtension == "json" }.compactMap { url -> AgentTask? in
      guard let data = try? Data(contentsOf: url),
        let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let subject = record["subject"] as? String, !subject.isEmpty
      else { return nil }
      return AgentTask(
        id: record["id"] as? String ?? url.deletingPathExtension().lastPathComponent,
        subject: subject,
        activeForm: record["activeForm"] as? String ?? "",
        status: (record["status"] as? String).flatMap(AgentTask.Status.init) ?? .pending,
        blockedBy: record["blockedBy"] as? [String] ?? [])
    }
    return tasks.sorted { left, right in
      if let l = Int(left.id), let r = Int(right.id) { return l < r }
      return left.id.localizedStandardCompare(right.id) == .orderedAscending
    }
  }
}
