import Clibgit2
import Foundation

/// git queries, answered in-process by libgit2 — no `git` subprocess is ever spawned. That is
/// the point: a change on disk used to fork two `git` processes per FSEvents batch per worktree
/// (`git diff --numstat` + `git ls-files`), so a large repository under a storm of writes buried
/// the machine in short-lived processes. The same two questions are now two in-process calls.
///
/// hukan only *reads* local worktrees — it never clones or fetches — so the bundled libgit2
/// (Vendor/Clibgit2.xcframework) is built with the network transports off; see
/// Vendor/build-libgit2.sh. libgit2 is wound up once at launch through `initialize()`. Each call
/// opens, uses, and frees its own `git_repository`, so a call is self-contained and safe on the
/// background queue the callers already hand it.
enum Git {
  /// Wind libgit2 up once, before anything asks it a question. Ref-counted, so a redundant call
  /// (a test host that never opens a repository, say) is harmless.
  static func initialize() {
    git_libgit2_init()
  }

  /// Changes with line counts, measured against `base` (always `HEAD` today). Mirrors
  /// `git diff --numstat HEAD`: the working tree — staged and unstaged both — against the base's
  /// tree. Binaries report 0/0, the way numstat's "-" read as zero.
  static func changedFiles(at url: URL, since base: String) -> [ChangedFile] {
    guard let repo = openRepository(at: url) else { return [] }
    defer { git_repository_free(repo) }
    guard let diff = headDiff(repo, base: base) else { return [] }
    defer { git_diff_free(diff) }

    var files: [ChangedFile] = []
    for i in 0..<git_diff_num_deltas(diff) {
      guard let delta = git_diff_get_delta(diff, i) else { continue }
      let path = delta.pointee.new_file.path.map { String(cString: $0) } ?? ""
      var added = 0
      var removed = 0
      var patch: OpaquePointer?
      if git_patch_from_diff(&patch, diff, i) == 0, let patch {
        var context = 0
        var additions = 0
        var deletions = 0
        if git_patch_line_stats(&context, &additions, &deletions, patch) == 0 {
          added = additions
          removed = deletions
        }
        git_patch_free(patch)
      }
      files.append(ChangedFile(path: path, added: added, removed: removed))
    }
    return files
  }

  /// The tracked list under git, otherwise a shallow walk of the real files. A Worktree is "a
  /// directory that may carry git information", so both cases have to work — and a git directory
  /// with nothing tracked yet (a fresh `git init`) falls through to the walk too, so its
  /// not-yet-added files still show, matching what `git ls-files` returning nothing used to do.
  /// The worktree's tracked paths, in git-index order — which is byte-sorted. The All-mode sidebar
  /// tree (`FileTree`) relies on that ordering for its prefix binary search, so the non-git
  /// fallback sorts the same way.
  static func trackedFiles(at url: URL) -> [String] {
    if let repo = openRepository(at: url) {
      defer { git_repository_free(repo) }
      var index: OpaquePointer?
      if git_repository_index(&index, repo) == 0, let index {
        defer { git_index_free(index) }
        git_index_read(index, 0)  // pick up an index a session changed under us
        var paths: [String] = []
        for i in 0..<git_index_entrycount(index) {
          if let entry = git_index_get_byindex(index, i), let path = entry.pointee.path {
            paths.append(String(cString: path))
          }
        }
        if !paths.isEmpty { return paths }
      }
    }
    return filesystemWalk(at: url)
  }

  /// The patch for one file, measured against `base` — `git diff HEAD -- <path>`. Returns the
  /// unified diff text, or nil when the file is unchanged.
  static func diff(at url: URL, path: String, since base: String) -> String? {
    guard let repo = openRepository(at: url) else { return nil }
    defer { git_repository_free(repo) }
    guard let diff = headDiff(repo, base: base) else { return nil }
    defer { git_diff_free(diff) }

    for i in 0..<git_diff_num_deltas(diff) {
      guard let delta = git_diff_get_delta(diff, i) else { continue }
      let newPath = delta.pointee.new_file.path.map { String(cString: $0) }
      let oldPath = delta.pointee.old_file.path.map { String(cString: $0) }
      guard newPath == path || oldPath == path else { continue }

      var patch: OpaquePointer?
      guard git_patch_from_diff(&patch, diff, i) == 0, let patch else { return nil }
      defer { git_patch_free(patch) }
      var buffer = git_buf()
      guard git_patch_to_buf(&buffer, patch) == 0 else { return nil }
      defer { git_buf_dispose(&buffer) }
      guard let ptr = buffer.ptr else { return nil }
      let text = String(cString: ptr)
      return text.isEmpty ? nil : text
    }
    return nil
  }

  static func fileContents(at url: URL, path: String) -> String? {
    try? String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
  }

