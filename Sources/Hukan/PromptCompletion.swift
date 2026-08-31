import AppKit

/// Completing a past prompt in the composer, by its reading.
///
/// The prompts typed here are Japanese (97% of 13,000 sends) and the composer is ASCII when the
/// input method is off, so the two are bridged by the reading rather than by the characters:
/// `kentou` finds 検討して. What the list holds is `PromptHistory`'s answer — this owns only the
/// reading, the match, and when a list is allowed to open at all.
enum PromptCompletion {
  /// A prompt beside the two strings it is matched by.
  ///
  /// Two, not one, because the reading is not the whole of what is written: `PRを作って` reads as
  /// `pīāruwotsukutte`, and the `PR` a person would actually type for it survives only in the
  /// text itself. So a query is tried against both, and an `ASCII` word in a Japanese sentence
  /// stays findable as itself.
  struct Indexed {
    let text: String
    /// The reading, folded.
    let reading: String
    /// The text itself, ASCII-folded — everything else dropped.
    let plain: String
  }

  /// The shortest query that opens a list. Two: a single letter matches most of the history and
  /// so answers nothing, and everything above that is worth offering.
  ///
  /// It is not free, because the list borrows Return: the ASCII messages that are sent as they
  /// stand are acknowledgements — `yes` (248 sends here), `ok` (111), `dou` (33) — and each of
  /// them now opens a list that Return answers instead of sending, so they go Esc then Return. A
  /// digit or a single letter is the one thing kept out of it, by the length and by there having
  /// to be a letter at all.
  static let minimumQueryLength = 2

  /// What the composer's text is completing against, when it is completing at all.
  ///
  /// A prompt is the whole message, the way a slash command is — so the query is the field, not a
  /// word in it. Three things close the list: a leading `/`, which is the command list's; anything
  /// but ASCII, which means the input method has already committed kana and there is no reading
  /// left to bridge; and text still being composed, since marked text is a guess the input method
  /// has not been asked to confirm and its own candidate window is over the field taking the same
  /// keys this list would.
  static func query(in text: String, isComposing: Bool) -> String? {
    guard !isComposing, !text.hasPrefix("/"), text.count >= minimumQueryLength,
      text.allSatisfy(\.isASCII), text.contains(where: \.isLetter)
    else { return nil }
    return text
  }

  /// The prompts `query` names, best first, and never the one already typed.
  ///
  /// Substring rather than prefix, because a reading's use is finding the word in the middle —
  /// `hyouji` is rarely how a sentence starts. A match at the head still sorts above one found
  /// inside, the rule the command list settled on; within each group `prompts` order stands,
  /// which is newest first.
  static func matches(_ query: String, in prompts: [Indexed]) -> [String] {
    let needle = fold(query)
    guard !needle.isEmpty else { return [] }
    var prefixed: [String] = []
    var contained: [String] = []
    for prompt in prompts where prompt.text != query {
      if prompt.reading.hasPrefix(needle) || prompt.plain.hasPrefix(needle) {
        prefixed.append(prompt.text)
      } else if prompt.reading.contains(needle) || prompt.plain.contains(needle) {
        contained.append(prompt.text)
      }
      if prefixed.count >= rowLimit { break }
    }
    return Array((prefixed + contained).prefix(rowLimit))
  }

  /// A list is scrolled, not read to the end: past this many rows what is on offer is the query,
  /// not the list. It also keeps the `completions` verb's report to something a script can read.
  private static let rowLimit = 50

  /// Read every prompt once, so a keystroke costs the match and nothing else. Measured at 80µs a
  /// prompt, which is a tenth of a second for the largest repository on this machine.
  static func index(_ prompts: [String]) -> [Indexed] {
    prompts.map {
      Indexed(text: $0, reading: fold(reading(of: $0)), plain: fold($0))
    }
  }

  // MARK: - Reading

