import AppKit
import XCTest

@testable import Hukan

/// hukan as a surface Claude Code's mods draw on: the messages it reads and writes, and a real
/// pane's tree — captured from the engine (2.1.325) answering `ui_render` for a mod that uses
/// every element — drawn with AppKit. `TEST_RUNNER_HUKAN_PREVIEW=mod` writes
/// /tmp/hukan-preview-mod.png; `TEST_RUNNER_HUKAN_PREVIEW_TREE=<file>` draws that `ui_render`
/// reply instead, so any mod's pane can be looked at without the app.
final class ModSurfaceTests: XCTestCase {
  private static let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/mod-showcase.json")

  private func showcase() throws -> [String: Any] {
    let data = try Data(contentsOf: Self.fixture)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testTheRosterIsReadAsTheEngineListsIt() {
    let roster = ModSurface.Roster([
      "panes": [
        ["id": "a", "title": "A", "plugin": "p"], ["id": "b", "plugin": "q"], ["title": "no id"],
      ],
      "shown_id": "b", "focus_requested_id": "gone",
    ])
    XCTAssertEqual(roster?.panes.map(\.id), ["a", "b"])
    XCTAssertEqual(roster?.panes.last?.title, "b")
    XCTAssertEqual(roster?.shownID, "b")
    // A pane the roster does not list cannot be the one to show.
    XCTAssertNil(roster?.focusRequestedID)
    XCTAssertNil(ModSurface.Roster(["shown_id": "a"]))
  }

  func testATreeIsReadWithItsPresses() throws {
    let tree = try XCTUnwrap(ModSurface.tree(try showcase()))
    guard case .element(let type, let props, let children, _) = tree else {
      return XCTFail("not an element")
    }
    XCTAssertEqual(type, "Box")
    XCTAssertEqual(props["flexDirection"] as? String, "column")
    XCTAssertGreaterThan(children.count, 5)
    var presses: [ModSurface.Press] = []
    func walk(_ node: ModSurface.Node) {
      if case .element(_, _, let children, let press) = node {
        if let press { presses.append(press) }
        children.forEach(walk)
      }
    }
    walk(tree)
    XCTAssertTrue(presses.allSatisfy { $0.plugin == "showcase" })
    XCTAssertGreaterThanOrEqual(presses.count, 4)
    let outline = ModRenderer.outline(tree)
    XCTAssertTrue(outline.contains("Pressed 1 times"), outline)
    XCTAssertTrue(outline.contains("[Press]"), outline)
  }

  /// A site no mod hooks answers the engine's own node, which on a pane is nothing to draw.
  func testAnUnhookedSiteDrawsNothing() {
    XCTAssertNil(ModSurface.tree(["tree": ["type": "engine", "ref": 0], "hooked": false]))
    XCTAssertNil(ModSurface.tree(nil))
  }

  /// On the wire an element's `hover` sits beside its props, not among them — as the engine sends
  /// a queue's row — and a row read that way lights under the pointer.
  func testHoverIsReadFromBesideTheProps() throws {
    let reply: [String: Any] = [
      "hooked": true,
      "tree": [
        "type": "Box", "props": ["key": "row-1", "flexDirection": "row"],
        "hover": ["scope": "row-1", "backgroundColor": "userMessageBackground"],
        "children": [
          ["type": "Text", "children": ["title"]],
          [
            "type": "Box", "props": ["display": "none"],
            "hover": ["scope": "row-1", "display": "flex"],
            "children": [["type": "Text", "children": ["Drop"]]],
          ],
        ],
      ] as [String: Any],
    ]
    let tree = try XCTUnwrap(ModSurface.tree(reply))
    guard case .element(_, let props, _, _) = tree else { return XCTFail("not an element") }
    XCTAssertEqual((props["hover"] as? [String: Any])?["scope"] as? String, "row-1")
    let renderer = ModRenderer(pane: "p")
    let view = try XCTUnwrap(renderer.view(for: tree))
    let surface = try XCTUnwrap(
      ([view] + subviews(of: view)).compactMap { $0 as? ModHoverSurface }.first)
    XCTAssertNotNil(surface.onHover, "the row's box tracks the pointer")
    XCTAssertTrue(subviews(of: view).contains { $0.isHidden }, "its action waits hidden")
  }

  func testRequestsCarryTheSurfaceAndClient() {
    let pane = ModSurface.Pane(id: "p", title: "Pane", plugin: "mod")
    let render = ModSurface.render(
      pane: pane, viewport: .init(columns: 80, rows: 30), isFocused: false)
    XCTAssertEqual(render["surface"] as? String, "desktop")
    XCTAssertEqual(render["client_id"] as? String, "hukan")
    XCTAssertEqual(render["instance_id"] as? String, "p")
    let props = render["props"] as? [String: Any]
    XCTAssertEqual(props?["placement"] as? String, "dock")
    XCTAssertEqual(props?["bodyColumns"] as? Int, 80)
    XCTAssertEqual((render["viewport"] as? [String: Any])?["isFullscreen"] as? Bool, true)
    let press = ModSurface.Press(["plugin": "mod", "handle": 7])!
    // A press carries the render of its site, and the answer's `drawn` is the tree after it.
    let pressing = ModSurface.press(press, render: render)
    XCTAssertEqual((pressing["render"] as? [String: Any])?["instance_id"] as? String, "p")
    XCTAssertNotNil(
      ModSurface.drawn([
        "handled": true, "drawn": ["tree": ["type": "Text", "children": ["after"]]],
      ]))
    XCTAssertNil(ModSurface.drawn(["handled": true]))
    let input = ModSurface.input(press, value: "x", submit: true, site: .pane("p"))
    XCTAssertEqual(input["kind"] as? String, "submit")
    XCTAssertEqual(input["component"] as? String, "Pane")
    // A field in the band names the band's site, or the engine looks for its handle in a pane.
    let band = ModSurface.select(press, value: "v", site: .band)
    XCTAssertEqual(band["component"] as? String, "AbovePrompt")
    XCTAssertEqual(band["instance_id"] as? String, "above-prompt")
    XCTAssertNil(ModSurface.Press(["plugin": "mod"]))
  }

  private func subviews(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { subviews(of: $0) }
  }

  private func node(
    _ type: String, _ props: [String: Any] = [:], _ children: [ModSurface.Node] = [],
    press: ModSurface.Press? = nil
  ) -> ModSurface.Node {
    .element(type: type, props: props, children: children, press: press)
  }

  /// A hover group lights every box under its scope while any is under the pointer, and a box
  /// drawn `display: "none"` whose hover says `display: "flex"` shows only while it is lit.
  func testAHoverGroupLightsAndReveals() throws {
    let tree = node(
      "Box", ["hover": ["scope": "row", "backgroundColor": "red"]],
      [
        node("Text", [:], [.text("title")]),
        node(
          "Box", ["display": "none", "hover": ["scope": "row", "display": "flex"]],
          [node("Text", [:], [.text("Drop")])]),
      ])
    // Held, as the pane holds its renderer: the hover reports to it.
    let renderer = ModRenderer(pane: "p")
    let view = try XCTUnwrap(renderer.view(for: tree))
    let surface = try XCTUnwrap(
      ([view] + subviews(of: view)).compactMap { $0 as? ModHoverSurface }.first {
        $0.onHover != nil
      })
    let revealed = try XCTUnwrap(subviews(of: view).first { $0.isHidden })
    XCTAssertFalse(surface.isLit)
    // In a window, the surface tracks the pointer.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
    window.contentView?.addSubview(view)
    window.contentView?.layoutSubtreeIfNeeded()
    // The pane follows the pointer and lights the boxes under it.
    let tracker = ModHoverTracker()
    let root = try XCTUnwrap(window.contentView)
    let middle = surface.convert(NSPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil)
    tracker.pointer(at: middle, in: root)
    XCTAssertTrue(surface.isLit)
    XCTAssertFalse(revealed.isHidden, "the row's hover reveals its action")
    tracker.pointer(at: nil, in: root)
    XCTAssertFalse(surface.isLit)
    XCTAssertTrue(revealed.isHidden)
  }

  /// `position: "absolute"` lays a child over its box rather than in the flow, and `flexWrap`
  /// makes a row that wraps.
  func testAbsoluteChildrenFloatAndRowsCanWrap() throws {
    let tree = node(
      "Box", ["flexDirection": "column"],
      [
        node("Text", [:], [.text("in the flow")]),
        node(
          "Box", ["position": "absolute", "top": 1, "left": 2], [node("Text", [:], [.text("over")])]
        ),
      ])
    let view = try XCTUnwrap(ModRenderer(pane: "p").view(for: tree))
    view.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
    view.layoutSubtreeIfNeeded()
    let metrics = ModRenderer.Metrics.standard
    let over = try XCTUnwrap(
      subviews(of: view).first { ($0 as? NSTextField)?.stringValue == "over" }?.superview)
    XCTAssertEqual(over.frame.minX, 2 * metrics.ch, accuracy: 0.5, "laid over, two cells in")
    XCTAssertEqual(over.frame.minY, metrics.lh, accuracy: 0.5, "and a line down")
    XCTAssertEqual(
      view.intrinsicContentSize.height, metrics.lh, "and the floating box is not in the flow")

    let row = node(
      "Box", ["flexDirection": "row", "flexWrap": "wrap", "columnGap": 1],
      (0..<5).map { node("Text", [:], [.text("item \($0)")]) })
    let wrapped = try XCTUnwrap(ModRenderer(pane: "p").view(for: row))
    wrapped.frame = NSRect(x: 0, y: 0, width: 120, height: 100)
    wrapped.layoutSubtreeIfNeeded()
    let items = subviews(of: wrapped).compactMap { $0 as? NSTextField }
    XCTAssertEqual(items.count, 5)
    XCTAssertGreaterThan(Set(items.map(\.frame.minY)).count, 1, "the row broke onto new lines")
    XCTAssertLessThanOrEqual(items.map(\.frame.maxX).max() ?? 0, 120, "inside its width")
  }

  /// A growing column takes a row's spare room, even beside a box that keeps a spacer of its own
  /// — the row of a queue, whose title had stayed its text's width while the room went past the
  /// revealed button beside it — and a truncating title truncates rather than wraps.
  func testAGrowingColumnTakesTheRoom() throws {
    let tree = node(
      "Box", ["flexDirection": "row", "columnGap": 1],
      [
        node(
          "Box", ["flexDirection": "column", "flexGrow": 1],
          [node("Text", ["wrap": "truncate-end"], [.text("title")])]),
        node("Box", [:], [node("Button", ["label": "Drop", "plain": true])]),
      ])
    let view = try XCTUnwrap(ModRenderer(pane: "p").view(for: tree))
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      view.topAnchor.constraint(equalTo: container.topAnchor),
    ])
    container.layoutSubtreeIfNeeded()
    let title = try XCTUnwrap(
      subviews(of: view).compactMap { $0 as? NSTextField }.first { $0.stringValue == "title" })
    let drop = try XCTUnwrap(subviews(of: view).first { $0 is NSButton })
    let dropRight = drop.convert(drop.bounds, to: view).maxX
    XCTAssertGreaterThan(title.frame.width, 250, "the title took the room")
    XCTAssertGreaterThan(dropRight, 380, "and the button sits at the row's end")
    let paragraph =
      title.attributedStringValue.attribute(
        .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    XCTAssertEqual(paragraph?.lineBreakMode ?? title.lineBreakMode, .byTruncatingTail)
  }

