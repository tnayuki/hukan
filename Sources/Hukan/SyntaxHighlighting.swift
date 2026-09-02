import AppKit
import CtreesitterParsers
import SwiftTreeSitter

/// The source pane's syntax highlighting: tree-sitter parses (the grammars vendored in
/// CtreesitterParsers.xcframework, the runtime via SwiftTreeSitter) and the colors land as
/// TextKit 2 *rendering* attributes — display-only, so the document text, its undo stack and
/// the dirty state never learn highlighting exists.
enum SyntaxHighlighting {
  /// The vendored grammars, keyed by file extension. A language is added by teaching
  /// Vendor/build-tree-sitter.sh to compile it and listing its extensions here.
  ///
  /// `.h` goes to C++ rather than to C on purpose: tree-sitter's C++ grammar is built by
  /// extending its C one, so it reads a C header correctly while the C grammar would choke on
  /// a C++ one. The extension cannot say which it is, and only one of the two answers is safe.
  private static let grammars: [String: (name: String, language: OpaquePointer)] = [
    "swift": ("swift", tree_sitter_swift()),
    "ts": ("typescript", tree_sitter_typescript()),
    "mts": ("typescript", tree_sitter_typescript()),
    "cts": ("typescript", tree_sitter_typescript()),
    "tsx": ("tsx", tree_sitter_tsx()),
    "js": ("javascript", tree_sitter_javascript()),
    "mjs": ("javascript", tree_sitter_javascript()),
    "cjs": ("javascript", tree_sitter_javascript()),
    "jsx": ("javascript", tree_sitter_javascript()),
    "py": ("python", tree_sitter_python()),
    "pyi": ("python", tree_sitter_python()),
    "rb": ("ruby", tree_sitter_ruby()),
    "rake": ("ruby", tree_sitter_ruby()),
    "gemfile": ("ruby", tree_sitter_ruby()),
    "rs": ("rust", tree_sitter_rust()),
    "go": ("go", tree_sitter_go()),
    "c": ("c", tree_sitter_c()),
    "h": ("cpp", tree_sitter_cpp()),
    "cpp": ("cpp", tree_sitter_cpp()),
    "cc": ("cpp", tree_sitter_cpp()),
    "cxx": ("cpp", tree_sitter_cpp()),
    "hpp": ("cpp", tree_sitter_cpp()),
    "hh": ("cpp", tree_sitter_cpp()),
    "cs": ("c-sharp", tree_sitter_c_sharp()),
    "sh": ("bash", tree_sitter_bash()),
    "bash": ("bash", tree_sitter_bash()),
    "zsh": ("bash", tree_sitter_bash()),
    "json": ("json", tree_sitter_json()),
    "yml": ("yaml", tree_sitter_yaml()),
    "yaml": ("yaml", tree_sitter_yaml()),
    "md": ("markdown", tree_sitter_markdown()),
    "markdown": ("markdown", tree_sitter_markdown()),
    // A patch is not a language and its grammar knows it: what the diff grammar reads is the
    // frame — which file, which hunk, which side — and what it says about the payload is that
    // the payload belongs to the file it names. Three extensions and no more, because a patch
    // read from a pipe has no name to be found by: `git format-patch` writes `.patch`, a
    // redirected `git diff` is `.diff` by convention, and `git apply --reject` leaves `.rej`.
    "diff": ("diff", tree_sitter_diff()),
    "patch": ("diff", tree_sitter_diff()),
    "rej": ("diff", tree_sitter_diff()),
  ]

  /// Grammars no file extension reaches: they exist to be injected into another language.
  /// Markdown is two grammars — one for the block structure, one for what is inside a
  /// paragraph — and only the first is ever opened as a file.
  private static let injectedGrammars: [String: (name: String, language: OpaquePointer)] = [
    "markdown_inline": ("markdown-inline", tree_sitter_markdown_inline())
  ]

  /// How deep an injection may nest. Markdown reaches Markdown-inline reaches HTML, and a
  /// fenced block reaches whatever its info string names; three is past anything real and
  /// stops a grammar that injects itself from running away.
  private static let injectionDepth = 3

  /// Past this many characters the file is left plain. A parse stays fast, but the spans are
  /// applied one attribute run at a time, and a machine-generated file (a tree-sitter
  /// parser.c is 20 MB) would spend that on text nobody is reading.
  static let sizeLimit = 1_000_000

  /// What a span asks of the glyphs beyond their colour: a weight, a slant. Drawn by
  /// `EmphasisFragment` at render time, never by the font, so the layout stays the layout.
  struct Emphasis: OptionSet, Hashable {
    let rawValue: UInt8
    static let bold = Emphasis(rawValue: 1)
    static let italic = Emphasis(rawValue: 2)
  }

  /// What a capture asks for. `plain` is a style in its own right, not the absence of one:
  /// Markdown's `(code_fence_content) @none` says a fence's content is nobody's language, and
  /// `@embedded` says an interpolation is not part of the string around it. Read as "nothing to
  /// say" — one nil doing for both "plain" and "unknown" — the colour they were correcting
  /// stands, and the fence keeps the red of the block it sits in. Only a name the theme has
  /// never heard of is nil.
  enum Style {
    /// Plain in colour. Emphasis is left alone: a capture saying "this is punctuation" is
    /// saying what it is, not that the bold around it has ended — the `**` of a `**bold**`
    /// belongs to the word and reads with it.
    case plain
    /// A colour of its own — or nil to keep the one already there, which is how Markdown's
    /// emphasis bolds a word without flattening a link inside it — and emphasis to add.
    case marked(color: NSColor?, adds: Emphasis)
    /// Painted behind the row rather than into it, and saying nothing about what is drawn on
    /// top. A patch's `+` and `-` rows are what this exists for: which side of the change a row
    /// is on is the frame, and what the row *says* is the language it is a patch of, so the two
    /// cannot both be the foreground colour. The commit tab settled that one — the band carries
    /// the side, the syntax carries the content — and a patch opened as a file reads the same
    /// way, in the same colours, or one window would read a diff two ways.
    case banded(NSColor)
  }

