import AppKit

/// Drive hukan from AppleScript.
///
/// If System Events is the only way in, a window moving behind another breaks coordinate clicking —
/// useless for automated checks and for personal automation. Being scriptable means state and
/// actions are both reachable from osascript.
///
/// The surface is an object model, not flat verbs: commands act on objects named by specifier
/// (`session "x" of worktree "y" of repository 1 of window 1`), and the objects themselves live in
/// `SDScripting.swift`. This file is only the commands.

/// The front workspace window — the default when a command names no window. Mirrors the old
/// `frontController()`: the key window if it is a workspace window, else the first one.
private func frontWorkspaceWindow() -> NSWindow? {
  if let key = NSApp.keyWindow, key.windowController is WorkspaceWindowController { return key }
  return WorkspaceWindowController.all.first?.window
}

/// The controller behind the front workspace window. The object model addresses everything by
/// specifier, but the two whole-window convenience commands kept for verification — `hukan status`
/// and `fold` — report on or drive the current window as a whole, so they take it directly.
private func frontController() -> WorkspaceWindowController? {
  frontWorkspaceWindow()?.windowController as? WorkspaceWindowController
}

/// Resolve a command argument to a proxy. The value may already be the proxy, an array of them
/// (an `evaluatedReceivers` list), or an unevaluated object specifier — handle all three.
private func resolve<T>(_ value: Any?, as type: T.Type) -> T? {
  if let object = value as? T { return object }
  if let array = value as? [Any] { return array.lazy.compactMap { resolve($0, as: T.self) }.first }
  if let specifier = value as? NSScriptObjectSpecifier {
    return resolve(specifier.objectsByEvaluatingSpecifier, as: T.self)
  }
  return nil
}

/// The object a command's by-name parameter names — used by the app-level utility commands that
/// still take a target by name (a bare `restart` has none). The
/// object-scoped session verbs went the other way: the session is the command's receiver, handled
/// by `responds-to` methods on `SDSession` (see `SDScripting.swift`), the same way `close` reaches a
/// repository. That is why an object *can* be a receiver after all — the earlier -1708 was a custom
/// command implemented as an `NSScriptCommand` subclass with an object direct-parameter; a
/// `responds-to` method on the object's class is the route Cocoa actually dispatches to.
extension NSScriptCommand {
  func argument<T>(_ key: String, as type: T.Type) -> T? {
    resolve(evaluatedArguments?[key], as: T.self)
  }

  /// Report failure as a real script error, the way any scriptable app does — the caller's
  /// `try` block sees it, and a command whose result is an object (`type="specifier"`) has no
  /// string to smuggle an "error:" through anyway.
  @discardableResult
  func fail(_ message: String) -> Any? {
    scriptErrorNumber = 1
    scriptErrorString = message
    return nil
  }
}

/// A handful of verbs stand in for a decision the human is meant to make: an approval keeps a human
/// in the tool-call loop, landing confirms first because it is unrecoverable. Their scripted forms
/// remove that guard, and a session's own agent can reach osascript — so it could approve its own
/// calls or discard a worktree unattended. Keep them out of the shipping scripting surface and only
/// honour them when a test harness opts in through the environment.
func guardedScriptingEnabled() -> Bool {
  ProcessInfo.processInfo.environment["HUKAN_SCRIPTING_GUARDED"] == "1"
}

// The object-scoped session verbs — stop, start, interrupt, approve, deny — are handled as
// `responds-to` methods on `SDSession` (the session is the receiver), not as commands here. See
// `SDScripting.swift`. `guardedScriptingEnabled()` above still gates approve/deny there.

/// `send "…" to session X` — the one session verb that stays a by-name command. Its natural direct
/// parameter is the message, so the session cannot also be the direct-parameter receiver; and a
/// verb whose direct parameter is not a specifier does not dispatch to a `responds-to` method (it
/// comes back `missing value`, verified). So send keeps naming its target with `to`.
@objc(SendCommand)
final class SendCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let text = directParameter as? String else { return fail("a message is required") }
    guard let proxy = argument("toSession", as: SDSession.self), let session = proxy.agentSession
    else { return fail("no such session") }
    // Reattach a detached session before sending — the one addressed, not the selected one.
    proxy.controller?.reattachIfNeeded(session)
    if session.heldByPID != nil { return fail("session is held by another process") }
    guard session.isRunning else { return fail("session is not running") }
    session.send(text)
    return "ok"
  }
}

