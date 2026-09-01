import AppKit
import UserNotifications

/// macOS notifications for the one moment a session becomes your turn — an agent blocking on an
/// approval or asking a question. That is the point the design's whole promise turns on: "come
/// back after an hour and clear what is waiting on you", and a notification is what pulls you back
/// before the hour is up. A turn merely finishing is deliberately silent — it is not blocked on
/// you, so a banner for it would train you to ignore the ones that are.
///
/// It fires *only while hukan is not the active app*. In front of the rail you already see every
/// session's state at a glance, so a notification for what the badge is already showing is noise —
/// and a banner is not modal, so it never covers the other sessions the way a dialog would.
///
/// State transitions are read off `onStateChange`, which fires for many unrelated reasons (model
/// updates, queueing, history load). A per-session snapshot diffs that down to the handful of
/// transitions worth a banner.
final class SessionNotifier: NSObject, UNUserNotificationCenterDelegate {
  static let shared = SessionNotifier()

  private enum PendingKind { case none, approval, question }
  private struct Snapshot {
    let state: RunState
    let kind: PendingKind
  }
  private var snapshots: [UUID: Snapshot] = [:]

  /// UNUserNotificationCenter needs a real `.app` bundle proxy; requesting authorization from the
  /// bare binary throws. Guard so that still runs.
  private let isBundled = Bundle.main.bundleURL.pathExtension == "app"
  private var center: UNUserNotificationCenter? { isBundled ? .current() : nil }

  func requestAuthorization() {
    guard let center else { return }
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  /// React to a session after an `onStateChange`. The first sighting of a session only records a
  /// baseline — `start()` flips it to `.running` and fires `onStateChange` before any turn, so
  /// that first call is what seeds the snapshot and nothing is announced for merely opening one.
  func observe(_ session: AgentSession, worktreeName: String?) {
    let kind: PendingKind =
      session.pendingApproval != nil
      ? .approval
      : session.pendingQuestion != nil ? .question : .none
    let now = Snapshot(state: session.state, kind: kind)
    defer { snapshots[session.id] = now }
    guard let prev = snapshots[session.id] else { return }

    // No longer waiting on you: pull the session's banner back out of Notification Center, so a
    // stale "承認が必要です" does not sit there after you have already dealt with it — whether you
    // resolved it in the app or the agent moved on. Keyed by session id like the post, and done
    // regardless of whether hukan is active (you may have answered it in-app).
    if kind == .none, prev.kind != .none {
      center?.removeDeliveredNotifications(withIdentifiers: [session.id.uuidString])
    }

    // Suppressed while you are watching the rail; only the away case earns a banner.
    guard !NSApp.isActive else { return }

    let name = session.title ?? worktreeName ?? "hukan"
    switch now.state {
    case .needsAttention where prev.state != .needsAttention || prev.kind != kind:
      switch kind {
      case .approval:
        post(session, title: name, subtitle: worktreeName, body: "承認が必要です")
      case .question:
        post(
          session, title: name, subtitle: worktreeName,
          body: session.pendingQuestion?.current.question ?? "確認があります")
      case .none:
        break
      }
    default:
      break
    }
  }

  private func post(_ session: AgentSession, title: String, subtitle: String?, body: String) {
    guard let center else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    // Only add the worktree line when it is not already the title (an unnamed session shows
    // the worktree as its title, so repeating it below would be redundant).
    if let subtitle, subtitle != title { content.subtitle = subtitle }
    content.body = body
    content.sound = .default
    content.userInfo = ["session": session.id.uuidString]
    // One identifier per session, so a newer banner replaces the session's older one rather
    // than stacking — the rail shows one row per session, and Notification Center should too.
    let request = UNNotificationRequest(
      identifier: session.id.uuidString, content: content, trigger: nil)
    center.add(request)
  }

  // Tapping a banner is the same move as Cmd+Return: jump to the session that wants you.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let raw = response.notification.request.content.userInfo["session"] as? String,
      let id = UUID(uuidString: raw)
    {
      DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        Self.whenActive { WorkspaceWindowController.focusSession(id: id) }
      }
    }
    completionHandler()
  }

  /// Run once the activation has actually landed, because the activation is itself a window
  /// order: macOS fronts whichever window was key last, and anything ordered ahead of that is
  /// overwritten by it. On one Space the loss is invisible — the window we asked for is on
  /// screen either way — so this only ever showed up where the windows are spread across Spaces,
  /// which is what a window per repository amounts to: the tapped session's window would come
  /// forward, its Space with it, and a beat later the whole thing was dragged back to the Space
  /// you had been on, landing on a window with nothing to do with the banner. Measured against a
  /// standalone app rather than reasoned about, since the two orderings are indistinguishable
  /// until a Space is in the way.
  private static func whenActive(_ body: @escaping () -> Void) {
    guard !NSApp.isActive else { return body() }
    var token: NSObjectProtocol?
    token = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
      if let token { NotificationCenter.default.removeObserver(token) }
      body()
    }
  }
}