  /// A resolved run: what the glyphs in `range` should actually look like, with everything
  /// enclosing it already folded in. Consumers apply these in order and the last one wins.
  typealias Span = (range: NSRange, color: NSColor, emphasis: Emphasis)

  /// A row to paint behind: the range the grammar named, and the fill.
  typealias Band = (range: NSRange, color: NSColor)

  /// What one read of a file comes back with. The two are separate because they are drawn in
  /// separate places — the spans are rendering attributes on the text, the bands are painted
  /// under it by the layout fragment — and because a band must not join the nesting the spans
  /// are built from: a `+` row encloses its whole line, and were it a colour every token on
  /// that line would inherit it, which is exactly the reading the band exists to avoid.
  struct Highlight {
    var spans: [Span] = []
    var bands: [Band] = []

    var isEmpty: Bool { spans.isEmpty && bands.isEmpty }
  }

  /// The colored spans of `text`, or empty when no vendored grammar covers the path. Ranges
  /// are UTF-16 offsets into `text`, so they address `NSTextStorage` directly. Later captures
  /// win where patterns overlap, which is the order tree-sitter defines and the order these
  /// are applied in.
  ///
  /// `within` narrows what is asked *of the tree*, never what is parsed. The parse has to read
  /// the file entire — a grammar picked up in the middle gets the strings and comments wrong at
  /// both ends, which is the same reason a commit's diff is coloured from the file's parse and
  /// not the hunk's — but running the highlights query and re-parsing every injected language is
  /// a search of the tree the parse already built, and on a long file that is most of the cost:
  /// measured on this repository, a 1568-line Swift file spends 19ms parsing and 18ms querying,
  /// and this file spends 50ms parsing and 146ms on the languages inside its fenced blocks.
  /// Passing nil asks for all of it, which is what a commit's diff wants — it has no viewport to
  /// speak of, and colours each file once.
  static func spans(in text: String, forPath path: String, within: NSRange? = nil) -> [Span] {
    highlight(in: text, forPath: path, within: within).spans
  }

  /// The colours *and* the bands. Only the editor wants both — a commit's diff is banded by the
  /// tab that built it, and every other reader is asking about text.
  static func highlight(in text: String, forPath path: String, within: NSRange? = nil) -> Highlight
  {
    guard let parsed = parse(text, forPath: path) else { return Highlight() }
    return highlight(of: parsed, within: within)
  }

  /// A file already parsed, held so that a second question about the *same text* costs the
  /// question and not the parse. Which is what following the viewport is: a scroll changes what
  /// is being asked for and changes nothing about the buffer, so re-parsing for one is work with
  /// no answer in it — no editor does it, and the ones that keep a tree keep it for exactly this.
  ///
  /// It is emphatically not the incremental parse this file declines: nothing is edited into a
  /// tree here, and the text it was built from is held beside it so a caller can only reuse one
  /// by proving the buffer has not moved. A tree that no longer matches its text is not a stale
  /// answer to be noticed later — it is a tree that cannot be looked up.
  final class Parsed {
    let text: String
    fileprivate let configuration: LanguageConfiguration
    fileprivate let tree: MutableTree

    fileprivate init(text: String, configuration: LanguageConfiguration, tree: MutableTree) {
      self.text = text
      self.configuration = configuration
      self.tree = tree
    }
  }

  /// Parse `text` as whatever language `path` names — the whole of it, always, for the reason
  /// `within` cannot narrow. Nil when no vendored grammar covers the path or the file is past
  /// the size limit, which is the same "left plain" answer `spans` gives.
  static func parse(_ text: String, forPath path: String) -> Parsed? {
    guard text.utf16.count <= sizeLimit, let configuration = languageConfiguration(forPath: path),
      let tree = makeParser(for: configuration.language).parse(text)
    else { return nil }
    return Parsed(text: text, configuration: configuration, tree: tree)
  }

  /// The spans of an already-parsed file. The injected languages inside the window are still
  /// parsed here — a fence's contents are a tree of their own, and only the host's is kept.
  static func spans(of parsed: Parsed, within: NSRange? = nil) -> [Span] {
    highlight(of: parsed, within: within).spans
  }

  static func highlight(of parsed: Parsed, within: NSRange? = nil) -> Highlight {
    highlight(
      in: parsed.text, using: parsed.configuration, tree: parsed.tree, depth: 0, within: within)
  }

  /// One language's spans, plus those of every language embedded in it.
  ///
  /// A grammar covers one language, and a real file is often more than one: a fenced block in
  /// Markdown is Swift, a Markdown paragraph's emphasis is a second grammar again, a heredoc in
  /// shell may be anything. `injections.scm` is where a grammar says so — which range belongs to
  /// another language, and which — so each of those is cut out, parsed on its own and folded
  /// back with its offsets moved. Cutting the text rather than using tree-sitter's included
  /// ranges keeps every offset in the UTF-16 units the rest of this file speaks; the ranges are
  /// contiguous, which is the case where the two agree.
  private static func highlight(
    in text: String, using configuration: LanguageConfiguration, depth: Int, within: NSRange?
  ) -> Highlight {
    guard let tree = makeParser(for: configuration.language).parse(text) else { return Highlight() }
    return highlight(in: text, using: configuration, tree: tree, depth: depth, within: within)
  }