  /// The Latin reading of `text`, as macOS's own Japanese tokenizer gives it.
  ///
  /// `kCFStringTokenizerAttributeLatinTranscription` is a morphological analyser's answer, not a
  /// transliteration: 検討 comes back `kentou` where a character-by-character rule would have no
  /// way to choose a reading at all. It is asked in `ja` explicitly — left to detect the language
  /// it words a line by whatever it finds in it, which is the same guess that had to be taken
  /// away from the double-click. A token it has no reading for stands as it was written, which is
  /// what leaves `commit` in `commit して` as itself.
  ///
  /// What it will not do is disambiguate: 日本語 comes back `nippongo`. That is why `Indexed`
  /// carries the text as well — a reading is one of two ways in, not the only one.
  static func reading(of text: String) -> String {
    let string = text as CFString
    let tokenizer = CFStringTokenizerCreate(
      nil, string, CFRangeMake(0, CFStringGetLength(string)),
      kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
    var out = ""
    let ns = text as NSString
    while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
      let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
      if let latin = CFStringTokenizerCopyCurrentTokenAttribute(
        tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
      {
        out += latin
      } else {
        out += ns.substring(with: NSRange(location: range.location, length: range.length))
      }
    }
    return out
  }

  /// One spelling for the several a reading and a keyboard can each be written in. Applied to the
  /// index and to the query alike, so what matters is only that the two agree.
  ///
  /// Four things move: the small tsu, which the tokenizer writes `~tsu` where a keyboard doubles
  /// the consonant after it; a long vowel, written with a macron for katakana (`rirīsu`) and spelt
  /// out for a kanji reading (`daijoubu`), so both are collapsed away; Hepburn against the
  /// kunrei-style an IME equally accepts, since `shi` and `si` are one keystroke apart and both
  /// produce し; and everything that is not an ASCII letter or digit, which drops — punctuation,
  /// and any token the tokenizer had no reading for and handed back as kanji.
  static func fold(_ text: String) -> String {
    var folded = ""
    folded.reserveCapacity(text.count)
    for character in geminate(text).lowercased() {
      if let vowel = macrons[character] {
        folded.append(vowel)
        folded.append(vowel)
      } else if character.isASCII, character.isLetter || character.isNumber {
        folded.append(character)
      }
    }
    return collapse(romanization(folded))
  }

  private static let macrons: [Character: Character] = [
    "ā": "a", "ī": "i", "ū": "u", "ē": "e", "ō": "o",
  ]

  /// `~tsu` is the tokenizer's small tsu: 打った comes back `u~tsuta`. It stands for the doubling
  /// of the consonant that follows it, which is what a keyboard types, so that is what it becomes
  /// — `utta`. With nothing consonantal after it (the end of a line, an interjection) it is just
  /// a tsu, and the marker drops.
  private static func geminate(_ text: String) -> String {
    guard text.contains("~") else { return text }
    var out = ""
    var rest = Substring(text)
    while let marker = rest.range(of: "~tsu") {
      out += rest[..<marker.lowerBound]
      let after = rest[marker.upperBound...]
      if let next = after.first, next.isASCII, next.isLetter, !"aiueo".contains(next) {
        out.append(next)
      } else {
        out += "tsu"
      }
      rest = after
    }
    return out + rest
  }

  /// Hepburn folded onto the kunrei-style spellings an IME takes just as happily, so `sukurinsyo`
  /// and `sukurinsho` are one query. Longest first, since `shi` must not be read as `hi`.
  private static let spellings: [(String, String)] = [
    ("sha", "sya"), ("shu", "syu"), ("sho", "syo"), ("she", "sye"), ("shi", "si"),
    ("cha", "tya"), ("chu", "tyu"), ("cho", "tyo"), ("che", "tye"), ("chi", "ti"),
    ("tsu", "tu"), ("ja", "zya"), ("ju", "zyu"), ("jo", "zyo"), ("je", "zye"), ("ji", "zi"),
    ("fu", "hu"),
  ]

  private static func romanization(_ text: String) -> String {
    var out = text
    for (hepburn, kunrei) in spellings {
      guard out.contains(hepburn) else { continue }
      out = out.replacingOccurrences(of: hepburn, with: kunrei)
    }
    return out
  }

  /// A long vowel written twice, or as `ou`, becomes one: `kentou`, `kentoo` and `kento` are the
  /// same word asked for three ways. `nn` goes with them — ん is `n` to the tokenizer and `nn` to
  /// anyone typing it in a hurry. Vowels and ん only: a doubled consonant is the small tsu
  /// `geminate` has just finished putting there, and collapsing it would undo that in the next
  /// line.
  private static func collapse(_ text: String) -> String {
    var out = ""
    var previous: Character = " "
    for character in text {
      let long =
        (character == previous && "aiueon".contains(character))
        || (character == "u" && previous == "o")
      if long { continue }
      out.append(character)
      previous = character
    }
    return out
  }
}