@objc(RestartCommand)
final class RestartCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
    // Switch on the target: `restart session X` cycles that one session's engine (resuming its
    // conversation); a bare `restart` — no session — relaunches the whole app, the dev-loop verb.
    if let proxy = argument("onSession", as: SDSession.self) {
      guard let session = proxy.agentSession else { return fail("no such session") }
      if session.heldByPID != nil { return fail("session is held by another process") }
      proxy.controller?.reattachIfNeeded(session)
      session.restart()
      return "ok"
    }
    // Relaunch the same bundle: a detached helper waits for us to exit, then reopens the .app
    // (so a fresh `make bundle` is picked up), and AppKit restores the window, its Space and
    // the open repositories. Live sessions reattach from their on-disk transcripts on select.
    //
    // This is what makes the dev loop bearable from inside the app: build, then
    // `osascript -e 'tell application "hukan" to restart'` — no manual quit-and-reopen.
    //
    // The helper polls `kill -0 <our pid>` until we are actually gone, rather than sleeping a
    // fixed guess: `open` on a bundle whose instance is still alive only reactivates the dying
    // process instead of launching a fresh one, and our own quit now takes as long as the
    // slowest engine's EOF→SIGTERM→SIGKILL shutdown — a fixed `sleep 1` lost that race and
    // left the app down. (The helper is our child, so it survives our exit to run the `open`.)
    let path = Bundle.main.bundlePath
    let pid = ProcessInfo.processInfo.processIdentifier
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = [
      "-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"\(path)\"",
    ]
    do {
      try task.run()
    } catch {
      return fail(error.localizedDescription)
    }
    // Terminate after the reply is on its way, or osascript sees the connection drop instead
    // of the result.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    return "restarting \((path as NSString).lastPathComponent)"
  }
}

/// Drive and observe the tool-call fold from a script, because a mouse cannot be scripted onto a
/// moving window (see the file comment). `fold status` counts each state in the on-screen storage;
/// `fold expand` and `fold collapse` run exactly the click delegate's link path on the last folded
/// line / first opened header, which is all a real click does.
@objc(FoldCommand)
final class FoldCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
    let action = (directParameter as? String) ?? "status"
    guard let contentView = frontController()?.window?.contentView,
      let textView = Self.transcriptTextView(in: contentView),
      let storage = textView.textStorage
    else { return fail("no transcript view") }
    let whole = NSRange(location: 0, length: storage.length)

    func states() -> (folded: [Int], expanded: [Int]) {
      var folded: [Int] = []
      var expanded: [Int] = []
      storage.enumerateAttribute(Transcript.toolTokenKey, in: whole) { value, range, _ in
        guard value is ToolCallToken else { return }
        if storage.attribute(Transcript.toolExpandedKey, at: range.location, effectiveRange: nil)
          != nil
        {
          expanded.append(range.location)
        } else {
          folded.append(range.location)
        }
      }
      return (folded, expanded)
    }

    func click(at index: Int) -> Any? {
      textView.scrollRangeToVisible(NSRange(location: index, length: 1))
      let handled =
        (textView.delegate as? TranscriptClickDelegate)?
        .textView(textView, clickedOnLink: Transcript.toolCallLinkURL, at: index) ?? false
      return handled ? "toggled at \(index)" : fail("click not handled at \(index)")
    }

    switch action {
    case "expand":
      guard let index = states().folded.last else { return fail("no folded line") }
      return click(at: index)
    case "collapse":
      guard let index = states().expanded.first else { return fail("no expanded block") }
      return click(at: index)
    default:
      let (folded, expanded) = states()
      return "folded:\(folded.count) expanded:\(expanded.count)"
    }
  }

  private static func transcriptTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView, textView.delegate is TranscriptClickDelegate {
      return textView
    }
    for subview in view.subviews {
      if let found = transcriptTextView(in: subview) { return found }
    }
    return nil
  }
}

