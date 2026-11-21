import AppKit

/// One mod pane as a desk tab: the tree the engine hands back for it (`ModSurface`), drawn in a
/// `ModSiteView`, and asked for when the tab is shown, when the engine says something in it
/// changed (`ui_invalidate`), after each press, and when the tab's width changes by a column — the
/// width being what the mod sizes its tree by.
final class ModPaneViewController: NSViewController {
  private(set) var pane: ModSurface.Pane
  private weak var session: AgentSession?
  /// An address a link was pressed on: the window opens it on the desk.
  var onOpenURL: ((URL) -> Void)?
  /// Escape: the window puts the keyboard in the composer.
  var onReleaseKeyboard: (() -> Void)?

  private var site: ModSiteView { view as! ModSiteView }
  private var lastViewport: ModSurface.Viewport?
  private var isRendering = false
  private var needsRender = false
  /// The last tree, as the `tabs` verb reads it — one line a part.
  private(set) var outline = ""

  var holdsKeyboard: Bool { isViewLoaded && site.holdsKeyboard }
  var ring: ModSurface.Element? { isViewLoaded ? site.ring : nil }

  /// Where the pane stands, for the `tabs` verb: a pane that shows nothing says why.
  var stateDescription: String {
    if isRendering { return "drawing" }
    if !isViewLoaded || view.window == nil { return "off screen" }
    if lastViewport == nil { return "not drawn yet" }
    if outline.isEmpty {
      return session?.isModSurfaceAttached == true ? "nothing drawn" : "engine not attached"
    }
    return "drawn"
  }

  init(session: AgentSession, pane: ModSurface.Pane) {
    self.session = session
    self.pane = pane
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  func update(_ pane: ModSurface.Pane) { self.pane = pane }

  override func loadView() {
    let site = ModSiteView(session: session, site: .pane(pane.id), inset: ModRenderer.inset)
    site.onWindow = { [weak self] in self?.setNeedsRender() }
    site.renderRequest = { [weak self] in self?.renderRequest() ?? [:] }
    site.onTook = { [weak self] tree in
      guard let self else { return }
      if let tree { self.draw(tree) } else { self.setNeedsRender() }
    }
    site.onHoldChange = { [weak self] held in
      guard let self else { return }
      self.session?.focusModPane(held ? self.pane.id : nil)
      // `isFocused` is a prop the tree is drawn with.
      self.setNeedsRender()
    }
    site.onEscape = { [weak self] in self?.leave() }
    site.onOpenURL = { [weak self] url in self?.onOpenURL?(url) }
    view = site
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    if viewport() != lastViewport { setNeedsRender() }
  }

  /// The room the tab has, in the cells the mod counts in.
  private func viewport() -> ModSurface.Viewport {
    let metrics = ModRenderer.Metrics.standard
    let body = site.bodySize
    let width = max(body.width - ModRenderer.inset * 2, metrics.ch)
    let height = max(body.height - ModRenderer.inset * 2, metrics.lh)
    return ModSurface.Viewport(
      columns: max(Int(width / metrics.ch), 10), rows: max(Int(height / metrics.lh), 4))
  }

  /// Ask for the tree again, once for any number of asks landing together — and only while the
  /// tab is on screen; one off screen is drawn when it is next shown.
  func setNeedsRender() {
    guard isViewLoaded, view.window != nil, !needsRender else { return }
    needsRender = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.needsRender = false
      self.render()
    }
  }

  private func render() {
    guard let session else { return }
    if isRendering {
      needsRender = true
      return
    }
    isRendering = true
    let viewport = viewport()
    lastViewport = viewport
    session.modViewport = viewport
    session.renderModPane(
      pane, viewport: viewport, isFocused: site.holdsKeyboard, layout: site.siteLayout()
    ) { [weak self] tree in
      guard let self else { return }
      self.isRendering = false
      self.draw(tree)
      // Asked again while this one was out: once more, a beat later, and only if the tab is
      // still on screen — a hook that invalidates as it draws is redrawn at a pace, not in a loop.
      if self.needsRender {
        self.needsRender = false
        DispatchQueue.main.asyncAfter(deadline: .now() + ModSurface.redrawInterval) {
          [weak self] in self?.setNeedsRender()
        }
      }
    }
  }

  /// The render an action here brings back with its answer: this pane, at the size it is.
  private func renderRequest() -> [String: Any] {
    ModSurface.render(
      pane: pane, viewport: lastViewport ?? viewport(), isFocused: site.holdsKeyboard,
      layout: site.siteLayout())
  }

  /// Internal so a test can hand the pane a tree without an engine.
  func draw(_ tree: ModSurface.Node?) {
    outline = tree.map(ModRenderer.outline) ?? ""
    site.draw(
      tree,
      empty: session?.isModSurfaceAttached == true
        ? "Nothing to show." : "The session's engine is not running.")
  }

  /// A mod asked for the keyboard and may have it.
  func takeKeyboard() { site.takeKeyboard() }

  func take(_ move: ModSurface.FocusMove) { site.take(move) }
  func take(_ move: ModSurface.ScrollMove) { site.take(move) }

  /// Escape: the keyboard goes back to the composer, and a pane opened with `closeOnEscape` closes.
  private func leave() {
    if pane.closesOnEscape { session?.closeModPane(pane.id) }
    onReleaseKeyboard?()
  }
}

/// A site a mod draws in — a pane's body or the band above the prompt — as a scrolling view of the
/// tree drawn with `ModRenderer`, and everything the person does in it that the engine is told:
/// presses, typing and picks; where the window is scrolled (`ui_scroll`); and where the keyboard
/// is (`ui_focus`). It takes the moves a plugin makes too — `$.ui.scroll`, `$.ui.focus`.
///
/// It is also what holds the keyboard for the site: a click on its background takes it, as a click
/// in a terminal pane does; Tab walks its controls, a plain key goes to the button whose `hotkey`
/// it is, and Escape gives the keyboard back.
final class ModSiteView: NSView {
  private weak var session: AgentSession?
  let site: ModSurface.Site
  /// The room around the tree, inside the scrolling body.
  private let inset: CGFloat

  /// The render an action in the site brings back with its answer.
  var renderRequest: () -> [String: Any] = { [:] }
  /// The tree an action brought back, or nil when it brought none and the site must ask.
  var onTook: (ModSurface.Node?) -> Void = { _ in }
  /// The keyboard entered the site or left it.
  var onHoldChange: (Bool) -> Void = { _ in }
  var onEscape: () -> Void = {}
  var onOpenURL: (URL) -> Void = { _ in }
  /// The site landed in a window.
  var onWindow: () -> Void = {}

  private let scroll = NSScrollView()
  private let document = ModFlippedView()
  private var content: NSView?
  private(set) var renderer: ModRenderer?
  /// The tallest the body grows before it scrolls, for a site sized to its tree (the band); nil
  /// for one that fills what it is given (a pane).
  private var heightLimit: NSLayoutConstraint?

  /// Which hover boxes the pointer is on, and where it last was — a redraw lands new boxes under
  /// a pointer that has not moved, and they are lit from where it stands.
  private let hover = ModHoverTracker()
  private var lastPointer: NSPoint?
  private var tracking: NSTrackingArea?

  /// Whether the keyboard is in the site, and which control holds the ring — as last told the
  /// engine.
  private(set) var holdsKeyboard = false
  private(set) var ring: ModSurface.Element?
  private var responderObservation: NSKeyValueObservation?
  /// Set while the site moves the keyboard itself — a redraw putting the ring back, a plugin's
  /// move — so the move is not reported as the person's.
  private var isMovingKeyboard = false
  /// Who the next move is reported as: `auto` when an `autoFocus` control takes the ring.
  private var nextMoveBy = "person"
  /// What a field last submitted: a redraw finding the field still holding just that lets the
  /// mod's answer stand rather than the typed text.
  private var submittedText: String?

  /// The first row the window shows, as last told the engine or taken from it, and whether the
  /// window keeps to the end as the content grows (a plugin's `$.ui.scroll` to the end).
  private var reportedOffset = 0
  private var followsEnd = false
  private var isScrollingForEngine = false
  private var isScrollReportPending = false

