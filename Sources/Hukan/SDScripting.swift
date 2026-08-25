import AppKit

/// The AppleScript object model.
///
/// Scripting addresses hukan the way Safari does — `session "x" of worktree "y" of repository "z"
/// of window 1` — rather than mutating a hidden "selected" state through flat verbs. That is the
/// only shape that lets a script name a *specific* window when several are open, which the charter
/// puts at the centre of the design.
///
/// The domain model stays where it is. `Worktree`/`AgentSession`/`Workspace` remain plain
/// `final class`; these `SD…` proxies are a thin translation layer that hold only an identity plus
/// the owning `Workspace`/`NSWindow` and re-resolve the real object on every access. So a proxy that
/// AppKit builds and discards mid-specifier-evaluation is always safe, and one that outlives its
/// model degrades to empty rather than showing something stale.
///
/// The `@objc(SD…)` names matter: the sdef binds each class by its Objective-C runtime name, and
/// Swift would otherwise mangle it to `hukan.SD…`, leaving AppleScript unable to resolve the class
/// (every property comes back as `missing value`).

// MARK: - Window → model bridge

extension NSWindow {
  /// A window is a hukan workspace window only through its controller. Panels and alerts have
  /// no controller, so they simply have no repositories.
  fileprivate var sdWorkspace: Workspace? {
    (windowController as? WorkspaceWindowController)?.workspace
  }

  @objc var repositories: [SDRepository] {
    guard let workspace = sdWorkspace else { return [] }
    var seen = Set<String>()
    return workspace.worktrees.compactMap { worktree in
      seen.insert(worktree.repositoryID).inserted
        ? SDRepository(repositoryID: worktree.repositoryID, workspace: workspace, window: self)
        : nil
    }
  }

  @objc(valueInRepositoriesWithUniqueID:)
  func valueInRepositories(withUniqueID id: Any) -> SDRepository? {
    guard let key = id as? String, let workspace = sdWorkspace,
      workspace.worktrees.contains(where: { $0.repositoryID == key })
    else { return nil }
    return SDRepository(repositoryID: key, workspace: workspace, window: self)
  }

  @objc(valueInRepositoriesWithName:)
  func valueInRepositories(withName name: String) -> SDRepository? {
    guard let workspace = sdWorkspace,
      let worktree = workspace.worktrees.first(where: {
        $0.repositoryName.localizedCaseInsensitiveCompare(name) == .orderedSame
      })
    else { return nil }
    return SDRepository(repositoryID: worktree.repositoryID, workspace: workspace, window: self)
  }

  /// Selection is a property of the window, not a verb — `set selected worktree of window 1 to …`.
  @objc var selectedWorktree: SDWorktree? {
    get {
      guard let workspace = sdWorkspace, let id = workspace.selectedWorktreeID,
        workspace.worktree(id: id) != nil
      else { return nil }
      return SDWorktree(uuid: id, workspace: workspace, window: self)
    }
    set {
      guard let workspace = sdWorkspace, let proxy = newValue,
        workspace.worktree(id: proxy.uuid) != nil
      else { return }
      workspace.selectedWorktreeID = proxy.uuid
      workspace.selectedSessionID = nil
      let controller = windowController as? WorkspaceWindowController
      controller?.resumeSelectedSessionIfNeeded()
      controller?.reload()
    }
  }

  @objc var selectedSession: SDSession? {
    get {
      guard let workspace = sdWorkspace, let session = workspace.selectedSession else { return nil }
      return SDSession(uuid: session.id, workspace: workspace, window: self)
    }
    set {
      guard let workspace = sdWorkspace, let proxy = newValue,
        let session = workspace.sessions.first(where: { $0.id == proxy.uuid })
      else { return }
      workspace.selectedWorktreeID = session.worktreeID
      workspace.selectedSessionID = session.id
      let controller = windowController as? WorkspaceWindowController
      controller?.resumeSelectedSessionIfNeeded()
      controller?.reload()
    }
  }

