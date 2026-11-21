import CryptoKit
import Foundation

/// What a session's panel is allowed to do, as its agent installed it (`panel_install`) and the
/// person approved it (see `docs/panels.md`).
///
/// The definition is the whole of the panel's power: the one command that draws it (`render`) and
/// the commands its buttons may run, each an argv with typed holes. Nothing else runs. The person
/// approves this, not a script's promise, which is why the approval is pinned to a hash of the
/// definition and of every file it names by absolute path: an approved definition whose script
/// was rewritten afterwards is a different definition, and it stops until it is approved again.
struct PanelDefinition: Equatable {
  /// An argv as the definition spells it, `{name}` marking where an argument goes.
  typealias Argv = [String]

  struct Render: Equatable {
    let run: Argv
    /// Globs, relative to the worktree, whose change redraws the panel. A trigger, not a list of
    /// what the script reads: the script reads what it likes.
    let watch: [String]
  }

  struct Command: Equatable {
    let run: Argv
    /// Each argument's pattern, matched against the whole value.
    let args: [String: String]
    /// Reaches past this Mac or past the worktree — a PR marked ready, a message posted — so each
    /// press shows what is about to run and waits for a second yes.
    let outward: Bool
  }

  let render: Render
  let commands: [String: Command]
  /// Further files the hash covers — a module the render script imports, say. The definition can
  /// only vouch for what it names.
  let files: [String]
  /// The definition as it was installed, keys sorted: what the card shows, what is hashed and
  /// what is kept.
  let source: String