  /// `maxRows` makes a site that is as tall as its tree up to that many rows, and scrolls past
  /// them; without it the site fills the room it is given.
  init(session: AgentSession?, site: ModSurface.Site, inset: CGFloat, maxRows: Int? = nil) {
    self.session = session
    self.site = site
    self.inset = inset
    super.init(frame: .zero)
    // The scroll view covers the site, so a click on its background lands on the document; it is
    // what hands the site the keyboard.
    document.onMouseDown = { [weak self] in self?.window?.makeFirstResponder(self) }
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = document
    // The person's scrolls are told the engine, which a mod reads as `ui.scroll`.
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(clipMoved), name: NSView.boundsDidChangeNotification,
      object: scroll.contentView)
    document.translatesAutoresizingMaskIntoConstraints = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scroll)
    scroll.pin(to: self)
    // The tree is as wide as the body, but only by a wish weaker than the window's columns hold
    // their widths by (250 and up): a tree that cannot be that narrow — a line of text keeps its
    // length at 750 — runs past the body's edge, scrolling sideways, rather than pushing the
    // column it sits in wider the moment its tab is shown.
    let fill = document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
    fill.priority = .init(rawValue: 240)
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      document.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
      fill,
      document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
    ])
    scroll.hasHorizontalScroller = true
    if let maxRows {
      // As tall as the tree, by a wish weaker than its lines hold their heights (750): at the
      // limit the body stops and the tree scrolls, rather than the tree being squeezed into it.
      let fit = scroll.heightAnchor.constraint(equalTo: document.heightAnchor)
      fit.priority = .init(rawValue: 700)
      fit.isActive = true
      let limit = scroll.heightAnchor.constraint(
        lessThanOrEqualToConstant: CGFloat(maxRows) * lineHeight + inset * 2)
      limit.isActive = true
      heightLimit = limit
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { NotificationCenter.default.removeObserver(self) }

  /// The size of the scrolling body: what a pane measures its viewport by.
  var bodySize: NSSize { scroll.contentView.bounds.size }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateTrackingAreas()
    guard let window else { return }
    responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.responderChanged() }
    }
    onWindow()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    // Always active: hover is a look, wanted on a window that is not the key one too.
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseMoved(with event: NSEvent) { pointer(at: event.locationInWindow) }
  override func mouseEntered(with event: NSEvent) { pointer(at: event.locationInWindow) }
  override func mouseExited(with event: NSEvent) { pointer(at: nil) }

  private func pointer(at point: NSPoint?) {
    lastPointer = point
    hover.pointer(at: point, in: self)
  }

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    super.mouseDown(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { return leaveModPane(nil) }
    guard let key = ModRenderer.isHotkey(event), renderer?.pressHotkey(key) == true
    else { return super.keyDown(with: event) }
  }

  override func cancelOperation(_ sender: Any?) { leaveModPane(sender) }

  // MARK: Drawing

  /// Draw a tree, or `empty` in its place when there is none.
  func draw(_ tree: ModSurface.Node?, empty: String? = nil) {
    // A field being typed into keeps its text, caret and focus across the redraw: the engine's
    // tree is a step behind the keyboard.
    let editing = renderer?.focusedField(in: window)
    let renderer = ModRenderer(pane: site.instance)
    renderer.onPress = { [weak self] press, href in
      guard let self else { return }
      self.session?.pressMod(press, href: href, render: self.renderRequest()) { tree in
        self.onTook(tree)
      }
    }
    renderer.onInput = { [weak self] press, value, submit in
      guard let self else { return }
      if submit { self.submittedText = value }
      // A keystroke is only told; the submit brings the tree back like a press.
      self.session?.inputMod(
        press, value: value, submit: submit, site: self.site,
        render: submit ? self.renderRequest() : nil
      ) { tree in if submit { self.onTook(tree) } }
    }
    renderer.onSelect = { [weak self] press, value in
      guard let self else { return }
      self.session?.selectMod(
        press, value: value, site: self.site, render: self.renderRequest()
      ) { tree in self.onTook(tree) }
    }
    renderer.onOpenURL = { [weak self] url in self?.onOpenURL(url) }
    let drawn: NSView
    if let tree, let view = renderer.view(for: tree) {
      drawn = view
    } else {
      let label = NSTextField(labelWithString: empty ?? "")
      label.textColor = .secondaryLabelColor
      drawn = label
    }
    self.renderer = renderer
    // The boxes the pointer was on are gone; the new ones under it light as the old did.
    hover.reset()
    // Taking the old controls out drops the keyboard from them; that is not the person's move.
    isMovingKeyboard = true
    defer {
      isMovingKeyboard = false
      responderChanged()
    }
    content?.removeFromSuperview()
    drawn.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(drawn)
    NSLayoutConstraint.activate([
      drawn.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: inset),
      drawn.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -inset),
      drawn.topAnchor.constraint(equalTo: document.topAnchor, constant: inset),
      drawn.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -inset),
    ])
    // A root that stretches (a column Box, as most are) takes the site's width.
    let fill = drawn.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -inset * 2)
    fill.priority = .init(rawValue: 490)
    fill.isActive = true
    content = drawn
    // The new tree is laid out and shown now: a redraw a press or a timer asked for lands outside
    // any layout pass, and the scroll view's document would otherwise keep the old frame — and
    // the old picture — until something resized it.
    document.needsLayout = true
    needsLayout = true
    layoutSubtreeIfNeeded()
    document.needsDisplay = true
    linkKeyViews()
    if holdsKeyboard {
      // The ring goes back to the control drawn under the same key, else to the site itself —
      // or, for a site that took the keyboard before it had a tree, to its `autoFocus` control.
      if awaitsAutoFocus, ring == nil, let auto = renderer.autoFocus {
        nextMoveBy = "auto"
        window?.makeFirstResponder(auto)
      } else {
        let target = ring.flatMap { renderer.control(for: $0) } ?? self
        window?.makeFirstResponder(target)
      }
    }
    // One tree is the first: after it, the ring is where the person or the mod puts it.
    if tree != nil { awaitsAutoFocus = false }
    if let editing {
      renderer.restore(editing, in: window, keepingDrawnText: editing.text == submittedText)
    }
    submittedText = nil
    if let lastPointer { hover.pointer(at: lastPointer, in: self) }
    if followsEnd { showEnd() }
  }

  // MARK: Keyboard

  /// Tab walks the site's controls in the tree's order and comes round again, as in every other
  /// host: the site's view first, then each control.
  private func linkKeyViews() {
    let controls = renderer?.focusables.filter(\.canBecomeKeyView) ?? []
    nextKeyView = controls.first
    for (index, control) in controls.enumerated() {
      control.nextKeyView = controls[(index + 1) % controls.count]
    }
  }

  /// The site's view or control the keyboard is in, a field's editor read as its field; nil when
  /// it is elsewhere.
  private func responderInSite() -> NSView? {
    guard let responder = window?.firstResponder else { return nil }
    var candidate = responder as? NSView
    if let editor = responder as? NSTextView, editor.isFieldEditor,
      let field = editor.delegate as? NSView
    {
      candidate = field
    }
    guard let candidate, candidate.isDescendant(of: self) else { return nil }
    return candidate
  }

  private func responderChanged() {
    guard !isMovingKeyboard else { return }
    let inside = responderInSite()
    report(held: inside != nil, element: inside.flatMap { renderer?.element(of: $0) })
  }

  /// Tell the engine where the keyboard is, when that changed: the ring in the site (`ui_focus`),
  /// which a hook may redirect, and to the owner whether the site took it or let it go.
  private func report(held: Bool, element: ModSurface.Element?) {
    guard held != holdsKeyboard || element != ring else { return }
    let changedHold = held != holdsKeyboard
    holdsKeyboard = held
    ring = held ? element : nil
    let by = nextMoveBy
    nextMoveBy = "person"
    if changedHold { onHoldChange(held) }
    if !held { awaitsAutoFocus = false }
    // The person moving on before the answer came supersedes it: only the answer to the latest
    // move is followed, and only when a hook put the ring somewhere other than it was sent.
    focusMoves += 1
    let move = focusMoves
    let sent = ring
    session?.focusMod(site: site, isHeld: held, element: sent, by: by) { [weak self] held in
      guard let self, move == self.focusMoves, self.holdsKeyboard, let held, held != sent,
        let control = self.renderer?.control(for: held)
      else { return }
      self.move(to: control, element: held)
    }
  }

  /// Counts the ring's moves, the person's and a plugin's: what tells a stale answer apart.
  private var focusMoves = 0

  /// Put the ring on a control without reporting it: a plugin's move, or a hook's redirect.
  private func move(to control: NSView, element: ModSurface.Element) {
    focusMoves += 1
    isMovingKeyboard = true
    window?.makeFirstResponder(control)
    isMovingKeyboard = false
    ring = element
  }

  /// The site takes the keyboard, on its `autoFocus` control when it drew one.
  func takeKeyboard() {
    guard let window else { return }
    // Held already — taken before the engine could be told, say — and told again, since no
    // responder change will tell it.
    if holdsKeyboard {
      onHoldChange(true)
      session?.focusMod(site: site, isHeld: true, element: ring)
      return
    }
    if let auto = renderer?.autoFocus {
      nextMoveBy = "auto"
      window.makeFirstResponder(auto)
    } else {
      // Not drawn yet, as a pane that has just opened is not: the site holds the keyboard, and
      // its `autoFocus` control takes the ring when the tree arrives.
      awaitsAutoFocus = true
      window.makeFirstResponder(self)
    }
  }

  /// The site took the keyboard before it had a tree: the first tree's `autoFocus` control takes
  /// the ring, unless the person has moved it since.
  private var awaitsAutoFocus = false

  /// A plugin moved the ring (`$.ui.focus`): onto that control, if the site still draws it and
  /// holds the keyboard.
  func take(_ move: ModSurface.FocusMove) {
    guard holdsKeyboard, let control = renderer?.control(for: move.element) else { return }
    self.move(to: control, element: move.element)
  }

  // MARK: Scrolling

  private var lineHeight: CGFloat { ModRenderer.Metrics.standard.lh }

  /// The first content row the window shows, counted from the tree's top.
  private var currentOffset: Int {
    max(0, Int(((scroll.contentView.bounds.minY - inset) / lineHeight).rounded()))
  }

  @objc private func clipMoved() {
    guard !isScrollingForEngine, !isMovingKeyboard, !isScrollReportPending else { return }
    isScrollReportPending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + ModSurface.redrawInterval) { [weak self] in
      guard let self else { return }
      self.isScrollReportPending = false
      self.reportScroll()
    }
  }

  /// Tell the engine where the person left the window: once it has settled, with the layout as
  /// drawn and where each keyed element sits, which a mod's `$.ui.scroll({ to: { key } })` needs.
  private func reportScroll() {
    guard let session, let content else { return }
    let offset = currentOffset
    guard offset != reportedOffset else { return }
    let by = offset - reportedOffset
    reportedOffset = offset
    followsEnd = false
    let request = ModSurface.scroll(
      site: site, offset: offset, by: by,
      bodyRows: Int(scroll.contentView.bounds.height / lineHeight),
      contentRows: Int((content.frame.height / lineHeight).rounded(.up)), keyed: placed())
    session.scrollMod(request) { [weak self] held, follows in
      guard let self, let held else { return }
      self.followsEnd = follows
      if follows {
        self.showEnd()
      } else if held != offset {
        // A hook denied the move or rewrote it: the window goes where the engine holds it.
        self.show(row: held)
      }
    }
  }

  /// Where the keyed boxes and controls of the drawn tree sit, in rows from its top.
  private func placed() -> [ModSurface.Placed] {
    (renderer?.keyed ?? []).compactMap { entry -> ModSurface.Placed? in
      guard entry.view.isDescendant(of: document), !entry.view.isHiddenOrHasHiddenAncestor
      else { return nil }
      let frame = entry.view.convert(entry.view.bounds, to: document)
      return ModSurface.Placed(
        element: entry.element,
        top: max(0, Int(((frame.minY - inset) / lineHeight).rounded(.down))),
        bottom: max(0, Int(((frame.maxY - inset) / lineHeight).rounded(.up))))
    }
  }

  /// The window and the last tree's layout, which a render carries; nil before anything drew.
  func siteLayout() -> ModSurface.Layout? {
    guard let content, renderer != nil else { return nil }
    return ModSurface.Layout(
      offset: currentOffset, contentRows: Int((content.frame.height / lineHeight).rounded(.up)),
      keyed: placed())
  }

  /// A plugin moved the window (`$.ui.scroll`).
  func take(_ move: ModSurface.ScrollMove) {
    followsEnd = move.followsEnd
    if followsEnd { showEnd() } else { show(row: move.offset) }
  }

  private func show(row: Int) {
    let limit = max(0, document.frame.height - scroll.contentView.bounds.height)
    let y = row == 0 ? 0 : min(inset + CGFloat(row) * lineHeight, limit)
    set(clipY: y)
  }

  private func showEnd() {
    layoutSubtreeIfNeeded()
    set(clipY: max(0, document.frame.height - scroll.contentView.bounds.height))
  }

  private func set(clipY y: CGFloat) {
    isScrollingForEngine = true
    // Only the window's row moves: a tree scrolled sideways stays where the person left it.
    scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
    isScrollingForEngine = false
    reportedOffset = currentOffset
  }
}