  /// The rail's full-text filter as a plain string — `set session filter of window 1 to "…"` to
  /// narrow the rail, `get` for the current query. Setting is synchronous, so `filtered sessions`
  /// on the next line already reflects it.
  /// Every selected row's session id, one a line — the multi-selection, which `selected session`
  /// (the anchor) cannot describe. Text rather than a list of `session`, because a property whose
  /// type is an element class is a specifier list AppleScript resolves by index, and these are
  /// picked out by identity.
  @objc var selectedSessionIDs: String {
    get {
      guard let controller = windowController as? WorkspaceWindowController else { return "" }
      return controller.selectedSessionIDs.map(\.uuidString).joined(separator: "\n")
    }
    set {
      guard let controller = windowController as? WorkspaceWindowController else { return }
      // Whitespace-separated, so a script can write "a b" or a newline-joined list back verbatim.
      controller.selectSessions(
        newValue.split(whereSeparator: { $0.isWhitespace })
          .compactMap { UUID(uuidString: String($0)) })
    }
  }

  @objc var sessionFilter: String {
    get { (windowController as? WorkspaceWindowController)?.sessionFilter ?? "" }
    set { (windowController as? WorkspaceWindowController)?.sessionFilter = newValue }
  }

  /// The sessions the filter currently shows — every session when no filter is set. Exposed as the
  /// window's own `session` element (`get name of every session of window 1`), read-only, so a
  /// script can check what a query matched without reaching for a screenshot. Distinct from the
  /// full path `session … of worktree …`, which is unaffected by the rail's filter.
  @objc var filteredSessions: [SDSession] {
    guard let workspace = sdWorkspace,
      let controller = windowController as? WorkspaceWindowController
    else { return [] }
    return controller.filteredSessionIDs.compactMap { id in
      workspace.sessions.contains { $0.id == id }
        ? SDSession(uuid: id, workspace: workspace, window: self) : nil
    }
  }

  /// How many times the filter's terms are highlighted in the open transcript, and the offset of
  /// the first (the one the view scrolled to) — -1 for none. Read-only probes so the highlight is
  /// verifiable from a script even when the screenshot verb is blocked by a missing capture grant.
  @objc var transcriptMatchCount: Int {
    (windowController as? WorkspaceWindowController)?.transcriptMatchCount ?? 0
  }
  @objc var transcriptFirstMatchOffset: Int {
    (windowController as? WorkspaceWindowController)?.transcriptFirstMatchOffset ?? -1
  }
}

// MARK: - Repository

/// A repository is not a model object — it is `Workspace.worktrees` grouped by `repositoryID` (a
/// path), the same grouping the rail shows. So the proxy is keyed on that path.
@objc(SDRepository)
final class SDRepository: NSObject {
  let repositoryID: String
  let workspace: Workspace
  let window: NSWindow

  init(repositoryID: String, workspace: Workspace, window: NSWindow) {
    self.repositoryID = repositoryID
    self.workspace = workspace
    self.window = window
  }

  var controller: WorkspaceWindowController? {
    window.windowController as? WorkspaceWindowController
  }
  private var anyWorktree: Worktree? {
    workspace.worktrees.first { $0.repositoryID == repositoryID }
  }

  @objc var uniqueID: String { repositoryID }
  @objc var name: String {
    anyWorktree?.repositoryName ?? (repositoryID as NSString).lastPathComponent
  }

  @objc var worktrees: [SDWorktree] {
    workspace.worktrees
      .filter { $0.repositoryID == repositoryID }
      .map { SDWorktree(uuid: $0.id, workspace: workspace, window: window) }
  }

  @objc(valueInWorktreesWithUniqueID:)
  func valueInWorktrees(withUniqueID id: Any) -> SDWorktree? {
    guard let key = id as? String, let uuid = UUID(uuidString: key),
      let worktree = workspace.worktree(id: uuid), worktree.repositoryID == repositoryID
    else { return nil }
    return SDWorktree(uuid: uuid, workspace: workspace, window: window)
  }

  @objc(valueInWorktreesWithName:)
  func valueInWorktrees(withName name: String) -> SDWorktree? {
    guard
      let worktree = workspace.worktrees.first(where: {
        $0.repositoryID == repositoryID
          && $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame
      })
    else { return nil }
    return SDWorktree(uuid: worktree.id, workspace: workspace, window: window)
  }