/// `files` reports the panel — what the field holds, which of its two gestures is showing, and
/// what it is waiting on — and `filtering`/`searching` run the two gestures. Hidden, like `fold`:
/// the panel is a tree of rows with no text to read back, and the states worth checking (the tree
/// budgeted open under a filter, the note while a read is out) are exactly the ones a screenshot
/// cannot assert. `menu` reads back the right-click menu a row would carry, for the same reason;
/// `creating`/`folder`/`renaming`/`deleting` run what that menu does, and are guarded, since each
/// of them stands in for a human's answer — a name typed on the row, or the alert before a
/// delete.
@objc(FilesPanelCommand)
final class FilesPanelCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let controller = frontController() else { return fail("no window") }
    let panel = controller.filesPanelForScripting
    if let query = argument("filtering", as: String.self) {
      panel.filterForScripting(query)
      return panel.report
    }
    if let query = argument("searching", as: String.self) {
      panel.searchForScripting(query)
      return panel.report
    }
    if let path = argument("menu", as: String.self) {
      return panel.menuForScripting(path: path)
    }
    // The writes the menu makes. Guarded, like `approve`: each stands in for a human's answer, so
    // a scripted one is hukan acting on a worktree with nobody having said yes.
    if let path = argument("creating", as: String.self) {
      guard guardedScriptingEnabled() else { return fail("guarded") }
      return panel.writeForScripting(create: path)
    }
    if let path = argument("renaming", as: String.self) {
      guard guardedScriptingEnabled() else { return fail("guarded") }
      guard let name = argument("toName", as: String.self) else {
        return fail("a name is required")
      }
      return panel.writeForScripting(rename: path, to: name)
    }
    if let path = argument("folder", as: String.self) {
      guard guardedScriptingEnabled() else { return fail("guarded") }
      return panel.writeForScripting(createFolder: path)
    }
    if let path = argument("deleting", as: String.self) {
      guard guardedScriptingEnabled() else { return fail("guarded") }
      return panel.writeForScripting(delete: path)
    }
    return panel.report
  }
}

/// `completions` reports whichever list the composer has open — the engine's slash commands, or
/// the past prompts a romaji query found — and `typing`/`moving`/`accepting`/`completing` drive
/// it. The last two are Return and Tab, which differ on a prompt list: it opens with no row
/// selected, so Return is still the send and Tab is what takes the best row. Hidden,
/// like `files` and `commit`, and for the same reason: the list is rows on a floating panel, so
/// checking that a `/` opened it — and that Return took the right row — would otherwise mean
/// clicking at coordinates. `typing` goes through the text view's own edit path, which is what
/// makes the prompt list reachable at all: it is opened by ordinary ASCII rather than by a
/// trigger character, so a shortcut only a script could take would be exercising nothing.
@objc(CompletionsCommand)
final class CompletionsCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let controller = frontController() else { return fail("no window") }
    let composer = controller.composerForScripting
    if let text = argument("typing", as: String.self) {
      composer.typeForScripting(text)
      return composer.completionReportForScripting
    }
    if let delta = argument("moving", as: Int.self) {
      for _ in 0..<abs(delta) {
        composer.completionKeyForScripting(delta < 0 ? .up : .down)
      }
      return composer.completionReportForScripting
    }
    if argument("accepting", as: Bool.self) == true {
      guard composer.completionKeyForScripting(.accept) else {
        return fail("no list open, or no row selected")
      }
      return composer.stringValue
    }
    if argument("completing", as: Bool.self) == true {
      guard composer.completionKeyForScripting(.complete) else { return fail("no list open") }
      return composer.stringValue
    }
    return composer.completionReportForScripting
  }
}

/// `tabs` reports the selected worktree's tab strip, one line per tab. Hidden, like the rest of
/// the checking verbs: the strip is a row of buttons with nothing to read back, and what it holds
/// after a relaunch — which tabs came back, in what order, and which of them is showing — is the
/// whole of what restoring the desk means.
@objc(TabsCommand)
final class TabsCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let controller = frontController() else { return fail("no window") }
    return controller.deskForScripting.tabStripReport
  }
}

