import Foundation

/// The worktree's directories as they are on disk, held in memory and kept there: one entry list
/// per directory, read by a walk on a background queue and re-read a directory at a time as
/// FSEvents names something in it. The files panel's tree reads its rows off this rather than
/// off the disk, so opening a row costs nothing on the main thread once the walk has been past
/// it — and the filter and the content search read their universe off it too, which is what
/// makes them the same set of files the tree shows.
///
/// The walk does not go into a directory git ignores. Those are on the tree, dimmed, and open on
/// demand (the tree lists one itself when the index has no answer), but they are not walked:
/// a dependency directory is a hundred thousand files nobody wants filtered or searched, and
/// walking it would cost more than the rest of the checkout together — measured at 566ms for the
/// whole disk of a 14,500-file checkout, ignore rules applied from outside libgit2, against the
/// 107ms the working-tree diff spends applying them inside. An ignored *file* in a plain directory
/// is walked with its neighbours — it is one file, and a plain directory is where a person's own
/// `.env` or a stray log lives. Which directories git ignores is asked once
/// per listing, for the directories that listing holds; it is the one thing about the index git
/// is asked at all.
///
/// Measured on a 14,500-file checkout with 3,300 directories: the walk is 235ms on its queue, of
/// which about 90ms is git's ignore answers at 27µs each (see `walk` for why not 330ms more), once
/// per worktree; after that a batch costs the directories it touched, plus the flattening the
/// filter reads (`filePaths`).
final class WorktreeIndex {
  struct Entry: Equatable {
    let name: String
    let isDirectory: Bool
  }

  let root: URL
  private let queue = DispatchQueue(label: "dev.tnayuki.hukan.worktree-index", qos: .userInitiated)
  private let lock = NSLock()
  /// Directory path (`""` for the root) → what is directly in it.
  private var directories: [String: [Entry]] = [:]
  private var ignoredDirectories: Set<String> = []
  /// Bumped on every change, so a reader holding a flattened copy knows when it is stale.
  private var generationValue = 0
  private var isBuiltValue = false
  /// The flattening, kept until the next change: the filter asks per keystroke, and 25,000
  /// entries walked per keystroke is what the git-list cache existed to avoid.
  private var filePathsCache: (generation: Int, paths: [String])?
  /// Which directories git ignores, asked per listing. Given rather than called directly so a
  /// test can index a plain directory with no git behind it.
  private let ignored: (_ directories: [String]) -> Set<String>

  init(root: URL, ignored: @escaping (_ directories: [String]) -> Set<String>) {
    self.root = root
    self.ignored = ignored
  }

  var generation: Int {
    lock.lock()
    defer { lock.unlock() }
    return generationValue
  }

  /// The walk has been to the bottom at least once.
  var isBuilt: Bool {
    lock.lock()
    defer { lock.unlock() }
    return isBuiltValue
  }

  /// What is directly in `directory`, or nil if the walk has not been there — which is the tree's
  /// cue to list it itself.
  func entries(of directory: String) -> [Entry]? {
    lock.lock()
    defer { lock.unlock() }
    return directories[directory]
  }

  func isIgnoredDirectory(_ path: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return ignoredDirectories.contains(path)
  }

  /// Every file the walk found, byte-sorted the way `FileTree` wants its input. Flattened on the
  /// queue after every change (39ms for 14,500 files, which is not a cost for the main thread to
  /// pay per batch while an agent writes) and kept; a reader ahead of that flattening — the first
  /// ask, in practice — does it here.
  var filePaths: [String] {
    lock.lock()
    if let cache = filePathsCache, cache.generation == generationValue {
      lock.unlock()
      return cache.paths
    }
    let snapshot = (directories, ignoredDirectories, generationValue)
    lock.unlock()
    return flatten(snapshot.0, ignored: snapshot.1, generation: snapshot.2)
  }

  /// Flatten a snapshot, off the lock, and keep the result if the index has not moved since.
  @discardableResult
  private func flatten(
    _ directories: [String: [Entry]], ignored: Set<String>, generation: Int
  ) -> [String] {
    var paths: [String] = []
    func walk(_ directory: String) {
      for entry in directories[directory] ?? [] {
        let path = directory.isEmpty ? entry.name : "\(directory)/\(entry.name)"
        if entry.isDirectory {
          if !ignored.contains(path) { walk(path) }
        } else {
          paths.append(path)
        }
      }
    }
    walk("")
    paths.sort(by: FileTree.precedesBytewise)
    lock.lock()
    if generation == generationValue { filePathsCache = (generation, paths) }
    lock.unlock()
    return paths
  }

  /// The flattening the queue does after each change, from a snapshot so the lock is not held
  /// for it.
  private func flattenLatest() {
    lock.lock()
    let snapshot = (directories, ignoredDirectories, generationValue)
    lock.unlock()
    flatten(snapshot.0, ignored: snapshot.1, generation: snapshot.2)
  }

  /// Walk the whole worktree, on the queue. `completion` lands on the main queue.
  func build(completion: @escaping () -> Void) {
    queue.async { [self] in
      var fresh: [String: [Entry]] = [:]
      var freshIgnored: Set<String> = []
      walk("", into: &fresh, ignored: &freshIgnored)
      lock.lock()
      directories = fresh
      ignoredDirectories = freshIgnored
      generationValue += 1
      isBuiltValue = true
      lock.unlock()
      flattenLatest()
      DispatchQueue.main.async(execute: completion)
    }
  }

