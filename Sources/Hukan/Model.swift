import AppKit
import Foundation

/// Buffer identity is (Worktree, relative path). Keying on the absolute path splits the same
/// file in two worktrees of one repository into two unrelated buffers, which kills
/// "put main and feature side by side". Practically impossible to retrofit later.
struct BufferKey: Hashable {
  let worktreeID: UUID
  let relativePath: String
}

enum RunState: String {
  case idle
  case running
  case needsAttention
  /// The engine failed to initialize because the account is signed out. Terminal like `.idle`
  /// (no turn is running), but it is not a state the agent can leave on its own — the fix is
  /// `/login`, which the composer intercepts and runs in a real terminal.
  case signedOut
  /// The turn ended on an error result (`result` with a non-`success` subtype — hit the max
  /// turns, a tool errored out, the engine gave up). Terminal like `.idle`, but a failure is
  /// not a "done", so it must not read as the green check: the whole point of the rail is to
  /// tell a turn that succeeded from one that did not at a glance.
  case failed

  var badge: String {
    switch self {
    case .idle: return "✓"
    case .running: return "⏳"
    case .needsAttention: return "!"
    case .signedOut: return "⚠"
    case .failed: return "✕"
    }
  }
}

/// How much of the agent's turn reaches the approval card. This is the lever the whole
/// design turns on: in a general editor it is a convenience, but here it decides which of the
/// parallel sessions interrupt you. An agent you trust on its task should not be generating
/// approvals at all.
///
/// These are Claude Code's own modes, passed at launch as `--permission-mode` and switched
/// live with a `set_permission_mode` control_request. `manual` is deliberately absent — it
/// fails tools instead of prompting, which is not an approval channel (see the charter).
///
/// `auto` is the engine's newer decide-per-tool mode. It sits behind a rollout gate: when the
/// gate is off the engine answers `set_permission_mode:auto` by falling back to `default`
/// (verified in the 2.1.212 dispatch). Offering it is safe either way — it works where the gate
/// is on and degrades to Ask where it is not.
enum PermissionMode: String, CaseIterable {
  case `default`
  case acceptEdits
  case auto
  case plan
  case bypassPermissions

  /// Short label for the picker. Wording tracks Claude Code so the mode reads the same here
  /// as in the CLI's own indicator.
  var label: String {
    switch self {
    case .default: return "Ask"
    case .acceptEdits: return "Auto-accept edits"
    case .auto: return "Auto"
    case .plan: return "Plan"
    case .bypassPermissions: return "Bypass"
    }
  }
}

/// A git repository: the open/close unit. Its identity is the path git's common dir sits under
/// (what `Git.repository(at:)` returns), shared by every worktree of it — grouping on the
/// display name alone would merge two different repositories that happen to be called the same
/// thing. The worktrees are enumerated from git and arrive with the repository; the type holds
/// nothing git does not, so there is no second copy of anything that can drift from git.
final class Repository {
  let id: String
  var worktrees: [Worktree] = []

  init(id: String) { self.id = id }

  var name: String { (id as NSString).lastPathComponent }
}

final class Worktree {
  let id: UUID
  let url: URL
  var branch: String?
  /// The repository this worktree belongs to. A back-reference, not a copy: the id and name
  /// read straight off it, so two worktrees of one repository can never disagree on either.
  /// Unowned because the repository owns the worktree (`Repository.worktrees`) and outlives it.
  unowned let repository: Repository
  var repositoryID: String { repository.id }
  var repositoryName: String { repository.name }

  /// Working tree changes. The diffstat belongs to the worktree, not to a session.
  var changedFiles: [ChangedFile] = []
  var trackedFiles: [String] = []
  /// The worktree's directories as they are on disk, walked once in the background and kept in
  /// step with FSEvents — what the files panel's tree, filter and search read. Built when the
  /// worktree is first selected; nil until then, where the panel lists the disk itself.
  var index: WorktreeIndex?
  /// What this worktree has committed past its base branch — the History section's list. Read on
  /// the same tick as the changed files, since the commit that empties one fills the other.
  var history = Git.History()
  /// Whether git has anything to say about this path at all — it tracks it, or it is already
  /// counted as changed. An ignored file is neither, which is what the question is for: a build
  /// writing into its output directory must not reload the window, while a file being edited
  /// must reach the tab showing it even on a write git measures identically.
  ///
  /// `trackedFiles` is git-index order, which is byte order, so this is a binary search rather
  /// than a walk of 400,000 strings per batch.
  func isKnownToGit(_ path: String) -> Bool {
    if changedFiles.contains(where: { $0.path == path }) { return true }
    var low = 0
    var high = trackedFiles.count
    while low < high {
      let middle = (low + high) / 2
      if FileTree.precedesBytewise(trackedFiles[middle], path) {
        low = middle + 1
      } else {
        high = middle
      }
    }
    return low < trackedFiles.count && trackedFiles[low] == path
  }

