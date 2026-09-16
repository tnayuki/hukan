import Foundation

/// The files panel's two gestures, both of them one `rg` per gesture: the filter's rows and the
/// content search's hits, streamed while the process runs and killed when the gesture is
/// superseded.
///
/// It is the one thing hukan spawns. The line it does not cross is the one libgit2 is here for —
/// git was spawned per FSEvents batch per worktree, which is a process storm nobody asked for —
/// where this is a process per *gesture*, started by someone typing and cancelled by their next
/// keystroke. What it buys is what hukan could not do for itself: the walk prunes by every
/// `.gitignore` it passes on the way down, nested repositories included and, with
/// `--no-require-git`, directories that are not repositories at all. That is what makes a
/// directory with no git above it survivable at all — the home directory here is 4.56M entries
/// walked blind against 1.56M files pruned.
///
/// The binary is bundled (`Vendor/build-ripgrep.sh` builds `Resources/rg` from a pinned source
/// release), so it is named by absolute path: no PATH to consult, and nothing for the user to
/// have uninstalled.
enum Ripgrep {
  /// The bundled binary, or nil where there is none — a test host without the resource, a build
  /// that dropped it. Every entry point answers "nothing found" rather than trapping, so the
  /// panel degrades to what git can tell it instead of coming up empty with no explanation.
  static let binary: URL? = Bundle.main.url(forResource: "rg", withExtension: nil)

  /// One line of a file that matched, which is the unit the search's result list is built from.
  struct Hit: Equatable {
    let path: String
    let line: Int
    let text: String
  }

  /// What every invocation says, whatever it is being asked: the worktree as it is on disk, less
  /// what git ignores, less the repository itself.
  ///
  /// `--hidden` because a dotfile is a file — and then `!.git`, because `.git` is the repository
  /// and not the worktree, and `--hidden` would otherwise walk straight into it (2,562 paths in
  /// this repository alone). A glob with no leading slash matches at every depth, so the one
  /// pattern covers a nested repository's gitdir too. `--no-require-git` is what applies a
  /// `.gitignore` in a directory nobody ran `git init` in, which is most of a home directory.
  private static let common = [
    "--hidden", "--no-require-git", "--no-messages", "--glob", "!.git",
  ]

  /// A run in flight. Cancelling kills the process: the reader has moved on, and what it was
  /// producing must neither land nor hold the next one behind it.
  final class Run {
    private let process: Process
    private let lock = NSLock()
    private var cancelled = false

    init(process: Process) { self.process = process }

    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }

