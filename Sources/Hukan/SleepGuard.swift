import AppKit

/// Keep the Mac awake while any agent is mid-turn. The whole point of running agents in parallel
/// is to leave and come back to progress — but a machine that idles to sleep suspends every
/// `claude` with it, so an hour away buys nothing. Hold a power assertion for as long as one
/// session is thinking, and drop it the moment none are.
///
/// `.idleSystemSleepDisabled` blocks only the idle timeout, not a deliberate sleep (closing the
/// lid still sleeps) — hukan should not fight the user's own decision to put the machine down, only
/// keep it from nodding off on its own while there is work in flight.
final class SleepGuard {
  static let shared = SleepGuard()

  private var activity: NSObjectProtocol?

  /// Re-evaluate against the live session list across every window. Cheap enough to call on each
  /// state change: it only flips the assertion when the "any thinking" answer actually changes.
  func refresh() {
    let anyThinking = WorkspaceWindowController.all.contains { controller in
      controller.workspace.sessions.contains { $0.isTurnActive }
    }
    if anyThinking, activity == nil {
      activity = ProcessInfo.processInfo.beginActivity(
        options: .idleSystemSleepDisabled,
        reason: "An agent is working")
    } else if !anyThinking, let token = activity {
      ProcessInfo.processInfo.endActivity(token)
      activity = nil
    }
  }
}
