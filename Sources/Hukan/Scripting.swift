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
/// cannot assert.
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
    return panel.report
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