  /// Scrolling and the keyboard on the wire: the person's moves as requests, a plugin's as
  /// pushes — only this client's — and whose drawing a box is, read from beside its props.
  func testScrollAndFocusTravelBothWays() throws {
    let site = ModSurface.Site.pane("queue")
    let element = ModSurface.Element(plugin: "gallery", key: "drop-1")
    let scroll = ModSurface.scroll(
      site: site, offset: 3, by: 2, bodyRows: 10, contentRows: 40,
      keyed: [ModSurface.Placed(element: element, top: 5, bottom: 7)])
    XCTAssertEqual(scroll["component"] as? String, "Pane")
    XCTAssertEqual(scroll["instance_id"] as? String, "queue")
    XCTAssertEqual(scroll["offset"] as? Int, 3)
    XCTAssertEqual(scroll["by"] as? Int, 2)
    XCTAssertEqual(scroll["body_rows"] as? Int, 10)
    XCTAssertEqual(scroll["content_rows"] as? Int, 40)
    let keyed = try XCTUnwrap(scroll["keyed"] as? [[String: Any]])
    XCTAssertEqual(keyed.first?["key"] as? String, "drop-1")
    XCTAssertEqual(keyed.first?["top"] as? Int, 5)

    let focus = ModSurface.focus(site: site, isHeld: true, element: element, by: "auto")
    XCTAssertEqual(focus["is_held"] as? Bool, true)
    XCTAssertEqual((focus["element"] as? [String: Any])?["key"] as? String, "drop-1")
    XCTAssertEqual(focus["by"] as? String, "auto")
    XCTAssertTrue(ModSurface.focus(site: site, isHeld: false, element: nil)["element"] is NSNull)
    XCTAssertTrue(ModSurface.paneFocus(nil)["id"] is NSNull)
    XCTAssertEqual(ModSurface.paneFocus("queue")["id"] as? String, "queue")

    let pushed = try XCTUnwrap(
      ModSurface.ScrollMove([
        "client_id": "hukan", "component": "Pane", "instance_id": "queue", "offset": 12,
        "follow_end": true,
      ]))
    XCTAssertEqual(pushed.site, site)
    XCTAssertEqual(pushed.offset, 12)
    XCTAssertTrue(pushed.followsEnd)
    XCTAssertNil(
      ModSurface.ScrollMove([
        "client_id": "vscode", "component": "Pane", "instance_id": "queue", "offset": 1,
      ]), "another client's window is not this one")
    let ring = try XCTUnwrap(
      ModSurface.FocusMove([
        "client_id": "hukan", "component": "Pane", "instance_id": "queue", "plugin": "gallery",
        "key": "drop-1",
      ]))
    XCTAssertEqual(ring.element, element)
    XCTAssertEqual(
      ModSurface.focusedElement(["element": ["plugin": "gallery", "key": "drop-1"]]), element)

    let roster = try XCTUnwrap(
      ModSurface.Roster([
        "panes": [["id": "queue", "title": "Queue", "plugin": "gallery", "close_on_escape": true]],
        "focused_id": "queue",
      ]))
    XCTAssertEqual(roster.focusedID, "queue")
    XCTAssertTrue(roster.panes[0].closesOnEscape)

    let tree = try XCTUnwrap(
      ModSurface.tree([
        "tree": [
          "type": "Box", "part": ["plugin": "gallery"], "props": ["key": "root"],
          "children": [],
        ]
      ]))
    guard case .element(_, let props, _, _) = tree else { return XCTFail("not an element") }
    XCTAssertEqual(props[ModSurface.pluginProp] as? String, "gallery")
  }

