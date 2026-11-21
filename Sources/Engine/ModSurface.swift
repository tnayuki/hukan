import Foundation

/// hukan as a surface Claude Code's mods draw on — the wire half (see `docs/mods.md`).
///
/// A mod is a plugin's hooks module running inside the engine. It opens a pane with
/// `$.ui.open`, and draws it from a `ui.render` hook as a tree of plain-data elements; a host that
/// speaks the control protocol can attach as a surface and be handed those trees. Everything here
/// was read off the shipped binary (2.1.325) and the VS Code extension (2.1.330), which draws the
/// same trees as the `vscode` surface: the engine answers `ui_attach`, `ui_render`, `ui_press`,
/// `ui_input`, `ui_select`, `ui_panes`, `ui_close` and `ui_pane_show` as control requests, and
/// pushes `ui_panes` and `ui_invalidate` as system messages. `@internal` and early access on the
/// engine's side — re-verify on upgrades.
///
/// hukan attaches as `desktop`, the surface the Claude desktop app draws as: the one whose element
/// table (`Box`, `Text`, `Button`, `Input`, `Select`, `Link`, `Code`, `Markdown`, `Progress`,
/// `Svg`, `Client`) matches what a window can draw, and whose panes are docked beside the
/// conversation — which is what a desk is. This type parses and builds the messages; it knows
/// nothing of a view.
enum ModSurface {
  static let surface = "desktop"
  /// One client per engine: the window is the one thing drawing a session's panes.
  static let clientID = "hukan"
  /// What the initialize reply's `capabilities` lists when the engine takes surfaces at all.
  static let capability = "ui_surface_v1"

  /// The room a surface draws into, in character cells: what a mod sizes its tree by. `dock`
  /// is the only seat a desk has, so it says fullscreen — the word under which the engine docks a
  /// pane beside the transcript rather than putting it above the prompt.
  struct Viewport: Equatable {
    var columns: Int
    var rows: Int

    var wire: [String: Any] {
      ["columns": max(1, columns), "rows": max(1, rows), "isFullscreen": true]
    }
  }

  struct Pane: Equatable {
    let id: String
    let title: String
    let plugin: String
    /// Escape closes it as well as handing the keyboard back (`closeOnEscape`).
    var closesOnEscape = false
  }

  /// The panes a session has open, and which one the engine would show — the `ui_panes` roster.
  struct Roster: Equatable {
    var panes: [Pane] = []
    var shownID: String?
    /// A pane the mod asked to have the keyboard (`$.ui.open({ focus: true })`), which the
    /// surface has yet to grant or refuse (`paneFocus`).
    var focusRequestedID: String?
    /// The pane the engine holds as having the keyboard, as the surface last told it.
    var focusedID: String?

    init() {}

    /// The roster in a `ui_panes` reply or push; nil when it is not one.
    init?(_ object: [String: Any]) {
      guard let list = object["panes"] as? [[String: Any]] else { return nil }
      panes = list.compactMap { entry in
        guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
        return Pane(
          id: id, title: entry["title"] as? String ?? id, plugin: entry["plugin"] as? String ?? "",
          closesOnEscape: entry["close_on_escape"] as? Bool == true)
      }
      let ids = Set(panes.map(\.id))
      shownID = (object["shown_id"] as? String).flatMap { ids.contains($0) ? $0 : nil }
      focusRequestedID = (object["focus_requested_id"] as? String).flatMap {
        ids.contains($0) ? $0 : nil
      }
      focusedID = (object["focused_id"] as? String).flatMap { ids.contains($0) ? $0 : nil }
    }
  }

  /// Where a press goes back to: the plugin that drew the element and the handle it was drawn
  /// with. A handle is good for the render it came in — each render hands out new ones.
  struct Press: Equatable, Hashable {
    let plugin: String
    let handle: Int

