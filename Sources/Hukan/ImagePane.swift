import AppKit
import ImageIO

/// A file whose content is pixels. Read as an image rather than as text, and drawn at its own
/// size rather than fitted to the pane.
enum ImageFile {
  /// The formats the pane draws. A table rather than a test, because both tests on offer are
  /// wrong in the same place: `NSImage(contentsOfFile:) != nil` and `UTType.conforms(to: .image)`
  /// each say yes to `.svg` (measured), which is source an agent edits and has to stay in the
  /// editor. `.pdf` is the one image-ish thing left out on purpose: a page is drawn from
  /// instructions rather than held as pixels, so the pane's whole promise — that what is on
  /// screen is the file's own pixels — has nothing to attach to. Anything not here falls through
  /// to the text pane, which says what the file is rather than showing an empty one.
  static let extensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "ico", "icns",
  ]

  static func covers(path: String) -> Bool {
    extensions.contains((path as NSString).pathExtension.lowercased())
  }

  /// Past these a file is not opened as an image at all. The bytes on disk are the cheap gate;
  /// the pixel count is the one that decides the cost, since decoding is four bytes a pixel and
  /// a file's size on disk says nothing about it — a 3 MB PNG can be 100 megapixels.
  private static let byteCap = 128 << 20
  private static let pixelCap = 32_000_000

  struct Loaded {
    /// One bitmap, named rather than left to `NSImage` to choose. A file may hold several — an
    /// `.icns` here holds ten, 1024 down to 16, and `NSImage.size` answers 512, which is neither
    /// the largest nor any one of them — so which one is on screen has to be this pane's own
    /// decision or the pixel count under it is a guess.
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
    /// How many bitmaps the file holds, so the caption can say the drawing is one of them.
    let count: Int
    /// The file's size on disk, for the caption.
    let bytes: Int

    /// What the pane says under the image. The pixel count is the one thing the drawing itself
    /// no longer states: at one image pixel to one *device* pixel a 1040-wide image measures
    /// 520pt on a 2× display, and nothing else on screen says 1040. A container says so too —
    /// otherwise its caption is a true number about a file it is not the whole of.
    var caption: String {
      let size =
        count > 1
        ? "\(pixelWidth) × \(pixelHeight), largest of \(count)"
        : "\(pixelWidth) × \(pixelHeight)"
      return "\(size)  ·  \(fileSizeText(bytes))"
    }
  }

  enum Read {
    case image(Loaded)
    /// Why there is no image — said in the text pane, beside the note a file that is not text
    /// gets, since both are the same answer: this is not something to show you.
    case failed(String)
  }

  /// Read the file as an image, off the main thread.
  ///
  /// Every bitmap in it is measured before any is decoded — ImageIO answers a dimension without
  /// decoding a pixel, which is the same shape as `git_patch_size` answering in bytes without
  /// building the patch — and the largest is the one drawn. Largest rather than first because an
  /// icon container is opened to be looked at, and because the order is the file's: `.icns` here
  /// happens to put 1024 first, and nothing in the format says it must.
  ///
  /// An animated GIF therefore stands at its first frame. Animating one means an `NSImageView`,
  /// which brings its own scaling back and would have to be laid over the checkerboard rather
  /// than drawn into it; standing still is not what a file opened to be looked at is short of.
  static func read(at url: URL) -> Read {
    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    guard bytes <= byteCap else {
      return .failed("Too large to open — \(fileSizeText(bytes))")
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      return .failed("This image could not be read")
    }
    let count = CGImageSourceGetCount(source)
    var largest: (index: Int, width: Int, height: Int)?
    for index in 0..<count {
      guard
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
          as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        width > 0, height > 0
      else { continue }
      if width * height > (largest.map { $0.width * $0.height } ?? 0) {
        largest = (index, width, height)
      }
    }
    guard let largest else {
      return .failed("This image could not be read")
    }
    guard largest.width * largest.height <= pixelCap else {
      return .failed("Too large to open — \(largest.width) × \(largest.height)")
    }
    // Decoded here rather than at the first draw, which is on the main thread — a screenshot is
    // megabytes of it.
    guard let image = CGImageSourceCreateImageAtIndex(source, largest.index, nil) else {
      return .failed("This image could not be read")
    }
    return .image(
      Loaded(
        image: image, pixelWidth: largest.width, pixelHeight: largest.height, count: count,
        bytes: bytes))
  }
}

/// Centres a document smaller than the clip, and lands it on the backing grid. Both halves are
/// the same requirement: an image drawn at one image pixel to one device pixel is sharp only
/// while its origin sits on that grid, and centring is exactly the arithmetic that produces a
/// fractional one.
private final class CenteringClipView: NSClipView {
  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var rect = super.constrainBoundsRect(proposedBounds)
    guard let document = documentView else { return rect }
    if rect.width > document.frame.width {
      rect.origin.x = (document.frame.width - rect.width) / 2
    }
    if rect.height > document.frame.height {
      rect.origin.y = (document.frame.height - rect.height) / 2
    }
    return backingAlignedRect(rect, options: .alignAllEdgesNearest)
  }
}