  /// Tab walks a pane's controls in the tree's order and comes round; each keyed control and box
  /// is named by its plugin and key; Escape hands the keyboard back; and a plugin's scroll moves
  /// the window.
  func testAPaneWalksItsControlsAndTakesScrolls() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace()
    let worktree = workspace.addWorktree(root)
    let session = deskSession(in: worktree, of: workspace)
    let pane = ModPaneViewController(
      session: session,
      pane: ModSurface.Pane(id: "queue", title: "Queue", plugin: "gallery"))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = pane.view
    let press = { (handle: Int) in ModSurface.Press(["plugin": "gallery", "handle": handle]) }
    let rows = (0..<30).map { node("Text", [:], [.text("line \($0)")]) }
    let tree = node(
      "Box", ["flexDirection": "column", ModSurface.pluginProp: "gallery"],
      [
        node("Button", ["key": "first", "label": "First"], press: press(1)),
        node("Box", ["key": "row"], [node("Input", ["key": "name"], press: press(2))]),
        node("Button", ["key": "last", "label": "Last", "autoFocus": true], press: press(3)),
      ] + rows)
    pane.draw(tree)

    let first = try XCTUnwrap(pane.view.nextKeyView)
    let second = try XCTUnwrap(first.nextKeyView)
    let third = try XCTUnwrap(second.nextKeyView)
    XCTAssertTrue(first is ModButton)
    XCTAssertTrue(second is ModInputField)
    XCTAssertTrue(third is ModButton)
    XCTAssertTrue(third.nextKeyView === first, "Tab comes round to the first control")

    pane.takeKeyboard()
    XCTAssertTrue(window.firstResponder === third, "the autoFocus control takes the ring")
    XCTAssertTrue(pane.holdsKeyboard)
    XCTAssertEqual(pane.ring, ModSurface.Element(plugin: "gallery", key: "last"))
    window.makeFirstResponder(first)
    XCTAssertEqual(pane.ring, ModSurface.Element(plugin: "gallery", key: "first"))

    // A plugin's ring move lands on the control it names.
    pane.take(
      try XCTUnwrap(
        ModSurface.FocusMove([
          "client_id": "hukan", "component": "Pane", "instance_id": "queue", "plugin": "gallery",
          "key": "last",
        ])))
    XCTAssertTrue(window.firstResponder === third)

    // A redraw puts the ring back on the control drawn under the same key.
    pane.draw(tree)
    XCTAssertEqual(
      (window.firstResponder as? ModButton)?.title, "Last", "the ring survives a redraw")