    init?(_ object: Any?) {
      guard let object = object as? [String: Any], let plugin = object["plugin"] as? String,
        let handle = (object["handle"] as? NSNumber)?.intValue
      else { return nil }
      self.plugin = plugin
      self.handle = handle
    }
  }

  /// One node of a drawn tree: a run of text, or an element with its props and children.
  indirect enum Node {
    case text(String)
    case element(type: String, props: [String: Any], children: [Node], press: Press?)

    /// Every string under this node, in order — a button's label drawn as children, a tab dump.
    var plainText: String {
      switch self {
      case .text(let text): return text
      case .element(_, _, let children, _): return children.map(\.plainText).joined()
      }
    }
  }

  /// The most a tree may hold before the rest is dropped: a pane is a page, and a hook gone wrong
  /// must not be able to build a window's worth of views.
  static let nodeLimit = 5000
  /// The least time between a render and the next one it made dirty: a hook that invalidates
  /// every time it draws is redrawn at this pace rather than as fast as the wire allows.
  static let redrawInterval: TimeInterval = 0.1
  static let depthLimit = 64

  /// The tree in a `ui_render` reply, or nil for none — a site no plugin hooks answers an
  /// `engine` node, which on a pane means there is nothing of the mod's to draw.
  static func tree(_ reply: [String: Any]?) -> Node? {
    guard let reply, reply["hooked"] as? Bool != false else { return nil }
    var budget = nodeLimit
    return node(reply["tree"], depth: 0, budget: &budget)
  }

  private static func node(_ value: Any?, depth: Int, budget: inout Int) -> Node? {
    guard budget > 0, depth < depthLimit else { return nil }
    budget -= 1
    if let text = value as? String { return .text(text) }
    if let number = value as? NSNumber { return .text(number.stringValue) }
    guard let object = value as? [String: Any], let type = object["type"] as? String,
      type != "engine"
    else { return nil }
    let children = (object["children"] as? [Any] ?? []).compactMap {
      node($0, depth: depth + 1, budget: &budget)
    }
    // An element's `hover` rides beside its props on the wire, as `press` does — measured, and
    // not where the mod wrote it — so it is put back among them, where the renderer reads it.
    var props = object["props"] as? [String: Any] ?? [:]
    if let hover = object["hover"] as? [String: Any] { props["hover"] = hover }
    // Whose drawing a box is rides beside its props too (`part` on a plugin's root, `group` on a
    // box with a hover): what names a keyed box's plugin when its place is reported.
    if let plugin = ((object["part"] ?? object["group"]) as? [String: Any])?["plugin"] as? String {
      props[pluginProp] = plugin
    }
    return .element(type: type, props: props, children: children, press: Press(object["press"]))
  }

  /// The prop a node's plugin is put back under, when the wire names it beside the props.
  static let pluginProp = "_plugin"

  // MARK: Requests

  static func attach(_ viewport: Viewport) -> [String: Any] {
    ["surface": surface, "client_id": clientID, "viewport": viewport.wire]
  }

  /// Where a site's window stands and how its last tree laid out: the first row shown, the rows
  /// the whole tree took, and where its keyed elements sit — what a plugin's `$.ui.scroll` to the
  /// end or to a key is measured against. Nil before the first layout.
  struct Layout: Equatable {
    var offset = 0
    var contentRows: Int
    var keyed: [Placed] = []
  }

  static func wire(_ keyed: [Placed]) -> [[String: Any]] {
    keyed.prefix(512).map {
      ["plugin": $0.element.plugin, "key": $0.element.key, "top": $0.top, "bottom": $0.bottom]
    }
  }