  private static func highlight(
    in text: String, using configuration: LanguageConfiguration, tree: MutableTree, depth: Int,
    within: NSRange?
  ) -> Highlight {
    guard let root = tree.rootNode else { return Highlight() }

    var result = Highlight()
    /// The captures covering the one being read, innermost last.
    var open: [Span] = []
    if let highlights = configuration.queries[.highlights] {
      let cursor = highlights.execute(node: root, in: tree)
      // Matches that *intersect* the range, so a node enclosing the whole of it still arrives —
      // which is what the `open` stack below is reading, and why narrowing does not change the
      // answer for anything inside the range.
      if let within { cursor.setRange(within) }
      while let match = cursor.next() {
        for capture in match.captures {
          guard let name = capture.name, capture.range.length > 0,
            let style = style(for: name)
          else { continue }
          // Captures arrive outermost first, so what is still open at this point is what
          // encloses it: a string around an interpolation, a heading around a link. Drop what
          // has ended, then read the innermost of what is left.
          while let last = open.last, NSMaxRange(last.range) <= capture.range.location {
            open.removeLast()
          }
          // Two patterns over the *same* node: the first one wins, which is tree-sitter's rule
          // and not the nesting one. Swift's query names a function's identifier `@function` and
          // then, further down, every identifier `@variable` — read as later-wins that second
          // pattern flattened every function name in the file.
          if open.last?.range == capture.range { continue }
          let enclosing = open.last
          let span: Span
          switch style {
          case .banded(let fill):
            // Nothing about the foreground, so it neither joins `open` nor ends what is open:
            // the row is coloured by whatever is drawn on it, and this only says what goes
            // behind. Deliberately last-wins with the rest, since a band is one row and rows
            // do not nest.
            result.bands.append((capture.range, fill))
            continue
          case .plain:
            // The colour, and only the colour. Saying a range is punctuation says what it is,
            // not that whatever encloses it has stopped: the `**` around a bold word is still
            // that word's, and reads as part of it. What a reset is actually for is a colour
            // that would otherwise be wrong — an interpolation kept in its string's red, a
            // fence's content kept in the block's.
            //
            // Which is why one that changes nothing is dropped rather than written out: in a
            // source file punctuation is most of the captures, and almost none of it sits in
            // anything coloured.
            guard let enclosing, enclosing.color != .labelColor else { continue }
            span = (capture.range, .labelColor, enclosing.emphasis)
          case .marked(let color, let adds):
            span = (
              capture.range, color ?? enclosing?.color ?? .labelColor,
              (enclosing?.emphasis ?? []).union(adds)
            )
          }
          open.append(span)
          result.spans.append(span)
        }
      }
    }

    guard depth < injectionDepth, let injections = configuration.queries[.injections]
    else { return result }
    let string = text as NSString
    let cursor = injections.execute(node: root, in: tree)
    if let within { cursor.setRange(within) }
    while let match = cursor.next() {
      let offset = contentOffset(of: injections.predicates(for: match.patternIndex))
      let injection = Injection(
        pieces: match.captures(named: "injection.content")
          .map { moving($0.range, by: offset, within: string.length) }
          .filter { $0.length > 0 }
          .sorted { $0.location < $1.location })
      guard !injection.isEmpty else { continue }
      // The range asked for, in the injected text's own offsets — and the fence that falls
      // outside it is not parsed at all, which is the whole of what makes a long Markdown file
      // affordable. The cursor already dropped most of them; a match may still carry content
      // that misses the range on its own.
      var nestedRange: NSRange?
      if let within {
        guard let narrowed = injection.narrowed(to: within) else { continue }
        nestedRange = narrowed
      }
      // Three ways a grammar says which language: a capture whose *text* names it — a fence's
      // info string — a directive that names it outright, or a filename to read it off. That
      // last is a diff's, which says what its payload is by naming the file it patches, and the
      // question it asks is the one the extension table already answers. It only ever asks it
      // for a patch carrying the `diff` line it was produced by: without one the grammar builds
      // no hunks, so a bare `diff -u` is read as a frame and its payload left plain. Every patch
      // git writes carries the line.
      let nested =
        match.captures(named: "injection.language").first
        .map { string.substring(with: $0.range) }
        .flatMap(languageConfiguration(named:))
        ?? match.metadata["injection.language"].flatMap(languageConfiguration(named:))
        ?? match.captures(named: "injection.filename").first
        .map { filename(string.substring(with: $0.range)) }
        .flatMap(languageConfiguration(forPath:))
      guard let nested else { continue }
      // Appended after the host's, so where the two cover the same text the inner one wins.
      let inner = highlight(
        in: injection.text(in: string), using: nested, depth: depth + 1, within: nestedRange)
      for span in inner.spans {
        for range in injection.ranges(of: span.range) {
          result.spans.append((range, span.color, span.emphasis))
        }
      }
      for band in inner.bands {
        for range in injection.ranges(of: band.range) {
          result.bands.append((range, band.color))
        }
      }
    }
    return result
  }