    var released = false
    pane.onReleaseKeyboard = { released = true }
    let escape = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    // The controls are the redrawn ones now.
    let ringed = try XCTUnwrap(window.firstResponder as? ModButton)
    ringed.keyDown(with: escape)
    XCTAssertTrue(released, "Escape from a button travels up to the pane")
    released = false
    let field = try XCTUnwrap(pane.view.nextKeyView?.nextKeyView as? ModInputField)
    let editor = NSTextView()
    _ = field.control(
      field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    XCTAssertTrue(released, "and from a field, where the text view would complete")

    let scroll = try XCTUnwrap(pane.view.subviews.compactMap { $0 as? NSScrollView }.first)
    pane.take(
      try XCTUnwrap(
        ModSurface.ScrollMove([
          "client_id": "hukan", "component": "Pane", "instance_id": "queue", "offset": 10,
        ])))
    XCTAssertEqual(
      scroll.contentView.bounds.minY, ModRenderer.inset + 10 * ModRenderer.Metrics.standard.lh,
      accuracy: 1)
    pane.take(
      try XCTUnwrap(
        ModSurface.ScrollMove([
          "client_id": "hukan", "component": "Pane", "instance_id": "queue", "offset": 0,
          "follow_end": true,
        ])))
    let document = try XCTUnwrap(scroll.documentView)
    XCTAssertEqual(
      scroll.contentView.bounds.maxY, document.frame.height, accuracy: 1, "kept to the end")
  }

  /// The band is as tall as its tree up to its rows and scrolls past them; its controls are
  /// walked and its keyboard handed back as a pane's are, and a plugin's moves land on it.
  func testTheBandScrollsAndTakesTheKeyboard() throws {
    let site = ModSiteView(session: nil, site: .band, inset: 0, maxRows: ModSurface.bandRows)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
    let holder = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
    window.contentView = holder
    site.translatesAutoresizingMaskIntoConstraints = false
    holder.addSubview(site)
    NSLayoutConstraint.activate([
      site.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
      site.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
      site.topAnchor.constraint(equalTo: holder.topAnchor),
    ])
    let press = { (handle: Int) in ModSurface.Press(["plugin": "band", "handle": handle]) }
    let short = node(
      "Box", ["flexDirection": "row", ModSurface.pluginProp: "band"],
      [
        node("Button", ["key": "one", "label": "One", "hotkey": "1"], press: press(1)),
        node("Button", ["key": "two", "label": "Two"], press: press(2)),
      ])
    site.draw(short)
    holder.layoutSubtreeIfNeeded()
    let lineHeight = ModRenderer.Metrics.standard.lh
    XCTAssertLessThan(site.frame.height, lineHeight * 3, "a short band is as tall as its tree")

    let tall = node(
      "Box", ["flexDirection": "column", ModSurface.pluginProp: "band"],
      (0..<30).map { node("Text", [:], [.text("line \($0)")]) })
    site.draw(tall)
    holder.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      site.frame.height, CGFloat(ModSurface.bandRows) * lineHeight, accuracy: 1,
      "a tall one stops at its rows")
    site.take(
      try XCTUnwrap(
        ModSurface.ScrollMove([
          "client_id": "hukan", "component": "AbovePrompt", "instance_id": "above-prompt",
          "offset": 0, "follow_end": true,
        ])))
    XCTAssertEqual(site.siteLayout()?.offset, 30 - ModSurface.bandRows, "and scrolls to its end")