  /// Standard Suite `close`, dispatched here by the sdef's `responds-to` — `close repository 1
  /// of window 1`, the verb the dictionary already carried, instead of a custom one. Closing
  /// removes the repository and its worktrees from the rail; nothing on disk is touched.
  @objc(handleCloseScriptCommand:)
  func handleClose(_ command: NSScriptCommand) -> Any? {
    workspace.closeRepository(repositoryID)
    controller?.reload()
    return nil
  }

  override var objectSpecifier: NSScriptObjectSpecifier? {
    guard let container = window.objectSpecifier, let desc = container.keyClassDescription else {
      return nil
    }
    return NSUniqueIDSpecifier(
      containerClassDescription: desc, containerSpecifier: container,
      key: "repositories", uniqueID: repositoryID)
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? SDRepository else { return false }
    return other.repositoryID == repositoryID && other.workspace === workspace
  }
  override var hash: Int { repositoryID.hashValue }
}

// MARK: - Worktree

@objc(SDWorktree)
final class SDWorktree: NSObject {
  let uuid: UUID
  let workspace: Workspace
  let window: NSWindow

  init(uuid: UUID, workspace: Workspace, window: NSWindow) {
    self.uuid = uuid
    self.workspace = workspace
    self.window = window
  }

  var controller: WorkspaceWindowController? {
    window.windowController as? WorkspaceWindowController
  }
  var worktreeModel: Worktree? { workspace.worktree(id: uuid) }

  @objc var uniqueID: String { uuid.uuidString }
  @objc var name: String { worktreeModel?.displayName ?? "" }
  @objc var branch: String? { worktreeModel?.branch }

  /// What the panel's History section lists, as text — one line per commit, `●` marking one the
  /// upstream does not carry yet. Read live rather than off the worktree's cache: a script may
  /// ask about a worktree this window has never drawn, and this is the surface that stands in for
  /// looking at the section (see the GUI-verification note in CLAUDE.md).
  @objc var history: String {
    guard let url = worktreeModel?.url else { return "" }
    return Git.history(at: url).commits
      .map { "\($0.isPushed == false ? "●" : " ") \($0.shortOID) \($0.summary)" }
      .joined(separator: "\n")
  }

  @objc var sessions: [SDSession] {
    workspace.sessions
      .filter { $0.worktreeID == uuid }
      .map { SDSession(uuid: $0.id, workspace: workspace, window: window) }
  }

  @objc(valueInSessionsWithUniqueID:)
  func valueInSessions(withUniqueID id: Any) -> SDSession? {
    guard let key = id as? String, let sessionID = UUID(uuidString: key),
      let session = workspace.sessions.first(where: { $0.id == sessionID && $0.worktreeID == uuid })
    else { return nil }
    return SDSession(uuid: session.id, workspace: workspace, window: window)
  }

  /// A session's title is optional and can repeat, so a name specifier is best-effort — the
  /// unique id is the reliable key.
  @objc(valueInSessionsWithName:)
  func valueInSessions(withName name: String) -> SDSession? {
    guard
      let session = workspace.sessions.first(where: {
        $0.worktreeID == uuid
          && ($0.title ?? "").localizedCaseInsensitiveCompare(name) == .orderedSame
      })
    else { return nil }
    return SDSession(uuid: session.id, workspace: workspace, window: window)
  }

  @objc var terminals: [SDTerminal] {
    workspace.terminals
      .filter { $0.worktreeID == uuid }
      .map { SDTerminal(uuid: $0.id, workspace: workspace, window: window) }
  }

  @objc(valueInTerminalsWithUniqueID:)
  func valueInTerminals(withUniqueID id: Any) -> SDTerminal? {
    guard let key = id as? String, let terminalID = UUID(uuidString: key),
      workspace.terminals.contains(where: { $0.id == terminalID && $0.worktreeID == uuid })
    else { return nil }
    return SDTerminal(uuid: terminalID, workspace: workspace, window: window)
  }