/// The image itself, over the checkerboard that says where it is transparent.
///
/// No border around it. The checkerboard is what actually confuses a reader — a transparent
/// corner and a white one look the same otherwise — and a hairline is the wrong answer to the
/// other half: drawn inside it covers the outermost row of the file's pixels, and drawn outside
/// it grows with the magnification into a frame nobody asked for.
private final class ImageCanvas: NSView {
  var image: CGImage? {
    didSet { needsDisplay = true }
  }

  /// The checkerboard's square, in points at magnification 1. It scales with the image, being
  /// what is behind the image rather than chrome laid over the pane.
  private static let square: CGFloat = 8

  override var isFlipped: Bool { true }

  /// The board is behind the image and nowhere else, so the view is clipped to itself: an
  /// `NSView` has not clipped to its own bounds by default since macOS 14, and a checkerboard
  /// running out over the pane says the whole column is transparent.
  override var clipsToBounds: Bool {
    get { true }
    set {}
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let image else { return }
    let area = dirtyRect.intersection(bounds)
    guard !area.isEmpty else { return }
    drawCheckerboard(in: area)
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    // Never smoothed: at magnification 1 this is a one-to-one blit where interpolation has
    // nothing to do, and past it what is being looked at is the pixels themselves, where a blur
    // invented between them is exactly what is in the way.
    context.interpolationQuality = .none
    // A `CGImage` draws bottom-up and this view is flipped, so the axis is turned back over the
    // view's own height before the blit.
    context.translateBy(x: 0, y: bounds.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: NSRect(origin: .zero, size: bounds.size))
    context.restoreGState()
  }

  /// Two semantic fills rather than the conventional white-and-grey pair, so the board follows
  /// the appearance: the second is translucent and composited over the first, which is how one
  /// pair reads in both.
  private func drawCheckerboard(in area: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    area.fill()
    NSColor.tertiarySystemFill.setFill()
    let step = Self.square
    let firstColumn = Int(floor(area.minX / step))
    let lastColumn = Int(ceil(area.maxX / step))
    let firstRow = Int(floor(area.minY / step))
    let lastRow = Int(ceil(area.maxY / step))
    for column in firstColumn..<lastColumn {
      for row in firstRow..<lastRow where (column + row) % 2 == 1 {
        NSRect(
          x: CGFloat(column) * step, y: CGFloat(row) * step, width: step, height: step
        ).intersection(area).fill()
      }
    }
  }
}

/// What the pane says under the image, drawn rather than set in a field. A label is a control,
/// and AppKit rounds a control's intrinsic size to the *screen's* backing grid rather than the
/// window's — the one thing a pinned snapshot cannot pin (see `SnapshotSurface`) — so a strip of
/// a fixed height with the string drawn into it is what keeps this pane's look checkable. It is
/// also what the transcript's own furniture already does, and for the neighbouring reason: text
/// nobody typed should not come out with a selection.
private final class CaptionStrip: NSView {
  static let height: CGFloat = 22

  var text = "" {
    didSet { needsDisplay = true }
  }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    (text as NSString).draw(
      at: NSPoint(x: 8, y: 4),
      withAttributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
      ])
  }
}

/// The file pane's other half: what a tab shows when its file is an image.
///
/// It opens at actual pixels — one image pixel to one device pixel — rather than fitted to the
/// column. `NSImage`'s own `size` is no use for that: it is the pixel count divided by whatever
/// DPI the file claims, and the DPI in real files is noise (hukan's own 2× snapshot references
/// say 72; a `@2x` asset in the wild said 96). So the pixels are read from the header and the
/// scale from the display, which as a side effect draws a `@2x` asset at the size it was drawn
/// for without anyone parsing `@2x` out of a filename.
///
/// What does not fit scrolls, which is the same rule the editor beside it already follows for a
/// long line: this pane never shrinks its content to the column. Getting closer is the trackpad's
/// — a pinch, and a two-finger double tap, both of which `allowsMagnification` brings — with the
/// zoom keys as the way back to 1, the rung that means actual pixels.
final class ImagePane: NSView {
  private let scroll = NSScrollView()
  private let canvas = ImageCanvas()
  private let caption = CaptionStrip()
  private var loaded: ImageFile.Loaded?

  /// The rungs a key press moves between, and 1 is on it — the browser's reading of the same
  /// problem, kept: the point of a second press is to land somewhere you meant, so walking back
  /// with ⌘− reaches exactly where ⌘0 puts you.
  private static let steps: [CGFloat] = [
    0.1, 0.125, 0.25, 0.33, 0.5, 0.67, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64,
  ]

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.contentView = CenteringClipView()
    scroll.documentView = canvas
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.drawsBackground = false
    scroll.allowsMagnification = true
    scroll.minMagnification = 0.05

