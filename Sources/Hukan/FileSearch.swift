import Foundation

/// A literal, case-insensitive search over a worktree's files, one hit per matching line. Pure —
/// no view, no git — so it is testable on a temp directory. It reads the disk, not the open
/// buffers: the Files tab's hits are a worklist of what is *there*, and an unsaved edit is not
/// there yet.
///
/// **Case-insensitive means ASCII case folding**, on bytes, and that is the one rule both this
/// and the panel's path filter match by (`FoldedText`), so "did this match" is the same question
/// in both of the field's two gestures. Foundation's `.caseInsensitive` was the obvious way to
/// write it and it is what made the search unusable: on a 25,000-file checkout a whole-worktree
/// scan took 10.5s, of which the matching alone — `range(of:options:.caseInsensitive)` once per
/// line, seven million of them — was most, and searching each file's text as one string instead
/// was five times worse again. What it buys over folding bytes is case-insensitivity for
/// *accented Latin*: `CAFÉ` no longer answers to `café`. Nothing else moves — a query with no
/// case of its own (Japanese, digits, punctuation) matches exactly as it did, since folding
/// leaves those bytes alone, and an ASCII byte cannot occur inside a UTF-8 multi-byte sequence,
/// so a folded byte scan is a true substring test rather than an approximation of one.
enum FileSearch {
  struct Hit: Equatable {
    let path: String
    /// 1-based, the way an editor counts.
    let line: Int
    /// The matching line, trimmed of its newline (not of its indent — the indent is the context).
    let text: String
  }

  /// Past this many hits the scan stops and says so — a query like `e` is not a worklist, and the
  /// point of the cap is to keep the list answerable rather than to render ten thousand rows.
  static let limit = 2000
  /// A file this large is not source you fix by hand; skipping it keeps the scan instant.
  static let maxFileSize = 2 << 20
  /// How many files one round reads at once. The files of a round are read in parallel, but the
  /// rounds themselves are in path order, so the cap above always cuts the same 2000 hits it
  /// would have cut serially — with one `concurrentPerform` per file instead, whichever files
  /// happened to finish first would decide what the cap kept.
  private static let round = 128

  /// `paths` relative to `root`, in the order given — the hits come back in that order, then by
  /// line. Binary (a NUL in its first KB) and non-UTF-8 files are skipped, as `git grep` skips
  /// them.
  ///
  /// `isCancelled` is asked once per round, which is what makes a scan abandonable: it reads
  /// every file of a large worktree, so without it a query typed by mistake goes on reading for
  /// ten seconds, the next Return queues behind it, and each FSEvents batch under an agent's
  /// writes queues another.
  static func scan(
    query: String, paths: [String], root: URL, isCancelled: () -> Bool = { false }
  ) -> (hits: [Hit], truncated: Bool) {
    guard !query.isEmpty else { return ([], false) }
    let needle = FoldedText(query)
    var hits: [Hit] = []
    var start = 0
    while start < paths.count {
      if isCancelled() { return (hits, false) }
      let end = min(start + round, paths.count)
      var found = [[Hit]](repeating: [], count: end - start)
      found.withUnsafeMutableBufferPointer { buffer in
        DispatchQueue.concurrentPerform(iterations: buffer.count) { index in
          buffer[index] = self.hits(in: paths[start + index], root: root, needle: needle)
        }
      }
      for file in found {
        hits.append(contentsOf: file)
        if hits.count >= limit { return (Array(hits.prefix(limit)), true) }
      }
      start = end
    }
    return (hits, false)
  }

  /// One file's hits. The file's bytes are searched whole before anything is decoded: a file with
  /// no match at all is the overwhelming majority, and answering that from the mapped bytes costs
  /// no `String` conversion and no walk over its lines.
  private static func hits(in path: String, root: URL, needle: FoldedText) -> [Hit] {
    let url = root.appendingPathComponent(path)
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
      data.count <= maxFileSize
    else { return [] }
    let matched = data.withUnsafeBytes { raw -> Bool in
      let bytes = raw.bindMemory(to: UInt8.self)
      guard !isBinary(bytes) else { return false }
      return needle.occurs(in: bytes)
    }
    guard matched, let text = String(data: data, encoding: .utf8) else { return [] }

    var found: [Hit] = []
    var line = 0
    text.enumerateLines { content, done in
      line += 1
      guard needle.occurs(in: content) else { return }
      found.append(Hit(path: path, line: line, text: content))
      if found.count >= limit { done = true }
    }
    return found
  }

  /// A NUL in the first KB, the way `git grep` decides the same thing.
  private static func isBinary(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
    for index in 0..<min(1024, bytes.count) where bytes[index] == 0 { return true }
    return false
  }
}

/// A query prepared once for matching: its bytes, ASCII-folded to lower case. See `FileSearch`
/// for what folding bytes does and does not answer for.
///
/// The haystack side is folded a byte at a time as it is compared rather than up front, because
/// the caller's haystack is a memory-mapped file it must not copy 2 MB of to ask one question.
struct FoldedText {
  private let bytes: [UInt8]

  init(_ text: String) {
    bytes = text.utf8.map(FoldedText.fold)
  }

  var isEmpty: Bool { bytes.isEmpty }

  @inline(__always)
  private static func fold(_ byte: UInt8) -> UInt8 {
    byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte | 0x20 : byte
  }

  /// Both sides bound to raw buffers, and the first byte gating the compare: this runs over a
  /// whole worktree's bytes — hundreds of megabytes — in the app's own unoptimized build, so what
  /// the loop touches per byte is the whole cost. Written the obvious way, with the needle read
  /// off the stored property inside the loop, the same scan did not finish in five minutes.
  ///
  /// `memchr` for the gaps was tried and is worse, not better: a letter has two spellings to look
  /// for, and on a common first letter the candidates are dense enough (`a`/`A` is some 5% of
  /// source text) that the per-call cost outweighs what the vector loop saves.
  func occurs(in haystack: UnsafeBufferPointer<UInt8>) -> Bool {
    bytes.withUnsafeBufferPointer { needle -> Bool in
      guard let first = needle.first, haystack.count >= needle.count else { return false }
      let length = needle.count
      let last = haystack.count - length
      var start = 0
      while start <= last {
        if Self.fold(haystack[start]) == first {
          var index = 1
          while index < length, Self.fold(haystack[start + index]) == needle[index] { index += 1 }
          if index == length { return true }
        }
        start += 1
      }
      return false
    }
  }

  /// The same test against a haystack that was folded ahead of time — the panel's path filter,
  /// where the paths are prepared once when git's answer moves rather than on every keystroke.
  /// Folding is idempotent, so the compare below re-folding bytes that are already folded costs
  /// a branch and changes nothing.
  func occurs(in other: FoldedText) -> Bool {
    other.bytes.withUnsafeBufferPointer { occurs(in: $0) }
  }

  /// The same test against a `String`, over its UTF-8 without copying it where the standard
  /// library can hand the storage over — which for a native Swift string it always can.
  func occurs(in text: String) -> Bool {
    var text = text
    let found = text.withUTF8 { occurs(in: $0) }
    return found
  }
}