  /// An injection's text, cut out of its host and joined, and the map back.
  ///
  /// Most injections are one piece — a fenced block — and this is a substring. A diff's is one
  /// piece per line: every line of a hunk that survives into the file it names, with the `+`,
  /// the `-` or the leading space taken off. Those are one injection rather than one each,
  /// because a grammar handed a single line gets its strings and comments wrong at both ends —
  /// the same reason a commit's diff is coloured from the file's parse and not the hunk's. The
  /// pieces need not be adjacent in the host, so a span coming back is placed by which of them
  /// it fell in, and one crossing a join comes back as one range per piece.
  private struct Injection {
    /// The pieces' ranges in the host, in the order they are joined and in host order.
    private let pieces: [NSRange]
    /// Where each piece begins in the joined text. Same count as `pieces`.
    private let starts: [Int]

    init(pieces: [NSRange]) {
      self.pieces = pieces
      var starts: [Int] = []
      var start = 0
      for piece in pieces {
        starts.append(start)
        start += piece.length
      }
      self.starts = starts
    }

    var isEmpty: Bool { pieces.isEmpty }

    func text(in string: NSString) -> String {
      pieces.count == 1
        ? string.substring(with: pieces[0])
        : pieces.reduce(into: "") { $0 += string.substring(with: $1) }
    }

    /// Where `range`, in the joined text's own offsets, sits in the host.
    func ranges(of range: NSRange) -> [NSRange] {
      var found: [NSRange] = []
      var index = firstPiece(endingAfter: range.location)
      while index < pieces.count, starts[index] < NSMaxRange(range) {
        let piece = pieces[index]
        let overlap = NSIntersectionRange(
          range, NSRange(location: starts[index], length: piece.length))
        if overlap.length > 0 {
          found.append(
            NSRange(
              location: piece.location + overlap.location - starts[index], length: overlap.length))
        }
        index += 1
      }
      return found
    }

    /// `within`, a range of the host, in the joined text's own offsets — nil when no piece of
    /// this injection falls inside it.
    func narrowed(to within: NSRange) -> NSRange? {
      var start: Int?
      var end: Int?
      for (index, piece) in pieces.enumerated() {
        let overlap = NSIntersectionRange(within, piece)
        guard overlap.length > 0 else { continue }
        let from = starts[index] + overlap.location - piece.location
        if start == nil { start = from }
        end = from + overlap.length
      }
      guard let start, let end else { return nil }
      return NSRange(location: start, length: end - start)
    }

    /// The first piece whose end is past `location`, by bisection: a patch is one piece per
    /// changed line, so walking them for every span coming back would be the file twice over.
    private func firstPiece(endingAfter location: Int) -> Int {
      var low = 0
      var high = pieces.count
      while low < high {
        let middle = (low + high) / 2
        if starts[middle] + pieces[middle].length <= location {
          low = middle + 1
        } else {
          high = middle
        }
      }
      return low
    }
  }

  /// The path in a diff's `---` or `+++` line, which is not always the whole of what the grammar
  /// calls its filename: a unified diff written by `diff -u` puts the file's timestamp after it,
  /// separated by a tab, and that is where the format says the name ends. git never writes one,
  /// so this is only ever the patch that came from somewhere else.
  private static func filename(_ captured: String) -> String {
    captured.prefix { $0 != "\t" }.description
  }

  /// The `#offset!` a pattern puts on its content, as a delta on each end of the range.
  ///
  /// A diff's injection uses it to take the marker off the head of every line and take the
  /// newline back at the tail, which is what makes the joined lines read as a file rather than
  /// as a run of statements. Only the column halves are honoured — a row delta would need the
  /// line index and no vendored grammar asks for one — and they are read in the UTF-16 units the
  /// rest of this file speaks rather than tree-sitter's bytes, which agree wherever what is
  /// being stepped over is ASCII. A marker, a fence or a quote always is.
  private static func contentOffset(of predicates: [SwiftTreeSitter.Predicate])
    -> (start: Int, end: Int)
  {
    for predicate in predicates {
      guard case .generic("offset!", let strings, let captures) = predicate,
        captures.first == "injection.content", strings.count == 4,
        let start = Int(strings[1]), let end = Int(strings[3])
      else { continue }
      return (start, end)
    }
    return (0, 0)
  }

  private static func moving(_ range: NSRange, by offset: (start: Int, end: Int), within limit: Int)
    -> NSRange
  {
    let start = min(max(range.location + offset.start, 0), limit)
    let end = min(max(NSMaxRange(range) + offset.end, start), limit)
    return NSRange(location: start, length: end - start)
  }

  static func canHighlight(path: String) -> Bool {
    grammars[(path as NSString).pathExtension.lowercased()] != nil
  }

  /// Take every colour and emphasis off a text view. Deliberately not a `SyntaxHighlighter`
  /// method: the case that needs it most is the one where there is no highlighter — a file no
  /// grammar covers leaves nothing to run `apply`, so the previous file's spans would otherwise
  /// stay on screen for good, drawn at offsets that mean nothing in the new text. Called where
  /// the buffer's text is replaced, which is the moment the old highlight stops describing it.
  static func clear(in textView: NSTextView) {
    guard let layoutManager = textView.textLayoutManager,
      let contentManager = layoutManager.textContentManager
    else { return }
    (layoutManager.delegate as? EmphasisTable).map {
      $0.spans = []
      $0.bands = []
    }
    layoutManager.setRenderingAttributes([:], for: contentManager.documentRange)
  }

  private static func makeParser(for language: Language) -> Parser {
    let parser = Parser()
    try? parser.setLanguage(language)
    return parser
  }

  /// The parsed grammar and its queries, built once per language and kept — compiling
  /// highlights.scm is the expensive part, and it does not vary by file.
  private static var configurations: [String: LanguageConfiguration?] = [:]
  /// The cache is reached from more than one background queue — every open file has a highlighter
  /// with a queue of its own, and a commit tab colours its diff on another — so the dictionary
  /// needs a lock even though what it holds is immutable once built.
  private static let configurationLock = NSLock()

