import Foundation

/// The directories the files panel's tree has actually listed, kept so that a change on disk can
/// be turned into "these rows read differently" without asking the disk about rows nobody is
/// looking at.
///
/// It used to be the whole worktree, walked once when a repository opened and held from then on:
/// every directory's entries, plus a flattened list of every path for the filter and the content
/// search to match against. The walk's only bound was git's ignore rules, and git answers nothing
/// at all outside a repository — so a plain directory was walked to the bottom however large it
/// was, and the plain directory people actually open is the home directory. 4.56M entries here,
/// about 174 bytes each held: three quarters of a gigabyte spent because a window was opened. A
/// budget was the obvious answer and the wrong one — it is a number nobody can defend, and it
/// makes the filter quietly partial in a way the person then has to be told about.
///
/// What replaced it is not a smaller walk but no walk. The whole set of paths is wanted by
/// exactly two readers, the filter and the content search, and `Ripgrep` produces it per gesture:
/// streamed while it runs, dropped when the gesture ends. What is left here is the other half of
/// the old job, which nothing else does — the tree lists a directory as it opens it and hands the
/// listing back through `note`, so a later FSEvents batch is answered by re-listing exactly those
/// directories and saying which of them moved. It is bounded by what someone opened, which is a
/// bound nobody had to choose.
final class WorktreeIndex {
  struct Entry: Equatable {
    let name: String
    let isDirectory: Bool
  }

  let root: URL
  private let queue = DispatchQueue(label: "dev.tnayuki.hukan.worktree-index", qos: .userInitiated)
  private let lock = NSLock()
  /// Directory path (`""` for the root) → what was in it when it was last listed.
  private var directories: [String: [Entry]] = [:]
  /// Bumped on every change, so a reader holding rows built from a listing knows when it is
  /// stale.
  private var generationValue = 0

  init(root: URL) {
    self.root = root
  }

  var generation: Int {
    lock.lock()
    defer { lock.unlock() }
    return generationValue
  }

  /// What was in `directory` when it was last listed, or nil for one nobody has opened — which is
  /// the tree's cue to list it itself, and then to say so through `note`.
  func entries(of directory: String) -> [Entry]? {
    lock.lock()
    defer { lock.unlock() }
    return directories[directory]
  }

  /// The tree listed this directory; keep it, so a batch naming something inside it has something
  /// to be compared against. No generation bump: nothing reads differently for this, it is the
  /// reader telling the index what it has already drawn.
  func note(_ directory: String, entries: [Entry]) {
    lock.lock()
    directories[directory] = entries
    lock.unlock()
  }

  /// FSEvents named `moved`; list again the directories those paths sit in, on the queue, and
  /// hand back on the main queue which of them now read differently.
  ///
  /// nil is the wholesale question — a batch that could not be placed. There is nothing to
  /// compare against then, so the listings are dropped rather than re-read: the tree is told that
  /// everything may have moved, and lists again whatever it draws next. Keeping a listing that
  /// may be wrong is worse than keeping none, because the tree asks here first.
  func update(moved: Set<String>?, completion: @escaping (Set<String>?) -> Void) {
    guard let moved else {
      lock.lock()
      directories.removeAll()
      generationValue += 1
      lock.unlock()
      DispatchQueue.main.async { completion(nil) }
      return
    }
    let parents = Set(moved.map { ($0 as NSString).deletingLastPathComponent })
    queue.async { [self] in
      var changed: Set<String> = []
      for parent in parents {
        lock.lock()
        let before = directories[parent]
        lock.unlock()
        // Not a directory the tree has opened, so nothing was ever drawn from it.
        guard let before else { continue }
        guard let after = list(parent) else {
          // The directory itself is gone; its parent's relisting is what says so.
          remove(parent)
          changed.insert(parent)
          continue
        }
        guard after != before else { continue }
        lock.lock()
        directories[parent] = after
        generationValue += 1
        lock.unlock()
        changed.insert(parent)
      }
      DispatchQueue.main.async { completion(changed) }
    }
  }

  /// List `directory` again now, on the calling thread — for the panel's own write, whose row has
  /// to be there before the next line of code names it.
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

  /// One directory, off the disk. Everything under `.git` is the one thing left out, being the
  /// repository and not the worktree — and in a linked worktree a file, not a directory.
  ///
  /// `readdir` rather than `contentsOfDirectory`, for the one thing the directory entry already
  /// carries: whether the name is a directory. Foundation's answer to that is a `stat` per entry —
  /// a syscall per *file* in the directory, where the listing itself is one — and it was near half
  /// of what listing cost: 475ms against 257ms over 48,000 files. A link is still stat'd, because
  /// what matters about one is what it points at, and so is an entry on a filesystem that does not
  /// fill `d_type` in.
  static func list(_ url: URL) -> [Entry]? {
    guard let handle = opendir(url.path) else { return nil }
    defer { closedir(handle) }
    var entries: [Entry] = []
    while let found = readdir(handle) {
      let name = withUnsafePointer(to: &found.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(found.pointee.d_namlen) + 1) {
          String(cString: $0)
        }
      }
      guard name != ".", name != "..", name != ".git" else { continue }
      var isDirectory = found.pointee.d_type == DT_DIR
      if found.pointee.d_type == DT_LNK || found.pointee.d_type == DT_UNKNOWN {
        var info = stat()
        isDirectory =
          stat(url.appendingPathComponent(name).path, &info) == 0
          && (info.st_mode & S_IFMT) == S_IFDIR
      }
      entries.append(Entry(name: name, isDirectory: isDirectory))
    }
    return entries
  }

  private func list(_ directory: String) -> [Entry]? {
    Self.list(directory.isEmpty ? root : root.appendingPathComponent(directory))
  }

  /// Forget `directory` and everything under it — it has left the disk.
  private func remove(_ directory: String) {
    lock.lock()
    let prefix = directory + "/"
    for key in directories.keys where key == directory || key.hasPrefix(prefix) {
      directories.removeValue(forKey: key)
    }
    generationValue += 1
    lock.unlock()
  }
}