extension ModSiteView: ModKeyboard {
  @objc func leaveModPane(_ sender: Any?) { onEscape() }
}

final class ModFlippedView: NSView {
  /// A click on the background, where no control took it: the pane takes the keyboard then.
  var onMouseDown: (() -> Void)?

  override var isFlipped: Bool { true }

  override func mouseDown(with event: NSEvent) {
    onMouseDown?()
    super.mouseDown(with: event)
  }
}

/// A mod's tree as AppKit views, following the VS Code extension's reading of each element (the
/// one surface whose drawing ships where it can be read): a `Box` is a flexbox whose lengths count
/// in cells — a column a character's width, a row a line's height — a `Text` a run of styled
/// text, and the rest a standard control each. `Client`, a module the surface would have to run,
/// is not drawn, as VS Code does not draw it: hukan runs no code of a mod's.
final class ModRenderer {
  struct Metrics {
    let font: NSFont
    let ch: CGFloat
    let lh: CGFloat

    /// The desktop app's body text, 14 on a 20 line — the surface hukan attaches as, read off its
    /// design tokens — so a mod sized for that app reads the same here. A row is a line of that.
    static let standard: Metrics = {
      let font = NSFont.systemFont(ofSize: 14)
      let ch = ("0" as NSString).size(withAttributes: [.font: font]).width
      return Metrics(font: font, ch: ch, lh: 20)
    }()

    /// A `Text`'s `size`, on the desktop app's scale: point size and line height.
    static func scale(_ size: String?) -> (points: CGFloat, line: CGFloat) {
      switch size {
      case "caption": return (12, 17)
      case "footnote": return (13, 17)
      case "heading": return (15, 20)
      case "title": return (22, 28)
      default: return (14, 20)
      }
    }
  }

  static let inset: CGFloat = 14

  let pane: String
  let metrics = Metrics.standard
  var onPress: (ModSurface.Press, String?) -> Void = { _, _ in }
  var onInput: (ModSurface.Press, String, Bool) -> Void = { _, _, _ in }
  var onSelect: (ModSurface.Press, String) -> Void = { _, _ in }
  var onOpenURL: (URL) -> Void = { _ in }

  private var actions: [ObjectIdentifier: () -> Void] = [:]
  private var fields: [String: ModInputField] = [:]
  private let target = ModActionTarget()

  /// Hover groups (`hover.scope`): how many of a group's boxes the pointer is on, and what each
  /// member does as the group lights and goes out. A group lights while any member is hovered,
  /// so a pointer moving from a row onto the button it revealed keeps the row lit.
  private var hoverCounts: [String: Int] = [:]
  /// The hover groups of the boxes being built around the element being built, innermost last.
  private var hoverScopes: [String] = []
  private var hoverMembers: [String: [(Bool) -> Void]] = [:]
  /// A button's `hotkey`: one character, pressed while the pane has the keyboard.
  private var hotkeys: [String: [(control: NSControl, plugin: String, press: () -> Void)]] = [:]

  /// The controls Tab walks, in the tree's order, and the plugin and key each was drawn under —
  /// how a focus move names it to the engine and back.
  private(set) var focusables: [NSView] = []
  private var elements: [ObjectIdentifier: ModSurface.Element] = [:]
  /// The control drawn with `autoFocus`, which takes the ring when the pane takes the keyboard.
  private(set) var autoFocus: NSView?
  /// Keyed boxes and controls, whose places a scroll report carries.
  private(set) var keyed: [(element: ModSurface.Element, view: NSView)] = []
  /// The plugin whose drawing is being built: the nearest box that named one, or a control's.
  private var plugin: String?

  func element(of view: NSView) -> ModSurface.Element? { elements[ObjectIdentifier(view)] }

  func control(for element: ModSurface.Element) -> NSView? {
    focusables.first { elements[ObjectIdentifier($0)] == element }
  }

  /// A control Tab reaches; with a `key`, one the engine can name.
  private func register(_ control: NSView, _ props: [String: Any], _ press: ModSurface.Press?) {
    focusables.append(control)
    if props["autoFocus"] as? Bool == true, autoFocus == nil { autoFocus = control }
    guard let key = props["key"] as? String, let plugin = press?.plugin ?? plugin else { return }
    let element = ModSurface.Element(plugin: plugin, key: key)
    elements[ObjectIdentifier(control)] = element
    keyed.append((element, control))
  }

  private func join(_ scope: String, _ apply: @escaping (Bool) -> Void) {
    hoverMembers[scope, default: []].append(apply)
  }

  private func hovered(_ scope: String, _ inside: Bool) {
    let before = hoverCounts[scope] ?? 0
    let after = max(0, before + (inside ? 1 : -1))
    hoverCounts[scope] = after
    guard (before == 0) != (after == 0) else { return }
    for member in hoverMembers[scope] ?? [] { member(after > 0) }
  }

  /// Light every hover group at once — how a preview draws what the pointer would show.
  func lightEveryHover() {
    for members in hoverMembers.values { for member in members { member(true) } }
  }

  /// Press the button whose hotkey `key` is; whether there was one.
  func pressHotkey(_ key: String) -> Bool {
    guard let match = hotkey(key) else { return false }
    match.press()
    return true
  }

  /// The button a key presses, as the desktop app picks it: only one the person can see — a
  /// button in a box a hover reveals is not there to press until it is shown — of two on one key
  /// the later, and none when the key is on buttons of two plugins, neither having more right to
  /// it than the other.
  func hotkey(_ key: String) -> (control: NSControl, press: () -> Void)? {
    let shown = (hotkeys[key.lowercased()] ?? []).filter {
      $0.control.isEnabled && !$0.control.isHiddenOrHasHiddenAncestor
    }
    guard Set(shown.map(\.plugin)).count == 1, let last = shown.last else { return nil }
    return (last.control, last.press)
  }

  /// Whether a key, with the modifiers it came with, may be a hotkey: no Command, Control or
  /// Option, and Shift only on a number — a layout where numbers need Shift still reaches them,
  /// and a capital letter is not its small one. The desktop app's reading.
  static func isHotkey(_ event: NSEvent) -> String? {
    guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
      let key = event.charactersIgnoringModifiers, key.count == 1, let character = key.first,
      character.isASCII, character.isLetter || character.isNumber
    else { return nil }
    if event.modifierFlags.contains(.shift), !character.isNumber { return nil }
    return key.lowercased()
  }

  init(pane: String) {
    self.pane = pane
    target.renderer = self
  }

  func view(for node: ModSurface.Node) -> NSView? {
    switch node {
    case .text(let text):
      return text.isEmpty ? nil : label(NSAttributedString(string: text, attributes: base()), [:])
    case .element(let type, let props, let children, let press):
      let outer = plugin
      if let named = props[ModSurface.pluginProp] as? String { plugin = named }
      defer { plugin = outer }
      let view = element(type, props, children, press)
      if type == "Box" || type == "div", let key = props["key"] as? String, let plugin, let view {
        keyed.append((ModSurface.Element(plugin: plugin, key: key), view))
      }
      return view
    }
  }

  private func element(
    _ type: String, _ props: [String: Any], _ children: [ModSurface.Node],
    _ press: ModSurface.Press?
  ) -> NSView? {
    switch type {
    case "Box", "div": return box(props, children)
    case "Text", "span", "b":
      var props = props
      if type == "b" { props["bold"] = true }
      let field = label(attributed(children, style(props)), props)
      // A text's hover restyles it while its group is lit: its own scope, or the box with a
      // hover it sits in.
      if let hover = props["hover"] as? [String: Any],
        let scope = hover["scope"] as? String ?? hoverScopes.last
      {
        let plain = field.attributedStringValue
        var lit = props
        for (key, value) in hover where key != "scope" { lit[key] = value }
        let litText = attributed(children, style(lit))
        join(scope) { [weak field] isLit in
          field?.attributedStringValue = isLit ? litText : plain
        }
      }
      return field
    case "Link": return link(props, children)
    case "Button": return button(props, children, press)
    case "Input": return input(props, press)
    case "Select": return select(props, press)
    case "Markdown": return markdown(props)
    case "Code": return code(props)
    case "Progress": return progress(props)
    case "Svg": return svg(props)
    case "Client":
      let note = NSTextField(labelWithString: "A part drawn by code hukan does not run.")
      note.textColor = .tertiaryLabelColor
      note.font = .systemFont(ofSize: 11)
      return note
    default:
      return box(["flexDirection": "column"], children)
    }
  }

