import CoreServices
import Foundation

/// Watches a directory subtree and fires a coalesced callback whenever anything under it changes
/// on disk, saying which paths moved. The caller decides what that means and re-reads
/// accordingly, so ignored churn collapses into one cheap re-check the caller's own equality test
/// then discards — and a caller holding several files open re-reads only the ones named.
///
/// hukan observes, it does not act — so this only triggers a re-read, never a write. Two things
/// use it: one watcher per open worktree for the git working set (`Workspace.syncWatchers()`), and
/// one over Claude Code's per-process registry for the held-elsewhere state
/// (`Workspace.startSessionsRegistryWatcher()`).
final class DirectoryWatcher {
  private var stream: FSEventStreamRef?
  private let callback: ([String]) -> Void
  /// FSEvents delivers on this queue; the callback hops to main itself. Also the fence deinit
  /// drains, so a teardown cannot race a callback already in flight.
  private let queue = DispatchQueue(label: "com.hukan.directory-watcher", qos: .utility)
  /// Set on `queue` so deinit can tell whether it is already running there. Per instance, not
  /// static: one watcher's deinit landing on *another* watcher's queue is a real fence that must
  /// still be drained, and a shared key could not tell the two apart.
  private let queueKey = DispatchSpecificKey<Void>()

  init(url: URL, onChange: @escaping ([String]) -> Void) {
    self.callback = onChange

    queue.setSpecific(key: queueKey, value: ())

    var context = FSEventStreamContext()
    context.info = Unmanaged.passUnretained(self).toOpaque()

    // 0.3s latency lets a burst of writes coalesce into one callback. NoDefer delivers the
    // first event promptly and coalesces the rest; IgnoreSelf drops events hukan's own reads
    // raise (another process's writes — a session's edits, another claude registering itself —
    // are never self and still come through). WatchRoot is deliberately *not* set: it would
    // monitor every ancestor up to the volume root — holding a directory handle on the home
    // directory and above — only to notice the watched directory itself being renamed, which the
    // callers' own refresh paths already catch. Watching the subtree is all the live update needs.
    // FileEvents reports the file that moved rather than the directory holding it, which is what
    // lets a caller re-read one open file instead of all of them. It raises the event count —
    // the coalescing above is what pays for that — and the exchange is worth it: without a path,
    // one agent write meant re-reading and re-parsing every file on the desk.
    let flags = UInt32(
      kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        | kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagFileEvents)

    guard
      let stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        { _, info, count, eventPaths, _, _ in
          guard let info else { return }
          let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
          // UseCFTypes is set, so this is a CFArray of CFStrings rather than a C string array.
          let paths =
            (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String])
            ?? []
          _ = count
          DispatchQueue.main.async { watcher.callback(paths) }
        },
        &context,
        [url.path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.3,
        flags)
    else {
      // A directory that cannot be watched (it may not exist yet) simply misses live updates;
      // the callers' refresh paths still catch it, so this is a graceful degrade, not a failure.
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
    // unretained pointer back to us can never read freed memory.
    //
    // Unless deinit is *on* that queue, which it can be. The callback takes the watcher
    // unretained and then captures it strongly for the hop to main; if that main-queue block has
    // already run and dropped its reference, and nothing else holds one, the release of the
    // callback's own local is the last one — and it happens on this queue, so deinit runs here.
    // `dispatch_sync` onto the queue it is already on is not a deadlock but an abort, and it was
    // reachable: a worktree leaving drops its watcher while its events are still in flight, which
    // is what `WorktreeSyncTests` does and what crashed it. There is nothing to wait for in that
    // case anyway — the queue is serial, so the callback we are inside is the only one that can
    // be running, and `FSEventStreamInvalidate` above has already stopped any more arriving.
    if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
  }
}
