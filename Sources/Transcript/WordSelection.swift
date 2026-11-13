import AppKit

/// What a double-click selects, corrected for the one thing AppKit gets wrong in a transcript and
/// extended for the three kinds of token this window is full of.
///
/// AppKit words a paragraph in the language it detects for that paragraph, and a transcript here
/// is a Japanese conversation with ASCII in it. One kana anywhere on the line puts the whole
/// paragraph — hash, path and all — on the Japanese dictionary tokenizer, which breaks a Latin
/// run at every class boundary: `756ae49` comes back `756` / `ae` / `49`, a full SHA comes back
/// in twenty-seven pieces, and `Model.swift` comes back `Model` / `.` / `swift`. The identical
/// line with the Japanese taken out words correctly. So the correction invents no word rule of
/// its own — it takes the ASCII run and asks how that run would be worded standing alone, which
/// is what `enWordRanges` is. Japanese text keeps AppKit's answer untouched, morphemes and all.
///
/// On top of that, three separators that break an English word do not break what is being read
/// here: a session id and a branch name keep their hyphens, a path and a URL keep their slashes,
/// and an option keeps its leading dashes. A path takes a trailing `:120` with it, because a file
/// and a line is the unit an agent is handed. An `http(s)` URL is read whole before any of that,
/// query string and all, by the rule the prose's autolink cuts one with — a `?`, `=` or `&` is
/// not a separator anyone means to stop at inside an address.
///
/// **There is nowhere else to put this.** `selectionRange(forProposedRange:granularity:)` — the
/// documented hook, and the only one — is never called on a TextKit 2 view: word selection is
/// `NSTextSelectionNavigation`'s, and that takes no delegate. So the correction rides
/// `setSelectedRanges`, which every step of the tracking loop passes through, and the wrong range
/// is therefore never drawn. Correcting after `mouseDown` returned was the first shape and it
/// showed on screen: `super.mouseDown` does not come back until the mouse is up, so the narrow
/// selection sat there for the whole gesture before snapping wider.
enum WordSelection {
  /// A run longer than this is not a word anyone double-clicks, and asking the tokenizer for it
  /// would be the minified-file freeze by another route — one line, three megabytes, no spaces.
  /// Past it the correction stands down and AppKit's answer is what it was.
  static let maximumSpan = 512

  // MARK: Character classes

  private static let hyphen: unichar = 45
  private static let slash: unichar = 47
  private static let colon: unichar = 58

  private static func isAlphanumeric(_ c: unichar) -> Bool {
    (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
  }
  private static func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
  /// What may sit inside one path component: a name, a dot, an underscore, a hyphen, a tilde.
  private static func isComponent(_ c: unichar) -> Bool {
    isAlphanumeric(c) || c == 46 || c == 95 || c == hyphen || c == 126
  }
  /// Printable ASCII, space excluded — so a span stops at a space, a tab and a newline, and never
  /// reaches into the line below or joins two words across a gap.
  private static func isSpanCharacter(_ c: unichar) -> Bool { c > 32 && c < 0x7f }

  // MARK: The span, and how it words on its own

  /// The maximal run of printable ASCII around `range`. Nil when the selection is not itself in
  /// that class — which is how Japanese keeps AppKit's answer — or when the run is longer than
  /// any word worth selecting.
  private static func span(_ s: NSString, around range: NSRange) -> NSRange? {
    guard range.length > 0, range.length <= maximumSpan, NSMaxRange(range) <= s.length
    else { return nil }
    for i in range.location..<NSMaxRange(range) where !isSpanCharacter(s.character(at: i)) {
      return nil
    }
    var lo = range.location
    var hi = NSMaxRange(range)
    while lo > 0, isSpanCharacter(s.character(at: lo - 1)) {
      lo -= 1
      if hi - lo > maximumSpan { return nil }
    }
    while hi < s.length, isSpanCharacter(s.character(at: hi)) {
      hi += 1
      if hi - lo > maximumSpan { return nil }
    }
    return NSRange(location: lo, length: hi - lo)
  }

  /// Word ranges of `text` broken as en_US — which is exactly how AppKit breaks a paragraph with
  /// no Japanese in it. Bounding the span at whitespace does not change these: measured against
  /// the same tokens read in a full sentence, isolated and in-context agree on every one.
  private static func enWordRanges(_ text: String) -> [NSRange] {
    let cf = text as CFString
    guard
      let tokenizer = CFStringTokenizerCreate(
        nil, cf, CFRangeMake(0, CFStringGetLength(cf)), kCFStringTokenizerUnitWordBoundary,
        Locale(identifier: "en_US") as CFLocale)
    else { return [] }
    var out: [NSRange] = []
    while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
      let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
      out.append(NSRange(location: r.location, length: r.length))
    }
    return out
  }