  private static func languageConfiguration(forPath path: String) -> LanguageConfiguration? {
    grammars[(path as NSString).pathExtension.lowercased()].flatMap(configuration(for:))
  }

  /// The grammar an injection asked for by name. What a fence's info string holds is whatever
  /// the writer typed — `js` as often as `javascript`, `sh` as often as `bash` — so the
  /// extensions are tried too, which is where those short spellings already live.
  private static func languageConfiguration(named name: String) -> LanguageConfiguration? {
    let name = name.lowercased()
    guard let grammar = injectedGrammars[name] ?? grammarsByName[name] ?? grammars[name]
    else { return nil }
    return configuration(for: grammar)
  }

  /// The grammars keyed by their own name rather than by a file's extension.
  private static let grammarsByName: [String: (name: String, language: OpaquePointer)] =
    Dictionary(grammars.values.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

  private static func configuration(for grammar: (name: String, language: OpaquePointer))
    -> LanguageConfiguration?
  {
    configurationLock.lock()
    defer { configurationLock.unlock() }
    if let cached = configurations[grammar.name] { return cached }
    let queries = Bundle.main.resourceURL?
      .appendingPathComponent("TreeSitter/\(grammar.name)/queries")
    let configuration = queries.flatMap {
      try? LanguageConfiguration(grammar.language, name: grammar.name, queriesURL: $0)
    }
    configurations[grammar.name] = configuration
    return configuration
  }

  /// Capture name → style, decided by the name's first dotted component so `keyword.repeat`
  /// and `keyword.return` fall together. A style is a colour and, for prose, a weight or a
  /// slant; neither touches the font the layout was measured with — the colour is a rendering
  /// attribute and the emphasis is drawn over the glyphs by `EmphasisFragment`, so every token
  /// keeps the same monospace advance. nil leaves the token plain (variables, operators,
  /// punctuation).
  private static func style(for captureName: String) -> Style? {
    // The whole name first, for the handful where the tail is what carries the meaning.
    switch captureName {
    case "text.title": return .marked(color: .systemBlue, adds: .bold)
    case "text.strong": return .marked(color: nil, adds: .bold)
    case "text.emphasis": return .marked(color: nil, adds: .italic)
    case "text.uri", "text.reference": return .marked(color: .systemTeal, adds: [])
    case "text.literal": return .marked(color: .systemRed, adds: [])
    // A key rather than a value, the same as YAML's `property` — which is what it is, and
    // reading one language's keys as keys and another's as strings was an accident of which
    // grammar names them how.
    case "string.special.key": return .marked(color: .systemTeal, adds: [])
    // A patch's frame: which side of the change a row is on, painted behind it in the commit
    // tab's own colours so the two readings of a diff in this window are one reading. The `!`
    // row of a context diff is neither added nor removed but rewritten, which is the blue the
    // editor's gutter already draws for that.
    case "diff.plus": return .banded(CommitTheme.addedBand)
    case "diff.minus": return .banded(CommitTheme.removedBand)
    case "diff.delta": return .banded(NSColor.systemBlue.withDynamicAlpha(0.12))
    // Not a highlight at all: a grammar marks the ranges a spell checker should look at.
    case "spell": return nil
    default: break
    }
    switch captureName.split(separator: ".").first.map(String.init) ?? captureName {
    case "keyword": return .marked(color: .systemPink, adds: [])
    case "string", "character", "escape": return .marked(color: .systemRed, adds: [])
    case "comment": return .marked(color: .secondaryLabelColor, adds: [])
    case "number", "boolean", "constant": return .marked(color: .systemPurple, adds: [])
    case "type", "constructor", "module": return .marked(color: .systemTeal, adds: [])
    case "function": return .marked(color: .systemBlue, adds: [])
    case "attribute", "label": return .marked(color: .systemOrange, adds: [])
    case "property": return .marked(color: .systemTeal, adds: [])
    // Plain on purpose, and plain *explicitly*, which is the whole point of the distinction.
    // Punctuation and operators are the shape of the code rather than anything in it, and a
    // variable is most of a file — colouring either is noise. Saying so here is also what lets
    // them do their other job: `@punctuation.special` on Swift's `\(` takes the interpolation
    // out of the string's red, `@embedded` does the same for the code inside it, and
    // `@punctuation.delimiter` takes Markdown's `**` out of the bold it delimits.
    case "punctuation", "delimiter", "operator", "variable", "embedded", "none": return .plain
    default: return nil
    }
  }
}

/// The layout fragment the editor's text is drawn through, and the one place emphasis exists.
///
/// TextKit 2's rendering attributes are colour and nothing else in practice: the layout manager
/// keeps whatever it is given, but only the foreground colour is merged into the line fragment
/// that gets drawn — underline, stroke and obliqueness are held and never reach the glyphs, and a
/// font could not be honoured even in principle, since the advances were measured before it
/// arrived. So a span that wants bold or italic is drawn here instead: the line's own attributed
/// string (colour already merged) with a stroke or a skew laid over the emphasised range, and
/// then drawn with the same text machinery the stock fragment uses. A negative stroke width
/// thickens the outline without moving it and obliqueness shears each glyph in place, so neither
/// changes an advance and the result lands exactly where the layout put it. The document is
/// untouched throughout — the storage, the undo stack and the dirty flag never see any of this,
/// which is the same line the colours already hold to.
///
/// A fragment with nothing emphasised in it draws the stock way, so a source file costs nothing.
///
/// It is also where a band is painted, which is a patch's and nothing else's: a `+` row says
/// which side of a change it is on, and its text says what the change *is* in the language being
/// patched, so the side cannot also be the foreground colour. Painted here rather than into the
/// storage because the buffer is exactly what `⌘S` writes, which is the same line the colours
/// and the emphasis already hold to.
final class EmphasisFragment: NSTextLayoutFragment {
  /// The emphasised ranges, in document UTF-16 offsets, read through the layout delegate that
  /// made this fragment. Looked up at draw time rather than copied, so a re-highlight is one
  /// table swap and a redraw.
  weak var table: EmphasisTable?

