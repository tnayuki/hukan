import AppKit
import yoga

/// A mod's `Box`: a flexbox container, laid out by Yoga — the engine Ink itself lays a tree out
/// with, and the rules the desktop app leaves to a browser — rather than by constraints, which
/// cannot say "shrink these in proportion" and which a wrapping label answers differently from
/// one pass to the next (`docs/mods.md`). A box holds other boxes, whose nodes hang off its own,
/// and leaves — text, controls — each a node that Yoga asks the size of.
///
/// Only the outermost box meets Auto Layout: it is as tall as its tree comes out at the width it
/// is given, and inside it every frame is Yoga's.
final class ModFlexView: ModHoverSurface {
  /// One per process: a layout is rounded to the pixels of the screen it is drawn on.
  private static let config: YGConfigRef = {
    let config = YGConfigNew()!
    YGConfigSetPointScaleFactor(config, Float(NSScreen.main?.backingScaleFactor ?? 2))
    return config
  }()

  let node: YGNodeRef = YGNodeNewWithConfig(ModFlexView.config)
  private var leaves: [ObjectIdentifier: Leaf] = [:]
  private var children: [NSView] = []

  /// The height last told Auto Layout, and the width the tree cannot be narrower than — a
  /// control keeps its width — which is what makes a pane scroll sideways.
  private var reportedHeight: CGFloat = -1
  private lazy var floor = widthAnchor.constraint(greaterThanOrEqualToConstant: 0)

  /// A leaf's node and how its size is asked: text by the width it would wrap at, anything else
  /// by the size its own constraints settle on.
  final class Leaf {
    let view: NSView
    let node: YGNodeRef
    private var fitting: NSSize?

    init(view: NSView, node: YGNodeRef) {
      self.view = view
      self.node = node
    }

    func size(width: CGFloat?, exactly: Bool) -> NSSize {
      if let measured = view as? ModWidthMeasured {
        return measured.size(forWidth: width, exactly: exactly)
      }
      if let label = view as? NSTextField, !label.isEditable {
        return ModFlexView.size(of: label, width: width, exactly: exactly)
      }
      let fitting = fitting ?? view.fittingSize
      self.fitting = fitting
      return NSSize(width: exactly ? width ?? fitting.width : fitting.width, height: fitting.height)
    }

    func forget() { fitting = nil }

    /// Whether the leaf is text in a row, whose basis is its one line's length — CSS's
    /// `max-content` — so that two texts short of room shrink in proportion to their lengths.
    /// Left to itself Yoga takes the length the row has room for, and halves them.
    var basisIsItsLine = false {
      didSet { setBasis() }
    }

    func setBasis() {
      guard basisIsItsLine else { return }
      YGNodeStyleSetFlexBasis(node, Float(ceil(size(width: nil, exactly: false).width)))
    }
  }