  /// The keys a definition may carry today. `mcp` and `schedules` are in the design and not built
  /// yet; a definition that asks for them is refused rather than half-installed, since a schedule
  /// silently not running is worse than an install that says why it did not happen.
  private static let knownKeys: Set<String> = ["render", "commands", "files"]
  private static let futureKeys: Set<String> = ["mcp", "schedules"]
  static let namePattern = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9_-]{0,63}$")

  struct Invalid: Error, Equatable, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  init(json object: Any) throws {
    guard let root = object as? [String: Any] else {
      throw Invalid("the definition must be an object")
    }
    for key in root.keys where !Self.knownKeys.contains(key) {
      if Self.futureKeys.contains(key) {
        throw Invalid("`\(key)` is not supported yet; install the panel without it")
      }
      throw Invalid("unknown key `\(key)`")
    }
    guard let render = root["render"] as? [String: Any] else {
      throw Invalid("`render` is required: { \"run\": [argv], \"watch\": [globs] }")
    }
    for key in render.keys where !["run", "watch"].contains(key) {
      throw Invalid("unknown key `render.\(key)`")
    }
    let renderRun = try Self.argv(render["run"], at: "render.run")
    if let hole = Self.holes(in: renderRun).first {
      throw Invalid("`render.run` takes no arguments, but names `{\(hole)}`")
    }
    let watch = try Self.strings(render["watch"] ?? [String](), at: "render.watch")
    for glob in watch where glob.hasPrefix("/") || glob.split(separator: "/").contains("..") {
      throw Invalid("`render.watch` globs are relative to the worktree: `\(glob)`")
    }
    self.render = Render(run: renderRun, watch: watch)

    var commands: [String: Command] = [:]
    let commandObjects = root["commands"] ?? [String: Any]()
    guard let commandObjects = commandObjects as? [String: Any] else {
      throw Invalid("`commands` must be an object of named commands")
    }
    for (name, value) in commandObjects {
      guard Self.isName(name) else { throw Invalid("`\(name)` is not a command name") }
      guard let command = value as? [String: Any] else {
        throw Invalid("`commands.\(name)` must be an object")
      }
      for key in command.keys where !["run", "args", "outward"].contains(key) {
        throw Invalid("unknown key `commands.\(name).\(key)`")
      }
      let run = try Self.argv(command["run"], at: "commands.\(name).run")
      let argObjects = command["args"] ?? [String: Any]()
      guard let argObjects = argObjects as? [String: Any] else {
        throw Invalid("`commands.\(name).args` must map each argument to a pattern")
      }
      var args: [String: String] = [:]
      for (arg, pattern) in argObjects {
        guard Self.isName(arg) else { throw Invalid("`\(arg)` is not an argument name") }
        guard let pattern = pattern as? String, (try? Self.anchored(pattern)) != nil else {
          throw Invalid("`commands.\(name).args.\(arg)` must be a regular expression")
        }
        args[arg] = pattern
      }
      let holes = Self.holes(in: run)
      if let undeclared = holes.subtracting(args.keys).sorted().first {
        throw Invalid("`commands.\(name).run` names `{\(undeclared)}`, which `args` does not type")
      }
      if let unused = Set(args.keys).subtracting(holes).sorted().first {
        throw Invalid("`commands.\(name).args.\(unused)` is not used in `run`")
      }
      let outward = command["outward"] ?? false
      guard let outward = outward as? Bool else {
        throw Invalid("`commands.\(name).outward` must be true or false")
      }
      commands[name] = Command(run: run, args: args, outward: outward)
    }
    self.commands = commands
    let files = try Self.strings(root["files"] ?? [String](), at: "files")
    for file in files where !file.hasPrefix("/") {
      throw Invalid("`files` are absolute paths: `\(file)`")
    }
    self.files = files
    let data = try JSONSerialization.data(
      withJSONObject: root, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    self.source = String(decoding: data, as: UTF8.self)
  }

  /// The definition read back from what was kept.
  init(source: String) throws {
    let object = try JSONSerialization.jsonObject(with: Data(source.utf8))
    try self.init(json: object)
  }

  // MARK: What the hash covers

  /// Every file the definition names: an argv entry that is an absolute path to a file, and the
  /// `files` list. A relative path is not followed — it names nothing fixed, the worktree being
  /// where commands run — and an interpreter found on PATH is the machine's, not the panel's.
  var namedFiles: [String] {
    var paths = files
    for argv in [render.run] + commands.keys.sorted().map({ commands[$0]!.run }) {
      for entry in argv where entry.hasPrefix("/") && !paths.contains(entry) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: entry, isDirectory: &isDirectory),
          !isDirectory.boolValue
        {
          paths.append(entry)
        }
      }
    }
    return paths
  }

  /// The hash of the definition and of each file it names, as approved. A `files` entry that is
  /// not there is refused: the definition vouches for it, and nothing can be pinned to a gap.
  func seal() throws -> PanelSeal {
    var hashes: [String: String] = [:]
    for path in namedFiles {
      guard let data = FileManager.default.contents(atPath: path) else {
        throw Invalid("`\(path)` cannot be read")
      }
      hashes[path] = Self.digest(data)
    }
    return PanelSeal(definition: Self.digest(Data(source.utf8)), files: hashes)
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Arguments

  /// A command's argv with its holes filled, or why not: every argument it types must be given,
  /// nothing else may be, and each must match its pattern whole. A value goes into argv as one
  /// element's text and never through a shell, so the pattern is about what the command is allowed
  /// to be pointed at, not about quoting.
  func argv(for name: String, arguments: [String: Any]) throws -> Argv {
    guard let command = commands[name] else { throw Invalid("no command `\(name)`") }
    var values: [String: String] = [:]
    for (key, value) in arguments {
      guard let pattern = command.args[key] else {
        throw Invalid("`\(name)` takes no argument `\(key)`")
      }
      let string: String
      if let text = value as? String {
        string = text
      } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        string = number.stringValue
      } else {
        throw Invalid("`\(name)`'s `\(key)` must be a string")
      }
      let regex = try Self.anchored(pattern)
      guard
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
      else { throw Invalid("`\(name)`'s `\(key)` does not match \(pattern): \(string)") }
      values[key] = string
    }
    if let missing = Set(command.args.keys).subtracting(values.keys).sorted().first {
      throw Invalid("`\(name)` needs `\(missing)`")
    }
    return command.run.map { entry in
      var filled = entry
      for (key, value) in values {
        filled = filled.replacingOccurrences(of: "{\(key)}", with: value)
      }
      return filled
    }
  }

  private static func anchored(_ pattern: String) throws -> NSRegularExpression {
    try NSRegularExpression(pattern: "^(?:\(pattern))$")
  }

  private static let holePattern = try! NSRegularExpression(
    pattern: "\\{([A-Za-z][A-Za-z0-9_-]*)\\}")

  static func holes(in argv: Argv) -> Set<String> {
    var names = Set<String>()
    for entry in argv {
      for match in holePattern.matches(in: entry, range: NSRange(entry.startIndex..., in: entry)) {
        if let range = Range(match.range(at: 1), in: entry) { names.insert(String(entry[range])) }
      }
    }
    return names
  }

  private static func isName(_ name: String) -> Bool {
    namePattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
  }

  private static func argv(_ value: Any?, at path: String) throws -> Argv {
    let argv = try strings(value ?? NSNull(), at: path)
    guard let first = argv.first, !first.isEmpty else {
      throw Invalid("`\(path)` must be a non-empty argv")
    }
    return argv
  }

  private static func strings(_ value: Any, at path: String) throws -> [String] {
    guard let values = value as? [Any] else { throw Invalid("`\(path)` must be a list of strings") }
    let strings = values.compactMap { $0 as? String }
    guard strings.count == values.count else {
      throw Invalid("`\(path)` must be a list of strings")
    }
    return strings
  }
}

/// What an approval is pinned to: the definition's hash and each named file's.
struct PanelSeal: Equatable, Codable {
  let definition: String
  let files: [String: String]

  /// The first named file whose contents no longer match, or nil when everything still does. A
  /// file gone counts as changed.
  func firstBroken() -> String? {
    for path in files.keys.sorted() {
      guard let data = FileManager.default.contents(atPath: path),
        PanelDefinition.digest(data) == files[path]
      else { return path }
    }
    return nil
  }
}