  // MARK: Growing a word across the separators that do not break it here

  /// Only a word grows. Clicking the hyphen or the slash itself does not, or the first `-` of
  /// `--strict` would take the flag with it and `a--b` would become one word.
  private static func grow(_ s: NSString, _ range: NSRange) -> NSRange {
    var sawAlphanumeric = false
    for i in range.location..<NSMaxRange(range) {
      let c = s.character(at: i)
      if isAlphanumeric(c) {
        sawAlphanumeric = true
      } else if !isComponent(c) {
        return range
      }
    }
    guard sawAlphanumeric else { return range }

    var lo = range.location
    var hi = NSMaxRange(range)
    func backOverComponent() { while lo > 0, isComponent(s.character(at: lo - 1)) { lo -= 1 } }
    func forwardOverComponent() {
      while hi < s.length, isComponent(s.character(at: hi)) { hi += 1 }
    }

    while lo >= 2 {
      let separator = s.character(at: lo - 1)
      let before = s.character(at: lo - 2)
      if separator == hyphen, isAlphanumeric(before) {
        lo -= 1
        backOverComponent()
      } else if separator == slash, isComponent(before) {
        lo -= 1
        backOverComponent()
      } else if separator == slash, before == slash, lo >= 3, s.character(at: lo - 3) == colon {
        // A URL's scheme: the two slashes are not a component, so `https://` needs its own step.
        lo -= 3
        backOverComponent()
      } else {
        break
      }
    }
    while hi + 1 < s.length {
      let separator = s.character(at: hi)
      let after = s.character(at: hi + 1)
      if separator == hyphen, isAlphanumeric(after) {
        hi += 1
        forwardOverComponent()
      } else if separator == slash, isComponent(after) {
        hi += 1
        forwardOverComponent()
      } else if separator == colon, after == slash, hi + 3 < s.length,
        s.character(at: hi + 2) == slash, isComponent(s.character(at: hi + 3))
      {
        // The same scheme, reached from the other side — clicking `https` itself.
        hi += 3
        forwardOverComponent()
      } else {
        break
      }
    }
    // An absolute path keeps its root: the slash that starts it has nothing before it to be a
    // component of, so the walk above stops one character short. Only where it starts the word —
    // after a component it was already crossed, and after a colon or a second slash it belongs to
    // a scheme the walk handles on its own.
    if lo > 0, s.character(at: lo - 1) == slash {
      let before = lo >= 2 ? s.character(at: lo - 2) : 0
      if lo == 1 || !(isComponent(before) || before == slash || before == colon) { lo -= 1 }
    }
    // An option keeps its leading dashes, but only where they start the word: an infix `a--b` is
    // two words, and a bullet's `- item` has a space in the way.
    if lo > 0, s.character(at: lo - 1) == hyphen {
      var dash = lo
      while dash > 0, s.character(at: dash - 1) == hyphen { dash -= 1 }
      if dash == 0 || !isComponent(s.character(at: dash - 1)) { lo = dash }
    }
    // `Model.swift:120`, once the path is settled and only for a run of digits.
    if hi + 1 < s.length, s.character(at: hi) == colon, isDigit(s.character(at: hi + 1)) {
      hi += 1
      while hi < s.length, isDigit(s.character(at: hi)) { hi += 1 }
    }
    return NSRange(location: lo, length: hi - lo)
  }

  // MARK: A URL is read whole