  /// A terminal's title can repeat, so a name specifier is best-effort — the id is reliable.
  @objc(valueInTerminalsWithName:)
  func valueInTerminals(withName name: String) -> SDTerminal? {
    guard
      let terminal = workspace.terminals.first(where: {
        $0.worktreeID == uuid && $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame
      })
    else { return nil }
    return SDTerminal(uuid: terminal.id, workspace: workspace, window: window)
  }

  /// Standard Suite `make new session` — `tell worktree 1 of … to make new session`, or `make
  /// new session at end of sessions of worktree 1 of …`. NSCreateCommand asks the container to
  /// create; the session is born in the model right here, so the insertion step that follows
  /// (`insertValue…`) has nothing left to do.
  override func newScriptingObject(
    of objectClass: AnyClass, forValueForKey key: String,
    withContentsValue contentsValue: Any?, properties: [String: Any]
  ) -> Any? {
    guard let worktree = worktreeModel, let controller else {
      return super.newScriptingObject(
        of: objectClass, forValueForKey: key, withContentsValue: contentsValue,
        properties: properties)
    }
    switch key {
    case "sessions":
      let session = controller.makeSession(in: worktree)
      return SDSession(uuid: session.id, workspace: workspace, window: window)
    case "terminals":
      let terminal = controller.makeTerminal(in: worktree)
      return SDTerminal(uuid: terminal.id, workspace: workspace, window: window)
    default:
      return super.newScriptingObject(
        of: objectClass, forValueForKey: key, withContentsValue: contentsValue,
        properties: properties)
    }
  }

  override func insertValue(_ value: Any, at index: Int, inPropertyWithKey key: String) {
    // `newScriptingObject` already created the object in the workspace — the model, not the
    // proxy list, is the storage — so NSCreateCommand's insertion is a no-op.
    guard key == "sessions" || key == "terminals" else {
      return super.insertValue(value, at: index, inPropertyWithKey: key)
    }
  }

  override var objectSpecifier: NSScriptObjectSpecifier? {
    guard let model = worktreeModel,
      let container = SDRepository(
        repositoryID: model.repositoryID, workspace: workspace, window: window
      ).objectSpecifier,
      let desc = container.keyClassDescription
    else { return nil }
    return NSUniqueIDSpecifier(
      containerClassDescription: desc, containerSpecifier: container,
      key: "worktrees", uniqueID: uuid.uuidString)
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? SDWorktree else { return false }
    return other.uuid == uuid && other.workspace === workspace
  }
  override var hash: Int { uuid.hashValue }
}

// MARK: - Session

@objc(SDSession)
final class SDSession: NSObject {
  let uuid: UUID
  let workspace: Workspace
  let window: NSWindow

  init(uuid: UUID, workspace: Workspace, window: NSWindow) {
    self.uuid = uuid
    self.workspace = workspace
    self.window = window
  }

  var controller: WorkspaceWindowController? {
    window.windowController as? WorkspaceWindowController
  }
  var agentSession: AgentSession? { workspace.sessions.first { $0.id == uuid } }

  @objc var uniqueID: String { uuid.uuidString }
  /// Exposed to AppleScript as the `name` property (see the sdef `<cocoa key="title"/>`).
  @objc var title: String { agentSession?.title ?? "" }
  @objc var transcript: String { agentSession?.transcript.string ?? "" }
  @objc var pendingApproval: String {
    guard let approval = agentSession?.pendingApproval else { return "" }
    return approval.detail.isEmpty ? approval.toolName : "\(approval.toolName): \(approval.detail)"
  }
  /// The agent's own task list, one line a task — `[x]` done, `[~]` in flight, `[ ]` still to
  /// do. The whole list, where the card shows only what is left: a script is reading data, not
  /// glancing at a card, and the finished tasks are half of what it might be checking.
  @objc var tasks: String {
    (agentSession?.tasks ?? [])
      .map { task in
        let box: String
        switch task.status {
        case .completed: box = "[x]"
        case .inProgress: box = "[~]"
        case .pending: box = "[ ]"
        }
        return "\(box) \(task.subject)"
      }
      .joined(separator: "\n")
  }
  @objc var running: Bool { agentSession?.isRunning ?? false }
  @objc var detached: Bool { agentSession?.isDetached ?? false }
  /// Another live process owns this session's engine; hukan will not start it until that process
  /// exits. `held by pid` gives the owner for a scripted check.
  @objc var heldElsewhere: Bool { agentSession?.heldByPID != nil }
  @objc var heldByPID: Int { agentSession?.heldByPID.map(Int.init) ?? 0 }
  /// Whether the rail is showing this session below the fold — which is the flag *and* the one
  /// rule that overrides it, since a session that is working or waiting on you comes back out.
  /// What a script checking the rail wants is what the rail is doing, not what was recorded.
  @objc var archived: Bool {
    guard let session = agentSession else { return false }
    return workspace.isArchived(session)
  }

