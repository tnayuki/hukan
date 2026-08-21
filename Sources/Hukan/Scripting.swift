import AppKit
import ScreenCaptureKit

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

/// The object a command's by-name parameter names. Targets are always by-name parameters, never the
/// direct parameter: an object direct-parameter makes AppleScript treat that object as the receiver,
/// which no proxy answers (-1708).
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
private func guardedScriptingEnabled() -> Bool {
  ProcessInfo.processInfo.environment["HUKAN_SCRIPTING_GUARDED"] == "1"
}

@objc(SendCommand)
final class SendCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let text = directParameter as? String else { return fail("a message is required") }
    guard let proxy = argument("toSession", as: SDSession.self),
      let session = proxy.agentSession
    else { return fail("no such session") }
    // Reattach a detached session before sending — the one addressed, not the selected one.
    proxy.controller?.reattachIfNeeded(session)
    guard session.isRunning else { return fail("session is not running") }
    session.send(text)
    return "ok"
  }
}

private func resolveApproval(_ command: NSScriptCommand, allow: Bool) -> Any? {
  guard guardedScriptingEnabled() else { return command.fail("approvals are not scriptable") }
  guard let proxy = command.argument("onSession", as: SDSession.self),
    let session = proxy.agentSession
  else { return command.fail("no such session") }
  guard session.pendingApproval != nil else { return command.fail("nothing to approve") }
  session.resolveApproval(allow: allow)
  proxy.controller?.reload()
  return allow ? "allowed" : "denied"
}

@objc(ApproveCommand)
final class ApproveCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? { resolveApproval(self, allow: true) }
}

@objc(DenyCommand)
final class DenyCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? { resolveApproval(self, allow: false) }
}

@objc(RestartCommand)
final class RestartCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
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

@objc(ScreenshotCommand)
final class ScreenshotCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let path = argument("toPath", as: String.self) else { return fail("a path is required") }
    // Resolve the window synchronously, before suspending: specifier evaluation must stay on the
    // main thread; only the capture is async.
    guard let window = argument("inWindow", as: NSWindow.self) ?? frontWorkspaceWindow() else {
      return fail("no window")
    }
    // Capture through ScreenCaptureKit, not the view hierarchy: this is what carries the
    // bundle's screen-recording grant (anchored by the stable signature), so it succeeds where
    // a terminal `screencapture` comes back black. It also captures exactly what is on screen,
    // AppKit-drawn group disclosures and all — which a cacheDisplay of the content view misses.
    // (CGWindowListCreateImage, the one-call way to do this, was obsoleted in macOS 15.)
    let windowID = CGWindowID(window.windowNumber)
    let scale = window.backingScaleFactor
    // SCScreenshotManager is async; NSScriptCommand suspends and resumes so osascript blocks
    // until the file is written rather than returning before the capture lands.
    suspendExecution()
    // The command outlives this method until resumed; NSScriptCommand isn't Sendable, but
    // resumeExecution(withResult:) is documented safe from any thread, so hand it across.
    nonisolated(unsafe) let command = self
    Task {
      do {
        let result = try await Self.capture(windowID: windowID, scale: scale, to: path)
        command.resumeExecution(withResult: result)
      } catch {
        // A script error across the suspension: set it on the main thread (where Cocoa
        // scripting lives), then resume with no result — the reply event carries the error.
        DispatchQueue.main.async {
          command.fail(error.localizedDescription)
          command.resumeExecution(withResult: nil)
        }
      }
    }
    return nil
  }

  /// A capture failure whose message is meant for the script error string.
  private struct CaptureError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }

  private static func capture(windowID: CGWindowID, scale: CGFloat, to path: String) async throws
    -> String
  {
    let content = try await SCShareableContent.current
    guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
      throw CaptureError("window not in shareable content (screen-recording permission for hukan?)")
    }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    config.width = Int(window.frame.width * scale)
    config.height = Int(window.frame.height * scale)
    config.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: config)
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else {
      throw CaptureError("could not encode png")
    }
    try data.write(to: URL(fileURLWithPath: path))
    return "\(image.width)x\(image.height) -> \(path)"
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

@objc(StatusCommand)
final class StatusCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
    guard let controller = frontController() else { return fail("no window") }
    let workspace = controller.workspace
    let groups = workspace.groupedEntries
    guard !groups.isEmpty else { return "(no worktrees)" }
    // Mirror the rail: grouped by repository, rows in the rail's own order (last-instructed
    // first). The "… ago" is last activity (`updatedAt`), not the sort key, so a row can read
    // fresher than the ones above it.
    let now = Date()
    let selected = workspace.selectedSession?.id
    return groups.map { group -> String in
      let rows = group.entries.map { entry -> String in
        let (session, worktree) = (entry.session, entry.worktree)
        let marker = session.id == selected ? "*" : " "
        let state =
          session.isDetached
          ? "detached"
          : (session.isRunning ? session.state.rawValue : "\(session.state.rawValue)(stopped)")
        let stat = worktree.diffstat
        let title = session.title ?? "New session"
        return
          "  \(marker) \(title)  (\(worktree.displayName))  [\(state)]  +\(stat.added) -\(stat.removed)  \(Self.ago(from: session.updatedAt, to: now))"
      }
      return ([group.repositoryName] + rows).joined(separator: "\n")
    }.joined(separator: "\n")
  }

  /// A compact "how long ago" for the rail's sort key. `.distantPast` (never active) reads as "—".
  private static func ago(from date: Date, to now: Date) -> String {
    guard date != .distantPast else { return "—" }
    let seconds = max(Int(now.timeIntervalSince(date)), 0)
    switch seconds {
    case ..<60: return "\(seconds)s"
    case ..<3600: return "\(seconds / 60)m"
    case ..<86400: return "\(seconds / 3600)h"
    default: return "\(seconds / 86400)d"
    }
  }
}