  /// A label's size the way CSS sizes text: its one line's length, and when the room is less,
  /// that room and the lines it breaks into there — or, for one that truncates, its one line cut.
  /// Asked of the cell, for the bounds it would be drawn in: a wrapping label's own
  /// `intrinsicContentSize` answers from whatever frame it had last.
  static func size(of label: NSTextField, width: CGFloat?, exactly: Bool) -> NSSize {
    guard let cell = label.cell else { return label.intrinsicContentSize }
    let far = CGFloat(10_000_000)
    let line = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: far, height: far))
    guard let width else { return line }
    guard line.width > width else {
      return NSSize(width: exactly ? width : line.width, height: line.height)
    }
    guard cell.wraps, width > 0 else { return NSSize(width: width, height: line.height) }
    var height = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: far)).height
    if label.maximumNumberOfLines > 0 {
      height = min(height, line.height * CGFloat(label.maximumNumberOfLines))
    }
    return NSSize(width: width, height: height)
  }

  init() {
    super.init(frame: .zero)
    setContentCompressionResistancePriority(.init(rawValue: 100), for: .horizontal)
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit {
    for leaf in leaves.values { YGNodeFree(leaf.node) }
    YGNodeFree(node)
  }

  override var isFlipped: Bool { true }

  /// Add a child in the tree's order: a box's node, or a new one for a leaf. The caller styles
  /// the node it gets back.
  @discardableResult
  func add(_ view: NSView) -> YGNodeRef {
    let child: YGNodeRef
    if let box = view as? ModFlexView {
      child = box.node
    } else {
      child = YGNodeNewWithConfig(ModFlexView.config)
      let leaf = Leaf(view: view, node: child)
      leaves[ObjectIdentifier(view)] = leaf
      YGNodeSetContext(child, Unmanaged.passUnretained(leaf).toOpaque())
      YGNodeSetMeasureFunc(child) { node, width, widthMode, _, _ in
        guard let context = YGNodeGetContext(node) else { return YGSize(width: 0, height: 0) }
        let leaf = Unmanaged<Leaf>.fromOpaque(context).takeUnretainedValue()
        let size = leaf.size(
          width: widthMode == YGMeasureMode.undefined ? nil : CGFloat(width),
          exactly: widthMode == YGMeasureMode.exactly)
        return YGSize(width: Float(ceil(size.width)), height: Float(ceil(size.height)))
      }
    }
    view.translatesAutoresizingMaskIntoConstraints = true
    view.autoresizingMask = []
    addSubview(view)
    children.append(view)
    YGNodeInsertChild(node, child, Int(YGNodeGetChildCount(node)))
    return child
  }

  /// A text among a row's children: see `Leaf.basisIsItsLine`.
  func basisIsItsLine(_ view: NSView) { leaves[ObjectIdentifier(view)]?.basisIsItsLine = true }

  private var root: ModFlexView {
    var view = self
    while let parent = view.superview as? ModFlexView { view = parent }
    return view
  }

  /// A child's content or style changed — a hover restyled a text, showed a box, moved one —
  /// so its size is asked again and the tree laid out again.
  func changed(_ view: NSView? = nil) {
    if let view, let leaf = leaves[ObjectIdentifier(view)] {
      leaf.forget()
      leaf.setBasis()
      YGNodeMarkDirty(leaf.node)
    }
    let root = root
    // The floor is the old content's: it is found again for what is shown now.
    root.floor.constant = 0
    root.needsLayout = true
    root.invalidateIntrinsicContentSize()
    // A tree that scrolls sideways inside another is a leaf of that one, measured again too.
    if let scroller = root.enclosingScrollView as? ModScrollBox {
      scroller.needsLayout = true
      ModFlexView.changed(scroller)
    }
  }

  /// The box a view is laid out by, to tell it the view changed.
  static func changed(_ view: NSView) {
    var parent = view.superview
    while let current = parent, !(current is ModFlexView) { parent = current.superview }
    (parent as? ModFlexView)?.changed(view)
  }

  /// The tree's size left to itself: every text on its one line.
  var naturalSize: NSSize {
    YGNodeCalculateLayout(node, .nan, .nan, YGDirection.LTR)
    return NSSize(
      width: CGFloat(YGNodeLayoutGetWidth(node)), height: CGFloat(YGNodeLayoutGetHeight(node)))
  }

  // MARK: The outermost box

  private var isRoot: Bool { !(superview is ModFlexView) }

  override var intrinsicContentSize: NSSize {
    guard isRoot else {
      return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    if reportedHeight < 0 {
      // Not laid out yet: the tree at its own width, every text on its one line.
      YGNodeCalculateLayout(node, .nan, .nan, YGDirection.LTR)
      return NSSize(
        width: CGFloat(YGNodeLayoutGetWidth(node)), height: CGFloat(YGNodeLayoutGetHeight(node)))
    }
    return NSSize(width: NSView.noIntrinsicMetric, height: reportedHeight)
  }

  override func layout() {
    super.layout()
    guard isRoot, bounds.width > 0 else { return }
    YGNodeCalculateLayout(node, Float(bounds.width), .nan, YGDirection.LTR)
    place()
    let height = CGFloat(YGNodeLayoutGetHeight(node))
    // What sticks out past the width is what could not shrink: the tree is at least that wide
    // from here on, and whatever holds it scrolls.
    let reach = extent()
    if reach > bounds.width + 0.5, reach > floor.constant {
      floor.constant = reach
      floor.isActive = true
    }
    if abs(height - reportedHeight) > 0.5 {
      reportedHeight = height
      invalidateIntrinsicContentSize()
    }
  }

  private func place() {
    for view in children {
      let child = (view as? ModFlexView)?.node ?? leaves[ObjectIdentifier(view)]?.node
      guard let child else { continue }
      let frame = NSRect(
        x: CGFloat(YGNodeLayoutGetLeft(child)), y: CGFloat(YGNodeLayoutGetTop(child)),
        width: CGFloat(YGNodeLayoutGetWidth(child)), height: CGFloat(YGNodeLayoutGetHeight(child)))
      if view.frame != frame { view.frame = frame }
      (view as? ModFlexView)?.place()
    }
  }

  /// How far right the flow reaches, in this box's coordinates. A floating box is not counted:
  /// it is laid over the tree, not part of how wide the tree is.
  private func extent() -> CGFloat {
    var reach: CGFloat = 0
    for view in children where !view.isHidden {
      let child = (view as? ModFlexView)?.node ?? leaves[ObjectIdentifier(view)]?.node
      guard let child, YGNodeStyleGetPositionType(child) != YGPositionType.absolute else {
        continue
      }
      let inner = (view as? ModFlexView).map { view.frame.minX + $0.extent() } ?? 0
      reach = max(reach, view.frame.maxX, inner)
    }
    return reach
  }
}

/// A leaf that is more than one label and wraps: it says how tall it is at a width.
protocol ModWidthMeasured: NSView {
  func size(forWidth width: CGFloat?, exactly: Bool) -> NSSize
}