  // MARK: Box

  private func cells(_ value: Any?, unit: CGFloat) -> CGFloat? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    let n = CGFloat(truncating: number)
    return n >= 0 && n <= 10000 ? n * unit : nil
  }

  private func percent(_ value: Any?) -> CGFloat? {
    guard let text = value as? String, text.hasSuffix("%"), let n = Double(text.dropLast()),
      n.isFinite, n >= 0, n <= 100
    else { return nil }
    return CGFloat(n / 100)
  }

  /// The first of `keys` that is set, in cells of `unit`: `paddingLeft`, then `paddingX`, then
  /// `padding`, the way Ink reads them.
  private func side(_ props: [String: Any], _ keys: [String], unit: CGFloat) -> CGFloat {
    for key in keys { if let value = cells(props[key], unit: unit) { return value } }
    return 0
  }

  private func box(_ props: [String: Any], _ children: [ModSurface.Node]) -> NSView? {
    let hover = props["hover"] as? [String: Any]
    // Drawn `display: "none"` is drawn not at all — unless its hover says `display: "flex"`, which
    // is a reveal: drawn hidden, shown while its hover group is lit.
    let revealed =
      props["display"] as? String == "none" && hover?["display"] as? String == "flex"
      && hover?["scope"] is String
    if props["display"] as? String == "none", !revealed { return nil }
    let direction = props["flexDirection"] as? String ?? "row"
    let isRow = direction.hasPrefix("row")
    // A box with a hover is a group for what it holds: a `Text` inside with a hover of its own and
    // no scope lights with this box, as the desktop app reads it.
    let ownScope = hover.map { $0["scope"] as? String ?? "box-\(UUID().uuidString)" }
    if let ownScope { hoverScopes.append(ownScope) }
    var all: [(view: NSView, props: [String: Any], type: String)] = children.compactMap {
      child in
      guard let view = view(for: child) else { return nil }
      if case .element(let type, let props, _, _) = child { return (view, props, type) }
      return (view, [:], "text")
    }
    if ownScope != nil { hoverScopes.removeLast() }
    if direction.hasSuffix("reverse") { all.reverse() }
    // An absolutely positioned child leaves the flow and is laid over the box, as CSS does it.
    let floating = all.filter { $0.props["position"] as? String == "absolute" }
    let items = all.filter { $0.props["position"] as? String != "absolute" }

    if isRow, props["flexWrap"] as? String == "wrap" {
      return wrapped(
        props, items.map(\.view), floating: floating, hover: hover, scope: ownScope,
        revealed: revealed)
    }

    let stack = NSStackView()
    stack.orientation = isRow ? .horizontal : .vertical
    stack.distribution = .fill
    let gap =
      isRow
      ? cells(props["columnGap"], unit: metrics.ch) ?? cells(props["gap"], unit: metrics.ch)
      : cells(props["rowGap"], unit: metrics.lh) ?? cells(props["gap"], unit: metrics.lh)
    stack.spacing = gap ?? 0
    let insets = NSEdgeInsets(
      top: side(props, ["paddingTop", "paddingY", "padding"], unit: metrics.lh),
      left: side(props, ["paddingLeft", "paddingX", "padding"], unit: metrics.ch),
      bottom: side(props, ["paddingBottom", "paddingY", "padding"], unit: metrics.lh),
      right: side(props, ["paddingRight", "paddingX", "padding"], unit: metrics.ch))
    let bordered = props["borderStyle"] is String
    // A border sits inside the box, and the text a cell in from it, as a terminal draws one.
    stack.edgeInsets = NSEdgeInsets(
      top: insets.top + (bordered ? 4 : 0), left: insets.left + (bordered ? metrics.ch : 0),
      bottom: insets.bottom + (bordered ? 4 : 0), right: insets.right + (bordered ? metrics.ch : 0))
    let align = props["alignItems"] as? String ?? "stretch"
    // A row that names no `alignItems` centres its leaves — text, buttons, links, fields — on its
    // height and stretches only the boxes in it: the desktop app's rule, which is what puts a
    // status dot and a row's button on the middle of a two-line title.
    let centresLeaves = isRow && props["alignItems"] == nil
    switch (isRow, align) {
    case (true, "center"): stack.alignment = .centerY
    case (true, "flex-end"): stack.alignment = .bottom
    case (true, _): stack.alignment = centresLeaves ? .centerY : .top
    case (false, "center"): stack.alignment = .centerX
    case (false, "flex-end"): stack.alignment = .trailing
    case (false, _): stack.alignment = .leading
    }

    let justify = props["justifyContent"] as? String ?? "flex-start"
    let grows = items.contains { ($0.props["flexGrow"] as? NSNumber)?.doubleValue ?? 0 > 0 }
    var spacers: [NSView] = []
    func spacer() -> NSView {
      let view = NSView()
      view.translatesAutoresizingMaskIntoConstraints = false
      // Weaker than anything but a child that grows: spare room goes to a `flexGrow` child
      // anywhere in the row before it goes to a spacer inside a box beside it.
      view.setContentHuggingPriority(.init(rawValue: 2), for: isRow ? .horizontal : .vertical)
      view.setContentCompressionResistancePriority(
        .init(rawValue: 1), for: isRow ? .horizontal : .vertical)
      // A spacer has no size of its own, so hugging alone does not hold it: without this it was
      // free to take a row's spare room from inside a box beside the child that grows.
      let none =
        isRow
        ? view.widthAnchor.constraint(equalToConstant: 0)
        : view.heightAnchor.constraint(equalToConstant: 0)
      none.priority = .init(rawValue: 1)
      none.isActive = true
      spacers.append(view)
      return view
    }
    var arranged: [NSView] = []
    let main = items.map(\.view)
    switch grows ? "flex-start-grow" : justify {
    case "flex-end": arranged = [spacer()] + main
    case "center": arranged = [spacer()] + main + [spacer()]
    case "space-between":
      for (index, view) in main.enumerated() {
        if index > 0 { arranged.append(spacer()) }
        arranged.append(view)
      }
    case "space-around", "space-evenly":
      arranged.append(spacer())
      for view in main { arranged += [view, spacer()] }
    case "flex-start-grow": arranged = main
    default: arranged = main + (isRow ? [spacer()] : [])
    }
    for view in arranged { stack.addArrangedSubview(view) }
    for pair in spacers.dropFirst() {
      let a = isRow ? pair.widthAnchor : pair.heightAnchor
      let b = isRow ? spacers[0].widthAnchor : spacers[0].heightAnchor
      a.constraint(equalTo: b).isActive = true
    }

    for (view, childProps, type) in items {
      let grow = (childProps["flexGrow"] as? NSNumber)?.doubleValue ?? 0
      let shrinkable = (childProps["flexShrink"] as? NSNumber)?.doubleValue ?? 1
      // A child that grows takes the room; its siblings hold to their own size, firmly — a
      // wrapping label's own hugging is weak enough to win the room otherwise.
      view.setContentHuggingPriority(
        grow > 0 ? .init(rawValue: 1) : grows ? .defaultHigh : .init(rawValue: 250),
        for: isRow ? .horizontal : .vertical)
      // Hugging on the child alone cannot hand it the room: a box is a stack that hugs its own
      // content, and a column holds each line it stretches to its own width, so a label's
      // hugging bound the column to its text. A growing box lets go of all that, and reaches for
      // the room, more weakly than anything else holds its own size.
      if grow > 0 {
        Self.letGo(view, isRow ? .horizontal : .vertical)
        let reach =
          isRow
          ? view.widthAnchor.constraint(equalToConstant: 100_000)
          : view.heightAnchor.constraint(equalToConstant: 100_000)
        reach.priority = .init(rawValue: 5)
        reach.isActive = true
      }
      if shrinkable == 0 {
        view.setContentCompressionResistancePriority(
          .required, for: isRow ? .horizontal : .vertical)
      }
      // A column stretches its children across, which is Ink's default and most trees' intent —
      // but a control keeps its own width, as it does in a terminal: a button across the pane is
      // a bar, not a button.
      if centresLeaves, type == "Box" || type == "div", childProps["height"] == nil {
        view.heightAnchor.constraint(
          equalTo: stack.heightAnchor, constant: -(stack.edgeInsets.top + stack.edgeInsets.bottom)
        ).isActive = true
      }
      let keepsOwnWidth = ["Button", "Select", "Link", "Svg"].contains(type)
      if !isRow, align == "stretch", childProps["width"] == nil, !keepsOwnWidth {
        view.widthAnchor.constraint(
          equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)
        ).isActive = true
      }
      // A picture's numbers are points, which it sizes itself by; read here as cells they would
      // fight its own.
      if type == "Svg" { continue }
      if let width = cells(childProps["width"], unit: metrics.ch) {
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
      } else if let fraction = percent(childProps["width"]) {
        // A share of the content box, inside the padding, as CSS reads it.
        let insets = stack.edgeInsets.left + stack.edgeInsets.right
        view.widthAnchor.constraint(
          equalTo: stack.widthAnchor, multiplier: fraction, constant: -insets * fraction
        ).isActive = true
      }
      if let height = cells(childProps["height"], unit: metrics.lh) {
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
      }
      if let width = cells(childProps["minWidth"], unit: metrics.ch) {
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true
      }
      if let height = cells(childProps["minHeight"], unit: metrics.lh) {
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
      }
    }

    return finish(
      props, stack, floating: floating, hover: hover, scope: ownScope, revealed: revealed)
  }

  /// Drops the hugging that ties a growing box to its content along `axis`: its own stack's, and
  /// that of each line a stack across the axis stretches to its width — a label, a nested box —
  /// down through boxes stacked that way. A stack along the axis lays its own children out, and
  /// is let go of without being entered.
  static func letGo(_ view: NSView, _ axis: NSLayoutConstraint.Orientation) {
    let weak = NSLayoutConstraint.Priority(rawValue: 2)
    if let stack = view as? NSStackView {
      stack.setHuggingPriority(weak, for: axis)
      let across: NSUserInterfaceLayoutOrientation = axis == .horizontal ? .vertical : .horizontal
      if stack.orientation == across {
        for child in stack.arrangedSubviews { letGo(child, axis) }
      }
    } else if let field = view as? NSTextField {
      field.setContentHuggingPriority(weak, for: axis)
    } else if view is ModHoverSurface || type(of: view) == NSView.self {
      for child in view.subviews { letGo(child, axis) }
    }
  }

  /// A row of `flexWrap: "wrap"`: its children at their own sizes, left to right, onto a new line
  /// when the width runs out. Justification and growth have no meaning across lines here.
  private func wrapped(
    _ props: [String: Any], _ views: [NSView],
    floating: [(view: NSView, props: [String: Any], type: String)],
    hover: [String: Any]?, scope: String?, revealed: Bool
  ) -> NSView {
    let flow = ModFlowView(
      views,
      spacing: NSSize(
        width: cells(props["columnGap"], unit: metrics.ch)
          ?? cells(props["gap"], unit: metrics.ch) ?? 0,
        height: cells(props["rowGap"], unit: metrics.lh)
          ?? cells(props["gap"], unit: metrics.lh) ?? 0))
    let insets = NSEdgeInsets(
      top: side(props, ["paddingTop", "paddingY", "padding"], unit: metrics.lh),
      left: side(props, ["paddingLeft", "paddingX", "padding"], unit: metrics.ch),
      bottom: side(props, ["paddingBottom", "paddingY", "padding"], unit: metrics.lh),
      right: side(props, ["paddingRight", "paddingX", "padding"], unit: metrics.ch))
    let padded = NSView()
    flow.translatesAutoresizingMaskIntoConstraints = false
    padded.addSubview(flow)
    flow.pin(to: padded, insets: insets)
    return finish(props, padded, floating: floating, hover: hover, scope: scope, revealed: revealed)
  }

  /// What every box gets around its children: its border and background, what it lays over
  /// itself (`position: "absolute"`), its hover, and its margin.
  private func finish(
    _ props: [String: Any], _ content: NSView,
    floating: [(view: NSView, props: [String: Any], type: String)],
    hover: [String: Any]?, scope ownScope: String?, revealed: Bool
  ) -> NSView {
    let bordered = props["borderStyle"] is String
    let background = color(props["backgroundColor"])
    var outer: NSView = content
    // A box with a hover gets a surface even with nothing to paint yet: the hover may paint it,
    // and the surface is what tracks the pointer.
    if bordered || background != nil || props["overflow"] as? String == "hidden" || hover != nil
      || !floating.isEmpty
    {
      let frame = ModHoverSurface()
      frame.wantsLayer = true
      frame.layer?.cornerRadius = props["borderStyle"] as? String == "round" ? 6 : 0
      frame.layer?.cornerCurve = .continuous
      frame.layer?.masksToBounds = props["overflow"] as? String == "hidden"
      let border =
        (color(props["borderColor"]) ?? .separatorColor).withAlphaComponent(
          props["borderDimColor"] as? Bool == true ? 0.5 : 1)
      let litBackground = color(hover?["backgroundColor"])
      let litBorder = color(hover?["borderColor"])
      let litBordered = hover?["borderStyle"] is String
      frame.paintLayer = { [weak frame] layer in
        let lit = frame?.isLit ?? false
        layer.borderWidth = bordered || (lit && litBordered) ? 1 : 0
        layer.borderColor = ((lit ? litBorder : nil) ?? border).cgColor
        layer.backgroundColor = ((lit ? litBackground : nil) ?? background)?.cgColor
      }
      content.translatesAutoresizingMaskIntoConstraints = false
      frame.addSubview(content)
      content.pin(to: frame)
      for (view, childProps, _) in floating {
        view.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(view)
        let placed = place(view, in: frame, childProps)
        NSLayoutConstraint.activate(placed)
        // A hover may move a floating box — the one kind it may move, since nothing in the flow
        // shifts for it — to the offsets it names while its group is lit.
        let sides = ["top", "left", "right", "bottom"]
        guard let hover = childProps["hover"] as? [String: Any],
          let scope = hover["scope"] as? String, sides.contains(where: { hover[$0] != nil })
        else { continue }
        var moved = childProps
        for side in sides where hover[side] != nil { moved[side] = hover[side] }
        let lit = place(view, in: frame, moved)
        join(scope) { isLit in
          NSLayoutConstraint.deactivate(isLit ? placed : lit)
          NSLayoutConstraint.activate(isLit ? lit : placed)
        }
      }
      if hover != nil, let scope = ownScope {
        // Its own group when it names none: a box lights while the pointer is on it.
        frame.onHover = { [weak self] inside in self?.hovered(scope, inside) }
        join(scope) { [weak frame] lit in
          frame?.isLit = lit
          frame?.needsDisplay = true
        }
      }
      outer = frame
    }
    if revealed, let scope = hover?["scope"] as? String {
      outer.isHidden = true
      join(scope) { [weak outer] lit in outer?.isHidden = !lit }
    }
    let margin = NSEdgeInsets(
      top: side(props, ["marginTop", "marginY", "margin"], unit: metrics.lh),
      left: side(props, ["marginLeft", "marginX", "margin"], unit: metrics.ch),
      bottom: side(props, ["marginBottom", "marginY", "margin"], unit: metrics.lh),
      right: side(props, ["marginRight", "marginX", "margin"], unit: metrics.ch))
    if margin.top + margin.left + margin.bottom + margin.right > 0 {
      let wrapper = NSView()
      outer.translatesAutoresizingMaskIntoConstraints = false
      wrapper.addSubview(outer)
      outer.pin(to: wrapper, insets: margin)
      outer = wrapper
    }
    return outer
  }

  /// A floating box's place over its box: `top` or else `bottom`, `left` or else `right`, in cells.
  private func place(_ view: NSView, in frame: NSView, _ props: [String: Any])
    -> [NSLayoutConstraint]
  {
    let top = cells(props["top"], unit: metrics.lh)
    let left = cells(props["left"], unit: metrics.ch)
    let right = cells(props["right"], unit: metrics.ch)
    let bottom = cells(props["bottom"], unit: metrics.lh)
    let vertical =
      top == nil && bottom != nil
      ? view.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -(bottom ?? 0))
      : view.topAnchor.constraint(equalTo: frame.topAnchor, constant: top ?? 0)
    let horizontal =
      left == nil && right != nil
      ? view.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -(right ?? 0))
      : view.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: left ?? 0)
    return [vertical, horizontal]
  }

  // MARK: Text

  private func base() -> [NSAttributedString.Key: Any] {
    Self.lined(
      [.font: metrics.font, .foregroundColor: NSColor.labelColor], line: metrics.lh)
  }

  /// Text on the desktop app's line: every line `line` points tall, the glyphs centred in it —
  /// AppKit's own leading for 14 points is two and a half short of the app's 20.
  static func lined(
    _ attributes: [NSAttributedString.Key: Any], line: CGFloat
  ) -> [NSAttributedString.Key: Any] {
    var attributes = attributes
    let font = attributes[.font] as? NSFont ?? Metrics.standard.font
    let paragraph =
      (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
      ?? NSMutableParagraphStyle()
    paragraph.minimumLineHeight = line
    paragraph.maximumLineHeight = line
    attributes[.paragraphStyle] = paragraph
    // The spare height goes above the glyphs; half of it back under them centres the line.
    attributes[.baselineOffset] = (line - (font.ascender - font.descender)) / 4
    return attributes
  }

  /// A `Text`'s own style as attributes over `inherited` — a nested `Text` restyles its span.
  private func style(
    _ props: [String: Any], over inherited: [NSAttributedString.Key: Any]? = nil
  ) -> [NSAttributedString.Key: Any] {
    var attributes = inherited ?? base()
    var font = attributes[.font] as? NSFont ?? metrics.font
    // Typography: a size on the desktop app's scale, a weight, the monospaced face, and digits of
    // one width — each only when asked, so a nested span keeps what it inherits.
    let size = props["size"] as? String
    let points = size.map { Metrics.scale($0).points } ?? font.pointSize
    let weight: NSFont.Weight? =
      switch props["weight"] as? String ?? (props["bold"] as? Bool == true ? "bold" : nil) {
      case "regular": .regular
      case "medium": .medium
      case "semibold": .semibold
      case "bold": .bold
      default: nil
      }
    let isMono =
      props["mono"] as? Bool == true
      || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
    if isMono {
      font = .monospacedSystemFont(ofSize: points, weight: weight ?? .regular)
    } else if size != nil || weight != nil {
      font = .systemFont(ofSize: points, weight: weight ?? .regular)
    }
    if props["tabular"] as? Bool == true {
      font =
        NSFont(
          descriptor: font.fontDescriptor.addingAttributes([
            .featureSettings: [
              [
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
              ]
            ]
          ]), size: font.pointSize) ?? font
    }
    if props["italic"] as? Bool == true {
      font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }
    attributes[.font] = font
    if let size { attributes = Self.lined(attributes, line: Metrics.scale(size).line) }
    var foreground = color(props["color"]) ?? attributes[.foregroundColor] as? NSColor
    var background = color(props["backgroundColor"])
    if props["inverse"] as? Bool == true {
      let swapped = foreground
      foreground = background ?? .windowBackgroundColor
      background = swapped ?? .labelColor
    }
    if props["dimColor"] as? Bool == true {
      // Plain text dims to the system's secondary colour — an alpha laid over `labelColor` is
      // drawn at full strength by a label — and a coloured run fades to two thirds of itself.
      if foreground == nil || foreground == .labelColor {
        foreground = .secondaryLabelColor
      } else {
        foreground = foreground?.withAlphaComponent(0.65)
      }
    }
    attributes[.foregroundColor] = foreground
    if let background { attributes[.backgroundColor] = background }
    if props["underline"] as? Bool == true {
      attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
    }
    if props["strikethrough"] as? Bool == true {
      attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }
    return attributes
  }

  private func attributed(
    _ children: [ModSurface.Node], _ attributes: [NSAttributedString.Key: Any]
  ) -> NSAttributedString {
    let text = NSMutableAttributedString()
    for child in children {
      switch child {
      case .text(let string):
        text.append(NSAttributedString(string: string, attributes: attributes))
      case .element(_, let props, let grandchildren, _):
        text.append(attributed(grandchildren, style(props, over: attributes)))
      }
    }
    return text
  }

  private func label(_ text: NSAttributedString, _ props: [String: Any]) -> NSTextField {
    let wrap = props["wrap"] as? String ?? "wrap"
    let field: NSTextField
    if wrap == "wrap" {
      field = NSTextField(wrappingLabelWithString: "")
      if let lines = (props["maxLines"] as? NSNumber)?.intValue, lines > 0 {
        field.maximumNumberOfLines = lines
        field.lineBreakMode = .byTruncatingTail
      }
    } else {
      field = NSTextField(labelWithString: "")
      field.lineBreakMode =
        switch wrap {
        case "truncate-start": .byTruncatingHead
        case "truncate-middle": .byTruncatingMiddle
        case "clip": .byClipping
        default: .byTruncatingTail
        }
      field.setContentCompressionResistancePriority(.init(rawValue: 200), for: .horizontal)
    }
    // Selectable first, the styled string last: making a label selectable afterwards has it
    // redraw from its own text colour, which flattens a dim or coloured run back to plain.
    field.isSelectable = true
    field.allowsEditingTextAttributes = true
    // The line height rides in a paragraph style, whose word wrapping would override the
    // field's truncation: a truncating label gets its break mode put back into the runs.
    if wrap != "wrap" {
      let runs = NSMutableAttributedString(attributedString: text)
      runs.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: runs.length)) {
        value, range, _ in
        let paragraph =
          (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
          ?? NSMutableParagraphStyle()
        paragraph.lineBreakMode = field.lineBreakMode
        runs.addAttribute(.paragraphStyle, value: paragraph, range: range)
      }
      field.attributedStringValue = runs
    } else {
      field.attributedStringValue = text
    }
    return field
  }

  // MARK: Controls

  private func bind(_ control: NSControl, _ action: @escaping () -> Void) {
    actions[ObjectIdentifier(control)] = action
    control.target = target
    control.action = #selector(ModActionTarget.fire(_:))
  }

  fileprivate func fire(_ sender: NSControl) { actions[ObjectIdentifier(sender)]?() }

  private func link(_ props: [String: Any], _ children: [ModSurface.Node]) -> NSView? {
    let text =
      (props["label"] as? String) ?? children.map(\.plainText).joined()
    guard let href = props["href"] as? String, let url = URL(string: href),
      ["http", "https"].contains(url.scheme?.lowercased())
    else { return label(NSAttributedString(string: text, attributes: base()), [:]) }
    let button = ModButton(title: text.isEmpty ? href : text, target: nil, action: nil)
    button.isBordered = false
    register(button, props, nil)
    // A column stretches its children across; the link's words stay where text starts.
    button.alignment = .left
    button.contentTintColor = .linkColor
    button.font = metrics.font
    button.toolTip = href
    bind(button) { [weak self] in self?.onOpenURL(url) }
    return button
  }

  private func button(
    _ props: [String: Any], _ children: [ModSurface.Node], _ press: ModSurface.Press?
  ) -> NSView {
    let title = (props["label"] as? String) ?? children.map(\.plainText).joined()
    let button = ModButton(title: title, target: nil, action: nil)
    button.bezelStyle = .push
    small(button)
    // `plain` is a button drawn as its words alone, the terminal's unboxed kind: text that
    // presses, in the text's colour, so a row of them reads as headings rather than as links.
    // A hotkey is one letter or digit, shown as the desktop app shows it: a small key cap inside
    // the button — before a plain button's words, after a bordered one's.
    let hotkey = (props["hotkey"] as? String).flatMap { key -> String? in
      guard key.count == 1, let first = key.first, first.isLetter || first.isNumber else {
        return nil
      }
      return key.lowercased()
    }
    let plain = props["plain"] as? Bool == true
    let dim = props["dimColor"] as? Bool == true
    let primary = props["variant"] as? String == "primary"
    let ink: NSColor = dim ? .secondaryLabelColor : .labelColor
    // A plain button is text in the body's face, as the desktop app draws one; a bordered one's
    // words are a step smaller, inside the control.
    let font = NSFont.systemFont(ofSize: plain ? metrics.font.pointSize : 13)
    let words = NSMutableAttributedString(
      string: title,
      attributes: primary && !plain ? [.font: font] : [.font: font, .foregroundColor: ink])
    if let hotkey {
      let cap = NSAttributedString(attachment: Self.keyCap(hotkey, font: font))
      if plain {
        words.insert(NSAttributedString(string: " "), at: 0)
        words.insert(cap, at: 0)
      } else {
        words.append(NSAttributedString(string: " "))
        words.append(cap)
      }
      button.setAccessibilityHelp("Key: \(hotkey)")
    }
    button.attributedTitle = words
    if plain {
      button.isBordered = false
    } else if primary {
      // The desktop app's primary is the accent fill: AppKit's own, a default-looking button.
      button.bezelColor = .controlAccentColor
    }
    button.setContentHuggingPriority(.required, for: .horizontal)
    if let press {
      bind(button) { [weak self] in self?.onPress(press, nil) }
      if let hotkey {
        hotkeys[hotkey, default: []].append(
          (button, press.plugin, { [weak self] in self?.onPress(press, nil) }))
      }
    }
    button.isEnabled = press != nil
    if press != nil { register(button, props, press) }
    guard plain else { return button }
    // A plain button has no bezel to answer the pointer, so its ground lights under it, as the
    // desktop app's does: a faint fill behind the words, a 4-point corner.
    let ground = ModHoverSurface()
    ground.wantsLayer = true
    ground.layer?.cornerRadius = 4
    ground.paintLayer = { [weak ground] layer in
      layer.backgroundColor =
        ground?.isLit == true ? NSColor.quaternarySystemFill.cgColor : NSColor.clear.cgColor
    }
    button.translatesAutoresizingMaskIntoConstraints = false
    ground.addSubview(button)
    button.pin(to: ground, insets: NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))
    let scope = "button-\(UUID().uuidString)"
    ground.onHover = { [weak self] inside in self?.hovered(scope, inside) }
    join(scope) { [weak ground] lit in
      ground?.isLit = lit
      ground?.needsDisplay = true
    }
    return ground
  }

  private func input(_ props: [String: Any], _ press: ModSurface.Press?) -> NSView {
    let field = ModInputField()
    small(field)
    // `rows` asks for a field that many lines tall. Return still submits and Option-Return
    // breaks a line, as in the composer.
    let rows = max((props["rows"] as? NSNumber)?.intValue ?? 1, 1)
    if rows > 1 {
      field.usesSingleLineMode = false
      field.cell?.wraps = true
      field.cell?.isScrollable = false
      field.heightAnchor.constraint(equalToConstant: CGFloat(rows) * metrics.lh + 6).isActive =
        true
    }
    field.placeholderString = props["placeholder"] as? String
    field.stringValue = props["value"] as? String ?? ""
    field.isEnabled = press != nil
    // A field is known across redraws by whose it is and its key — or, keyless, by its place
    // among the tree's fields — never by its label, which two fields may share.
    let key =
      (props["key"] as? String).map { "\(press?.plugin ?? plugin ?? "")/\($0)" }
      ?? "#\(fields.count)"
    fields[key] = field
    if press != nil { register(field, props, press) }
    if let press {
      field.onChange = { [weak self] value in self?.onInput(press, value, false) }
      field.onSubmit = { [weak self] value in self?.onInput(press, value, true) }
    }
    var views: [NSView] = []
    if let label = props["label"] as? String { views.append(fieldLabel(label)) }
    views.append(field)
    if let submit = props["submitLabel"] as? String, let press {
      let button = ModButton(title: submit, target: nil, action: nil)
      button.bezelStyle = .push
      small(button)
      register(button, [:], press)
      bind(button) { [weak self, weak field] in
        self?.onInput(press, field?.stringValue ?? "", true)
      }
      views.append(button)
    }
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = rows > 1 ? .top : .firstBaseline
    row.spacing = 6
    field.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
    field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    return row
  }

  /// A key cap for a hotkey, in the desktop app's measure: a square an `em` and 6 points across,
  /// a hairline of the text colour at a fifth, a 4-point corner, the key in caption size and
  /// upper case. Drawn at draw time, so it follows the appearance like the text around it.
  static func keyCap(_ key: String, font: NSFont) -> NSTextAttachment {
    let side = font.pointSize + 6
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      let box = rect.insetBy(dx: 0.5, dy: 0.5)
      let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
      NSColor.labelColor.withAlphaComponent(0.2).setStroke()
      path.lineWidth = 1
      path.stroke()
      let letter = NSAttributedString(
        string: key.uppercased(),
        attributes: [
          .font: NSFont.systemFont(ofSize: 11, weight: .medium),
          .foregroundColor: NSColor.secondaryLabelColor,
        ])
      let size = letter.size()
      letter.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
      return true
    }
    let attachment = NSTextAttachment()
    attachment.image = image
    // Centred on the words' middle rather than standing on their baseline.
    attachment.bounds = NSRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
    return attachment
  }

  /// A control at the pane's size: the regular control, its label a step under the body text, as
  /// the desktop app sets a control's words against its 14-point prose.
  private func small(_ control: NSControl) {
    control.controlSize = .regular
    control.font = .systemFont(ofSize: 13)
  }

  /// The words before a field or a pick, in the pane's own font and a step back from the value.
  private func fieldLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = metrics.font
    label.textColor = .secondaryLabelColor
    label.setContentHuggingPriority(.required, for: .horizontal)
    return label
  }

  private func select(_ props: [String: Any], _ press: ModSurface.Press?) -> NSView {
    let popup = ModPopUpButton()
    small(popup)
    let options = (props["options"] as? [[String: Any]] ?? []).compactMap {
      option -> (value: String, label: String)? in
      guard let value = option["value"] as? String else { return nil }
      return (value, option["label"] as? String ?? value)
    }
    for option in options {
      popup.addItem(withTitle: option.label)
      popup.lastItem?.representedObject = option.value
    }
    if let value = props["value"] as? String,
      let index = options.firstIndex(where: { $0.value == value })
    {
      popup.selectItem(at: index)
    }
    popup.isEnabled = press != nil
    if press != nil { register(popup, props, press) }
    if let press {
      bind(popup) { [weak self, weak popup] in
        guard let value = popup?.selectedItem?.representedObject as? String else { return }
        self?.onSelect(press, value)
      }
    }
    guard let label = props["label"] as? String else { return popup }
    let row = NSStackView(views: [fieldLabel(label), popup])
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.spacing = 6
    return row
  }

  private func markdown(_ props: [String: Any]) -> NSView? {
    guard let text = props["text"] as? String else { return nil }
    let rendered = NSMutableAttributedString(attributedString: Transcript.markdown(text))
    // The renderer ends a block with its paragraph break; a pane's gap is the Box's to give.
    while rendered.string.hasSuffix("\n") {
      rendered.deleteCharacters(in: NSRange(location: rendered.length - 1, length: 1))
    }
    if props["dimColor"] as? Bool == true {
      rendered.enumerateAttribute(
        .foregroundColor, in: NSRange(location: 0, length: rendered.length)
      ) { value, range, _ in
        let color = (value as? NSColor) ?? .labelColor
        rendered.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.65), range: range)
      }
    }
    return label(rendered, [:])
  }

  /// Code in monospace, coloured by the editor's grammars when the mod names a language or a
  /// path, as a patch when it says `format: "diff"`, and numbered from `startLine` when it gives
  /// one.
  private func code(_ props: [String: Any]) -> NSView? {
    guard let raw = props["source"] as? String else { return nil }
    // A diff's hunk headers become its line numbers, as Claude Code draws one; plain code is
    // numbered from `startLine` when it gives one.
    let source: String
    let numbers: [Int?]?
    if props["format"] as? String == "diff" {
      (source, numbers) = Self.numberedDiff(raw)
    } else {
      source = raw
      numbers = ((props["startLine"] as? NSNumber)?.intValue).flatMap { first in
        first >= 0
          ? (0..<(raw as NSString).components(separatedBy: "\n").count).map { first + $0 } : nil
      }
    }
    let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let text = NSMutableAttributedString(
      string: source, attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
    if let file = Self.highlightPath(props) {
      let highlight = SyntaxHighlighting.highlight(in: source, forPath: file)
      for span in highlight.spans where NSMaxRange(span.range) <= text.length {
        text.addAttribute(.foregroundColor, value: span.color, range: span.range)
        if span.emphasis.contains(.bold) {
          text.addAttribute(
            .font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), range: span.range)
        }
      }
      for band in highlight.bands where NSMaxRange(band.range) <= text.length {
        text.addAttribute(.backgroundColor, value: band.color, range: band.range)
      }
    }
    if let numbers {
      // Numbered from the last line up, so each insertion leaves the offsets before it in place.
      let lines = (source as NSString).components(separatedBy: "\n")
      let width = numbers.compactMap { $0.map { String($0).count } }.max() ?? 1
      var starts: [Int] = []
      var offset = 0
      for line in lines {
        starts.append(offset)
        offset += (line as NSString).length + 1
      }
      for (index, start) in starts.enumerated().reversed() where index < numbers.count {
        let number = numbers[index].map(String.init) ?? ""
        let gutter = String(repeating: " ", count: width - number.count) + number + "  "
        text.insert(
          NSAttributedString(
            string: gutter,
            attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor]),
          at: min(start, text.length))
      }
    }
    let field = NSTextField(wrappingLabelWithString: "")
    field.attributedStringValue = text
    field.isSelectable = true
    let frame = LayerSurface()
    frame.wantsLayer = true
    frame.layer?.cornerRadius = 6
    frame.paintLayer = { $0.backgroundColor = NSColor.quaternarySystemFill.cgColor }
    field.translatesAutoresizingMaskIntoConstraints = false
    frame.addSubview(field)
    field.pin(to: frame, insets: NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8))
    return frame
  }

  /// A unified diff's lines without their hunk headers, each with the number it has: a removed
  /// line its old one, any other its new one, counted from the header's `-a,b +c,d`.
  static func numberedDiff(_ source: String) -> (String, [Int?]) {
    let header = try? NSRegularExpression(pattern: "^@@ -(\\d+)(?:,\\d+)? \\+(\\d+)")
    var old: Int?
    var new: Int?
    var lines: [String] = []
    var numbers: [Int?] = []
    for line in source.components(separatedBy: "\n") {
      if line.hasPrefix("@@"),
        let match = header?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
        let a = Range(match.range(at: 1), in: line), let b = Range(match.range(at: 2), in: line)
      {
        old = Int(line[a])
        new = Int(line[b])
        continue
      }
      lines.append(line)
      if line.hasPrefix("-") {
        numbers.append(old)
        old = old.map { $0 + 1 }
      } else if line.hasPrefix("+") {
        numbers.append(new)
        new = new.map { $0 + 1 }
      } else {
        numbers.append(new)
        old = old.map { $0 + 1 }
        new = new.map { $0 + 1 }
      }
    }
    return (lines.joined(separator: "\n"), numbers)
  }

  /// The file name a grammar is picked by: a patch for `format: "diff"`, else the mod's `path`,
  /// else its `language` as the extension that names it.
  static func highlightPath(_ props: [String: Any]) -> String? {
    if props["format"] as? String == "diff" { return "code.diff" }
    if let path = props["path"] as? String, !path.isEmpty { return path }
    guard let language = (props["language"] as? String)?.lowercased(), !language.isEmpty else {
      return nil
    }
    let extensions = [
      "typescript": "ts", "javascript": "js", "python": "py", "ruby": "rb", "rust": "rs",
      "csharp": "cs", "c#": "cs", "c++": "cpp", "bash": "sh", "shell": "sh", "zsh": "sh",
      "yaml": "yml", "markdown": "md", "golang": "go", "patch": "diff",
    ]
    return "code." + (extensions[language] ?? language)
  }

  private func progress(_ props: [String: Any]) -> NSView {
    let bar = NSProgressIndicator()
    bar.style = .bar
    bar.controlSize = .small
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.minValue = 0
    bar.maxValue = 1
    if let value = (props["value"] as? NSNumber)?.doubleValue {
      bar.isIndeterminate = false
      bar.doubleValue = min(max(value, 0), 1)
    } else {
      bar.isIndeterminate = true
      bar.startAnimation(nil)
    }
    bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    var views: [NSView] = []
    if let label = props["label"] as? String { views.append(NSTextField(labelWithString: label)) }
    views.append(bar)
    if let text = props["valueText"] as? String {
      let value = NSTextField(labelWithString: text)
      value.textColor = .secondaryLabelColor
      views.append(value)
    }
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    for view in views where view !== bar {
      view.setContentHuggingPriority(.required, for: .horizontal)
    }
    bar.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
    return row
  }

  private func svg(_ props: [String: Any]) -> NSView? {
    guard let source = props["source"] as? String, source.utf8.count < 1 << 20,
      let image = NSImage(data: Data(source.utf8))
    else { return nil }
    let view = NSImageView(image: image)
    view.imageScaling = .scaleProportionallyUpOrDown
    view.setAccessibilityLabel(props["alt"] as? String)
    view.toolTip = props["alt"] as? String
    // A picture's size is in points, not cells — the VS Code extension's reading, and what an
    // SVG's own width means — up to the engine's own bound.
    func points(_ value: Any?) -> CGFloat? {
      guard let number = value as? NSNumber else { return nil }
      let n = CGFloat(truncating: number)
      return n > 0 && n <= 4096 ? n : nil
    }
    let size = NSSize(
      width: points(props["width"]) ?? image.size.width,
      height: points(props["height"]) ?? image.size.height)
    view.widthAnchor.constraint(equalToConstant: max(size.width, 1)).isActive = true
    view.heightAnchor.constraint(equalToConstant: max(size.height, 1)).isActive = true
    view.setContentHuggingPriority(.required, for: .horizontal)
    return view
  }

  // MARK: Colours

  /// A colour as a mod names one: a theme key (`success`, `claude`), one of the sixteen terminal
  /// colours (`green`, `ansi:redBright`), `#rgb`/`#rrggbb`, or `rgb(r, g, b)` — the names VS Code
  /// reads, mapped to the system's colours so they hold in light and dark.
  func color(_ value: Any?) -> NSColor? {
    guard let name = value as? String, !name.isEmpty else { return nil }
    let theme: [String: NSColor] = [
      "text": .labelColor, "inverseText": .windowBackgroundColor,
      "inactive": .secondaryLabelColor, "secondaryText": .secondaryLabelColor,
      "subtle": .tertiaryLabelColor, "background": .windowBackgroundColor,
      "promptBorder": .separatorColor, "error": .systemRed, "success": .systemGreen,
      "warning": .systemOrange, "claude": NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1),
      "permission": .controlAccentColor, "suggestion": .controlAccentColor,
      "ide": .controlAccentColor, "diffAdded": .systemGreen, "diffRemoved": .systemRed,
      "userMessageBackground": .quaternarySystemFill,
      "bashMessageBackgroundColor": .textBackgroundColor,
    ]
    if let color = theme[name] { return color }
    var ansi = name.hasPrefix("ansi:") ? String(name.dropFirst(5)) : name
    if ansi == "blackBright" { ansi = "gray" }
    if ansi.hasSuffix("Bright") { ansi = String(ansi.dropLast(6)) }
    let terminal: [String: NSColor] = [
      "black": .labelColor, "red": .systemRed, "green": .systemGreen, "yellow": .systemYellow,
      "blue": .systemBlue, "magenta": .systemPurple, "cyan": .systemTeal, "white": .white,
      "gray": .systemGray, "grey": .systemGray,
    ]
    if let color = terminal[ansi] { return color }
    if name.hasPrefix("#") {
      var hex = String(name.dropFirst())
      if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
      guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else {
        return nil
      }
      let rgb = hex.count == 8 ? value >> 8 : value
      return NSColor(
        srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
        blue: CGFloat(rgb & 0xff) / 255, alpha: hex.count == 8 ? CGFloat(value & 0xff) / 255 : 1)
    }
    if name.hasPrefix("rgb(") {
      let parts = name.dropFirst(4).dropLast().split(separator: ",").compactMap {
        Double($0.trimmingCharacters(in: .whitespaces))
      }
      guard parts.count == 3 else { return nil }
      return NSColor(
        srgbRed: min(parts[0], 255) / 255, green: min(parts[1], 255) / 255,
        blue: min(parts[2], 255) / 255, alpha: 1)
    }
    return nil
  }

  // MARK: Focus across a redraw

  struct EditingField {
    let key: String
    let text: String
    let selection: NSRange
  }

  func focusedField(in window: NSWindow?) -> EditingField? {
    guard let editor = window?.firstResponder as? NSTextView else { return nil }
    for (key, field) in fields where editor.delegate === field {
      return EditingField(key: key, text: field.stringValue, selection: editor.selectedRange())
    }
    return nil
  }

  /// Put a field's keyboard back after a redraw: its focus and caret, and its text unless the
  /// tree's should win (`keepingDrawnText`) — after a submit nothing was typed since, the mod's
  /// answer is what the field holds, a cleared field cleared.
  func restore(_ editing: EditingField, in window: NSWindow?, keepingDrawnText: Bool = false) {
    guard let field = fields[editing.key] else { return }
    if !keepingDrawnText { field.stringValue = editing.text }
    window?.makeFirstResponder(field)
    let length = (field.stringValue as NSString).length
    let start = min(editing.selection.location, length)
    field.currentEditor()?.selectedRange = NSRange(
      location: start, length: min(editing.selection.length, length - start))
  }

  // MARK: Outline

  /// The tree as lines, for a script to read what a pane shows: a `Text` its words, a control its
  /// label in brackets.
  static func outline(_ node: ModSurface.Node) -> String {
    var lines: [String] = []
    func walk(_ node: ModSurface.Node) {
      switch node {
      case .text(let text): lines.append(text)
      case .element(let type, let props, let children, _):
        switch type {
        case "Text", "span", "b", "Link":
          let text = (props["label"] as? String) ?? node.plainText
          if !text.isEmpty { lines.append(text) }
        case "Button": lines.append("[\((props["label"] as? String) ?? node.plainText)]")
        case "Input":
          lines.append(
            "<\(props["label"] as? String ?? "input"): \(props["value"] as? String ?? "")>")
        case "Select": lines.append("{\(props["value"] as? String ?? "")}")
        case "Markdown": lines.append(props["text"] as? String ?? "")
        case "Code": lines.append(props["source"] as? String ?? "")
        case "Progress": lines.append("progress \(props["valueText"] as? String ?? "")")
        default: children.forEach(walk)
        }
      }
    }
    walk(node)
    return lines.joined(separator: "\n")
  }
}