  private var textView: NSTextView? { textLayoutManager?.textContainer?.textView }

  /// This fragment's range in document UTF-16 offsets, which is what both tables are keyed by.
  private var extent: NSRange? {
    guard let contentManager = textLayoutManager?.textContentManager else { return nil }
    let base = contentManager.offset(
      from: contentManager.documentRange.location, to: rangeInElement.location)
    return NSRange(
      location: base,
      length: contentManager.offset(from: rangeInElement.location, to: rangeInElement.endLocation))
  }

  /// The fill behind this row. One band or none: rows do not nest, and a patch's grammar names
  /// each of them once.
  private var band: NSColor? {
    guard let table, !table.bands.isEmpty, let extent else { return nil }
    return table.bands.first { NSIntersectionRange($0.range, extent).length > 0 }?.color
  }

  /// A band reaches past the row's own text, which the transcript's fragment does to every
  /// paragraph and this editor was built not to (see `makeEditorTextView`). So the widening is
  /// asked for only where a band can land at all — a file whose grammar bands rows, which is a
  /// patch — and every other file keeps the stock surface.
  override var renderingSurfaceBounds: CGRect {
    guard let table, !table.bands.isEmpty else { return super.renderingSurfaceBounds }
    return super.renderingSurfaceBounds.union(bandSurface(in: textView))
  }

  override func draw(at point: CGPoint, in context: CGContext) {
    if let band { fillBand(band, at: point, in: context, of: textView) }
    guard let table, !table.spans.isEmpty, let extent,
      let contentManager = textLayoutManager?.textContentManager
    else { return super.draw(at: point, in: context) }
    let base = extent.location
    let hits = table.spans.filter { NSIntersectionRange($0.range, extent).length > 0 }
    guard !hits.isEmpty else { return super.draw(at: point, in: context) }

    for line in textLineFragments {
      let text = NSMutableAttributedString(attributedString: line.attributedString)
      let lineRange = NSRange(
        location: base + line.characterRange.location, length: line.characterRange.length)
      // The line's string carries the storage's attributes, not the rendering ones: the stock
      // draw merges those at the last moment, and this draw is standing in for it. Fold them in
      // by hand, or every colour on an emphasised line — the heading's blue, a code span's red
      // beside a bold word — is lost to the plain label colour.
      if let layoutManager = textLayoutManager,
        let start = contentManager.location(
          contentManager.documentRange.location, offsetBy: lineRange.location)
      {
        layoutManager.enumerateRenderingAttributes(from: start, reverse: false) {
          _, attributes, range in
          let from = contentManager.offset(
            from: contentManager.documentRange.location, to: range.location)
          let to = contentManager.offset(
            from: contentManager.documentRange.location, to: range.endLocation)
          let overlap = NSIntersectionRange(NSRange(location: from, length: to - from), lineRange)
          guard from < NSMaxRange(lineRange) else { return false }
          if overlap.length > 0 {
            text.addAttributes(
              attributes,
              range: NSRange(
                location: overlap.location - lineRange.location, length: overlap.length))
          }
          return true
        }
      }
      for hit in hits {
        let overlap = NSIntersectionRange(hit.range, lineRange)
        guard overlap.length > 0 else { continue }
        let local = NSRange(location: overlap.location - lineRange.location, length: overlap.length)
        if hit.emphasis.contains(.bold) {
          // A percentage of the point size, not a width: at 12pt, -2.5 buys a third of a point
          // of outline and reads as the plain face beside it. -6 is where it becomes a weight.
          text.addAttribute(.strokeWidth, value: -6.0, range: local)
        }
        if hit.emphasis.contains(.italic) {
          text.addAttribute(.obliqueness, value: 0.2, range: local)
        }
      }
      let origin = CGPoint(
        x: point.x + line.typographicBounds.minX, y: point.y + line.typographicBounds.minY)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
      text.draw(at: origin)
      NSGraphicsContext.restoreGraphicsState()
    }
  }
}

/// The editor's layout delegate: hands every paragraph an `EmphasisFragment`, and holds the
/// table those fragments read. One per text view, installed by `makeEditorTextView` and kept
/// alive by it — the layout manager only holds its delegate weakly.
final class EmphasisTable: NSObject, NSTextLayoutManagerDelegate {
  /// The emphasised spans of the current highlight, in document UTF-16 offsets.
  var spans: [(range: NSRange, emphasis: SyntaxHighlighting.Emphasis)] = []
  /// The banded rows of the current highlight, in the same offsets. Only a patch has any, and
  /// whether there are any at all is also what decides the fragments' rendering surface — so
  /// going from none to some has to be a relayout and not just a redraw, which is `SyntaxHighlighter`'s.
  var bands: [SyntaxHighlighting.Band] = []

