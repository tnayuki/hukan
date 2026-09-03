import AppKit

/// A view whose layer carries the app's own colours.
///
/// A `CALayer` holds a `CGColor`, which is a colour already resolved — so a catalog colour handed
/// to one in an `init` freezes whatever appearance happened to be current at that moment, and the
/// view keeps it for good. On a machine whose system appearance is light that is a black hairline
/// under a dark tab strip and an approval card washed the wrong way round. `updateLayer` is the
/// drawing moment instead: AppKit puts the view's own appearance in force before calling it, and
/// calls it again whenever that appearance changes. The same fault as the transcript's
/// `withDynamicAlpha`, one layer down.
class LayerSurface: NSView {
  /// The colours, and only the colours — a radius and a width are not appearance's business and
  /// belong where the view is built. Called at every display, with the view's appearance in force.
  var paintLayer: ((CALayer) -> Void)?

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    super.updateLayer()
    if let layer { paintLayer?(layer) }
  }
}
