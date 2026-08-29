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

  /// Changes with line counts, measured against `base` (always `HEAD` today): the working tree —
  /// staged, unstaged and untracked alike — against the base's tree. Close to
  /// `git diff --numstat HEAD`, except that untracked files count as added, since a file nobody
  /// has run `git add` on is still the work (see `headDiff`). Binaries report 0/0, the way
  /// numstat's "-" read as zero.
  static func changedFiles(at url: URL, since base: String) -> [ChangedFile] {
    guard let repo = openRepository(at: url) else { return [] }
    defer { git_repository_free(repo) }
    guard let diff = headDiff(repo, base: base) else { return [] }
    defer { git_diff_free(diff) }

    return fileStats(in: diff)
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

  // MARK: - History (the worktree's own commits)

  /// One commit in the History section.
  struct Commit: Equatable {
    let oid: String
    let summary: String
    /// Whether the branch's upstream already carries this commit — nil when the branch has no
    /// upstream, where "pushed" is not a question with an answer and the section says nothing.
    let isPushed: Bool?
    var shortOID: String { String(oid.prefix(7)) }
  }

  /// The branch's log, newest first — `git log --first-parent`, read a page at a time.
  ///
  /// It was `<base>..HEAD` once, which made the section vanish the moment the branch was pushed:
  /// on a checkout in sync with its remote there is nothing past the base, so the one thing the
  /// list is asked for most — what landed recently — was exactly what it would not show. The base
  /// is still read, but only to mark *where the task began*; the walk carries on past it into the
  /// history the branch was cut from, which is what scrolling the section reaches.
  struct History: Equatable {
    var commits: [Commit] = []
    /// The base the fork-point rule is labelled with, by short name. nil when no base could be
    /// found — a repository with only this branch.
    var base: String?
    /// How many of `commits` the base does not carry: where the fork-point rule goes. 0 on a
    /// checkout with nothing of its own, where no rule is drawn at all.
    var forkIndex = 0
    /// The walk stopped at `limit` — there is more history below, which is what the section pages
    /// in as it is scrolled.
    var truncated = false
    /// A rebase, merge or cherry-pick this worktree is in the middle of, if any — see `Operation`.
    var operation: Operation?
  }

  /// Something git has started in this worktree and not finished: a rebase stopped on a conflict,
  /// a merge waiting to be committed, a bisect underway.
  ///
  /// It belongs to the history rather than beside it because it is the history that stops making
  /// sense without it. Mid-rebase, HEAD is detached partway through the replay, so `<base>..HEAD`
  /// is *empty* until the first commit lands and then grows back one row at a time — a list that
  /// silently empties, on a worktree whose files are full of conflict markers, with nothing on
  /// screen saying why.
  struct Operation: Equatable {
    enum Kind: Equatable {
      case rebase
      case merge
      case cherryPick
      case revert
      case bisect
      case applyMailbox
    }
    let kind: Kind
    /// The branch the operation is being run on. A rebase detaches HEAD, so this is the only
    /// place the worktree's own name survives while it runs.
    let branch: String?
    /// Which step of how many, when git records that — a rebase does, a merge has no steps.
    let step: Int?
    let total: Int?
  }

  /// How many commits a page of history holds. The first read is one page; scrolling to the end
  /// of the section asks for the next.
  static let historyPage = 50

  /// The branch's commits, newest first, at most `limit` of them.
  ///
  /// First-parent only: a task branch is nearly always linear, and a lane graph on top of it
  /// would be decoration rather than information — what the reader needs from the shape is where
  /// the task began, and that is one rule in the list rather than a second column of ancestry.
  static func history(at url: URL, limit: Int = historyPage) -> History {
    guard let repo = openRepository(at: url) else { return History() }
    defer { git_repository_free(repo) }

    var head: OpaquePointer?
    guard git_repository_head(&head, repo) == 0, let head else { return History() }
    defer { git_reference_free(head) }
    guard let headTarget = git_reference_target(head) else { return History() }
    var headOID = headTarget.pointee

    var result = History()
    var walk: OpaquePointer?
    guard git_revwalk_new(&walk, repo) == 0, let walk else { return result }
    defer { git_revwalk_free(walk) }
    // Unsorted, which here is not "in no order": first-parent simplification off one tip leaves a
    // single chain, so the walk yields it newest-first by construction. Asking for a topological
    // sort instead makes libgit2 preload the *whole* history before it yields a row, which is
    // what a paged list cannot afford — measured on a synthesized 5000-commit repository, a
    // 50-row page cost 13.7ms sorted against 0.41ms unsorted, and the sorted number is a function
    // of the history's depth rather than the page's size.
    git_revwalk_sorting(walk, UInt32(GIT_SORT_NONE.rawValue))
    git_revwalk_simplify_first_parent(walk)
    guard git_revwalk_push(walk, &headOID) == 0 else { return result }

    // The base bounds nothing — it only says where this branch's own work stops and the history
    // it was cut from begins, which is the row the fork-point rule sits on.
    if let (name, oid) = baseBranch(repo, head: head) {
      result.base = name
      result.forkIndex = aheadCount(repo, head: head, base: oid, limit: limit)
    }

    result.operation = operation(in: repo)

    // The upstream is only ever consulted for the pushed marker — never as the base. A pushed
    // task still has a history worth reading; that is when it is being reviewed.
    let unpushed = unpushedOIDs(repo, head: head, limit: limit)

    var oid = git_oid()
    while git_revwalk_next(&oid, walk) == 0 {
      guard result.commits.count < limit else {
        result.truncated = true
        break
      }
      var commit: OpaquePointer?
      guard git_commit_lookup(&commit, repo, &oid) == 0, let commit else { continue }
      defer { git_commit_free(commit) }
      let summary = git_commit_summary(commit).map { String(cString: $0) } ?? ""
      let hex = String(cString: git_oid_tostr_s(&oid))
      result.commits.append(
        Commit(oid: hex, summary: summary, isPushed: unpushed.map { !$0.contains(hex) }))
    }
    return result
  }

  /// How many commits `head` carries that `base` does not — `git rev-list --count base..HEAD`,
  /// first-parent and capped. Cheap for the same reason the old bounded list was: hiding the base
  /// prunes the walk rather than running it to the root.
  private static func aheadCount(
    _ repo: OpaquePointer, head: OpaquePointer, base: git_oid, limit: Int
  ) -> Int {
    guard let target = git_reference_target(head) else { return 0 }
    var headOID = target.pointee
    var base = base
    var walk: OpaquePointer?
    guard git_revwalk_new(&walk, repo) == 0, let walk else { return 0 }
    defer { git_revwalk_free(walk) }
    git_revwalk_sorting(walk, UInt32(GIT_SORT_NONE.rawValue))
    git_revwalk_simplify_first_parent(walk)
    guard git_revwalk_push(walk, &headOID) == 0 else { return 0 }
    git_revwalk_hide(walk, &base)

    var count = 0
    var oid = git_oid()
    while count < limit, git_revwalk_next(&oid, walk) == 0 { count += 1 }
    return count
  }

  /// The commits the upstream does not carry — `upstream..HEAD`, walked once. nil when the branch
  /// has no upstream, which is how the marker learns to say nothing at all.
  ///
  /// Asking per row instead (`git_graph_descendant_of` for each) cost time proportional to *rows ×
  /// history depth*: measured at 8ms for a full list on a 50k-commit repository, against the 1.3ms
  /// of everything else a refresh does — and a refresh runs per FSEvents batch for every open
  /// worktree, which is the shape that buried the machine back when these reads were subprocesses.
  /// One walk is exact for the same reason the list itself is first-parent: both are prefixes of
  /// the one chain leading back from HEAD, so `limit` entries here cover `limit` rows there.
  private static func unpushedOIDs(_ repo: OpaquePointer, head: OpaquePointer, limit: Int) -> Set<
    String
  >? {
    guard var upstream = upstreamOID(repo, head: head),
      let target = git_reference_target(head)
    else { return nil }
    var headOID = target.pointee
    var walk: OpaquePointer?
    guard git_revwalk_new(&walk, repo) == 0, let walk else { return nil }
    defer { git_revwalk_free(walk) }
    git_revwalk_sorting(walk, UInt32(GIT_SORT_NONE.rawValue))
    git_revwalk_simplify_first_parent(walk)
    guard git_revwalk_push(walk, &headOID) == 0 else { return nil }
    // A branch whose upstream is gone (deleted on the remote) hides nothing and would walk the
    // whole history; the cap below is what keeps that bounded either way.
    git_revwalk_hide(walk, &upstream)

    var found = Set<String>()
    var oid = git_oid()
    while found.count < limit, git_revwalk_next(&oid, walk) == 0 {
      found.insert(String(cString: git_oid_tostr_s(&oid)))
    }
    return found
  }

  /// The branch this worktree's work is measured against: what the remote calls its default
  /// branch, falling back to a local `main`/`master` in a repository that has no remote. HEAD's
  /// own branch is never the base — it would hide everything and leave the section permanently
  /// empty.
  private static func baseBranch(_ repo: OpaquePointer, head: OpaquePointer) -> (String, git_oid)? {
    let headName = git_reference_name(head).map { String(cString: $0) }
    let candidates = [
      "refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master",
      "refs/heads/main", "refs/heads/master",
    ]
    for candidate in candidates {
      var reference: OpaquePointer?
      guard git_reference_lookup(&reference, repo, candidate) == 0, let reference else { continue }
      defer { git_reference_free(reference) }
      // origin/HEAD is symbolic (→ origin/main); resolve before reading a target off it.
      var resolved: OpaquePointer?
      guard git_reference_resolve(&resolved, reference) == 0, let resolved else { continue }
      defer { git_reference_free(resolved) }
      guard let name = git_reference_name(resolved).map({ String(cString: $0) }), name != headName,
        let target = git_reference_target(resolved)
      else { continue }
      let short = git_reference_shorthand(resolved).map { String(cString: $0) } ?? name
      return (short, target.pointee)
    }
    return nil
  }

  /// The tip of HEAD's upstream branch, when it has one.
  private static func upstreamOID(_ repo: OpaquePointer, head: OpaquePointer) -> git_oid? {
    var upstream: OpaquePointer?
    guard git_branch_upstream(&upstream, head) == 0, let upstream else { return nil }
    defer { git_reference_free(upstream) }
    return git_reference_target(upstream)?.pointee
  }

  /// One file inside a commit — one row of the tab, and one section of its diff.
  ///
  /// git's own status letter rather than a word: the row is monospace, so a column of letters
  /// lines up where `Modified` and `Renamed` would not. A rename is one row rather than the
  /// delete-and-add pair a raw tree diff reports — `git_diff_find_similar` is what folds it back
  /// into one, and without it a directory move reads as twice the work it was and spends twice
  /// the budget saying so.
  struct CommitFile: Equatable {
    enum Status: String, Equatable {
      case added = "A"
      case modified = "M"
      case deleted = "D"
      case renamed = "R"
      case copied = "C"
      case typeChanged = "T"
    }
    let path: String
    /// Where the file came from, on a rename or a copy; nil otherwise.
    let oldPath: String?
    let status: Status
    /// nil where the count was not paid for: a commit wider than `commitFileCap`, where counting
    /// means diffing every file's content, and a binary, where lines are not the unit.
    let added: Int?
    let removed: Int?
    let isBinary: Bool
  }

  /// One commit as its tab reads it: what it says, and which files it touched. Not the diff —
  /// that is `fileDiff`, one file at a time, because a file is what a reader opens and so what
  /// the cost should be charged to. Reading a commit whole is what used to freeze the window for
  /// the best part of a second on a vendor drop, and no cap on the *commit* fixed that honestly:
  /// the caps counted changed lines, while what gets laid out is the patch, which carries every
  /// hunk's context too — measured at 4.5× the changed-line count on scattered edits.
  struct CommitDetail: Equatable {
    let oid: String
    let summary: String
    /// The message past its summary line, already trimmed. Empty for a one-line message.
    let body: String
    let author: String
    let date: Date
    let files: [CommitFile]
    /// The commit is wider than `commitFileCap`, so its files arrive with their status and no
    /// counts. The list itself stays free — the tree diff already knows its deltas — so even the
    /// 5000-file drop says what it touched, and charges for a file's lines only when one is
    /// opened.
    let countsOmitted: Bool
    var shortOID: String { String(oid.prefix(7)) }
  }

  /// Past this many files a commit's per-file counts are dropped rather than counted: counting
  /// means building every delta's patch, which on a 5000-file commit is 363ms. The file list
  /// survives it, because `git_diff_num_deltas` is free.
  private static let commitFileCap = 500

  /// Past either of these a file's diff is not built. Lines catch the generated file; bytes catch
  /// the minified one, which is two changed lines and three megabytes — and which no count-based
  /// cap ever sees coming.
  private static let filePatchLineCap = 20_000
  private static let filePatchByteCap = 1 << 20

  /// Past this a side is not read for colouring: parsing stays fast, but a megabyte of generated
  /// source is not what anyone is reading a diff of.
  private static let sourceByteCap = 1_000_000

  /// One commit's message and file list. Diffed against its first parent, which is the same
  /// simplification the history list makes; a root commit is diffed against nothing, so it reads
  /// as all additions.
  static func commit(at url: URL, oid: String) -> CommitDetail? {
    guard let repo = openRepository(at: url) else { return nil }
    defer { git_repository_free(repo) }
    var id = git_oid()
    guard git_oid_fromstr(&id, oid) == 0 else { return nil }
    var commit: OpaquePointer?
    guard git_commit_lookup(&commit, repo, &id) == 0, let commit else { return nil }
    defer { git_commit_free(commit) }
    guard let diff = commitDiff(repo, commit: commit) else { return nil }
    defer { git_diff_free(diff) }

    let deltas = Int(git_diff_num_deltas(diff))
    let counted = deltas <= commitFileCap
    var files: [CommitFile] = []
    for i in 0..<deltas {
      guard let delta = git_diff_get_delta(diff, i) else { continue }
      files.append(commitFile(delta, in: diff, at: i, counted: counted))
    }

    let summary = git_commit_summary(commit).map { String(cString: $0) } ?? ""
    let body = git_commit_body(commit).map { String(cString: $0) } ?? ""
    let author = git_commit_author(commit)?.pointee.name.map { String(cString: $0) } ?? ""
    return CommitDetail(
      oid: String(cString: git_oid_tostr_s(&id)),
      summary: summary,
      body: body.trimmingCharacters(in: .whitespacesAndNewlines),
      author: author,
      date: Date(timeIntervalSince1970: TimeInterval(git_commit_time(commit))),
      files: files,
      countsOmitted: !counted)
  }

  /// One file's diff, as the rows the tab draws — not as patch text.
  ///
  /// A row already knows which side it is on and which line number it carries there, which is
  /// what lets the gutter number both sides and the `+`/`-` column disappear into a coloured
  /// band. It also leaves `diff --git`, `index`, `---` and `+++` unbuilt: the section's header
  /// row says the path and the status, so those four lines per file would only say it again.
  struct FileDiff: Equatable {
    enum Kind: Equatable {
      case context, added, removed
    }
    enum Row: Equatable {
      /// A hunk's `@@ … @@` header, function context and all.
      case hunk(String)
      case line(old: Int?, new: Int?, kind: Kind, text: String)
    }
    /// Why there are no rows. The section still opens and says this, so a wall is one file wide
    /// rather than the whole commit's.
    enum Note: Equatable {
      case binary
      case tooLarge(lines: Int, bytes: Int)
      /// The commit no longer has that path — a list built before an amend, opened after it.
      case unreadable
    }
    var rows: [Row] = []
    var note: Note?
    /// The file's own text on each side, when it is text, small enough, and asked for. The colours
    /// in a diff come from parsing the *file*: a hunk starts mid-scope, so a grammar reading one
    /// alone gets its strings, comments and braces wrong at both ends.
    var newSource: String?
    var oldSource: String?
  }

  /// The diff of one path within `oid`, against the commit's first parent. `wantsSource` reads
  /// the two blobs the colouring needs — the caller leaves it off where no grammar covers the
  /// path, so a diff of something unhighlightable costs one patch and nothing else.
  static func fileDiff(at url: URL, oid: String, path: String, wantsSource: Bool) -> FileDiff? {
    guard let repo = openRepository(at: url) else { return nil }
    defer { git_repository_free(repo) }
    var id = git_oid()
    guard git_oid_fromstr(&id, oid) == 0 else { return nil }
    var commit: OpaquePointer?
    guard git_commit_lookup(&commit, repo, &id) == 0, let commit else { return nil }
    defer { git_commit_free(commit) }
    guard let diff = commitDiff(repo, commit: commit) else { return nil }
    defer { git_diff_free(diff) }

    for i in 0..<git_diff_num_deltas(diff) {
      guard let delta = git_diff_get_delta(diff, i) else { continue }
      let newPath = delta.pointee.new_file.path.map { String(cString: $0) }
      let oldPath = delta.pointee.old_file.path.map { String(cString: $0) }
      guard newPath == path || oldPath == path else { continue }
      var patch: OpaquePointer?
      guard git_patch_from_diff(&patch, diff, i) == 0, let patch else { return nil }
      defer { git_patch_free(patch) }
      var result = rows(of: patch)
      if wantsSource, result.note == nil {
        result.newSource = newPath.flatMap { source(repo, commit: commit, path: $0, new: true) }
        result.oldSource = oldPath.flatMap { source(repo, commit: commit, path: $0, new: false) }
      }
      return result
    }
    return nil
  }

  /// A commit against its first parent, renames folded back together. The caller frees it.
  private static func commitDiff(_ repo: OpaquePointer, commit: OpaquePointer) -> OpaquePointer? {
    var tree: OpaquePointer?
    guard git_commit_tree(&tree, commit) == 0, let tree else { return nil }
    defer { git_tree_free(tree) }
    var parentTree: OpaquePointer?
    var parent: OpaquePointer?
    if git_commit_parent(&parent, commit, 0) == 0, let parent {
      defer { git_commit_free(parent) }
      git_commit_tree(&parentTree, parent)
    }
    defer { if let parentTree { git_tree_free(parentTree) } }

    var options = git_diff_options()
    git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
    var diff: OpaquePointer?
    guard git_diff_tree_to_tree(&diff, repo, parentTree, tree, &options) == 0, let diff else {
      return nil
    }
    // Only where the diff is narrow enough for the similarity pass to be affordable — and a drop
    // that wide has nothing to find anyway.
    if git_diff_num_deltas(diff) <= commitFileCap {
      var find = git_diff_find_options()
      git_diff_find_options_init(&find, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION))
      find.flags = UInt32(GIT_DIFF_FIND_RENAMES.rawValue)
      git_diff_find_similar(diff, &find)
    }
    return diff
  }

  /// One delta as a row: its path, its status, and — where the commit is narrow enough to pay for
  /// it — how many lines moved. `git_patch_from_diff` is what counts them, and it is also what
  /// tells the truth about a binary (the flag is set only once content has been looked at), so
  /// both answers come out of the one pass.
  private static func commitFile(
    _ delta: UnsafePointer<git_diff_delta>, in diff: OpaquePointer, at index: Int, counted: Bool
  ) -> CommitFile {
    let newPath = delta.pointee.new_file.path.map { String(cString: $0) } ?? ""
    let oldPath = delta.pointee.old_file.path.map { String(cString: $0) } ?? ""
    let status: CommitFile.Status
    switch delta.pointee.status {
    case GIT_DELTA_ADDED: status = .added
    case GIT_DELTA_DELETED: status = .deleted
    case GIT_DELTA_RENAMED: status = .renamed
    case GIT_DELTA_COPIED: status = .copied
    case GIT_DELTA_TYPECHANGE: status = .typeChanged
    default: status = .modified
    }
    var isBinary = delta.pointee.flags & UInt32(GIT_DIFF_FLAG_BINARY.rawValue) != 0
    var added: Int?
    var removed: Int?
    if counted {
      var patch: OpaquePointer?
      if git_patch_from_diff(&patch, diff, index) == 0, let patch {
        defer { git_patch_free(patch) }
        if let examined = git_patch_get_delta(patch) {
          isBinary = examined.pointee.flags & UInt32(GIT_DIFF_FLAG_BINARY.rawValue) != 0
        }
        var context = 0
        var additions = 0
        var deletions = 0
        if !isBinary, git_patch_line_stats(&context, &additions, &deletions, patch) == 0 {
          added = additions
          removed = deletions
        }
      }
    }
    let moved = status == .renamed || status == .copied
    return CommitFile(
      path: status == .deleted ? oldPath : newPath,
      oldPath: moved && oldPath != newPath ? oldPath : nil,
      status: status, added: added, removed: removed, isBinary: isBinary)
  }

  /// A patch's hunks and lines, or the note saying why they were not built.
  private static func rows(of patch: OpaquePointer) -> FileDiff {
    var result = FileDiff()
    if let delta = git_patch_get_delta(patch),
      delta.pointee.flags & UInt32(GIT_DIFF_FLAG_BINARY.rawValue) != 0
    {
      result.note = .binary
      return result
    }

    let hunks = git_patch_num_hunks(patch)
    var lines = 0
    for h in 0..<hunks {
      var hunk: UnsafePointer<git_diff_hunk>?
      var linesInHunk = 0
      guard git_patch_get_hunk(&hunk, &linesInHunk, patch, h) == 0 else { continue }
      lines += linesInHunk
    }
    // `git_patch_size` answers in bytes without building the text — which is the whole point,
    // since building it is the cost being refused.
    let bytes = Int(git_patch_size(patch, 1, 1, 0))
    guard lines <= filePatchLineCap, bytes <= filePatchByteCap else {
      result.note = .tooLarge(lines: lines, bytes: bytes)
      return result
    }

    result.rows.reserveCapacity(lines + Int(hunks))
    for h in 0..<hunks {
      var hunk: UnsafePointer<git_diff_hunk>?
      var linesInHunk = 0
      guard git_patch_get_hunk(&hunk, &linesInHunk, patch, h) == 0, let hunk else { continue }
      result.rows.append(.hunk(header(of: hunk.pointee)))
      for l in 0..<linesInHunk {
        var line: UnsafePointer<git_diff_line>?
        guard git_patch_get_line_in_hunk(&line, patch, h, l) == 0, let line else { continue }
        let text = content(of: line.pointee)
        switch UInt8(bitPattern: line.pointee.origin) {
        case UInt8(ascii: "+"):
          result.rows.append(
            .line(old: nil, new: Int(line.pointee.new_lineno), kind: .added, text: text))
        case UInt8(ascii: "-"):
          result.rows.append(
            .line(old: Int(line.pointee.old_lineno), new: nil, kind: .removed, text: text))
        case UInt8(ascii: " "):
          result.rows.append(
            .line(
              old: Int(line.pointee.old_lineno), new: Int(line.pointee.new_lineno),
              kind: .context, text: text))
        default:
          // `\ No newline at end of file`, and the binary markers — nothing a numbered row can
          // carry, and nothing a reader loses by not seeing.
          break
        }
      }
    }
    return result
  }

  /// A hunk's header, `@@ -12,7 +12,9 @@ func commit(…)` — a fixed C array, so it is read through
  /// its own storage rather than as a Swift tuple.
  private static func header(of hunk: git_diff_hunk) -> String {
    let text = withUnsafeBytes(of: hunk.header) { raw -> String in
      guard let base = raw.baseAddress else { return "" }
      return String(cString: base.assumingMemoryBound(to: CChar.self))
    }
    return text.trimmingCharacters(in: .newlines)
  }

  /// One diff line's text, without its newline: the row *is* the line, so the break is the
  /// document's to add.
  private static func content(of line: git_diff_line) -> String {
    guard let pointer = line.content, line.content_len > 0 else { return "" }
    var text = String(
      decoding: UnsafeRawBufferPointer(start: pointer, count: Int(line.content_len)),
      as: UTF8.self)
    if text.hasSuffix("\n") { text.removeLast() }
    if text.hasSuffix("\r") { text.removeLast() }
    return text
  }

  /// One side's whole file text out of a commit's tree — `new: false` reads the first parent's.
  private static func source(
    _ repo: OpaquePointer, commit: OpaquePointer, path: String, new: Bool
  ) -> String? {
    var tree: OpaquePointer?
    if new {
      guard git_commit_tree(&tree, commit) == 0 else { return nil }
    } else {
      var parent: OpaquePointer?
      guard git_commit_parent(&parent, commit, 0) == 0, let parent else { return nil }
      defer { git_commit_free(parent) }
      guard git_commit_tree(&tree, parent) == 0 else { return nil }
    }
    guard let tree else { return nil }
    defer { git_tree_free(tree) }

    var entry: OpaquePointer?
    guard git_tree_entry_bypath(&entry, tree, path) == 0, let entry else { return nil }
    defer { git_tree_entry_free(entry) }
    var blob: OpaquePointer?
    guard git_blob_lookup(&blob, repo, git_tree_entry_id(entry)) == 0, let blob else { return nil }
    defer { git_blob_free(blob) }
    let size = Int(git_blob_rawsize(blob))
    guard size > 0, size <= sourceByteCap, git_blob_is_binary(blob) == 0,
      let bytes = git_blob_rawcontent(blob)
    else { return nil }
    return String(decoding: UnsafeRawBufferPointer(start: bytes, count: size), as: UTF8.self)
  }

  /// Each delta of `diff` with its line counts — the same shape `changedFiles` reports, so a
  /// commit's files and a working tree's read alike.
  private static func fileStats(in diff: OpaquePointer) -> [ChangedFile] {
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
    // A rebase replays onto a detached HEAD, whose shorthand is the literal "HEAD" — so a
    // worktree in the middle of one lost its name on the rail and in the top bar for as long as
    // the rebase ran. git knows which branch it is putting back; ask it.
    if git_repository_head_detached(repo) == 1, let branch = operation(in: repo)?.branch {
      return branch
    }
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

  /// What git has underway in this worktree, if anything.
  ///
  /// The *kind* is `git_repository_state`, which is one read of the gitdir and no walk. The
  /// progress is read out of the gitdir's own files rather than through `git_rebase_open`,
  /// because that call opens a rebase in order to *drive* it — `git_rebase_next`, `commit`,
  /// `abort` — and hukan observes worktrees, it does not act on them. What it wants is the three
  /// numbers git already wrote down.
  ///
  /// Note the enum is not a label: git has run every rebase through the merge backend since 2.26,
  /// so it leaves an `interactive` marker in `rebase-merge/` even for a plain `git rebase main`
  /// — which makes libgit2 answer `REBASE_INTERACTIVE` for both. Saying "interactive rebase"
  /// because the enum did would be reporting git's plumbing rather than what is happening.
  private static func operation(in repo: OpaquePointer) -> Operation? {
    let kind: Operation.Kind
    switch git_repository_state_t(UInt32(git_repository_state(repo))) {
    case GIT_REPOSITORY_STATE_MERGE: kind = .merge
    case GIT_REPOSITORY_STATE_REVERT, GIT_REPOSITORY_STATE_REVERT_SEQUENCE: kind = .revert
    case GIT_REPOSITORY_STATE_CHERRYPICK, GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE:
      kind = .cherryPick
    case GIT_REPOSITORY_STATE_BISECT: kind = .bisect
    case GIT_REPOSITORY_STATE_REBASE, GIT_REPOSITORY_STATE_REBASE_INTERACTIVE,
      GIT_REPOSITORY_STATE_REBASE_MERGE:
      kind = .rebase
    case GIT_REPOSITORY_STATE_APPLY_MAILBOX, GIT_REPOSITORY_STATE_APPLY_MAILBOX_OR_REBASE:
      kind = .applyMailbox
    default: return nil
    }

    // The worktree's own gitdir, which for a linked worktree is `…/.git/worktrees/<name>/` — the
    // same directory the watcher had to be taught about, so this state goes stale exactly as
    // rarely as the diffstat does.
    guard let path = git_repository_path(repo) else {
      return Operation(kind: kind, branch: nil, step: nil, total: nil)
    }
    let gitDirectory = URL(fileURLWithPath: String(cString: path))
    // Two layouts: the merge backend counts `msgnum` of `end`, the apply backend `next` of
    // `last`. Which one is running is which directory exists.
    for (directory, current, last) in [
      ("rebase-merge", "msgnum", "end"), ("rebase-apply", "next", "last"),
    ] {
      let base = gitDirectory.appendingPathComponent(directory)
      guard FileManager.default.fileExists(atPath: base.path) else { continue }
      func read(_ name: String) -> String? {
        try? String(contentsOf: base.appendingPathComponent(name), encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      let branch = read("head-name").map {
        $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0
      }
      return Operation(
        kind: kind, branch: branch, step: read(current).flatMap(Int.init),
        total: read(last).flatMap(Int.init))
    }
    return Operation(kind: kind, branch: nil, step: nil, total: nil)
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
    // Untracked files are part of the change, and are the *only* thing a brand-new file is: a
    // diff without them made the file an agent had just written — or the files panel's own New
    // File — invisible everywhere hukan reads a change from, the tree included, until something
    // ran `git add`. `git diff HEAD` leaves them out and `git status` does not; this is the
    // second reading, since what hukan is answering is "what has moved in this worktree".
    // Recursing is what makes an untracked *directory* report its files rather than itself, and
    // the content flag is what gives those files line counts instead of 0/0. Ignored files stay
    // out, which is libgit2's default and the only part of this nobody wants changed.
    options.flags =
      UInt32(GIT_DIFF_INCLUDE_UNTRACKED.rawValue)
      | UInt32(GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue)
      | UInt32(GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue)
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