  /// A pane's render. The props are the `Pane` site's, as the surface seats it: docked, its body
  /// as wide as the viewport, its window where the tab has it scrolled.
  static func render(
    pane: Pane, viewport: Viewport, isFocused: Bool, layout: Layout? = nil
  ) -> [String: Any] {
    var request: [String: Any] = [
      "surface": surface, "client_id": clientID, "component": "Pane", "instance_id": pane.id,
      "viewport": viewport.wire,
      "props": [
        "title": pane.title, "isFocused": isFocused, "bodyColumns": viewport.columns,
        "placement": "dock",
        "scroll": ["offset": layout?.offset ?? 0, "bodyRows": viewport.rows],
        "view": [String: Any](),
      ] as [String: Any],
    ]
    if let layout {
      request["content_rows"] = max(0, layout.contentRows)
      if !layout.keyed.isEmpty { request["keyed"] = wire(layout.keyed) }
    }
    return request
  }

  /// The band above the prompt: one instance per session, under the id every surface gives it,
  /// at most `bandRows` tall. `isWorking` is what a band that shows progress reads.
  static let bandInstance = "above-prompt"
  static let bandRows = 12

  static func renderBand(columns: Int, isWorking: Bool, layout: Layout? = nil) -> [String: Any] {
    var request: [String: Any] = [
      "surface": surface, "client_id": clientID, "component": "AbovePrompt",
      "instance_id": bandInstance,
      "viewport": Viewport(columns: columns, rows: bandRows).wire,
      "props": [
        "hasSurvey": false, "isCollapsed": false, "isWorking": isWorking, "maxRows": bandRows,
        "bodyColumns": columns, "scroll": ["offset": layout?.offset ?? 0, "bodyRows": bandRows],
        "view": [String: Any](),
      ] as [String: Any],
    ]
    if let layout {
      request["content_rows"] = max(0, layout.contentRows)
      if !layout.keyed.isEmpty { request["keyed"] = wire(layout.keyed) }
    }
    return request
  }

  /// A press, with the render of the site it was drawn at riding along: the engine answers the
  /// press once its handler has run, and hands back (`drawn`) the tree as it stands then, with
  /// fresh handles. Asking for the tree in a second request instead was measured to come back a
  /// step early — before the handler had written what it changes — so a pane whose mod keeps its
  /// state in a variable showed the old picture, with buttons whose handles had gone stale.
  static func press(
    _ press: Press, href: String? = nil, render: [String: Any]? = nil
  ) -> [String: Any] {
    var request: [String: Any] = [
      "plugin": press.plugin, "handle": press.handle, "surface": surface, "client_id": clientID,
    ]
    if let href { request["href"] = String(href.prefix(2048)) }
    if let render { request["render"] = render }
    return request
  }

  /// The tree a press, a field's submit or a pick handed back with its answer (`drawn`), when it
  /// carried a render and the engine could draw it.
  static func drawn(_ reply: [String: Any]?) -> Node? {
    tree(reply?["drawn"] as? [String: Any])
  }

  /// A field's text: each change as it is typed, and the submit.
  /// The render site an element was drawn at — a pane by its id, or the band — which a field's
  /// text and a pick name, so the engine finds the handle where it handed it out.
  struct Site: Equatable {
    let component: String
    let instance: String

    static func pane(_ id: String) -> Site { Site(component: "Pane", instance: id) }
    static let band = Site(component: "AbovePrompt", instance: bandInstance)
  }

  static func input(
    _ press: Press, value: String, submit: Bool, site: Site, render: [String: Any]? = nil
  ) -> [String: Any] {
    var request: [String: Any] = [
      "plugin": press.plugin, "handle": press.handle, "kind": submit ? "submit" : "change",
      "value": String(value.prefix(16384)), "surface": surface, "client_id": clientID,
      "component": site.component, "instance_id": site.instance,
    ]
    if let render { request["render"] = render }
    return request
  }

  static func select(
    _ press: Press, value: String, site: Site, render: [String: Any]? = nil
  ) -> [String: Any] {
    var request: [String: Any] = [
      "plugin": press.plugin, "handle": press.handle, "value": value, "surface": surface,
      "client_id": clientID, "component": site.component, "instance_id": site.instance,
    ]
    if let render { request["render"] = render }
    return request
  }

  // MARK: Scrolling and the keyboard