  /// The stamp of the newest read whose answer this worktree has taken. A read that started
  /// before it read the disk earlier, so its answer is the older one however it finished, and it
  /// is dropped rather than written over the newer. Two reads do overlap: `loadFiles` and
  /// `refreshFiles` have gates of their own, so a first read of a large worktree — seconds of
  /// it — runs while the batches an agent's writes raise are answered beside it, and the slow
  /// one landing last used to put the worktree back as it was before them.
  var readStamp = 0

  /// Where HEAD and the index stood when the last refresh read them — what decides whether that
  /// refresh reports "everything moved" or only the paths it saw move. nil until the first read.
  var measurementBase: Git.MeasurementBase?
  /// How far back the History section has been scrolled, in commits. It lives here rather than in
  /// the panel because every re-read goes through the worktree — a commit landing, a branch
  /// moving — and each of those has to return what has already been paged in rather than the
  /// first page.
  var historyLimit = Git.historyPage
  /// Whether the file list has ever been read, which is what gates *drawing* the tree — so it is
  /// set once and never cleared. Wanting a re-read is `needsFileReload`, deliberately a second
  /// flag: clearing this one to force a refresh blanked the rail's file tree until the query came
  /// back, which is the flicker a rebase (a branch move per commit) made impossible to miss.
  var hasLoadedFiles = false
  /// Set when something invalidated the file list wholesale — a branch move — so the next reload
  /// re-queries git. The old list stays on screen until the new one lands.
  var needsFileReload = false

  init(id: UUID = UUID(), url: URL, branch: String? = nil, repository: Repository) {
    self.id = id
    self.url = url
    self.branch = branch
    self.repository = repository
  }

  var displayName: String { branch ?? url.lastPathComponent }

  /// The repository's primary checkout — the common dir's parent, which is the repository's own
  /// id. It is the default worktree, so the rail folds it into the repository heading itself;
  /// only the linked worktrees (git worktree add) earn a heading of their own.
  var isMain: Bool {
    url.standardizedFileURL.path == URL(fileURLWithPath: repository.id).standardizedFileURL.path
  }

  var diffstat: (added: Int, removed: Int) {
    changedFiles.reduce(into: (0, 0)) { total, file in
      total.0 += file.added
      total.1 += file.removed
    }
  }
}

struct ChangedFile: Equatable {
  let path: String
  let added: Int
  let removed: Int
  var name: String { (path as NSString).lastPathComponent }
}

/// One node in the sidebar, materialized lazily: a directory's children are computed, and then
/// cached, only when the outline view asks for them, so a huge worktree costs what it shows on
/// screen, not what it holds. Where the children come from is the node's `source` — a slice of a
/// path-sorted `FileTree` when the tree is a list of paths (a filter, the changed scope), or the
/// directory itself on disk when it is the worktree as it is (`DiskTree`).
final class FileNode: NSObject {
  let name: String
  let relativePath: String
  let isDirectory: Bool
  var added: Int?
  var removed: Int?
  /// git would not take this file, or anything under this directory. Shown all the same — it is
  /// in the worktree — but dimmed, so the build output does not read as the work.
  var isIgnored = false

  private enum Source {
    /// A directory whose descendants are exactly `paths[range]` of the tree, every one of them
    /// sharing the node's first `depth` components.
    case block(FileTree, Range<Int>, Int)
    /// A directory listed from disk as it opens.
    case disk(DiskTree)
  }
  /// nil for a leaf, whose `children` is always empty.
  private let source: Source?
  private var cachedChildren: [FileNode]?
  /// The listing is known to be out of date (the directory moved on disk, or git's answer did),
  /// and is read again on the next ask — reusing the nodes for what is still there, since the
  /// outline keys its disclosure state on the node objects and a fresh set would fold every open
  /// row beneath.
  private var stale = false

