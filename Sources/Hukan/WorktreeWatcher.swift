import CoreServices
import Foundation

/// Watches a worktree's directory subtree and fires a coalesced callback whenever anything
/// under it changes on disk — an agent's edit, a terminal command, an external editor, a git
/// operation. It reports only "something moved"; the caller re-asks git what that means, so
/// ignored churn (a build writing into `node_modules` or `.build`) collapses into one cheap
/// query whose result the equality check then discards. Watching git's own directory too is
/// deliberate: a commit made by a session shrinks the changed set, and that is a change worth
/// noticing the same as an edit.
///
/// hukan observes worktrees, it does not act on them — so this only triggers a re-read, never a
/// write. One watcher lives per open worktree, reconciled by `Workspace.syncWatchers()`.
final class WorktreeWatcher {
  private var stream: FSEventStreamRef?
  private let callback: () -> Void
  /// FSEvents delivers on this queue; the callback hops to main itself. Also the fence deinit
  /// drains, so a teardown cannot race a callback already in flight.
  private let queue = DispatchQueue(label: "com.hukan.worktree-watcher", qos: .utility)

  init(url: URL, onChange: @escaping () -> Void) {
    self.callback = onChange

    var context = FSEventStreamContext()
    context.info = Unmanaged.passUnretained(self).toOpaque()

    // 0.3s latency lets a burst of writes coalesce into one callback. NoDefer delivers the
    // first event promptly and coalesces the rest; IgnoreSelf drops events hukan's own reads
    // raise (a session runs in a separate process, so its edits are never self and still come
    // through). WatchRoot is deliberately *not* set: it would monitor every ancestor of the
    // worktree up to the volume root — holding a directory handle on the home directory and
    // above — only to notice the worktree itself being renamed, which the focus-time refresh
    // already catches. Watching the subtree is all the live update needs.
    let flags = UInt32(
      kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        | kFSEventStreamCreateFlagIgnoreSelf)

    guard
      let stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        { _, info, _, _, _, _ in
          guard let info else { return }
          let watcher = Unmanaged<WorktreeWatcher>.fromOpaque(info).takeUnretainedValue()
          DispatchQueue.main.async { watcher.callback() }
        },
        &context,
        [url.path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.3,
        flags)
    else {
      // A worktree that cannot be watched simply misses live updates; the focus-time refresh
      // still catches it, so this is a graceful degrade, not a failure.
      return
    }

    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, queue)
    FSEventStreamStart(stream)
  }

  deinit {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    // Fence: any callback already dequeued on `queue` finishes before self is gone, so its
    // unretained pointer back to us can never read freed memory. Safe because deinit runs off
    // this queue (the watcher is released from the main thread), so the sync cannot deadlock.
    queue.sync {}
  }
}