    caption.translatesAutoresizingMaskIntoConstraints = false

    addSubview(scroll)
    addSubview(caption)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      scroll.topAnchor.constraint(equalTo: topAnchor),
      scroll.bottomAnchor.constraint(equalTo: caption.topAnchor),
      caption.leadingAnchor.constraint(equalTo: leadingAnchor),
      caption.trailingAnchor.constraint(equalTo: trailingAnchor),
      caption.bottomAnchor.constraint(equalTo: bottomAnchor),
      caption.heightAnchor.constraint(equalToConstant: CaptionStrip.height),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  /// The keyboard lands here rather than on the editor's text view when the tab is an image —
  /// there is nothing to type, but the scroll keys and Escape have somewhere to go.
  override var acceptsFirstResponder: Bool { true }

  /// What the pane is showing, in the terms it decides them in. An image has no text to read
  /// back — the same hole the strip's report fills for the tab — so this is what a test asserts
  /// actual pixels and a key press on.
  var drawnSize: NSSize { canvas.frame.size }
  var magnification: CGFloat { scroll.magnification }
  var maxMagnification: CGFloat { scroll.maxMagnification }

  /// Show an image, from the top-left at actual pixels. A re-read of the same file keeps the
  /// magnification and where it was scrolled: an agent rewriting a screenshot under the reader
  /// should change the picture, not the place they were looking at it from.
  func show(_ image: ImageFile.Loaded, keepingPlace: Bool) {
    let origin = scroll.contentView.bounds.origin
    let magnification = scroll.magnification
    loaded = image
    canvas.image = image.image
    caption.text = image.caption
    applySize()
    if keepingPlace {
      scroll.magnification = magnification
      scroll.contentView.scroll(to: origin)
      scroll.reflectScrolledClipView(scroll.contentView)
    } else {
      scroll.magnification = 1
      scroll.contentView.scroll(to: .zero)
      scroll.reflectScrolledClipView(scroll.contentView)
    }
  }

  /// The scale the image is drawn at when the magnification is 1 — the display's, not the file's.
  /// Off-screen it is the main display's rather than this machine's 2, since a snapshot host and
  /// a test both draw without a window.
  private var backingScale: CGFloat {
    window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
  }

  /// Size the canvas so one image pixel covers one device pixel, and set how far in a press or a
  /// pinch may go. Out is a flat floor, enough to bring anything inside the pane. In is per
  /// image, because far enough is a size on screen and not a factor: 4× of a 16px icon is still
  /// 32pt of nothing, so the ceiling is whatever brings the shorter side up to something
  /// readable — and never less than 4, which is all a screenshot needs.
  private func applySize() {
    guard let loaded else { return }
    let scale = backingScale
    let size = NSSize(
      width: CGFloat(loaded.pixelWidth) / scale, height: CGFloat(loaded.pixelHeight) / scale)
    canvas.setFrameSize(size)
    scroll.maxMagnification = min(64, max(4, 512 / max(1, min(size.width, size.height))))
  }

  /// The display changed under the window — moved to one with a different backing scale, or the
  /// window opened on one. Actual pixels is a statement about the display, so it is re-measured
  /// rather than kept; the magnification is the reader's and stays.
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    let magnification = scroll.magnification
    applySize()
    scroll.magnification = magnification
  }

  /// ⌘+ / ⌘−: one rung, from whichever the image is nearest, holding at both ends.
  func zoom(by delta: Int) {
    let rungs = Self.steps.filter {
      $0 >= scroll.minMagnification && $0 <= scroll.maxMagnification
    }
    guard !rungs.isEmpty else { return }
    let current = scroll.magnification
    let nearest =
      rungs.indices.min { abs(rungs[$0] - current) < abs(rungs[$1] - current) } ?? 0
    setMagnificationKeepingCentre(rungs[min(max(nearest + delta, 0), rungs.count - 1)])
  }

  /// ⌘0. Not a walk back along the ladder but the rung itself, and here that rung has a meaning
  /// of its own: 1 is one image pixel to one device pixel, which is what the pane opened at.
  func resetZoom() {
    setMagnificationKeepingCentre(1)
  }

  /// Zooming keeps what is in the middle of the pane in the middle of the pane — the pinch's own
  /// behaviour, so the keys do not disagree with the gesture beside them.
  private func setMagnificationKeepingCentre(_ magnification: CGFloat) {
    let visible = scroll.contentView.bounds
    let centre = NSPoint(x: visible.midX, y: visible.midY)
    scroll.setMagnification(magnification, centeredAt: centre)
  }
}