/// A box's surface: its border and background, and — when it has a hover — what the pane's
/// pointer tracking tells of the pointer's coming and going, which lights its hover group
/// (`ModRenderer.hovered`).
final class ModHoverSurface: LayerSurface {
  /// The pointer came onto or left this box — told by the pane (`ModHoverTracker`), which follows
  /// the pointer across all of its boxes at once.
  var onHover: ((Bool) -> Void)?
  /// Whether its hover group is lit: what `paintLayer` reads.
  var isLit = false
}

/// Which hover boxes the pointer is on, worked out from where it is: the boxes under the view it
/// points at, outermost to innermost. One tracking area on the pane rather than one per box, so
/// a box that comes or goes with a redraw is simply found, or not, at the next move.
final class ModHoverTracker {
  private var inside: [ObjectIdentifier: ModHoverSurface] = [:]

  /// The pointer is at `point` in `root`'s window, or has left the pane (nil).
  func pointer(at point: NSPoint?, in root: NSView) {
    var now: [ObjectIdentifier: ModHoverSurface] = [:]
    // Asked of the pane alone, in its superview's coordinates as `hitTest` wants: whatever the
    // window lays over the pane must not stand in for the box under the pointer.
    if let point, let parent = root.superview,
      var view = root.hitTest(parent.convert(point, from: nil))
    {
      while view !== root {
        if let surface = view as? ModHoverSurface, surface.onHover != nil {
          now[ObjectIdentifier(surface)] = surface
        }
        guard let parent = view.superview else { break }
        view = parent
      }
    }
    for (id, surface) in inside where now[id] == nil { surface.onHover?(false) }
    for (id, surface) in now where inside[id] == nil { surface.onHover?(true) }
    inside = now
  }