  /// A leaf, or a flat Changed-mode row.
  init(
    name: String, relativePath: String, isDirectory: Bool, added: Int? = nil, removed: Int? = nil
  ) {
    self.name = name
    self.relativePath = relativePath
    self.isDirectory = isDirectory
    self.added = added
    self.removed = removed
    self.source = nil
  }

  /// A lazy directory node over `tree.paths[range]`.
  fileprivate init(
    name: String, relativePath: String, tree: FileTree, range: Range<Int>, depth: Int
  ) {
    self.name = name
    self.relativePath = relativePath
    self.isDirectory = true
    self.source = .block(tree, range, depth)
  }

  /// A directory on disk, listed when it opens.
  fileprivate init(name: String, relativePath: String, disk: DiskTree) {
    self.name = name
    self.relativePath = relativePath
    self.isDirectory = true
    self.source = .disk(disk)
  }

  var isFromDisk: Bool {
    if case .disk = source { return true }
    return false
  }

  /// This directory's immediate children, computed once on first access. Empty for a leaf.
  var children: [FileNode] {
    if let cachedChildren, !stale { return cachedChildren }
    let result: [FileNode]
    switch source {
    case .block(let tree, let range, let depth)?:
      result = tree.children(inRange: range, depth: depth)
    case .disk(let disk)?:
      result = disk.children(
        of: relativePath, parentIgnored: isIgnored, reusing: cachedChildren ?? [])
    case nil:
      result = []
    }
    cachedChildren = result
    stale = false
    return result
  }

  /// The children already listed, without listing — what a stale walk goes through.
  fileprivate var listedChildren: [FileNode] { cachedChildren ?? [] }

  func markStale() { stale = true }

  /// Build a hierarchy from a list of paths, attaching diffstats to changed files. A convenience
  /// over `FileTree` for a caller holding a plain, possibly-unsorted list (the tests); production
  /// builds a `FileTree` straight from `Git.trackedFiles`, which is already byte-sorted, and skips
  /// this sort.
  static func tree(paths: [String], changed: [String: ChangedFile]) -> [FileNode] {
    FileTree(paths: paths.sorted(by: FileTree.precedesBytewise), changed: changed).rootChildren
  }

  /// Directories first, then natural order — the look the eager tree had.
  static func byKindThenName(_ left: FileNode, _ right: FileNode) -> Bool {
    if left.isDirectory != right.isDirectory { return left.isDirectory }
    return left.name.localizedStandardCompare(right.name) == .orderedAscending
  }
}

/// The worktree as it is on disk, one directory at a time. A directory's rows are built when it
/// opens and not before, and their entries come off the worktree's index — the walk that already
/// went past, on its own queue — so opening a row costs the main thread nothing off the disk. The
/// disk is read here only where the index has no answer: a directory git ignores, which the walk
/// does not go into, or one the walk has not reached yet. Either is one directory's listing —
/// measured at 0.08ms for 30 entries and 4ms for 900, listing and stat together — and the
/// nodes are kept until something says the directory moved. git is not the source; it is asked
/// two things about what was found: which of it changed (the diffstats, from the working-tree
/// diff) and which of it git would not take (the dimming).
final class DiskTree {
  let root: URL
  /// The walk's answer, when there is one. Set by the panel as the worktree's index appears.
  var index: WorktreeIndex?
  /// Diffstats by path.
  private var changed: [String: ChangedFile] = [:]
  /// Every path git would take — tracked, or untracked and not ignored. A file on disk that is
  /// not here is one git ignores, or one git has not been asked about yet; the second is told
  /// from the first by asking. nil where there is no git, and so nothing is ignored.
  private var known: Set<String>?
  /// git's ignore rules, asked once per listing for the directories it holds and the files git
  /// does not know — never for a listing under an ignored directory, where the answer is already
  /// known for the lot.
  private let ignored: (_ directories: [String], _ files: [String]) -> Set<String>
  private(set) var roots: [FileNode] = []

  init(root: URL, ignored: @escaping (_ directories: [String], _ files: [String]) -> Set<String>) {
    self.root = root
    self.ignored = ignored
  }