  // MARK: Verbs (the session is the receiver, the way `close` reaches a repository). Addressed as
  // `stop session X` or `tell session X to stop`; the command definitions carry no `<cocoa class>`,
  // so Cocoa dispatches straight to these `responds-to` methods.

  @objc(handleStopScriptCommand:)
  func handleStop(_ command: NSScriptCommand) -> Any? {
    guard let session = agentSession else { return command.fail("no such session") }
    session.stop()
    return "ok"
  }

  @objc(handleStartScriptCommand:)
  func handleStart(_ command: NSScriptCommand) -> Any? {
    guard let session = agentSession else { return command.fail("no such session") }
    if session.heldByPID != nil { return command.fail("session is held by another process") }
    guard !session.isRunning else { return command.fail("session is already running") }
    controller?.startSessionFromRail(session)
    return "ok"
  }

  @objc(handleInterruptScriptCommand:)
  func handleInterrupt(_ command: NSScriptCommand) -> Any? {
    guard let session = agentSession else { return command.fail("no such session") }
    guard session.isRunning else { return command.fail("session is not running") }
    session.interrupt()
    return "ok"
  }

  /// `fork session X` branches the conversation before its last message; `fork session X before 2`
  /// before the second message that has anything above it. Reads the fork points out of the
  /// transcript the session is *showing*, so a session whose conversation has never been loaded
  /// (restored, never selected) has none to offer — select it first. Returns the new session's id.
  @objc(handleForkScriptCommand:)
  func handleFork(_ command: NSScriptCommand) -> Any? {
    guard let session = agentSession, let controller else {
      return command.fail("no such session")
    }
    guard let point = forkPoint(command, in: session) else { return nil }
    guard
      let forked = controller.forkSession(
        session, at: point.anchor, keeping: point.range.location)
    else { return command.fail("no worktree for this session") }
    return forked.id.uuidString
  }

  /// `roll back session X` cuts the conversation back to before its last message; `before 2` to
  /// before the second that has anything above it. Unlike the menu item this does not ask —
  /// scripting is the automated path, and a confirmation nothing can answer is a hang.
  @objc(handleRollBackScriptCommand:)
  func handleRollBack(_ command: NSScriptCommand) -> Any? {
    guard let session = agentSession, let controller else {
      return command.fail("no such session")
    }
    guard session.canRollBack else {
      return command.fail(
        "session is held by another process; close it there, or fork instead")
    }
    guard let point = forkPoint(command, in: session) else { return nil }
    session.rollBack(to: point.anchor, keeping: point.range.location)
    controller.reload()
    return "ok"
  }

  /// The message a `fork`/`roll back` names, read out of the transcript the session is *showing*
  /// — so a session whose conversation has never been loaded (restored, never selected) has none
  /// to offer. Fails the command and returns nil when there is nothing to point at.
  private func forkPoint(_ command: NSScriptCommand, in session: AgentSession) -> (
    anchor: String, range: NSRange
  )? {
    let points = Transcript.forkPoints(in: session.transcript)
    guard !points.isEmpty else {
      command.fail(
        "no fork point — the session's conversation is not loaded, or has nothing before its "
          + "first message")
      return nil
    }
    let requested = (command.evaluatedArguments?["before"] as? NSNumber)?.intValue ?? points.count
    guard requested >= 1, requested <= points.count else {
      command.fail("fork point \(requested) is out of range (1…\(points.count))")
      return nil
    }
    return points[requested - 1]
  }

