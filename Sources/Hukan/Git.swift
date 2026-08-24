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

  // MARK: - Line-level changes (the gutter's change bars)

  /// One changed block between a base text and the current one, in both line spaces, carrying
  /// the lines themselves so the gutter can show what was replaced without asking git again.
  /// `oldLen == 0` is a pure addition (nothing removed to show); `newLen == 0` is a pure
  /// deletion, and its `newStart` is the line the removed text sat above.
  struct Hunk: Equatable {
    /// 0-based, in the base text.
    var oldStart = 0
    var oldLen = 0
    /// 0-based, in the current text.
    var newStart = 0
    var newLen = 0
    /// What the block reads as at the base, and what it reads as now.
    var oldLines: [String] = []
    var newLines: [String] = []
    /// Whether this exact change already sits in the index.
    var staged = false
  }

  /// What a file's gutter diffs against: its content at HEAD, and in the index. Read once per
  /// file (and again when git moves under it), so an edit re-diffs without touching the
  /// repository.
  struct FileBase: Equatable {
    var head: String?
    var index: String?

    var isEmpty: Bool { head == nil && index == nil }
  }

  /// One file's changes, line by line, for the gutter to draw.
  struct LineChanges: Equatable {
    enum Kind: Equatable {
      case added, modified
    }
    struct Bar: Equatable {
      var kind: Kind
      var staged: Bool
    }
    /// 1-based line → its change bar.
    var bars: [Int: Bar] = [:]
    /// Lines were deleted just below this 1-based line (0 = above the first) → whether that
    /// deletion is staged.
    var deletions: [Int: Bool] = [:]
    /// The blocks the bars came from, so a hover can show one.
    var hunks: [Hunk] = []
  }

  /// A file's base texts. `HEAD:<path>` for the committed side; the index entry's blob for the
  /// staged one. A file with no commit yet has neither, and the gutter stays empty rather than
  /// marking every line of a new file as added.
  static func fileBase(at url: URL, path: String) -> FileBase {
    guard let repo = openRepository(at: url) else { return FileBase() }
    defer { git_repository_free(repo) }
    return FileBase(head: headBlob(repo, path: path), index: indexBlob(repo, path: path))
  }

  private static func headBlob(_ repo: OpaquePointer, path: String) -> String? {
    var object: OpaquePointer?
    guard git_revparse_single(&object, repo, "HEAD:\(path)") == 0, let object else { return nil }
    defer { git_object_free(object) }
    guard git_object_type(object) == GIT_OBJECT_BLOB else { return nil }
    return blobText(object)
  }

  private static func indexBlob(_ repo: OpaquePointer, path: String) -> String? {
    var index: OpaquePointer?
    guard git_repository_index(&index, repo) == 0, let index else { return nil }
    defer { git_index_free(index) }
    guard var entry = git_index_get_bypath(index, path, 0)?.pointee else { return nil }
    var blob: OpaquePointer?
    guard git_blob_lookup(&blob, repo, &entry.id) == 0, let blob else { return nil }
    defer { git_blob_free(blob) }
    return blobText(blob)
  }

  private static func blobText(_ blob: OpaquePointer) -> String? {
    guard git_blob_is_binary(blob) == 0, let content = git_blob_rawcontent(blob) else {
      return nil
    }
    let size = Int(git_blob_rawsize(blob))
    return String(
      data: Data(bytes: content, count: size), encoding: .utf8)
  }

  /// The changed blocks between two texts, straight from libgit2 — `git_diff_buffers` diffs two
  /// strings with no repository behind them, which is what lets the gutter re-diff the *buffer*
  /// on every edit instead of only the file on disk.
  static func hunks(base: String, current: String) -> [Hunk] {
    guard base != current else { return [] }
    var collected: [Hunk] = []
    let old = Array(base.utf8)
    let new = Array(current.utf8)
    old.withUnsafeBufferPointer { oldBuffer in
      new.withUnsafeBufferPointer { newBuffer in
        var options = git_diff_options()
        git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
        // No context. git's default of three lines merges two changes that happen to sit near
        // each other into one hunk, and the gutter's unit is the change, not the neighbourhood:
        // merged, a staged edit and an unstaged one four lines apart would read as one block and
        // take one another's fill.
        options.context_lines = 0
        // Discarded deliberately: the closure's value is `git_diff_buffers`'s return code, and
        // there is nothing to do with a failure here — a diff that will not run leaves the
        // blocks empty, which is the same answer as a file with nothing changed in it.
        _ = withUnsafeMutablePointer(to: &collected) { payload in
          git_diff_buffers(
            oldBuffer.baseAddress, oldBuffer.count, nil,
            newBuffer.baseAddress, newBuffer.count, nil,
            &options, nil, nil,
            { _, header, payload in
              guard let header, let payload else { return 0 }
              // Seed the new-side anchor from the hunk header. For a block with nothing added
              // that is the whole answer: git numbers a pure deletion `+N,0`, meaning it sat
              // after line N — which is both the 1-based line above the gap and the 0-based
              // index of the line now below it, the same integer either way.
              payload.assumingMemoryBound(to: [Hunk].self).pointee.append(
                Hunk(newStart: Int(header.pointee.new_start)))
              return 0
            },
            { _, _, line, payload in
              guard let line, let payload else { return 0 }
              let hunks = payload.assumingMemoryBound(to: [Hunk].self)
              guard var hunk = hunks.pointee.last, let content = line.pointee.content else {
                return 0
              }
              let text =
                String(
                  data: Data(bytes: content, count: line.pointee.content_len), encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n")) ?? ""
              switch UInt8(bitPattern: line.pointee.origin) {
              case UInt8(ascii: "-"):
                if hunk.oldLines.isEmpty { hunk.oldStart = Int(line.pointee.old_lineno) - 1 }
                hunk.oldLines.append(text)
                hunk.oldLen += 1
              case UInt8(ascii: "+"):
                if hunk.newLines.isEmpty { hunk.newStart = Int(line.pointee.new_lineno) - 1 }
                hunk.newLines.append(text)
                hunk.newLen += 1
              default:
                return 0
              }
              hunks.pointee[hunks.pointee.count - 1] = hunk
              return 0
            }, payload)
        }
      }
    }
    return collected.filter { $0.oldLen > 0 || $0.newLen > 0 }
  }

  /// Which of `current`'s blocks are already staged: the change has to sit in the index
  /// *exactly* — same place in the base, same replacement text — or it is still working-tree
  /// only. A block staged and then edited again therefore reads unstaged, which is what it is.
  static func markStaged(_ current: [Hunk], against index: [Hunk]) -> [Hunk] {
    current.map { hunk in
      var hunk = hunk
      hunk.staged = index.contains {
        $0.oldStart == hunk.oldStart && $0.oldLen == hunk.oldLen && $0.newLines == hunk.newLines
      }
      return hunk
    }
  }

  /// The per-line bars a set of blocks draws as. A replaced run marks its whole new span as
  /// modified (any surplus removed lines fold into it, the way VS Code reads it), a block with
  /// nothing removed is an addition, and a block with nothing added is a deletion sitting on
  /// the boundary above the line that now follows it.
  static func lineChanges(from hunks: [Hunk]) -> LineChanges {
    var changes = LineChanges(hunks: hunks)
    for hunk in hunks {
      guard hunk.newLen > 0 else {
        changes.deletions[hunk.newStart] = hunk.staged
        continue
      }
      let kind: LineChanges.Kind = hunk.oldLen > 0 ? .modified : .added
      for line in hunk.newStart..<(hunk.newStart + hunk.newLen) {
        changes.bars[line + 1] = LineChanges.Bar(kind: kind, staged: hunk.staged)
      }
    }
    return changes
  }

  /// The gutter's whole reading for one file: the buffer against HEAD for what changed, the
  /// index against HEAD for what of it is staged.
  static func lineChanges(base: FileBase, current: String) -> LineChanges {
    guard let head = base.head else { return LineChanges() }
    let current = hunks(base: head, current: current)
    let staged = base.index.map { hunks(base: head, current: $0) } ?? []
    return lineChanges(from: markStaged(current, against: staged))
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

  /// The index against the working tree — the unstaged half of a file's changes. The caller
  /// frees it with `git_diff_free`.
  private static func indexToWorkdirDiff(_ repo: OpaquePointer) -> OpaquePointer? {
    var options = git_diff_options()
    git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
    var diff: OpaquePointer?
    guard git_diff_index_to_workdir(&diff, repo, nil, &options) == 0 else { return nil }
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