  /// git answered. What it moves is the numbers on the rows and which of them are dimmed, and
  /// both are re-read off the answer in memory — never the disk, which has not been touched by
  /// git answering and which FSEvents speaks for on its own. An agent at work is a git answer
  /// every batch, and a listing of every open directory per batch was the one recurring cost on
  /// the main thread this tree had; this leaves it with none.
  func update(changed: [String: ChangedFile], known: Set<String>?) {
    self.changed = changed
    self.known = known
    for node in listedNodes() {
      if node.isDirectory {
        sumChanges(into: node)
      } else {
        node.added = changed[node.relativePath]?.added
        node.removed = changed[node.relativePath]?.removed
        // A file git now lists is one it takes; one it still does not keeps the answer it was
        // given when it was listed.
        if known?.contains(node.relativePath) == true { node.isIgnored = false }
      }
    }
  }

  /// Everything listed is read again on its next ask — for a batch of moved paths that could
  /// not be placed, where which directories moved is not known and all of them might have.
  func markAllStale() {
    for node in listedNodes() { node.markStale() }
  }

  /// A directory carries the sum of what changed beneath it, so a folded tree still says where
  /// the work is. Summed over the changed set, which is small, rather than over the listing,
  /// which does not know what is under it.
  private func sumChanges(into node: FileNode) {
    var added = 0
    var removed = 0
    let prefix = node.relativePath + "/"
    for (changedPath, file) in changed where changedPath.hasPrefix(prefix) {
      added += file.added
      removed += file.removed
    }
    node.added = added + removed > 0 ? added : nil
    node.removed = added + removed > 0 ? removed : nil
  }

  /// The top-level entries, listed again — reusing the nodes for what is still there.
  @discardableResult
  func relistRoots() -> [FileNode] {
    roots = children(of: "", parentIgnored: false, reusing: roots)
    return roots
  }

  /// The node for `path`, if the directories above it have been listed — the walk goes through
  /// listings only and never causes one, since a node nobody has opened has nothing to go stale.
  func listedNode(at path: String) -> FileNode? {
    var nodes = roots
    let components = path.split(separator: "/").map(String.init)
    for depth in 0..<components.count {
      let prefix = components[0...depth].joined(separator: "/")
      guard let node = nodes.first(where: { $0.relativePath == prefix }) else { return nil }
      if depth == components.count - 1 { return node }
      nodes = node.listedChildren
    }
    return nil
  }

  private func listedNodes() -> [FileNode] {
    var result: [FileNode] = []
    func walk(_ nodes: [FileNode]) {
      for node in nodes {
        result.append(node)
        walk(node.listedChildren)
      }
    }
    walk(roots)
    return result
  }

  func children(of parent: String, parentIgnored: Bool, reusing previous: [FileNode]) -> [FileNode]
  {
    let indexed = index?.entries(of: parent)
    guard
      let entries = indexed
        ?? WorktreeIndex.list(parent.isEmpty ? root : root.appendingPathComponent(parent))
    else { return [] }
    // Reused by path, and only where the node is the same kind of thing: a leaf is a leaf
    // whatever listed it, but a directory node from a path-list tree would go on drawing its
    // children from that list.
    let reusable = Dictionary(
      previous.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
    var result: [FileNode] = []
    var directories: [FileNode] = []
    var unknownFiles: [FileNode] = []
    for entry in entries {
      let name = entry.name
      let path = parent.isEmpty ? name : "\(parent)/\(name)"
      let isDirectory = entry.isDirectory
      let node: FileNode
      if let old = reusable[path], old.isDirectory == isDirectory,
        !old.isDirectory || old.isFromDisk
      {
        node = old
      } else if isDirectory {
        node = FileNode(name: name, relativePath: path, disk: self)
      } else {
        node = FileNode(name: name, relativePath: path, isDirectory: false)
      }
      if isDirectory {
        sumChanges(into: node)
        directories.append(node)
      } else {
        node.added = changed[path]?.added
        node.removed = changed[path]?.removed
        if known != nil, known?.contains(path) != true { unknownFiles.append(node) }
      }
      node.isIgnored = parentIgnored
      result.append(node)
    }
    // Under an ignored directory everything is ignored and nothing is asked. Under a plain one
    // the index already knows which directories git ignores, having asked as it walked; git is
    // asked here about the directories only where the listing was this tree's own, and about
    // the files it did not produce — which are the ignored ones and the brand-new ones, and the
    // ask is what tells those apart.
    if known != nil, !parentIgnored, !(directories.isEmpty && unknownFiles.isEmpty) {
      let askAbout = indexed == nil ? directories : []
      if let index, indexed != nil {
        for node in directories { node.isIgnored = index.isIgnoredDirectory(node.relativePath) }
      }
      if !(askAbout.isEmpty && unknownFiles.isEmpty) {
        let answer = ignored(askAbout.map(\.relativePath), unknownFiles.map(\.relativePath))
        for node in askAbout + unknownFiles {
          node.isIgnored = answer.contains(node.relativePath)
        }
      }
    }
    result.sort(by: FileNode.byKindThenName)
    return result
  }
}

/// The path-sorted backing for an All-mode sidebar tree. It holds the worktree's tracked paths in
/// git-index order — byte-sorted, which is what the prefix binary search below relies on — plus the
/// changed-file diffstats, and hands a directory node its immediate children on demand. Because a
/// child directory's block is found by binary-searching to its end rather than scanning the subtree
/// underneath, one directory costs the number of children it has, not the count of descendants.
final class FileTree {
  let paths: [String]
  private let changed: [String: ChangedFile]