  /// `archive session X` / `unarchive session X`. Not guarded the way approve/deny are: those
  /// stand in for a decision only a person can make, where this only moves a row — and the agent
  /// hiding its own row is a nuisance, not a bypass.
  @objc(handleArchiveScriptCommand:)
  func handleArchive(_ command: NSScriptCommand) -> Any? {
    setArchived(true, command)
  }

  @objc(handleUnarchiveScriptCommand:)
  func handleUnarchive(_ command: NSScriptCommand) -> Any? {
    setArchived(false, command)
  }

  private func setArchived(_ archived: Bool, _ command: NSScriptCommand) -> Any? {
    guard let session = agentSession else { return command.fail("no such session") }
    if archived, !workspace.canArchive(session) {
      return command.fail("only the main worktree's sessions can be archived")
    }
    guard workspace.setArchived(archived, for: [session]) else {
      return command.fail(archived ? "session is already archived" : "session is not archived")
    }
    controller?.reload()
    window.invalidateRestorableState()
    return "ok"
  }

  @objc(handleApproveScriptCommand:)
  func handleApprove(_ command: NSScriptCommand) -> Any? { resolveApproval(command, allow: true) }

  @objc(handleDenyScriptCommand:)
  func handleDeny(_ command: NSScriptCommand) -> Any? { resolveApproval(command, allow: false) }

  /// approve/deny stand in for a human decision, so they stay behind `HUKAN_SCRIPTING_GUARDED` — a
  /// session's own agent can reach osascript and must not approve its own tool calls.
  private func resolveApproval(_ command: NSScriptCommand, allow: Bool) -> Any? {
    guard guardedScriptingEnabled() else { return command.fail("approvals are not scriptable") }
    guard let session = agentSession else { return command.fail("no such session") }
    guard session.pendingApproval != nil else { return command.fail("nothing to approve") }
    session.resolveApproval(allow: allow)
    controller?.reload()
    return allow ? "allowed" : "denied"
  }

  override var objectSpecifier: NSScriptObjectSpecifier? {
    guard let model = agentSession,
      let container = SDWorktree(uuid: model.worktreeID, workspace: workspace, window: window)
        .objectSpecifier,
      let desc = container.keyClassDescription
    else { return nil }
    return NSUniqueIDSpecifier(
      containerClassDescription: desc, containerSpecifier: container,
      key: "sessions", uniqueID: uuid.uuidString)
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? SDSession else { return false }
    return other.uuid == uuid && other.workspace === workspace
  }
  override var hash: Int { uuid.hashValue }
}

// MARK: - Terminal

@objc(SDTerminal)
final class SDTerminal: NSObject {
  let uuid: UUID
  let workspace: Workspace
  let window: NSWindow

  init(uuid: UUID, workspace: Workspace, window: NSWindow) {
    self.uuid = uuid
    self.workspace = workspace
    self.window = window
  }

  var terminalModel: TerminalSession? { workspace.terminals.first { $0.id == uuid } }

  @objc var uniqueID: String { uuid.uuidString }
  /// Exposed to AppleScript as the `name` property (see the sdef `<cocoa key="title"/>`).
  @objc var title: String { terminalModel?.title ?? "" }
  @objc var running: Bool { terminalModel?.isRunning ?? false }

  override var objectSpecifier: NSScriptObjectSpecifier? {
    guard let model = terminalModel,
      let container = SDWorktree(uuid: model.worktreeID, workspace: workspace, window: window)
        .objectSpecifier,
      let desc = container.keyClassDescription
    else { return nil }
    return NSUniqueIDSpecifier(
      containerClassDescription: desc, containerSpecifier: container,
      key: "terminals", uniqueID: uuid.uuidString)
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? SDTerminal else { return false }
    return other.uuid == uuid && other.workspace === workspace
  }
  override var hash: Int { uuid.hashValue }
}
