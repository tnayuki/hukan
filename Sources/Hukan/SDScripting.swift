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

  /// Standard Suite `make new session` — `tell worktree 1 of … to make new session`, or `make
  /// new session at end of sessions of worktree 1 of …`. NSCreateCommand asks the container to
  /// create; the session is born in the model right here, so the insertion step that follows
  /// (`insertValue…`) has nothing left to do.
  override func newScriptingObject(
    of objectClass: AnyClass, forValueForKey key: String,
    withContentsValue contentsValue: Any?, properties: [String: Any]
  ) -> Any? {
    guard key == "sessions", let worktree = worktreeModel, let controller else {
      return super.newScriptingObject(
        of: objectClass, forValueForKey: key, withContentsValue: contentsValue,
        properties: properties)
    }
    let session = controller.makeSession(in: worktree)
    return SDSession(uuid: session.id, workspace: workspace, window: window)
  }

  override func insertValue(_ value: Any, at index: Int, inPropertyWithKey key: String) {
    // `newScriptingObject` already created the session in the workspace — the model, not the
    // proxy list, is the storage — so NSCreateCommand's insertion is a no-op.
    guard key == "sessions" else {
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
  @objc var running: Bool { agentSession?.isRunning ?? false }
  @objc var detached: Bool { agentSession?.isDetached ?? false }

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