    func cancel() {
      lock.lock()
      cancelled = true
      lock.unlock()
      if process.isRunning { process.terminate() }
    }
  }

  /// The files under `root` whose path matches `query` — every file when it is empty — handed
  /// over in batches as rg walks, relative and in rg's own order.
  ///
  /// The matching is rg's: two globs, which between them are the rule the panel's filter has
  /// always had. `**/*q*` matches a path component containing the query and `**/*q*/**` matches
  /// anything under such a directory, so typing `Tests` narrows to the directory's contents and
  /// typing `Hukan/Files` narrows by two components at once — measured against the substring
  /// match this replaces, on this repository, the two answer identically. What a glob will not do
  /// is straddle a separator inside a component, which the substring did: a `/` in the query has
  /// to line up with one in the path.
  ///
  /// Not `--sort path`: it serialises the walk, and on a home directory that is 9.5s against
  /// 29.6s (measured). What has to be in path order is the matches, which is a sort of what
  /// survived rather than of everything walked.
  @discardableResult
  static func files(
    in root: URL, matching query: String = "", on callbackQueue: DispatchQueue = .main,
    batch: @escaping (Data) -> Void, completion: @escaping (Bool) -> Void
  ) -> Run? {
    run(
      arguments: ["--files", "--null"] + common + globs(for: query), in: root, separator: 0,
      on: callbackQueue, batch: batch, completion: completion)
  }

  /// The lines under `root` that contain `query`, literally and without regard to case, in the
  /// order rg finishes files in. `paths`, when given, is what to search instead of the whole
  /// worktree — the ± scope's changed set, which git has already answered for.
  ///
  /// Not `--sort path`, for the same reason the listing refuses it: it serialises the walk, which
  /// is three times the wall clock on a large tree. Order is the caller's to put back, over a
  /// list it is holding anyway.
  ///
  /// Nothing is capped and no file is skipped for its size. The scan this replaces did both — a
  /// 2000-hit limit and a 2MB file — because it read every file itself, in rounds, on this
  /// machine's cores: the limit was what kept a query like `e` from costing ten thousand rows of
  /// work that nobody asked for. rg streams instead, so the rows arrive as they are found and a
  /// query nobody wants the whole of is cancelled by typing the next one. What is still skipped
  /// is a binary file, which is rg's own default and was the old scan's rule too.
  @discardableResult
  static func search(
    in root: URL, for query: String, in paths: [String] = [],
    on callbackQueue: DispatchQueue = .main,
    batch: @escaping ([Hit]) -> Void, completion: @escaping (Bool) -> Void
  ) -> Run? {
    run(
      arguments: ["--json", "--fixed-strings", "--ignore-case"]
        + common + ["--", query] + paths, in: root, separator: UInt8(ascii: "\n"),
      on: callbackQueue,
      batch: { data in
        let hits = data.split(separator: UInt8(ascii: "\n")).compactMap(hit(from:))
        guard !hits.isEmpty else { return }
        batch(hits)
      }, completion: completion)
  }

  /// One `match` event of rg's JSON, or nil for any other line — `begin`, `end` and `summary` say
  /// nothing the result list shows, and a line whose text rg could not decode carries `bytes`
  /// instead of `text`, which is a file the old scan skipped as binary too.
  private static func hit(from line: Data.SubSequence) -> Hit? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
      object["type"] as? String == "match", let data = object["data"] as? [String: Any],
      let path = (data["path"] as? [String: Any])?["text"] as? String,
      let number = data["line_number"] as? Int,
      let text = (data["lines"] as? [String: Any])?["text"] as? String
    else { return nil }
    // rg keeps the line's own terminator; a row in the list is the line, not the line break.
    return Hit(
      path: path, line: number,
      text: text.hasSuffix("\n") ? String(text.dropLast()) : text)
  }

  /// The globs that narrow a listing to a typed query, with the query's own glob characters
  /// escaped — someone filtering for `*.swift` means the two characters, not a pattern.
  private static func globs(for query: String) -> [String] {
    guard !query.isEmpty else { return [] }
    let escaped = query.map { "*?[]{}\\".contains($0) ? "\\\($0)" : String($0) }.joined()
    return ["--glob-case-insensitive", "-g", "**/*\(escaped)*", "-g", "**/*\(escaped)*/**"]
  }

  /// One rg, its standard output split on `separator` and handed over as it arrives.
  ///
  /// The read is on a queue of its own, and the batches land on `callbackQueue` — the main one
  /// for a caller that draws them, a queue of the caller's own where they are parsed or collected
  /// first. What crosses the boundary is a batch rather than a line: a home directory is 1.6M
  /// paths, and a hop each would be the walk's cost all over again.
  private static func run(
    arguments: [String], in root: URL, separator: UInt8, on callbackQueue: DispatchQueue,
    batch: @escaping (Data) -> Void, completion: @escaping (Bool) -> Void
  ) -> Run? {
    guard let binary else {
      callbackQueue.async { completion(false) }
      return nil
    }
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    process.currentDirectoryURL = root
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let run = Run(process: process)

    do {
      try process.run()
    } catch {
      callbackQueue.async { completion(false) }
      return nil
    }

    DispatchQueue.global(qos: .userInitiated).async {
      var carry = Data()
      while true {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        carry.append(chunk)
        // The tail after the last separator is a record still being written; it waits for the
        // chunk that finishes it.
        guard let last = carry.lastIndex(of: separator) else { continue }
        let complete = Data(carry[carry.startIndex...last])
        carry = Data(carry[carry.index(after: last)...])
        guard !run.isCancelled else { continue }
        // Synchronously, which is the backpressure: handed over `async`, the reader runs as fast
        // as rg writes and the chunks queue up behind a consumer that is slower — the whole of
        // the walk's output held twice, which is what a home directory's 756MB spike was. Waiting
        // here fills the pipe instead, and rg blocks on the write until there is room. The
        // consumer never waits on this thread, so there is nothing for the wait to deadlock on.
        callbackQueue.sync { batch(complete) }
      }
      process.waitUntilExit()
      // Finished means the walk was not abandoned, and nothing else. rg exits 1 when nothing
      // matched and 2 when a directory could not be read — and on a home directory the second is
      // the ordinary case, several of the ones under `~/Library` being TCC-protected, where
      // `--no-messages` silences the complaint rather than the status. Reading either as "did not
      // finish" left the filter saying it was still reading for good, and the content search
      // waiting for a list that never came.
      callbackQueue.async { completion(!run.isCancelled) }
    }
    return run
  }
}