  /// Forget the boxes of a tree that has been replaced — they are gone with their renderer, and
  /// telling them they were left would only count down a group nobody is drawing any more.
  func reset() { inside = [:] }
}

/// Views left to right at their own sizes, onto a new line when the width runs out — a row of
/// `flexWrap: "wrap"`. Laid out by hand: how many fit on a line is a question of the width.
final class ModFlowView: NSView {
  private let items: [NSView]
  private let spacing: NSSize
  private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)

  init(_ items: [NSView], spacing: NSSize) {
    self.items = items
    self.spacing = spacing
    super.init(frame: .zero)
    for item in items {
      item.translatesAutoresizingMaskIntoConstraints = true
      addSubview(item)
    }
    heightConstraint.isActive = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    let width = bounds.width
    guard width > 0 else { return }
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    for item in items where !item.isHidden {
      item.layoutSubtreeIfNeeded()
      var size = item.fittingSize
      size.width = min(size.width, width)
      if x > 0, x + size.width > width {
        x = 0
        y += lineHeight + spacing.height
        lineHeight = 0
      }
      item.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
      x += size.width + spacing.width
      lineHeight = max(lineHeight, size.height)
    }
    let total = y + lineHeight
    if abs(heightConstraint.constant - total) > 0.5 { heightConstraint.constant = total }
  }
}