  /// git-index order: bytes. `utf8.lexicographicallyPrecedes` says the same thing and walks the
  /// two views a byte at a time through generic iteration — 315ms to sort 14,500 paths, against
  /// the few milliseconds one `memcmp` per comparison costs.
  static func precedesBytewise(_ left: String, _ right: String) -> Bool {
    var left = left
    var right = right
    return left.withUTF8 { leftBytes in
      right.withUTF8 { rightBytes in
        let common = min(leftBytes.count, rightBytes.count)
        let order = memcmp(leftBytes.baseAddress, rightBytes.baseAddress, common)
        return order != 0 ? order < 0 : leftBytes.count < rightBytes.count
      }
    }
  }

  init(paths: [String], changed: [String: ChangedFile]) {
    self.paths = paths
    self.changed = changed
  }

  /// The top-level entries.
  var rootChildren: [FileNode] { children(inRange: 0..<paths.count, depth: 0) }

  /// The immediate children of the directory whose descendants are exactly `paths[range]`, every
  /// one of them sharing the same first `depth` path components. Directories come first, then
  /// natural order — the look the eager tree had.
  func children(inRange range: Range<Int>, depth: Int) -> [FileNode] {
    var result: [FileNode] = []
    var i = range.lowerBound
    while i < range.upperBound {
      let components = paths[i].split(separator: "/").map(String.init)
      let name = components[depth]
      if components.count == depth + 1 {
        result.append(
          FileNode(
            name: name, relativePath: paths[i], isDirectory: false,
            added: changed[paths[i]]?.added, removed: changed[paths[i]]?.removed))
        i += 1
      } else {
        let relativePath = components[0...depth].joined(separator: "/")
        let end = blockEnd(prefix: relativePath + "/", from: i, to: range.upperBound)
        let node = FileNode(
          name: name, relativePath: relativePath, tree: self, range: i..<end, depth: depth + 1)
        // A directory carries the sum of what changed beneath it, so a folded tree still says
        // where the work is — you see which branch to open before opening it. Summed over the
        // node's own path block rather than by path prefix, so a filtered tree totals only the
        // files it actually shows. Skipped outright when nothing is changed, which is the common
        // case and the one where walking every path would be pure waste.
        if !changed.isEmpty {
          var added = 0
          var removed = 0
          for index in i..<end {
            guard let file = changed[paths[index]] else { continue }
            added += file.added
            removed += file.removed
          }
          if added + removed > 0 {
            node.added = added
            node.removed = removed
          }
        }
        result.append(node)
        i = end
      }
    }
    result.sort(by: FileNode.byKindThenName)
    return result
  }

  /// The first index in `from..<to` whose path no longer starts with `prefix`. Because the paths
  /// are byte-sorted, everything under one directory is a contiguous block, so this binary search
  /// jumps straight past the whole subtree.
  private func blockEnd(prefix: String, from: Int, to: Int) -> Int {
    var lo = from
    var hi = to
    while lo < hi {
      let mid = (lo + hi) / 2
      if paths[mid].hasPrefix(prefix) { lo = mid + 1 } else { hi = mid }
    }
    return lo
  }
}
