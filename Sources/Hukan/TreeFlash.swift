import AppKit

/// Which rows of the files panel's tree light up when files change, and the light itself.
///
/// A change is lit on the deepest row on screen that stands for it: the file's own row when it is
/// showing, otherwise the folded directory it is hidden in. An open directory is lit only when the
/// row under it on the way to the file has gone — a deletion — since otherwise that row is merely
/// scrolled out of view, and lighting its parent would point at the wrong place.
enum TreeFlash {
  /// How long a light takes to fade. A change arriving again restarts it rather than stacking.
  static let duration: CFTimeInterval = 1.2

  /// One row on screen: its path, and whether it is a directory currently open.
  struct VisibleRow {
    let path: String
    let isOpenDirectory: Bool
  }

  /// The paths of the rows in `visible` that `changed` lights. `hasRow` answers whether the tree
  /// has a row for a path at all, on screen or not.
  static func rowsToLight(
    changed: Set<String>, visible: [VisibleRow], hasRow: (String) -> Bool
  ) -> Set<String> {
    guard !changed.isEmpty, !visible.isEmpty else { return [] }
    let rows = Dictionary(
      visible.map { ($0.path, $0.isOpenDirectory) }, uniquingKeysWith: { a, _ in a })
    var lit: Set<String> = []
    for path in changed {
      var below = path
      var candidate = path
      while true {
        if let isOpen = rows[candidate] {
          if candidate == path || !isOpen || !hasRow(below) { lit.insert(candidate) }
          break
        }
        guard candidate.contains("/") else { break }
        below = candidate
        candidate = (candidate as NSString).deletingLastPathComponent
      }
    }
    return lit
  }
}

/// The light itself: a wash of the accent colour laid under a row's content, fading out. A view
/// of its own rather than drawing in the row view, so the outline's selection drawing and reuse
/// stay AppKit's; it takes no clicks.
final class RowFlashView: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    autoresizingMask = [.width, .height]
    layer?.opacity = 0
  }

  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// Run the fade as if it had started `elapsed` seconds ago, so a row view made again partway
  /// through — every batch reloads rows — carries on where the light was rather than restarting.
  func run(elapsed: CFTimeInterval) {
    guard let layer else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1.0
    fade.toValue = 0.0
    fade.duration = TreeFlash.duration
    fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
    fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - elapsed
    layer.opacity = 0
    layer.add(fade, forKey: "flash")
  }

  func stop() { layer?.removeAnimation(forKey: "flash") }

  /// The row view's light, made the first time it is asked for.
  static func on(_ rowView: NSTableRowView) -> RowFlashView {
    if let existing = rowView.subviews.lazy.compactMap({ $0 as? RowFlashView }).first {
      return existing
    }
    let view = RowFlashView(frame: rowView.bounds)
    rowView.addSubview(view, positioned: .below, relativeTo: nil)
    return view
  }

  static func existing(on rowView: NSTableRowView) -> RowFlashView? {
    rowView.subviews.lazy.compactMap { $0 as? RowFlashView }.first
  }
}