  static func currentBranch(at url: URL) -> String? {
    guard let repo = openRepository(at: url) else { return nil }
    defer { git_repository_free(repo) }
    var head: OpaquePointer?
    guard git_repository_head(&head, repo) == 0, let head else { return nil }
    defer { git_reference_free(head) }
    guard let name = git_reference_shorthand(head) else { return nil }
    return String(cString: name)
  }

  /// Where this worktree's own git information actually lives — `rev-parse --git-dir`. For the
  /// main checkout that is the `.git` directory inside it, but a linked worktree's `.git` is a
  /// one-line pointer file and the real directory sits under the common dir
  /// (`…/.git/worktrees/<name>/`), holding that worktree's `HEAD` and `index`. Watching a
  /// worktree therefore takes more than watching the worktree; see `Workspace.syncWatchers()`.
  static func gitDirectory(at url: URL) -> URL? {
    guard let repo = openRepository(at: url) else { return nil }
    defer { git_repository_free(repo) }
    guard let path = git_repository_path(repo) else { return nil }
    return URL(fileURLWithPath: String(cString: path)).standardizedFileURL
  }

  /// The path every worktree of one repository has in common. Used as the repository's identity,
  /// with its last component as the display name. libgit2's common dir is `…/<main>/.git`, so
  /// its parent is that shared root — the same string `rev-parse --git-common-dir` produced.
  static func repository(at url: URL) -> String? {
    guard let repo = openRepository(at: url) else { return nil }
    defer { git_repository_free(repo) }
    guard let common = git_repository_commondir(repo) else { return nil }
    return URL(fileURLWithPath: String(cString: common))
      .deletingLastPathComponent().standardizedFileURL.path
  }

  /// Every worktree of the repository — the main checkout first, then each linked one — matching
  /// `git worktree list`, which leads with the main worktree whichever one you opened. The main
  /// checkout is the common dir's parent; the linked ones come from git by name.
  static func worktrees(at url: URL) -> [URL] {
    guard let repo = openRepository(at: url) else { return [] }
    defer { git_repository_free(repo) }

    var result: [URL] = []
    if let common = git_repository_commondir(repo) {
      let main = URL(fileURLWithPath: String(cString: common)).deletingLastPathComponent()
      result.append(main.standardizedFileURL)
    }
    var names = git_strarray()
    if git_worktree_list(&names, repo) == 0 {
      defer { git_strarray_dispose(&names) }
      for i in 0..<names.count {
        guard let name = names.strings[i] else { continue }
        var worktree: OpaquePointer?
        guard git_worktree_lookup(&worktree, repo, name) == 0, let worktree else { continue }
        defer { git_worktree_free(worktree) }
        if let path = git_worktree_path(worktree) {
          result.append(URL(fileURLWithPath: String(cString: path)).standardizedFileURL)
        }
      }
    }
    return result
  }

  // MARK: - libgit2 plumbing

  /// Open the repository at `url`; the caller frees it with `git_repository_free`. nil when the
  /// directory carries no git information (the degenerate non-git case).
  private static func openRepository(at url: URL) -> OpaquePointer? {
    var repo: OpaquePointer?
    guard git_repository_open(&repo, url.path) == 0 else { return nil }
    return repo
  }

  /// The diff of `base`'s tree against the working tree with the index folded in — libgit2's
  /// stand-in for `git diff <base>`. The caller frees it with `git_diff_free`. nil when `base`
  /// has no tree yet (an unborn HEAD in a fresh repository), where `git diff HEAD` errored too.
  private static func headDiff(_ repo: OpaquePointer, base: String) -> OpaquePointer? {
    var tree: OpaquePointer?
    guard git_revparse_single(&tree, repo, "\(base)^{tree}") == 0, let tree else { return nil }
    defer { git_object_free(tree) }
    var options = git_diff_options()
    git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
    var diff: OpaquePointer?
    guard git_diff_tree_to_workdir_with_index(&diff, repo, tree, &options) == 0 else { return nil }
    return diff
  }

  /// The non-git fallback: a shallow walk of the real files under `url`, capped so a huge tree
  /// cannot stall the sidebar.
  private static func filesystemWalk(at url: URL) -> [String] {
    let keys: [URLResourceKey] = [.isDirectoryKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [] }
    var paths: [String] = []
    let prefix = url.standardizedFileURL.path + "/"
    for case let fileURL as URL in enumerator {
      if (try? fileURL.resourceValues(forKeys: Set(keys)))?.isDirectory == true { continue }
      let path = fileURL.standardizedFileURL.path
      guard path.hasPrefix(prefix) else { continue }
      paths.append(String(path.dropFirst(prefix.count)))
      if paths.count >= 5000 { break }
    }
    // Match the git-index path order the tree expects (enumeration order is not sorted).
    return paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
  }
}