  /// FSEvents named `moved`; list again the directories they sit in, on the queue, and hand back
  /// on the main queue which directories the index now reads differently for — nil for all of
  /// them, which is what a batch that could not be placed (one that reached into `.git`) costs.
  /// A directory that appeared is walked; one that went takes its subtree out of the index.
  func update(moved: Set<String>?, completion: @escaping (Set<String>?) -> Void) {
    guard let moved else {
      build { completion(nil) }
      return
    }
    let parents = Set(moved.map { ($0 as NSString).deletingLastPathComponent })
    queue.async { [self] in
      var changed: Set<String> = []
      for parent in parents {
        lock.lock()
        let before = directories[parent]
        let parentKnown = before != nil
        let parentIgnored = ignoredDirectories.contains(parent)
        lock.unlock()
        // Not yet walked — inside an ignored directory, or not there when the walk went past —
        // and not the tree's business to have indexed; it lists such a directory itself.
        guard parentKnown, !parentIgnored else { continue }
        guard let after = list(parent) else {
          // The directory itself is gone; its parent's relisting is what says so.
          remove(parent)
          changed.insert(parent)
          continue
        }
        var fresh: [String: [Entry]] = [:]
        var freshIgnored: Set<String> = []
        let ignoredHere = ignored(
          after.filter(\.isDirectory).map { parent.isEmpty ? $0.name : "\(parent)/\($0.name)" })
        // A directory that is new to the listing is walked in; one that stayed keeps its subtree.
        let known = Set((before ?? []).map(\.name))
        for entry in after where entry.isDirectory && !known.contains(entry.name) {
          let path = parent.isEmpty ? entry.name : "\(parent)/\(entry.name)"
          if ignoredHere.contains(path) {
            freshIgnored.insert(path)
          } else {
            walk(path, into: &fresh, ignored: &freshIgnored)
          }
        }
        lock.lock()
        for entry in before ?? [] where entry.isDirectory && !after.contains(entry) {
          removeLocked(parent.isEmpty ? entry.name : "\(parent)/\(entry.name)")
        }
        directories[parent] = after
        directories.merge(fresh) { _, new in new }
        ignoredDirectories.formUnion(freshIgnored)
        for path in ignoredHere { ignoredDirectories.insert(path) }
        generationValue += 1
        lock.unlock()
        changed.insert(parent)
      }
      if !changed.isEmpty { flattenLatest() }
      DispatchQueue.main.async { completion(changed) }
    }
  }

  /// List `directory` again now, on the calling thread — for the panel's own write, whose row
  /// has to be there before the next line of code names it. One directory, no subtree: what a
  /// New File or a rename adds to a directory is the entry itself, and a directory that moved is
  /// walked by `update`, which the caller also runs.
  func refreshNow(_ directory: String) {
    lock.lock()
    let known = directories[directory] != nil
    lock.unlock()
    guard known, let entries = list(directory) else { return }
    lock.lock()
    directories[directory] = entries
    generationValue += 1
    lock.unlock()
  }

  /// List `directory` and everything under it that git does not ignore, into `into`. Breadth
  /// first, so git is asked once per level about every directory found on it rather than once
  /// per directory: an ask opens the repository, and 3,300 opens were 330ms of a walk that is
  /// otherwise 75ms.
  private func walk(
    _ directory: String, into: inout [String: [Entry]], ignored ignoredOut: inout Set<String>
  ) {
    var frontier = [directory]
    while !frontier.isEmpty {
      var subdirectories: [String] = []
      for parent in frontier {
        guard let entries = list(parent) else { continue }
        into[parent] = entries
        for entry in entries where entry.isDirectory {
          subdirectories.append(parent.isEmpty ? entry.name : "\(parent)/\(entry.name)")
        }
      }
      guard !subdirectories.isEmpty else { return }
      let ignoredHere = ignored(subdirectories)
      ignoredOut.formUnion(ignoredHere)
      frontier = subdirectories.filter { !ignoredHere.contains($0) }
    }
  }

  /// One directory, off the disk. Everything under `.git` is the one thing left out, being the
  /// repository and not the worktree — and in a linked worktree a file, not a directory.
  static func list(_ url: URL) -> [Entry]? {
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
    else { return nil }
    return urls.compactMap { entry in
      let name = entry.lastPathComponent
      guard name != ".git" else { return nil }
      let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      return Entry(name: name, isDirectory: isDirectory)
    }
  }

  private func list(_ directory: String) -> [Entry]? {
    Self.list(directory.isEmpty ? root : root.appendingPathComponent(directory))
  }

  private func remove(_ directory: String) {
    lock.lock()
    removeLocked(directory)
    generationValue += 1
    lock.unlock()
  }

  private func removeLocked(_ directory: String) {
    let prefix = directory + "/"
    for key in directories.keys where key == directory || key.hasPrefix(prefix) {
      directories[key] = nil
    }
    ignoredDirectories = ignoredDirectories.filter { $0 != directory && !$0.hasPrefix(prefix) }
  }
}
