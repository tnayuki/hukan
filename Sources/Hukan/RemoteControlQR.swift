import AppKit
import CoreImage

/// The address of a bridged conversation, as a code a phone can read.
///
/// The whole of Remote Control is "carry on somewhere else", and the address that makes that
/// possible is on the wrong screen: it is on this Mac, and the device that wants it is in your
/// hand. Every other way across — mailing yourself the link, finding the session in the app — is
/// longer than pointing a camera at the window. So the header's antenna carries the code behind a
/// hover, which costs nothing while the bridge is down and takes no gesture away from the toggle.
///
/// Nothing leaves the machine to build it: CoreImage generates the code from a string hukan
/// already has. It is not a picture of a URL so much as the URL in another alphabet.
enum RemoteControlQR {
  /// Draw `url` as a QR code `points` wide, at this window's scale.
  ///
  /// **The scaling is nearest-neighbour and integral**, which is the one thing a QR cannot be
  /// sloppy about: the generator answers at one pixel per module — about 25 across for an address
  /// this length — and the smooth scaling AppKit would otherwise apply turns every module edge
  /// into a ramp. A camera reads that as an ambiguous module and gives up. So the modules are
  /// multiplied by a whole number and the result is drawn with interpolation off, which is the
  /// same argument the image pane makes for a screenshot of text, one step further: there, a soft
  /// pixel is ugly, and here it is unreadable.
  ///
  /// `scale` is the *device* pixel ratio, so the code lands on the backing grid and a 2× display
  /// gets twice the modules rather than one blurred set. Nil when the generator declines the
  /// string, which leaves the caller to show nothing rather than an empty white square.
  static func image(for url: URL, points: CGFloat, scale: CGFloat) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
    // Medium correction: the code is read off a bright screen at 20cm, not off a crate in a
    // warehouse, so the redundancy the higher levels buy is paid for in modules nobody needs.
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }

    let modules = max(output.extent.width, 1)
    let target = points * scale
    // **The quiet zone is part of the code**, not a margin the layout could have supplied: a
    // reader finds the code by its border of light, and one drawn hard against the edge of its
    // image is one many readers will not see at all. Two modules each side — the spec asks four,
    // which is sized for print at a distance, where this is read off a bright screen at 20cm and
    // every module spent on white is one not spent on the address.
    let quiet: CGFloat = 2
    // At least one device pixel per module, and a whole number of them: a fractional multiple is
    // what puts a module boundary halfway across a pixel, which is exactly the ambiguity above.
    // The zone scales with the modules, so it is solved for in one step rather than subtracted.
    let factor = max(floor(target / (modules + quiet * 2)), 1)
    let inset = Int(quiet * factor)
    let side = Int(modules * factor) + inset * 2

    let context = CIContext(options: [.useSoftwareRenderer: false])
    guard
      let cgImage = context.createCGImage(
        output.transformed(by: CGAffineTransform(scaleX: factor, y: factor)),
        from: output.extent.applying(CGAffineTransform(scaleX: factor, y: factor)))
    else { return nil }

    // Drawn into a bitmap of exactly the module count, then handed back at its point size, so
    // AppKit has no resampling left to do at draw time.
    let image = NSImage(size: NSSize(width: CGFloat(side) / scale, height: CGFloat(side) / scale))
    image.addRepresentation(
      {
        let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
          samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        // Drawn in *pixels*, which is what the rep's own size still says at this point. Setting
        // the point size first is the trap: the context then maps points to pixels and every
        // coordinate below is scaled by the display, which on a 2× screen drew the code at twice
        // its size and kept the quarter of it that fitted. The size is set after, once there is
        // nothing left to draw.
        NSGraphicsContext.saveGraphicsState()
        let graphics = NSGraphicsContext(bitmapImageRep: rep)!
        graphics.imageInterpolation = .none
        NSGraphicsContext.current = graphics
        graphics.cgContext.interpolationQuality = .none
        // White is painted in rather than left to whatever is behind: the generator hands back
        // modules on transparency, and a code composited onto a dark appearance is inverted —
        // which most readers refuse. This bitmap is the code, background included.
        graphics.cgContext.setFillColor(NSColor.white.cgColor)
        graphics.cgContext.fill(CGRect(x: 0, y: 0, width: side, height: side))
        graphics.cgContext.draw(
          cgImage,
          in: CGRect(
            x: inset, y: inset, width: side - inset * 2, height: side - inset * 2))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: CGFloat(side) / scale, height: CGFloat(side) / scale)
        return rep
      }())
    return image
  }
}

