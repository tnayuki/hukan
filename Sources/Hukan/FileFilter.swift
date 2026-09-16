import Foundation

/// The rows a typed query narrows the files panel's tree to: one `rg` per query, streamed as it
/// walks and killed when the next keystroke replaces it.
///
/// Nothing is held between questions. A filter with text in it and a content search are the only
/// two readers of a worktree's whole path set, and both begin with someone typing — so the walk
/// starts when one of them asks, and what it found goes when the field empties or the worktree
/// changes. That is what lets a directory of any size be opened for nothing at all; see
/// `WorktreeIndex` for what replaced the walk that used to run on open.
///
/// The matching is rg's own (see `Ripgrep.files(in:matching:…)`), which is why nothing here holds
/// the paths that did not match: on a home directory that is 1.56M paths the process never hands
/// over. What it costs is that every keystroke walks again — 0.03s on this checkout, 10s on a
/// home directory — where holding the walk would have made the second keystroke free and the
/// first one 170MB.
final class FileFilter {
  /// What the panel draws: the paths that matched so far, byte-sorted, and whether the walk
  /// behind them has finished — the second so a note can say the answer is still growing rather
  /// than empty.
  struct Snapshot {
    let matches: [String]
    let isComplete: Bool
  }

  let query: String
  private let publish: (Snapshot) -> Void
  private let queue = DispatchQueue(label: "dev.tnayuki.hukan.file-filter", qos: .userInitiated)
  /// ~7 publishes a second while a walk streams: enough that a filter fills in visibly, few
  /// enough that the main queue is not rebuilding a tree under the reader's hands.
  private static let publishInterval: TimeInterval = 0.15

  // Touched on `queue` alone.
  private var matches: [String] = []
  private var walkFinished = false
  private var publishScheduled = false

  private var run: Ripgrep.Run?

  /// Start the walk. `publish` lands on the main queue, at most every `publishInterval` while it
  /// streams and once more when it ends.
  init(root: URL, query: String, publish: @escaping (Snapshot) -> Void) {
    self.query = query
    self.publish = publish
    run = Ripgrep.files(
      in: root, matching: query, on: queue,
      batch: { [weak self] chunk in self?.took(chunk) },
      completion: { [weak self] finished in self?.finished(finished) })
  }

  deinit { run?.cancel() }

  /// Stop the walk. The gesture is over, or the worktree on screen is not the one being walked.
  func cancel() {
    run?.cancel()
    run = nil
  }

  private func took(_ chunk: Data) {
    // A path becomes a string only because it matched: what rg hands over here is already the
    // answer, so there is no set of rejects to pay for.
    matches.append(
      contentsOf: chunk.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
    publishSoon()
  }

  private func finished(_ finished: Bool) {
    walkFinished = finished
    run = nil
    publishNow()
  }

  private func publishSoon() {
    guard !publishScheduled else { return }
    publishScheduled = true
    queue.asyncAfter(deadline: .now() + Self.publishInterval) { [weak self] in
      self?.publishScheduled = false
      self?.publishNow()
    }
  }

  private func publishNow() {
    // Sorted here rather than where it is drawn: `FileTree` finds a directory's block by binary
    // search and so needs byte order, and this is the thread that can afford it. rg is asked to
    // walk in parallel rather than in path order, which is three times faster on a large tree —
    // so the order is put back over what matched, which is the short list.
    let snapshot = Snapshot(
      matches: matches.sorted(by: FileTree.precedesBytewise), isComplete: walkFinished)
    DispatchQueue.main.async { [publish] in publish(snapshot) }
  }
}