/// `recents` reports what Open Recent would offer this window, one line per entry — the title the
/// row would carry and the path it would open. Hidden, like the rest of the checking verbs, and for
/// the same reason `files menu` is: two of the three places it hangs are context menus, which
/// cannot be opened at all without a right-click at coordinates. `opening "<path>"` takes one, the
/// way clicking the row would.
@objc(RecentsCommand)
final class RecentsCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let controller = frontController() else { return fail("no window") }
    if let path = evaluatedArguments?["opening"] as? String, !path.isEmpty {
      let item = NSMenuItem()
      item.representedObject = path
      controller.openRecentRepository(item)
      return nil
    }
    let open = Set(controller.workspace.repositories.map(\.id))
    let entries = RecentRepositories.shared.entries(excluding: open)
    guard !entries.isEmpty else { return "(no recent repositories)" }
    return entries.map { "\($0.title)  \($0.path)" }.joined(separator: "\n")
  }
}

/// `browser "<address>"` opens or focuses a web tab on the selected worktree's desk, taking the
/// address bar's own reading of the text — so a script exercises the same address-or-search rule a
/// person does. With nothing to open it reports the worktree's web tabs, one line each. Hidden,
/// like `commit`, `fold` and `files`, and for the same reason: a web tab has no text to read back, so
/// checking where a click or a typed line landed would otherwise mean clicking at coordinates.
@objc(BrowserCommand)
final class BrowserCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let controller = frontController() else { return fail("no window") }
    let desk = controller.deskForScripting
    guard let text = (directParameter as? String), !text.isEmpty else {
      return desk.browserTabsReport
    }
    let workspace = controller.workspace
    guard let worktree = workspace.selectedWorktreeID.flatMap({ workspace.worktree(id: $0) })
    else { return fail("no selected worktree") }
    // An address bar takes text, not a URL: sending it through the pane's own `load` is what
    // makes the search fallback and the refusals scriptable at all.
    if let pane = desk.selectedBrowserPane {
      pane.load(text)
    } else {
      desk.openBrowser(worktree: worktree)
      desk.selectedBrowserPane?.load(text)
    }
    return "loading \(text)"
  }
}

/// `commit "<oid>"` opens one on the selected worktree's desk; with no oid it reports the tab
/// already showing, and `toggling`/`finding` drive its cards. Hidden, like `fold`: it exists so
/// the tab can be checked without System Events clicking at coordinates.
@objc(CommitTabCommand)
final class CommitTabCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let controller = frontController() else { return fail("no window") }
    let desk = controller.deskForScripting
    if let oid = directParameter as? String, !oid.isEmpty {
      let workspace = controller.workspace
      guard let worktree = workspace.selectedWorktreeID.flatMap({ workspace.worktree(id: $0) })
      else { return fail("no selected worktree") }
      desk.openCommit(worktree: worktree, oid: oid, preview: false)
      return "opened \(oid)"
    }
    guard let tab = desk.selectedCommitTab else { return fail("no commit tab is showing") }
    if let index = argument("toggling", as: NSNumber.self) {
      tab.toggleSection(at: index.intValue - 1)
      return "toggled card \(index.intValue)"
    }
    if let term = argument("finding", as: String.self) {
      tab.find(term)
      return "\(tab.findState.count) matches"
    }
    return tab.report
  }
}

@objc(StatusCommand)
final class StatusCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let controller = frontController() else { return fail("no window") }
    let workspace = controller.workspace
    let repositories = workspace.railRepositories
    guard !repositories.isEmpty else { return "(no worktrees)" }
    // The rail's own tree, flattened: repository, then its worktrees — main first, the way the
    // rail orders them — then that worktree's sessions in the rail's order, last-instructed first.
    // Derived from `railRepositories` so there is one grouping to keep right rather than two that
    // can disagree. The Archived section is not folded away here — it exists to keep a long tail
    // off the rail, and a dump has nothing to fold — but its rows say so, since "what is on the
    // rail right now" is exactly what a script checking the rail wants to be able to tell. The
    // diffstat sits on the worktree line because that is what it measures — a worktree's
    // uncommitted work, not a session's. The "… ago" is last activity (`updatedAt`), not the sort
    // key, so a row can read fresher than the ones above it.
    let now = Date()
    let selected = workspace.selectedSession?.id
    return repositories.map { repository -> String in
      let blocks = repository.worktrees.map { railWorktree -> String in
        let worktree = railWorktree.worktree
        let stat = worktree.diffstat
        func row(_ entry: Workspace.RailEntry, archived: Bool) -> String {
          let session = entry.session
          let marker = session.id == selected ? "*" : " "
          let title = session.title ?? "New session"
          let state = Self.state(of: session)
          let ago = Self.ago(from: session.updatedAt, to: now)
          return "    \(marker) \(title)  [\(state)]  \(ago)" + (archived ? "  (archived)" : "")
        }
        let rows =
          railWorktree.sessions.map { row($0, archived: false) }
          + railWorktree.archived.map { row($0, archived: true) }
        let heading = "  \(worktree.displayName)  +\(stat.added) -\(stat.removed)"
        return ([heading] + rows).joined(separator: "\n")
      }
      return ([repository.repositoryName] + blocks).joined(separator: "\n")
    }.joined(separator: "\n")
  }

  /// How a row reads its session. A hold by another process and a detached engine both outrank
  /// the run state: neither is something this window can act on, so saying "idle" would mislead.
  private static func state(of session: AgentSession) -> String {
    if let pid = session.heldByPID { return "held(pid \(pid))" }
    if session.isDetached { return "detached" }
    if session.isRunning { return session.state.rawValue }
    return "\(session.state.rawValue)(stopped)"
  }

  /// A compact "how long ago" for the rail's sort key. `.distantPast` (never active) reads as "—".
  private static func ago(from date: Date, to now: Date) -> String {
    AgentSession.age(since: date, at: now) ?? "—"
  }
}

