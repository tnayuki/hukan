import Foundation

/// What a panel's render command printed: a tree of the parts hukan knows how to draw, and the
/// actions its buttons name. A part is data — nothing in it is a script or markup — so the panel
/// can only show and offer what this type can say, and an action can only be a message to the
/// session or a command the definition declared (`PanelDefinition`).
struct PanelContent: Equatable {
  enum Tone: String, Equatable {
    case neutral, info, success, warning, danger
  }

  enum Action: Equatable {
    /// A message to this session.
    case send(String)
    /// A declared command, with its arguments as the render gave them — checked against the
    /// definition when pressed, not here, so an output naming a command that does not exist still
    /// draws, its button failing with the reason.
    case command(name: String, args: [String: String])
  }

  struct Button: Equatable {
    let label: String
    let action: Action
    /// An SF Symbol drawn before the label.
    var symbol: String? = nil
  }

  /// A run of text a part shows: plain words, and inside them what plain words cannot be — a
  /// link, a tag chip as the rail draws it, a time kept relative, a symbol. Anywhere a part takes
  /// text it takes a string or a list of these, so the plain case stays a string.
  struct Inline: Equatable, ExpressibleByStringLiteral {
    enum Span: Equatable {
      case text(String, mono: Bool, strong: Bool, tone: Tone?)
      case link(String, Target)
      /// `kind: value`, optionally ending in `<address>` — the rail's tag (`SessionTags`).
      case tag(String)
      case time(Date)
      case symbol(String, Tone?)
    }

    let spans: [Span]

    init(_ spans: [Span]) { self.spans = spans }
    init(stringLiteral value: String) {
      spans = [.text(value, mono: false, strong: false, tone: nil)]
    }

    /// The words alone, for a tooltip, a script, a sort.
    var plain: String {
      spans.map { span -> String in
        switch span {
        case .text(let text, _, _, _), .link(let text, _): return text
        case .tag(let tag): return SessionTags.split(tag).value
        case .time(let date): return Inline.relative(date)
        case .symbol: return ""
        }
      }.joined()
    }

    /// A time as the rail spells an age — `3m ago`, `in 2h`.
    static func relative(_ date: Date, now: Date = Date()) -> String {
      if date > now.addingTimeInterval(1) {
        return "in " + (AgentSession.age(since: now, at: date) ?? "0s")
      }
      return (AgentSession.age(since: date, at: now) ?? "0s") + " ago"
    }
  }

  /// Where a row or a link leads.
  enum Target: Equatable {
    case url(URL)
    /// A file in the worktree, by its path relative to it.
    case document(String)
    case session(UUID)
  }

  struct Field: Equatable {
    let label: String
    let value: Inline
    var symbol: String? = nil
  }

  struct Row: Equatable {
    let title: Inline
    let subtitle: Inline?
    var symbol: String? = nil
    let status: (text: String, tone: Tone)?
    let buttons: [Button]
    let target: Target?

    static func == (a: Row, b: Row) -> Bool {
      a.title == b.title && a.subtitle == b.subtitle && a.status?.text == b.status?.text
        && a.status?.tone == b.status?.tone && a.buttons == b.buttons && a.target == b.target
        && a.symbol == b.symbol
    }
  }

  struct Group: Equatable {
    let title: String?
    let rows: [Row]
  }

  indirect enum Part: Equatable {
    case badge(String, Tone)
    case text(Inline)
    case fields([Field])
    case list(groups: [Group], limit: Int?, empty: String?)
    case button(Button)
    case approval(document: String, label: String?)
    case notice(String, Tone)
    case divider
  }

  let title: String?
  let parts: [Part]

  /// The most rows a list draws before the rest are counted. A page, not a database.
  static let rowLimit = 500
  static let partLimit = 200

  struct Invalid: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  init(title: String?, parts: [Part]) {
    self.title = title
    self.parts = parts
  }

