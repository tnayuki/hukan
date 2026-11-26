import Foundation

/// What a session's mods last drew — its panes with their trees, the band and the status lines —
/// kept so a session whose engine is not running shows them as they were, as a browser shows a
/// page from before a relaunch: marked as old, with nothing in it to press (`docs/mods.md`). The
/// trees are kept without their handles, which were good only for the render that gave them.
struct ModMemory {
  struct Pane {
    var pane: ModSurface.Pane
    var tree: ModSurface.Node?
  }

  var panes: [Pane] = []
  var band: ModSurface.Node?
  var statuses: [(plugin: String, text: String)] = []
  /// When any of it was last drawn: the age the notice over it gives.
  var drawnAt: Date?

  var isEmpty: Bool { panes.isEmpty && band == nil && statuses.isEmpty }

  /// Follow a roster: a pane that stays keeps its tree, a new one has none yet.
  mutating func take(_ roster: ModSurface.Roster) {
    let trees = Dictionary(panes.map { ($0.pane.id, $0.tree) }, uniquingKeysWith: { a, _ in a })
    panes = roster.panes.map { Pane(pane: $0, tree: trees[$0.id] ?? nil) }
  }

  mutating func take(_ tree: ModSurface.Node?, forPane id: String, at date: Date = Date()) {
    guard let index = panes.firstIndex(where: { $0.pane.id == id }) else { return }
    panes[index].tree = tree?.inert
    drawnAt = date
  }

  func tree(forPane id: String) -> ModSurface.Node? {
    panes.first { $0.pane.id == id }?.tree
  }

  // MARK: Restorable state

  /// As JSON, for the window's restorable state; nil when there is nothing to keep, or a tree
  /// holds a value JSON cannot spell.
  var json: String? {
    guard !isEmpty else { return nil }
    var object: [String: Any] = [
      "panes": panes.map { entry -> [String: Any] in
        var pane: [String: Any] = [
          "id": entry.pane.id, "title": entry.pane.title, "plugin": entry.pane.plugin,
          "close_on_escape": entry.pane.closesOnEscape,
        ]
        if let tree = entry.tree { pane["tree"] = tree.wire }
        return pane
      },
      "statuses": statuses.map { ["plugin": $0.plugin, "text": $0.text] },
    ]
    if let band { object["band"] = band.wire }
    if let drawnAt { object["drawn_at"] = drawnAt.timeIntervalSince1970 }
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  init() {}

  init?(json: String) {
    guard let data = json.data(using: .utf8),
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    let roster = ModSurface.Roster(["panes": object["panes"] ?? []]) ?? ModSurface.Roster()
    let entries = object["panes"] as? [[String: Any]] ?? []
    panes = roster.panes.map { pane in
      let entry = entries.first { $0["id"] as? String == pane.id }
      return Pane(pane: pane, tree: Self.tree(entry?["tree"]))
    }
    band = Self.tree(object["band"])
    statuses = (object["statuses"] as? [[String: Any]] ?? []).compactMap { entry in
      guard let plugin = entry["plugin"] as? String, let text = entry["text"] as? String,
        !text.isEmpty
      else { return nil }
      return (plugin, text)
    }
    drawnAt = (object["drawn_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    guard !isEmpty else { return nil }
  }

  private static func tree(_ wire: Any?) -> ModSurface.Node? {
    wire.flatMap { ModSurface.tree(["tree": $0]) }
  }
}