/// `edit "<path>"` — the verb behind the CLI helper and the terminals' `$EDITOR`. The resolution
/// is `openPath`'s, shared with the Finder drop and the command line; what only this verb adds is
/// `waiting`, which holds the Apple event's reply until the tab closes — the whole of what makes
/// `git commit` in a hukan terminal work, since git's editor is done when it exits.
///
/// Unguarded deliberately: it opens tabs, the same reach `commit` and `browser` already have. The
/// guarded verbs stand in for human decisions, and showing a file is not one.
@objc(EditCommand)
final class EditCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let text = directParameter as? String, text.hasPrefix("/") else {
      return fail("an absolute path is required")
    }
    // Who asked, when a hukan terminal did: the id is the TERM_SESSION_ID the terminal was
    // spawned with, and it also names the window — the front one is only the fallback.
    var terminalID: UUID?
    var controller: WorkspaceWindowController?
    if let key = argument("fromTerminal", as: String.self), !key.isEmpty {
      for candidate in WorkspaceWindowController.all {
        guard let terminal = candidate.workspace.terminals.first(where: { $0.sessionID == key })
        else { continue }
        terminalID = terminal.id
        controller = candidate
        break
      }
    }
    guard let controller = controller ?? frontController() else { return fail("no window") }
    guard let opened = controller.openPath(URL(fileURLWithPath: text), terminalID: terminalID)
    else { return fail("no such path: \(text)") }
    guard case .file(let worktreeID, let tabPath) = opened,
      argument("waiting", as: Bool.self) == true
    else { return "opened" }
    // Held, not blocked: the reply is suspended and the run loop goes on. The desk resumes it
    // when the tab closes (`onFileTabClosed`); the caller's own timeout is the only clock.
    EditWaiters.wait(worktreeID: worktreeID, path: tabPath, command: self)
    return nil
  }
}

/// The suspended `edit … waiting true` replies, keyed by the tab identity the desk closes with.
/// The command objects are retained here — the one requirement `suspendExecution` documents —
/// and a rename moves a key with its tab, so a waited-on file that is renamed still resumes.
enum EditWaiters {
  private static var pending: [(worktreeID: UUID, path: String, command: NSScriptCommand)] = []

  static func wait(worktreeID: UUID, path: String, command: NSScriptCommand) {
    command.suspendExecution()
    pending.append((worktreeID, path, command))
  }

  static func fileClosed(worktreeID: UUID, path: String) {
    let done = pending.filter { $0.worktreeID == worktreeID && $0.path == path }
    guard !done.isEmpty else { return }
    pending.removeAll { $0.worktreeID == worktreeID && $0.path == path }
    for waiter in done { waiter.command.resumeExecution(withResult: "closed") }
  }

  static func fileRenamed(worktreeID: UUID, from: String, to: String) {
    pending = pending.map {
      $0.worktreeID == worktreeID && $0.path == from ? (worktreeID, to, $0.command) : $0
    }
  }
}