  func textLayoutManager(
    _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
    in textElement: NSTextElement
  ) -> NSTextLayoutFragment {
    let fragment = EmphasisFragment(textElement: textElement, range: textElement.elementRange)
    fragment.table = self
    return fragment
  }
}

/// Keeps one text view colored. The whole file is re-parsed off the main thread and the spans
/// replace the previous ones wholesale — tree-sitter parses far faster than a person types, and
/// a whole-file parse is the one that cannot drift out of step with the buffer.
///
/// The parse is stamped with the edit count it read, so a result that lands after the next
/// keystroke is dropped rather than painted over text it never saw.
@MainActor
final class SyntaxHighlighter {
  /// The last parse, reached only from `queue`. It is a box rather than a property because the
  /// queue is where it is written as well as read, and the main actor never looks at it: what
  /// crosses is a string going one way and spans coming back.
  private final class ParseBox {
    var parsed: SyntaxHighlighting.Parsed?
  }

  private weak var textView: NSTextView?
  private let path: String
  private let queue = DispatchQueue(label: "dev.tnayuki.Hukan.highlight", qos: .userInitiated)
  private let box = ParseBox()
  private var generation = 0
  private var pending: DispatchWorkItem?

  /// Typing is a burst; parsing every keystroke would be work nobody sees. A scroll that leaves
  /// the coloured window is a burst too, and collapses the same way.
  private let debounce = 0.08

  /// What has been coloured so far, or nil once that is the whole file. It starts at the
  /// viewport and grows outward on its own (see `fill`), so it is a moving front rather than a
  /// setting — and a viewport still inside it has nothing to ask for.
  private var painted: NSRange?

  /// The emphasised runs handed to the fragments, accumulated as the front moves: a slice is
  /// added to what is already drawn rather than replacing it, since the rest of the file is on
  /// screen and must not go plain while the next slice is read.
  private var emphasised: [(range: NSRange, emphasis: SyntaxHighlighting.Emphasis)] = []

  /// The bands, kept the same way and for the same reason.
  private var banded: [SyntaxHighlighting.Band] = []

  /// How far past the visible text the *first* query reaches, in UTF-16 units — a screenful
  /// either side, floored so a very short pane does not ask for almost nothing. It decides how
  /// soon the reader sees colour and nothing else: the rest of the file follows on its own.
  private static let windowMargin = 4_000

  /// How much further each background step reaches. Larger than the first window because
  /// nobody is waiting on these — what they are racing is a scroll, not the eye.
  private static let fillStep = 40_000

  /// A beat between steps, so the first screenful is drawn and the reader has the main thread
  /// before the rest of the file starts arriving.
  private static let fillDelay = 0.05

  /// Does not parse: a highlighter is made when the file is opened, which is *before* its text
  /// has been read off disk, so what is in the buffer at this point is the file being left. A
  /// parse here would read the previous file through the new one's grammar and — landing after
  /// the new text does — paint that answer onto it. The owner calls `refresh` once the text the
  /// grammar belongs to is actually in the buffer.
  init?(textView: NSTextView, path: String) {
    guard SyntaxHighlighting.canHighlight(path: path) else { return nil }
    self.textView = textView
    self.path = path
    NotificationCenter.default.addObserver(
      self, selector: #selector(textStorageDidChange),
      name: NSTextStorage.didProcessEditingNotification, object: textView.textStorage)
    if let clipView = textView.enclosingScrollView?.contentView {
      clipView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self, selector: #selector(viewportMoved),
        name: NSView.boundsDidChangeNotification, object: clipView)
    }
  }

  deinit { pending?.cancel() }

  @objc private func textStorageDidChange() {
    scheduleRefresh()
  }

  /// Text that was never coloured has come into view. Only then: inside the margin there is
  /// nothing to add, and a scroll fires this several times a frame.
  @objc private func viewportMoved() {
    guard let painted, let visible = visibleRange(), visible.length > 0,
      NSIntersectionRange(visible, painted) != visible
    else { return }
    scheduleRefresh()
  }