/// The controls' target: a renderer is not an `NSObject`, and a selector needs one.
private final class ModActionTarget: NSObject {
  weak var renderer: ModRenderer?
  @objc func fire(_ sender: NSControl) { renderer?.fire(sender) }
}

/// A mod's field: each edit handed on as it is typed, Return as the submit.
final class ModInputField: NSTextField, NSTextFieldDelegate {
  var onChange: ((String) -> Void)?
  var onSubmit: ((String) -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    delegate = self
  }

  required init?(coder: NSCoder) { fatalError() }

  func controlTextDidChange(_ notification: Notification) { onChange?(stringValue) }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    // Escape hands the keyboard back from a field too, where the text view would complete.
    if selector == #selector(NSResponder.cancelOperation(_:)) {
      // Up the field's own chain, which reaches the pane's view whichever window is key.
      return tryToPerform(#selector(ModKeyboard.leaveModPane(_:)), with: self)
    }
    guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
    onSubmit?(stringValue)
    return true
  }
}

/// What the pane's own view answers as Escape travels up from a control: the keyboard leaves the
/// pane.
@objc protocol ModKeyboard {
  func leaveModPane(_ sender: Any?)
}

/// A key a control in a pane does not take itself — Escape, or a hotkey's one plain character —
/// handed to the site's own view, which AppKit's controls do not pass it up to.
private func passToPane(_ event: NSEvent, from view: NSView) -> Bool {
  guard event.keyCode == 53 || ModRenderer.isHotkey(event) != nil else { return false }
  var ancestor = view.superview
  while let candidate = ancestor {
    if let host = candidate as? ModSiteView {
      host.keyDown(with: event)
      return true
    }
    ancestor = candidate.superview
  }
  return false
}

/// Return, Enter and Space, unmodified.
private func presses(_ event: NSEvent) -> Bool {
  [36, 49, 76].contains(event.keyCode)
    && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
}

/// A button Tab reaches without Full Keyboard Access, as a pane's controls are reached in every
/// other host, and that Return and Space press once it has the ring.
final class ModButton: NSButton {
  override var acceptsFirstResponder: Bool { isEnabled }
  override var canBecomeKeyView: Bool { isEnabled }

  override func keyDown(with event: NSEvent) {
    if presses(event) {
      performClick(nil)
    } else if !passToPane(event, from: self) {
      super.keyDown(with: event)
    }
  }
}

/// A pick Tab reaches, which Return or Space opens.
final class ModPopUpButton: NSPopUpButton {
  override var acceptsFirstResponder: Bool { isEnabled }
  override var canBecomeKeyView: Bool { isEnabled }

  override func keyDown(with event: NSEvent) {
    if presses(event) {
      performClick(nil)
    } else if !passToPane(event, from: self) {
      super.keyDown(with: event)
    }
  }
}