    site.draw(short)
    holder.layoutSubtreeIfNeeded()
    let first = try XCTUnwrap(site.nextKeyView as? ModButton)
    XCTAssertTrue(first.nextKeyView?.nextKeyView === first, "Tab comes round")
    var released = false
    site.onEscape = { released = true }
    site.takeKeyboard()
    XCTAssertTrue(site.holdsKeyboard)
    window.makeFirstResponder(first)
    XCTAssertEqual(site.ring, ModSurface.Element(plugin: "band", key: "one"))
    let escape = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    first.keyDown(with: escape)
    XCTAssertTrue(released, "Escape hands the keyboard back")
  }

  /// A hotkey presses only a button the person can see; a picture keeps the size it names in
  /// points inside a box; and a field a submit cleared stays cleared across the redraw.
  func testHotkeysPicturesAndSubmittedFields() throws {
    let press = { (handle: Int) in ModSurface.Press(["plugin": "p", "handle": handle]) }
    let renderer = ModRenderer(pane: "p")
    var pressed: [Int] = []
    renderer.onPress = { press, _ in pressed.append(press.handle) }
    let tree = node(
      "Box", ["flexDirection": "column"],
      [
        node("Button", ["key": "shown", "label": "Done", "hotkey": "d"], press: press(2)),
        node(
          "Box",
          ["display": "none", "hover": ["scope": "row", "display": "flex"] as [String: Any]],
          [node("Button", ["key": "hidden", "label": "Drop", "hotkey": "d"], press: press(1))]),
        node(
          "Svg",
          [
            "source": "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'/>",
            "width": 40, "height": 30,
          ]),
      ])
    let view = try XCTUnwrap(renderer.view(for: tree))
    XCTAssertTrue(renderer.pressHotkey("d"))
    XCTAssertEqual(pressed, [2], "the hidden button's key does not fire it")
    renderer.lightEveryHover()
    pressed = []
    XCTAssertTrue(renderer.pressHotkey("d"))
    XCTAssertEqual(pressed, [1], "shown, it does — of two on one key, the later")

    let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      view.topAnchor.constraint(equalTo: container.topAnchor),
    ])
    container.layoutSubtreeIfNeeded()
    let picture = try XCTUnwrap(subviews(of: view).compactMap { $0 as? NSImageView }.first)
    XCTAssertEqual(picture.frame.size, NSSize(width: 40, height: 30))

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    let site = ModSiteView(session: nil, site: .pane("p"), inset: 0)
    window.contentView = site
    let field = { (value: String) in
      self.node(
        "Box", [ModSurface.pluginProp: "p"],
        [self.node("Input", ["key": "note", "value": value], press: press(3))])
    }
    site.draw(field(""))
    let input = try XCTUnwrap(site.renderer?.focusables.first as? ModInputField)
    window.makeFirstResponder(input)
    input.currentEditor()?.string = "hello"
    input.stringValue = "hello"
    // A submit the mod answers by clearing the field: the redraw shows it cleared.
    input.onSubmit?("hello")
    site.draw(field(""))
    let redrawn = try XCTUnwrap(site.renderer?.focusables.first as? ModInputField)
    XCTAssertEqual(redrawn.stringValue, "", "the mod's answer stands after a submit")
    // A redraw mid-typing keeps what is typed, the engine's tree being a step behind.
    window.makeFirstResponder(redrawn)
    redrawn.stringValue = "typing"
    site.draw(field(""))
    let again = try XCTUnwrap(site.renderer?.focusables.first as? ModInputField)
    XCTAssertEqual(again.stringValue, "typing")
  }

  /// A tree wider than its site runs past the body's edge rather than widening the column: the
  /// column holds its width at the split view's priorities (250 and up), and controls that keep
  /// their widths — a field's least, a pick's menu — must not outweigh that.
  func testAWideTreeDoesNotWidenItsColumn() throws {
    let column = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    let site = ModSiteView(session: nil, site: .pane("p"), inset: ModRenderer.inset)
    let press = ModSurface.Press(["plugin": "p", "handle": 1])
    site.translatesAutoresizingMaskIntoConstraints = false
    column.addSubview(site)
    let held = site.widthAnchor.constraint(equalToConstant: 200)
    held.priority = .init(rawValue: 250)
    NSLayoutConstraint.activate([
      held,
      site.leadingAnchor.constraint(equalTo: column.leadingAnchor),
      site.topAnchor.constraint(equalTo: column.topAnchor),
      site.heightAnchor.constraint(equalToConstant: 300),
    ])
    site.draw(
      node(
        "Box", ["flexDirection": "row", "columnGap": 2],
        [
          node("Input", ["key": "filter", "label": "Filter"], press: press),
          node(
            "Select",
            [
              "key": "sort", "label": "Sort",
              "options": [["value": "title", "label": "Title"]],
            ],
            press: press),
        ]))
    column.layoutSubtreeIfNeeded()
    XCTAssertEqual(site.frame.width, 200, accuracy: 0.5, "the column kept its width")
  }

  /// A bordered box holding wrapped text is as wide as the body, however the text sits in it — a
  /// wrapping label left to itself measured its width off whatever frame it had last, so the same
  /// tree drew its box at the body's width one time and far off it the next — and the text
  /// wraps at that width, as tall as its lines.
  func testABoxOfWrappedTextIsAsWideAsTheBody() throws {
    let long = String(repeating: "The review found the session waiting on a decision. ", count: 6)
    let border: [String: Any] = ["borderStyle": "round", "flexDirection": "column", "paddingX": 1]
    let text = node("Text", [:], [.text(long)])
    let shapes = [
      node("Box", [:], [node("Box", border, [text])]),
      node("Box", ["flexDirection": "column"], [node("Box", border, [text])]),
      node("Box", ["flexDirection": "column"], [node("Box", ["borderStyle": "round"], [text])]),
      node(
        "Box", ["flexDirection": "column"],
        [
          node(
            "Box", border,
            [node("Box", [:], [node("Text", [:], [.text("●")]), node("Box", border, [text])])])
        ]),
    ]
    for (index, tree) in shapes.enumerated() {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled],
        backing: .buffered, defer: false)
      let content = try XCTUnwrap(window.contentView)
      let site = ModSiteView(session: nil, site: .pane("p"), inset: ModRenderer.inset)
      site.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(site)
      site.pin(to: content)
      site.draw(tree)
      content.layoutSubtreeIfNeeded()
      let boxes = subviews(of: site).filter { $0.layer?.cornerRadius == 12 }
      let outer = try XCTUnwrap(boxes.first)
      XCTAssertEqual(
        outer.frame.width, 500 - ModRenderer.inset * 2, accuracy: 0.5, "shape \(index)")
      let label = try XCTUnwrap(
        subviews(of: site).compactMap { $0 as? NSTextField }.first { $0.stringValue == long })
      XCTAssertLessThanOrEqual(
        label.convert(label.bounds, to: site).maxX, 500, "shape \(index) wraps inside")
      XCTAssertGreaterThan(label.frame.height, 40, "shape \(index) is as tall as its lines")
    }
  }

  /// The outermost box keeps its margin, and what a hover showed stops holding the tree wide
  /// once it is hidden again.
  func testTheRootKeepsItsMarginAndAHiddenBoxLetsGoOfTheWidth() throws {
    func site(_ tree: ModSurface.Node) throws -> (ModSiteView, NSWindow) {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
      let content = try XCTUnwrap(window.contentView)
      let site = ModSiteView(session: nil, site: .pane("p"), inset: ModRenderer.inset)
      site.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(site)
      site.pin(to: content)
      site.draw(tree)
      content.layoutSubtreeIfNeeded()
      return (site, window)
    }
    let metrics = ModRenderer.Metrics.standard
    let (margined, first) = try site(
      node("Box", ["borderStyle": "round", "marginLeft": 2, "marginTop": 1], [.text("in")]))
    let box = try XCTUnwrap(subviews(of: margined).first { $0.layer?.cornerRadius == 12 })
    let origin = box.convert(box.bounds, to: margined).origin
    XCTAssertEqual(origin.x, ModRenderer.inset + 2 * metrics.ch, accuracy: 0.5)
    _ = first

    let wide = node(
      "Box", ["flexDirection": "column"],
      [
        node("Box", ["hover": ["scope": "row"]], [.text("row")]),
        node(
          "Box", ["display": "none", "hover": ["scope": "row", "display": "flex"]],
          (0..<8).map { node("Button", ["label": "a button \($0)"]) }),
      ])
    let (revealing, second) = try site(wide)
    let renderer = try XCTUnwrap(revealing.renderer)
    let root = try XCTUnwrap(subviews(of: revealing).first { $0 is ModFlexView })
    renderer.lightEveryHover()
    second.contentView?.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(root.frame.width, 300, "the buttons do not fit, so the tree is wider")
    let surface = try XCTUnwrap(
      subviews(of: revealing).compactMap { $0 as? ModHoverSurface }.first { $0.onHover != nil })
    surface.onHover?(true)
    surface.onHover?(false)
    second.contentView?.layoutSubtreeIfNeeded()
    XCTAssertLessThanOrEqual(root.frame.width, 300, "and as wide as the body again once hidden")
  }

  /// Spacing is the desktop app's: a gap down is half a line, a named one its token, a bordered
  /// box pads itself where the mod names no padding; a text is cut at its end whichever end it
  /// names; and a box of `overflowX: "scroll"` scrolls under what does not fit.
  func testSpacingTruncationAndSidewaysScrollFollowTheDesktopApp() throws {
    let metrics = ModRenderer.Metrics.standard
    func laid(_ tree: ModSurface.Node, width: CGFloat = 300) throws -> NSView {
      let view = try XCTUnwrap(ModRenderer(pane: "p").view(for: tree))
      view.frame = NSRect(x: 0, y: 0, width: width, height: 400)
      view.layoutSubtreeIfNeeded()
      return view
    }
    func labels(_ view: NSView) -> [NSTextField] {
      subviews(of: view).compactMap { $0 as? NSTextField }
    }
    let halfLines = labels(
      try laid(node("Box", ["flexDirection": "column", "gap": 1], [.text("a"), .text("b")])))
    XCTAssertEqual(halfLines[1].frame.minY - halfLines[0].frame.maxY, metrics.lh / 2, accuracy: 0.5)
    let named = labels(
      try laid(node("Box", ["flexDirection": "column", "rowGap": "md"], [.text("a"), .text("b")])))
    XCTAssertEqual(named[1].frame.minY - named[0].frame.maxY, 16, accuracy: 0.5)
    let padded = labels(try laid(node("Box", ["borderStyle": "single"], [.text("in")])))
    XCTAssertEqual(padded[0].frame.minX, 17, accuracy: 0.5, "16 across and the line")
    let own = labels(
      try laid(node("Box", ["borderStyle": "single", "paddingX": 1], [.text("in")])))
    XCTAssertEqual(own[0].frame.minX, metrics.ch + 1, accuracy: 0.5, "the mod's padding instead")

    let cut = labels(
      try laid(node("Box", [:], [node("Text", ["wrap": "truncate-start"], [.text("words")])])))
    XCTAssertEqual(cut.first?.lineBreakMode, .byTruncatingTail)

    let long = String(repeating: "a line that does not fit ", count: 8)
    let scrolling = try laid(
      node(
        "Box", ["flexDirection": "column"],
        [node("Box", ["overflowX": "scroll"], [node("Text", [:], [.text(long)])])]), width: 200)
    let scroller = try XCTUnwrap(subviews(of: scrolling).compactMap { $0 as? ModScrollBox }.first)
    scroller.layoutSubtreeIfNeeded()
    XCTAssertEqual(scroller.frame.width, 200, accuracy: 0.5, "as wide as it is given")
    XCTAssertGreaterThan(scroller.documentView?.frame.width ?? 0, 400, "its text on one line")
    XCTAssertEqual(scroller.frame.height, metrics.lh, accuracy: 0.5)

    // Its border is the box's, which stays put: the viewport is inside the line and padding.
    let framed = try laid(
      node(
        "Box", ["flexDirection": "column"],
        [
          node(
            "Box", ["overflowX": "scroll", "borderStyle": "single"],
            [node("Text", [:], [.text(long)])])
        ]), width: 200)
    let inside = try XCTUnwrap(subviews(of: framed).compactMap { $0 as? ModScrollBox }.first)
    XCTAssertEqual(inside.superview?.frame.width ?? 0, 200, accuracy: 0.5)
    XCTAssertEqual(inside.frame.minX, 17, accuracy: 0.5)
    XCTAssertEqual(inside.frame.width, 200 - 34, accuracy: 0.5)
  }

  /// Two texts in a row, short of room, shrink in proportion to their lengths, as flexbox has
  /// it: one three times the other's length keeps three times its width.
  func testTextsInARowShrinkInProportion() throws {
    let short = String(repeating: "The review found the session waiting. ", count: 4)
    let long = String(repeating: short, count: 3)
    let tree = node(
      "Box", [:], [node("Text", [:], [.text(short)]), node("Text", [:], [.text(long)])])
    let view = try XCTUnwrap(ModRenderer(pane: "p").view(for: tree))
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.layoutSubtreeIfNeeded()
    let labels = subviews(of: view).compactMap { $0 as? NSTextField }
    XCTAssertEqual(labels.count, 2)
    XCTAssertEqual(labels[0].frame.width + labels[1].frame.width, 600, accuracy: 1)
    XCTAssertEqual(labels[1].frame.width / labels[0].frame.width, 3, accuracy: 0.1)
  }

  /// A band taller than its rows scrolls rather than squeezing its tree into them; a key on the
  /// buttons of two plugins presses neither; and Shift reaches a number but not a letter — the
  /// desktop app's rules.
  func testTheBandScrollsAndKeysFollowTheDesktopApp() throws {
    let site = ModSiteView(session: nil, site: .band, inset: 0, maxRows: 3)
    let holder = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    site.translatesAutoresizingMaskIntoConstraints = false
    holder.addSubview(site)
    NSLayoutConstraint.activate([
      site.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
      site.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
      site.topAnchor.constraint(equalTo: holder.topAnchor),
    ])
    site.draw(
      node(
        "Box", ["flexDirection": "column"],
        (0..<10).map { node("Text", [:], [.text("line \($0)")]) }))
    holder.layoutSubtreeIfNeeded()
    let lineHeight = ModRenderer.Metrics.standard.lh
    XCTAssertEqual(site.frame.height, 3 * lineHeight, accuracy: 1, "the band stops at its rows")
    XCTAssertEqual(site.siteLayout()?.contentRows, 10, "and its tree keeps its own height")

    let renderer = ModRenderer(pane: "p")
    var pressed: [Int] = []
    renderer.onPress = { press, _ in pressed.append(press.handle) }
    _ = renderer.view(
      for: node(
        "Box", [:],
        [
          node(
            "Button", ["key": "a", "label": "A", "hotkey": "x"],
            press: ModSurface.Press(["plugin": "one", "handle": 1])),
          node(
            "Button", ["key": "b", "label": "B", "hotkey": "x"],
            press: ModSurface.Press(["plugin": "two", "handle": 2])),
        ]))
    XCTAssertFalse(renderer.pressHotkey("x"), "two plugins on one key: neither")
    XCTAssertEqual(pressed, [])

    func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
      try XCTUnwrap(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
          context: nil, characters: characters, charactersIgnoringModifiers: characters,
          isARepeat: false, keyCode: 0))
    }
    XCTAssertEqual(ModRenderer.isHotkey(try key("a", [])), "a")
    XCTAssertEqual(ModRenderer.isHotkey(try key("1", .shift)), "1", "Shift reaches a number")
    XCTAssertNil(ModRenderer.isHotkey(try key("A", .shift)), "but a capital is no hotkey")
    XCTAssertNil(ModRenderer.isHotkey(try key("a", .command)))
  }

  /// A site given the keyboard before its first tree — a pane just opened that asked for it —
  /// puts the ring on that tree's `autoFocus` control once it arrives.
  func testAutoFocusWaitsForTheFirstTree() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    let site = ModSiteView(session: nil, site: .pane("p"), inset: 0)
    window.contentView = site
    site.takeKeyboard()
    XCTAssertTrue(window.firstResponder === site, "nothing drawn yet: the site holds it")
    site.draw(
      node(
        "Box", ["flexDirection": "column", ModSurface.pluginProp: "p"],
        [
          node(
            "Button", ["key": "first", "label": "First"],
            press: ModSurface.Press(["plugin": "p", "handle": 1])),
          node(
            "Input", ["key": "name", "autoFocus": true],
            press: ModSurface.Press(["plugin": "p", "handle": 2])),
        ]))
    XCTAssertEqual(site.ring, ModSurface.Element(plugin: "p", key: "name"))
    // A redraw after that leaves the ring where it is, not on autoFocus again.
    window.makeFirstResponder(site.nextKeyView)
    XCTAssertEqual(site.ring, ModSurface.Element(plugin: "p", key: "first"))
    site.draw(
      node(
        "Box", ["flexDirection": "column", ModSurface.pluginProp: "p"],
        [
          node(
            "Button", ["key": "first", "label": "First"],
            press: ModSurface.Press(["plugin": "p", "handle": 3])),
          node(
            "Input", ["key": "name", "autoFocus": true],
            press: ModSurface.Press(["plugin": "p", "handle": 4])),
        ]))
    XCTAssertEqual(site.ring, ModSurface.Element(plugin: "p", key: "first"))
  }

  /// A hover moves a floating box to the offsets it names while its group is lit.
  func testAHoverMovesAFloatingBox() throws {
    let badge = node(
      "Box",
      [
        "position": "absolute", "top": 0, "left": 1,
        "hover": ["scope": "card", "left": 6] as [String: Any],
      ],
      [node("Text", [:], [.text("badge")])])
    let tree = node(
      "Box", ["key": "card", "hover": ["scope": "card"] as [String: Any], "width": 30],
      [node("Text", [:], [.text("card body")]), badge])
    let renderer = ModRenderer(pane: "p")
    let view = try XCTUnwrap(renderer.view(for: tree))
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      view.topAnchor.constraint(equalTo: container.topAnchor),
    ])
    container.layoutSubtreeIfNeeded()
    let label = try XCTUnwrap(
      subviews(of: view).compactMap { $0 as? NSTextField }.first { $0.stringValue == "badge" })
    let before = label.convert(label.bounds, to: view).minX
    renderer.lightEveryHover()
    container.layoutSubtreeIfNeeded()
    let after = label.convert(label.bounds, to: view).minX
    XCTAssertEqual(
      after - before, 5 * ModRenderer.Metrics.standard.ch, accuracy: 1, "moved five columns")
  }

  /// A button's hotkey presses it, and a plain one says its key before its words.
  func testAHotkeyPressesItsButton() throws {
    let press = try XCTUnwrap(ModSurface.Press(["plugin": "mod", "handle": 3]))
    let renderer = ModRenderer(pane: "p")
    var pressed: ModSurface.Press?
    renderer.onPress = { press, _ in pressed = press }
    // A plain button stands on a ground that lights under the pointer.
    let ground = try XCTUnwrap(
      renderer.view(
        for: node("Button", ["label": "Next", "hotkey": "n", "plain": true], press: press))
        as? ModHoverSurface)
    XCTAssertNotNil(ground.onHover)
    let button = try XCTUnwrap(ground.subviews.first as? NSButton)
    // The key cap stands before a plain button's words, an attachment and a space.
    let title = button.attributedTitle
    XCTAssertTrue(title.string.hasSuffix(" Next"), title.string)
    XCTAssertNotNil(title.attribute(.attachment, at: 0, effectiveRange: nil))
    XCTAssertFalse(renderer.pressHotkey("x"))
    XCTAssertTrue(renderer.pressHotkey("N"))
    XCTAssertEqual(pressed, press)
  }

  /// `dimColor` reaches the drawn label as a fainter colour than plain text.
  func testDimTextIsDrawnFainter() throws {
    let node = ModSurface.Node.element(
      type: "Text", props: ["dimColor": true], children: [.text("queued")], press: nil)
    let field = try XCTUnwrap(ModRenderer(pane: "p").view(for: node) as? NSTextField)
    let color = try XCTUnwrap(
      field.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil)
        as? NSColor)
    XCTAssertEqual(color, .secondaryLabelColor)
  }

  func testColoursAreReadAsAModNamesThem() {
    let renderer = ModRenderer(pane: "p")
    XCTAssertEqual(renderer.color("success"), .systemGreen)
    XCTAssertEqual(renderer.color("ansi:redBright"), .systemRed)
    XCTAssertEqual(renderer.color("blackBright"), .systemGray)
    XCTAssertNotNil(renderer.color("#0a0"))
    XCTAssertNotNil(renderer.color("rgb(1, 2, 3)"))
    XCTAssertNil(renderer.color("chartreuse-ish"))
  }

  func testAPressInTheDrawnTreeReachesItsHandle() throws {
    let tree = try XCTUnwrap(ModSurface.tree(try showcase()))
    let renderer = ModRenderer(pane: "showcase")
    var pressed: ModSurface.Press?
    renderer.onPress = { press, _ in pressed = press }
    let view = try XCTUnwrap(renderer.view(for: tree))
    func buttons(_ view: NSView) -> [NSButton] {
      (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    let press = try XCTUnwrap(buttons(view).first { $0.title == "Press" })
    press.performClick(nil)
    XCTAssertEqual(pressed?.plugin, "showcase")
  }

  /// A pane is a tab on its session's desk — a desk holding nothing else included — and a close
  /// the engine does not carry out (refused, or no engine to ask) puts the tab back.
  func testAPaneIsATabAndARefusedCloseBringsItBack() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace()
    let worktree = workspace.addWorktree(root)
    let session = deskSession(in: worktree, of: workspace)
    let desk = WorktreeDeskViewController()
    desk.workspace = workspace
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = desk.view
    desk.reload(deskID: session.id)
    session.onModPanesChange = { [weak desk, weak session] in
      guard let desk, let session else { return }
      desk.syncModPanes(for: session)
    }
    var roster = try XCTUnwrap(
      ModSurface.Roster(["panes": [["id": "ledger", "title": "Ledger", "plugin": "ledger"]]]))
    roster.shownID = "ledger"
    session.setModRoster(roster)
    XCTAssertEqual(desk.tabCount, 1)
    XCTAssertTrue(desk.tabStripReport.contains("Ledger"), desk.tabStripReport)

    desk.closeTab(at: 0)
    let deadline = Date().addingTimeInterval(5)
    while desk.tabCount == 0, Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    XCTAssertEqual(desk.tabCount, 1, "the pane is still open, so its tab came back")

    session.setModRoster(ModSurface.Roster())
    XCTAssertEqual(desk.tabCount, 0)
  }

  /// The band above the prompt: asked for under the id every surface gives it, with the props a
  /// band reads, and its tree — captured from the engine — drawn with its `plain` button bare.
  func testTheBandIsAskedForAndDrawn() throws {
    let request = ModSurface.renderBand(columns: 90, isWorking: true)
    XCTAssertEqual(request["component"] as? String, "AbovePrompt")
    XCTAssertEqual(request["instance_id"] as? String, "above-prompt")
    let props = request["props"] as? [String: Any]
    XCTAssertEqual(props?["isWorking"] as? Bool, true)
    XCTAssertEqual(props?["maxRows"] as? Int, ModSurface.bandRows)
    XCTAssertEqual(props?["bodyColumns"] as? Int, 90)

    let url = Self.fixture.deletingLastPathComponent().appendingPathComponent("mod-band.json")
    let reply = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let tree = try XCTUnwrap(ModSurface.tree(reply))
    XCTAssertTrue(ModRenderer.outline(tree).contains("[+1]"))
    let view = try XCTUnwrap(ModRenderer(pane: ModSurface.bandInstance).view(for: tree))
    func buttons(_ view: NSView) -> [NSButton] {
      (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    XCTAssertEqual(buttons(view).first { $0.title == "+1" }?.isBordered, false)
  }

  /// `Code` is coloured by the grammar its language or path names, as a patch for a diff, and
  /// numbered from `startLine`.
  func testCodeIsHighlightedAndNumbered() throws {
    XCTAssertEqual(ModRenderer.highlightPath(["language": "typescript"]), "code.ts")
    XCTAssertEqual(ModRenderer.highlightPath(["path": "a/b.swift"]), "a/b.swift")
    XCTAssertEqual(ModRenderer.highlightPath(["format": "diff", "language": "swift"]), "code.diff")
    XCTAssertNil(ModRenderer.highlightPath([:]))
    let node = ModSurface.Node.element(
      type: "Code", props: ["source": "let a = 1\nlet b = 2", "language": "swift", "startLine": 9],
      children: [], press: nil)
    let view = try XCTUnwrap(ModRenderer(pane: "p").view(for: node))
    func fields(_ view: NSView) -> [NSTextField] {
      (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    let text = try XCTUnwrap(fields(view).first).attributedStringValue
    XCTAssertEqual(text.string, " 9  let a = 1\n10  let b = 2")
    let keyword = text.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
    XCTAssertNotEqual(keyword, .labelColor, "the keyword is not coloured")
  }

  func testPreviewMod() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["HUKAN_PREVIEW"] == "mod", "no preview asked for")
    var reply = try showcase()
    if let path = ProcessInfo.processInfo.environment["HUKAN_PREVIEW_TREE"] {
      reply = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
          as? [String: Any])
    }
    let tree = try XCTUnwrap(ModSurface.tree(reply))
    // `TEST_RUNNER_HUKAN_PREVIEW_APPEARANCE=light` draws it in the light appearance.
    let light = ProcessInfo.processInfo.environment["HUKAN_PREVIEW_APPEARANCE"] == "light"
    let appearance = NSAppearance(named: light ? .aqua : .darkAqua)!
    NSApplication.shared.appearance = appearance
    // `TEST_RUNNER_HUKAN_PREVIEW_WIDTH` draws the pane that wide, to see what a narrow desk does.
    let width = CGFloat(
      Double(ProcessInfo.processInfo.environment["HUKAN_PREVIEW_WIDTH"] ?? "") ?? 620)
    let container = ModFlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 1400))
    container.wantsLayer = true
    container.appearance = appearance
    // `TEST_RUNNER_HUKAN_PREVIEW_HOVER=1` draws every hover lit, as under the pointer.
    let renderer = ModRenderer(pane: "showcase")
    let view = try XCTUnwrap(renderer.view(for: tree))
    if ProcessInfo.processInfo.environment["HUKAN_PREVIEW_HOVER"] == "1" {
      renderer.lightEveryHover()
    }
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
      view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
      view.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
    ])
    let window = SnapshotSurface.window(contentRect: container.frame, appearance: appearance)
    window.contentView = container
    container.layoutSubtreeIfNeeded()
    container.layoutSubtreeIfNeeded()
    let height = view.frame.height + 28
    window.setContentSize(NSSize(width: width, height: height))
    appearance.performAsCurrentDrawingAppearance {
      container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    container.layoutSubtreeIfNeeded()
    let bounds = container.bounds
    let png = SnapshotSurface.png(size: bounds.size, appearance: appearance) { context in
      container.displayIgnoringOpacity(bounds, in: context)
    }
    try png.write(to: URL(fileURLWithPath: "/tmp/hukan-preview-mod.png"))
  }
}
