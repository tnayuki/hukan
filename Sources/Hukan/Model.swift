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
  /// What this worktree has committed past its base branch — the History section's list. Read on
  /// the same tick as the changed files, since the commit that empties one fills the other.
  var history = Git.History()
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

/// One node in the sidebar. Flat in Changed mode; in All mode it is a lazily-materialized window
/// onto a shared, path-sorted `FileTree` — a directory's children are computed, and then cached,
/// only when the outline view asks for them, so a huge worktree costs what it shows on screen, not
/// what it holds on disk.
final class FileNode: NSObject {
  let name: String
  let relativePath: String
  let isDirectory: Bool
  var added: Int?
  var removed: Int?

  /// The tree this directory node draws its children from, and the `paths` slice — every entry
  /// sharing this node's first `depth` components — those children live in. nil for a leaf or a
  /// flat Changed-mode node, whose `children` is always empty.
  private let tree: FileTree?
  private let range: Range<Int>
  private let depth: Int
  private var cachedChildren: [FileNode]?

  /// A leaf, or a flat Changed-mode row.
  init(
    name: String, relativePath: String, isDirectory: Bool, added: Int? = nil, removed: Int? = nil
  ) {
    self.name = name
    self.relativePath = relativePath
    self.isDirectory = isDirectory
    self.added = added
    self.removed = removed
    self.tree = nil
    self.range = 0..<0
    self.depth = 0
  }

  /// A lazy directory node over `tree.paths[range]`.
  fileprivate init(
    name: String, relativePath: String, tree: FileTree, range: Range<Int>, depth: Int
  ) {
    self.name = name
    self.relativePath = relativePath
    self.isDirectory = true
    self.tree = tree
    self.range = range
    self.depth = depth
  }

  /// This directory's immediate children, computed once on first access. Empty for a leaf.
  var children: [FileNode] {
    if let cachedChildren { return cachedChildren }
    let result = tree?.children(inRange: range, depth: depth) ?? []
    cachedChildren = result
    return result
  }

  /// Build a hierarchy from a list of paths, attaching diffstats to changed files. A convenience
  /// over `FileTree` for a caller holding a plain, possibly-unsorted list (the tests); production
  /// builds a `FileTree` straight from `Git.trackedFiles`, which is already byte-sorted, and skips
  /// this sort.
  static func tree(paths: [String], changed: [String: ChangedFile]) -> [FileNode] {
    FileTree(
      paths: paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }, changed: changed
    ).rootChildren
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
    result.sort { left, right in
      if left.isDirectory != right.isDirectory { return left.isDirectory }
      return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }
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