  init(data: Data) throws {
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
      throw Invalid("the render printed no JSON")
    }
    guard let root = object as? [String: Any] else { throw Invalid("the output must be an object") }
    title = try Self.optionalString(root["title"], at: "title")
    guard let items = (root["items"] ?? [Any]()) as? [Any] else {
      throw Invalid("`items` must be a list")
    }
    guard items.count <= Self.partLimit else {
      throw Invalid("more than \(Self.partLimit) items")
    }
    parts = try items.enumerated().map { try Self.part($1, at: "items[\($0)]") }
  }

  private static func part(_ value: Any, at path: String) throws -> Part {
    guard let object = value as? [String: Any], let type = object["type"] as? String else {
      throw Invalid("`\(path)` must be an object with a `type`")
    }
    switch type {
    case "badge":
      return .badge(
        try string(object["text"], at: "\(path).text"), try tone(object["tone"], at: path))
    case "text":
      return .text(try inline(object["text"], at: "\(path).text"))
    case "fields":
      guard let items = object["items"] as? [Any] else {
        throw Invalid("`\(path).items` must be a list")
      }
      return .fields(
        try items.enumerated().map { index, item in
          let at = "\(path).items[\(index)]"
          guard let field = item as? [String: Any] else {
            throw Invalid("`\(at)` must be an object")
          }
          return Field(
            label: try string(field["label"], at: "\(at).label"),
            value: try inline(field["value"], at: "\(at).value"),
            symbol: try optionalString(field["symbol"], at: "\(at).symbol"))
        })
    case "list":
      var groups: [Group] = []
      if let rows = object["rows"] {
        groups.append(Group(title: nil, rows: try self.rows(rows, at: "\(path).rows")))
      }
      if let groupList = object["groups"] {
        guard let groupList = groupList as? [Any] else {
          throw Invalid("`\(path).groups` must be a list")
        }
        for (index, item) in groupList.enumerated() {
          let at = "\(path).groups[\(index)]"
          guard let group = item as? [String: Any] else {
            throw Invalid("`\(at)` must be an object")
          }
          groups.append(
            Group(
              title: try optionalString(group["title"], at: "\(at).title"),
              rows: try rows(group["rows"] ?? [Any](), at: "\(at).rows")))
        }
      }
      guard groups.reduce(0, { $0 + $1.rows.count }) <= rowLimit else {
        throw Invalid("`\(path)` has more than \(rowLimit) rows")
      }
      var limit: Int?
      if let value = object["limit"] {
        guard let number = value as? Int, number > 0 else {
          throw Invalid("`\(path).limit` must be a positive number")
        }
        limit = number
      }
      return .list(
        groups: groups, limit: limit,
        empty: try optionalString(object["empty"], at: "\(path).empty"))
    case "button":
      return .button(try button(object, at: path))
    case "approval":
      let document = try string(object["document"], at: "\(path).document")
      guard PanelContent.isRelative(document) else {
        throw Invalid("`\(path).document` must be a path inside the worktree")
      }
      return .approval(
        document: document, label: try optionalString(object["label"], at: "\(path).label"))
    case "notice":
      return .notice(
        try string(object["text"], at: "\(path).text"), try tone(object["tone"], at: path))
    case "divider":
      return .divider
    default:
      throw Invalid("`\(path)` is of unknown type `\(type)`")
    }
  }

  private static func rows(_ value: Any, at path: String) throws -> [Row] {
    guard let list = value as? [Any] else { throw Invalid("`\(path)` must be a list") }
    return try list.enumerated().map { index, item in
      let at = "\(path)[\(index)]"
      guard let row = item as? [String: Any] else { throw Invalid("`\(at)` must be an object") }
      var status: (text: String, tone: Tone)?
      if let value = row["status"] {
        if let text = value as? String {
          status = (text, .neutral)
        } else if let object = value as? [String: Any] {
          status = (
            try string(object["text"], at: "\(at).status.text"),
            try tone(object["tone"], at: "\(at).status")
          )
        } else {
          throw Invalid("`\(at).status` must be a string or { text, tone }")
        }
      }
      guard let buttonList = (row["buttons"] ?? [Any]()) as? [Any] else {
        throw Invalid("`\(at).buttons` must be a list")
      }
      let buttons = try buttonList.enumerated().map { try button($1, at: "\(at).buttons[\($0)]") }
      return Row(
        title: try inline(row["title"], at: "\(at).title"),
        subtitle: try row["subtitle"].map { try inline($0, at: "\(at).subtitle") },
        symbol: try optionalString(row["symbol"], at: "\(at).symbol"),
        status: status, buttons: buttons, target: try target(row, at: at))
    }
  }

  private static func target(_ object: [String: Any], at path: String) throws -> Target? {
    if let url = object["url"] {
      guard let string = url as? String, let url = URL(string: string),
        ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil
      else { throw Invalid("`\(path).url` must be an http(s) address") }
      return .url(url)
    }
    if let document = object["document"] {
      guard let document = document as? String, isRelative(document) else {
        throw Invalid("`\(path).document` must be a path inside the worktree")
      }
      return .document(document)
    }
    if let session = object["session"] {
      guard let string = session as? String, let id = UUID(uuidString: string) else {
        throw Invalid("`\(path).session` must be a session id")
      }
      return .session(id)
    }
    return nil
  }

  private static func button(_ value: Any, at path: String) throws -> Button {
    guard let object = value as? [String: Any] else { throw Invalid("`\(path)` must be an object") }
    let label = try string(object["label"], at: "\(path).label")
    if let text = object["send"] {
      guard let text = text as? String, !text.isEmpty else {
        throw Invalid("`\(path).send` must be the message to send")
      }
      return Button(
        label: label, action: .send(text),
        symbol: try optionalString(object["symbol"], at: "\(path).symbol"))
    }
    if let name = object["command"] {
      guard let name = name as? String else { throw Invalid("`\(path).command` must be a name") }
      var args: [String: String] = [:]
      if let given = object["args"] {
        guard let given = given as? [String: Any] else {
          throw Invalid("`\(path).args` must be an object")
        }
        for (key, value) in given {
          if let text = value as? String {
            args[key] = text
          } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            args[key] = number.stringValue
          } else {
            throw Invalid("`\(path).args.\(key)` must be a string")
          }
        }
      }
      return Button(
        label: label, action: .command(name: name, args: args),
        symbol: try optionalString(object["symbol"], at: "\(path).symbol"))
    }
    throw Invalid("`\(path)` needs `send` or `command`")
  }

  /// A string, or a list of spans: a string, `{text, mono, strong, tone}`, `{text, url | document |
  /// session}` for a link, `{tag}`, `{time}` (ISO 8601) or `{symbol, tone}`.
  private static func inline(_ value: Any?, at path: String) throws -> Inline {
    if let text = value as? String { return Inline(stringLiteral: text) }
    guard let list = value as? [Any] else {
      throw Invalid("`\(path)` must be a string or a list of spans")
    }
    return Inline(
      try list.enumerated().map { index, item -> Inline.Span in
        let at = "\(path)[\(index)]"
        if let text = item as? String { return .text(text, mono: false, strong: false, tone: nil) }
        guard let span = item as? [String: Any] else {
          throw Invalid("`\(at)` must be a string or an object")
        }
        if let tag = span["tag"] {
          guard let tag = tag as? String, !SessionTags.normalized([tag]).isEmpty else {
            throw Invalid("`\(at).tag` must be a tag, `kind: value`")
          }
          return .tag(SessionTags.normalized([tag])[0])
        }
        if let time = span["time"] {
          guard let time = time as? String, let date = parseDate(time) else {
            throw Invalid("`\(at).time` must be an ISO 8601 time")
          }
          return .time(date)
        }
        if let symbol = span["symbol"] {
          guard let symbol = symbol as? String else {
            throw Invalid("`\(at).symbol` must be a symbol name")
          }
          return .symbol(symbol, span["tone"] == nil ? nil : try tone(span["tone"], at: at))
        }
        let text = try string(span["text"], at: "\(at).text")
        if let target = try target(span, at: at) { return .link(text, target) }
        return .text(
          text, mono: span["mono"] as? Bool ?? false, strong: span["strong"] as? Bool ?? false,
          tone: span["tone"] == nil ? nil : try tone(span["tone"], at: at))
      })
  }

  static func parseDate(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string)
  }

  private static func tone(_ value: Any?, at path: String) throws -> Tone {
    guard let value else { return .neutral }
    guard let name = value as? String, let tone = Tone(rawValue: name) else {
      throw Invalid("`\(path).tone` must be neutral, info, success, warning or danger")
    }
    return tone
  }

  private static func string(_ value: Any?, at path: String) throws -> String {
    guard let string = value as? String else { throw Invalid("`\(path)` must be a string") }
    return string
  }

  private static func optionalString(_ value: Any?, at path: String) throws -> String? {
    guard let value, !(value is NSNull) else { return nil }
    return try string(value, at: path)
  }

  /// A path that stays inside the worktree it is read against: relative, and never climbing out.
  static func isRelative(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
  }
}