  /// The `http(s)` URL around `index`, or nil when the character there is not inside one: the
  /// last scheme in the run of printable ASCII that starts at or before it, cut where the prose's
  /// autolink cuts a URL. The right-click's link inside code asks the same question, so what a
  /// double-click selects there is exactly what the menu would open.
  static func url(in s: NSString, at index: Int) -> NSRange? {
    guard index >= 0, index < s.length,
      let span = span(s, around: NSRange(location: index, length: 1))
    else { return nil }
    let run = s.substring(with: span)
    let click = run.utf16.index(run.utf16.startIndex, offsetBy: index - span.location)
    // Searched a scheme's length past the click, so a click on `https` itself still counts.
    let limit = run.utf16.index(click, offsetBy: 8, limitedBy: run.endIndex) ?? run.endIndex
    guard
      let scheme = ["https://", "http://"]
        .compactMap({ run.range(of: $0, options: .backwards, range: run.startIndex..<limit) })
        .filter({ $0.lowerBound <= click })
        .max(by: { $0.lowerBound < $1.lowerBound })
    else { return nil }
    let tail = run[scheme.lowerBound...]
    let end = Transcript.autolinkEnd(of: tail)
    guard end > scheme.upperBound, click < end else { return nil }
    let range = NSRange(scheme.lowerBound..<end, in: run)
    return NSRange(location: range.location + span.location, length: range.length)
  }

  // MARK: What to select

  /// The word under `click`, or nil to leave `selection` exactly as AppKit made it.
  ///
  /// `appkitWord` is what AppKit answered for this same double-click, kept only to tell "still on
  /// the word it started on" from "being dragged across several". It never decides the answer:
  /// deferring to it was the first rule here, and it is what made `kebab-case-name` come out
  /// whole on a Japanese line and in pieces on an English one — the Japanese tokenizer happens to
  /// call that one word, and honouring whichever answer was wider is how the two lines diverged.
  static func word(in s: NSString, click: Int, selection: NSRange, appkitWord: NSRange?)
    -> NSRange?
  {
    guard selection.length > 0, NSMaxRange(selection) <= s.length,
      let span = span(s, around: selection)
    else { return nil }
    let tokens = enWordRanges(s.substring(with: span)).map {
      NSRange(location: $0.location + span.location, length: $0.length)
    }
    func word(at i: Int) -> NSRange? {
      url(in: s, at: i) ?? tokens.first { NSLocationInRange(i, $0) }.map { grow(s, $0) }
    }
    let anchor = min(max(click, span.location), NSMaxRange(span) - 1)
    guard var result = word(at: anchor) else { return nil }
    // Dragged past the word it started on: take in the word under the far end too.
    if let appkitWord, !NSEqualRanges(selection, appkitWord) {
      let far =
        selection.location < appkitWord.location
        ? selection.location : max(NSMaxRange(selection) - 1, selection.location)
      if let t = word(at: far) { result = NSUnionRange(result, t) }
    }
    return NSEqualRanges(result, selection) ? nil : result
  }
}

/// An `NSTextView` whose double-click selects what `WordSelection` says. The transcript, the
/// editor and the commit tab all read the same kind of text, so they all get it.
public class WordSelectingTextView: NSTextView {
  private var doubleClicking = false
  private var clickIndex = 0
  /// AppKit's own answer for this double-click, taken from the first selection it sets.
  private var appkitWord: NSRange?

  public override func mouseDown(with event: NSEvent) {
    clickIndex = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
    appkitWord = nil
    doubleClicking = event.clickCount >= 2
    defer { doubleClicking = false }
    super.mouseDown(with: event)
  }

  public override func setSelectedRanges(
    _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
  ) {
    var ranges = ranges
    if doubleClicking, let s = textStorage?.string as NSString? {
      if appkitWord == nil { appkitWord = ranges.first?.rangeValue }
      ranges = ranges.map { value in
        WordSelection.word(
          in: s, click: clickIndex, selection: value.rangeValue, appkitWord: appkitWord
        ).map(NSValue.init(range:)) ?? value
      }
    }
    super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
  }
}