  private func scheduleRefresh() {
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.refresh() }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
  }

  /// What the text view is showing, in UTF-16 offsets — TextKit 2's own answer, since the
  /// viewport controller is what decides which fragments exist at all. Nil before the first
  /// layout, which is the state a file opens in.
  private func visibleRange() -> NSRange? {
    guard let layoutManager = textView?.textLayoutManager,
      let contentManager = layoutManager.textContentManager,
      let viewport = layoutManager.textViewportLayoutController.viewportRange
    else { return nil }
    let start = contentManager.documentRange.location
    let from = contentManager.offset(from: start, to: viewport.location)
    let to = contentManager.offset(from: start, to: viewport.endLocation)
    guard from >= 0, to >= from else { return nil }
    return NSRange(location: from, length: to - from)
  }

  /// The window to colour: what is visible, plus a margin either side — or nil once that covers
  /// the file, which is the answer for anything short and leaves those files parsed exactly as
  /// they were. A file that has not been laid out yet is read from the top, which is where one
  /// that has just been opened is scrolled to.
  private func windowOfInterest(length: Int) -> NSRange? {
    guard length > 2 * Self.windowMargin else { return nil }
    let visible = visibleRange() ?? NSRange(location: 0, length: 0)
    let margin = max(visible.length, Self.windowMargin)
    let from = max(0, visible.location - margin)
    let to = min(length, NSMaxRange(visible) + margin)
    guard to > from, to - from < length else { return nil }
    return NSRange(location: from, length: to - from)
  }

  /// Parse the buffer as it stands now. Called directly when a file's text lands, which is why
  /// it drops whatever the debounce had scheduled: the notification that text replacement posts
  /// queues a parse 80ms out, and paying a typist's delay to colour a file that was just opened
  /// is the whole of the wait between opening one and seeing it.
  func refresh() {
    pending?.cancel()
    pending = nil
    guard let textView, let text = textView.textStorage?.string else { return }
    generation += 1
    // The viewport is read after the text has landed but before it has been drawn, so ask the
    // controller to catch up first — otherwise the window is measured against the file that was
    // just replaced, and the reader watches the top of the new one come in plain.
    textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let length = (text as NSString).length
    let window = windowOfInterest(length: length)
    paint(
      slices: [window], covering: window, replacingAll: true, text: text, length: length,
      generation: generation)
  }

  /// The rest of the file, a step at a time, without being asked. What is on screen is coloured
  /// first because that is what the reader is waiting for, but stopping there would mean every
  /// scroll runs a query and waits for it — and there is nothing to wait for: the tree is
  /// already built, so the rest is a search of it that can happen while nobody is looking. The
  /// front grows outward from the viewport until it reaches both ends, and then this stops for
  /// good, leaving a file coloured exactly as a whole-file read would have coloured it.
  private func fill(text: String, length: Int, generation: Int) {
    guard self.generation == generation, let painted else { return }
    let from = max(0, painted.location - Self.fillStep)
    let to = min(length, NSMaxRange(painted) + Self.fillStep)
    var slices: [NSRange?] = []
    if painted.location > from {
      slices.append(NSRange(location: from, length: painted.location - from))
    }
    if to > NSMaxRange(painted) {
      slices.append(NSRange(location: NSMaxRange(painted), length: to - NSMaxRange(painted)))
    }
    // Nil covering says the file is done, which is what stops both this and the scroll watcher.
    let covering = from == 0 && to == length ? nil : NSRange(location: from, length: to - from)
    paint(
      slices: slices, covering: covering, replacingAll: false, text: text, length: length,
      generation: generation)
  }

  /// Read `slices` off the tree, hand them to the view, and come back for the next step unless
  /// the file is covered.
  private func paint(
    slices: [NSRange?], covering: NSRange?, replacingAll: Bool, text: String, length: Int,
    generation: Int
  ) {
    let box = box
    let path = path
    queue.async { [weak self] in
      // The parse is reused when the buffer has not moved since it was made, which is every step
      // of the fill and every scroll — the whole reason either is affordable. Keyed on the text
      // itself rather than on a flag someone has to remember to clear: a tree that does not
      // match the buffer is one this comparison cannot return, so nothing can fall out of step.
      if box.parsed?.text != text { box.parsed = SyntaxHighlighting.parse(text, forPath: path) }
      let read =
        box.parsed.map { parsed in
          slices.reduce(into: SyntaxHighlighting.Highlight()) {
            let slice = SyntaxHighlighting.highlight(of: parsed, within: $1)
            $0.spans += slice.spans
            $0.bands += slice.bands
          }
        } ?? SyntaxHighlighting.Highlight()
      DispatchQueue.main.async {
        guard let self, self.generation == generation else { return }
        self.apply(read, length: length, replacingAll: replacingAll)
        self.painted = covering
        guard covering != nil else { return }
        self.pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
          self?.fill(text: text, length: length, generation: generation)
        }
        self.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fillDelay, execute: work)
      }
    }
  }

  private func apply(
    _ read: SyntaxHighlighting.Highlight, length: Int, replacingAll: Bool
  ) {
    guard let layoutManager = textView?.textLayoutManager,
      let contentManager = layoutManager.textContentManager
    else { return }
    let spans = read.spans
    // Only a fresh read clears: a step of the fill is adding to a file that is already coloured
    // and on screen, and clearing there would take the colour off every line the reader is
    // looking at for as long as the next slice takes to arrive.
    if replacingAll {
      emphasised = []
      banded = []
      guard let documentRange = textRange(in: contentManager, NSRange(location: 0, length: length))
      else { return }
      layoutManager.setRenderingAttributes([:], for: documentRange)
    }
    // The weights and slants go to the table the fragments draw from; the colours below are the
    // rendering attributes, and setting them is also what makes a fragment redraw. Everything
    // with emphasis, and the resets that follow one — a span with no emphasis earns its place in
    // the table only by taking emphasis away from something already in it.
    for span in spans {
      if !span.emphasis.isEmpty {
        emphasised.append((span.range, span.emphasis))
      } else if emphasised.contains(where: { NSIntersectionRange($0.range, span.range).length > 0 })
      {
        emphasised.append((span.range, []))
      }
    }
    let table = layoutManager.delegate as? EmphasisTable
    table?.spans = emphasised
    // Whether the file has bands at all is what the fragments' rendering surface is read off, and
    // that is read once, when a fragment is laid out. So the first bands to arrive are a relayout
    // — the fragments already standing were measured for a file that had none — while every later
    // one is only a redraw, which the rendering attributes below already provoke.
    let hadBands = !banded.isEmpty
    banded += read.bands
    table?.bands = banded
    if !hadBands, !banded.isEmpty,
      let documentRange = textRange(in: contentManager, NSRange(location: 0, length: length))
    {
      layoutManager.invalidateLayout(for: documentRange)
    }
    for span in spans {
      guard let range = textRange(in: contentManager, span.range) else { continue }
      layoutManager.setRenderingAttributes([.foregroundColor: span.color], for: range)
    }
  }

  private func textRange(in contentManager: NSTextContentManager, _ range: NSRange)
    -> NSTextRange?
  {
    let start = contentManager.documentRange.location
    guard let from = contentManager.location(start, offsetBy: range.location),
      let to = contentManager.location(start, offsetBy: NSMaxRange(range))
    else { return nil }
    return NSTextRange(location: from, end: to)
  }
}