  /// A control a plugin drew, by whose it is and the `key` it was drawn under — how a focus move
  /// names it, both ways.
  struct Element: Hashable {
    let plugin: String
    let key: String

    var wire: [String: Any] { ["plugin": plugin, "key": key] }
  }

  /// Where a keyed element sits in a site's content, in rows from its top: what lets a plugin's
  /// `$.ui.scroll({ to: { key } })` land on it.
  struct Placed: Equatable {
    let element: Element
    let top: Int
    let bottom: Int
  }

  /// The person scrolled a site: where its window is now (`offset`, the first row it shows), how
  /// far it moved, how tall the window and the content are, and where the keyed elements sit.
  /// The engine answers with the offset it holds, which a `ui.scroll` hook may have changed.
  static func scroll(
    site: Site, offset: Int, by: Int, bodyRows: Int, contentRows: Int,
    pointer: (column: Int, row: Int)? = nil, keyed: [Placed] = []
  ) -> [String: Any] {
    var request: [String: Any] = [
      "component": site.component, "instance_id": site.instance, "offset": max(0, offset),
      "by": by, "body_rows": max(0, bodyRows), "content_rows": max(0, contentRows),
      "surface": surface, "client_id": clientID,
    ]
    if let pointer {
      request["pointer"] = ["column": max(0, pointer.column), "row": max(0, pointer.row)]
    }
    if !keyed.isEmpty { request["keyed"] = wire(keyed) }
    return request
  }

  /// The keyboard moved in a site: whether the site holds it, and which control took the ring —
  /// nil for the site itself; `by` is `person`, or `auto` for an `autoFocus` control taking it as
  /// the site was drawn. The answer carries the element the engine holds, a hook's redirect
  /// included, for the site to follow.
  static func focus(site: Site, isHeld: Bool, element: Element?, by: String = "person")
    -> [String: Any]
  {
    [
      "component": site.component, "instance_id": site.instance, "is_held": isHeld,
      "element": element.map { $0.wire as Any } ?? NSNull(), "by": by, "surface": surface,
      "client_id": clientID,
    ]
  }

  /// The keyboard went to a pane (its id), or back to the composer (nil). Also how a standing
  /// focus request is granted or refused.
  static func paneFocus(_ id: String?) -> [String: Any] {
    ["id": id.map { $0 as Any } ?? NSNull(), "surface": surface, "client_id": clientID]
  }

  /// A plugin moved a site's window (`$.ui.scroll`): the offset to show, and whether to keep to
  /// the end as the content grows. Nil when the push is not one, or is for another client.
  struct ScrollMove: Equatable {
    let site: Site
    let offset: Int
    let followsEnd: Bool

    init?(_ object: [String: Any]) {
      guard object["client_id"] as? String ?? clientID == clientID,
        let component = object["component"] as? String,
        let instance = object["instance_id"] as? String,
        let offset = (object["offset"] as? NSNumber)?.intValue
      else { return nil }
      site = Site(component: component, instance: instance)
      self.offset = max(0, offset)
      followsEnd = object["follow_end"] as? Bool == true
    }
  }

  /// A plugin moved a site's focus ring onto one of its controls (`$.ui.focus`).
  struct FocusMove: Equatable {
    let site: Site
    let element: Element

    init?(_ object: [String: Any]) {
      guard object["client_id"] as? String ?? clientID == clientID,
        let component = object["component"] as? String,
        let instance = object["instance_id"] as? String,
        let plugin = object["plugin"] as? String, let key = object["key"] as? String
      else { return nil }
      site = Site(component: component, instance: instance)
      element = Element(plugin: plugin, key: key)
    }
  }

  /// The element a `ui_focus` answer says holds the ring; nil for the site itself or none.
  static func focusedElement(_ reply: [String: Any]?) -> Element? {
    guard let object = reply?["element"] as? [String: Any],
      let plugin = object["plugin"] as? String, let key = object["key"] as? String
    else { return nil }
    return Element(plugin: plugin, key: key)
  }
}