/// The panel behind the antenna's hover: the code, whose login it is for, and the address in
/// words.
///
/// **A bridged conversation opens only for the account that bridged it**, so a code scanned on a
/// phone signed in as somebody else fails — and fails on the phone, several steps after the
/// decision that doomed it. That is not something hukan can fix, the bridge being account-scoped
/// by construction, but it is something it can *say*: the account rides in the same initialize
/// reply the rest of this reads, so the panel names it and the mismatch is visible before the
/// camera comes up rather than after.
///
/// The address is spelled out as well as encoded for the same reason — the code answers only "get
/// this onto my phone", where someone looking at it may want to know which session they are about
/// to hand over. Neither is a control: there is nothing to press here, which is what lets the
/// panel be a hover at all.
final class RemoteControlQRView: NSView {
  private let imageView = NSImageView()
  private let addressLabel = NSTextField(labelWithString: "")
  private let captionLabel = NSTextField(labelWithString: "")
  private let accountLabel = NSTextField(labelWithString: "")

  /// The drawn side of the code, in points. Large enough for a phone camera at arm's length and
  /// small enough that the panel does not stand over the conversation it belongs to.
  private static let side: CGFloat = 148

  private let url: URL

  init(url: URL, account: String?) {
    self.url = url
    super.init(frame: .zero)
    // Plain white behind the code whatever the appearance: a dark-mode inversion is a code most
    // readers refuse, and this is the one surface in hukan that is read by a machine rather than
    // by a person.
    imageView.wantsLayer = true
    imageView.layer?.backgroundColor = NSColor.white.cgColor
    imageView.layer?.cornerRadius = 4
    imageView.imageScaling = .scaleNone

    // The caption names the login when there is one to name, since "on your phone" is only true
    // of a phone signed in as this account. With none — an engine too old to report it — it falls
    // back to the plain sentence rather than to a gap where the address should be.
    captionLabel.font = .systemFont(ofSize: 11)
    captionLabel.textColor = .secondaryLabelColor
    captionLabel.stringValue =
      account == nil ? "Scan to continue on your phone" : "Scan to continue, signed in as"
    accountLabel.font = .systemFont(ofSize: 11, weight: .medium)
    accountLabel.textColor = .labelColor
    accountLabel.lineBreakMode = .byTruncatingMiddle
    accountLabel.stringValue = account ?? ""
    accountLabel.isHidden = account == nil
    addressLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
    addressLabel.textColor = .tertiaryLabelColor
    addressLabel.lineBreakMode = .byTruncatingMiddle
    addressLabel.stringValue = url.absoluteString
    addressLabel.isSelectable = true

    let stack = NSStackView(views: [imageView, captionLabel, accountLabel, addressLabel])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 6
    stack.setCustomSpacing(10, after: imageView)
    stack.setCustomSpacing(2, after: captionLabel)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      imageView.widthAnchor.constraint(equalToConstant: Self.side),
      imageView.heightAnchor.constraint(equalToConstant: Self.side),
      addressLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.side + 40),
      accountLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.side + 40),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Built once the view is in a window, because the scale it has to be built for is the
  /// window's — the same reason the image pane re-measures when it changes display.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    imageView.image = RemoteControlQR.image(
      for: url, points: Self.side, scale: window.backingScaleFactor)
  }
}
