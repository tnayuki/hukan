import CoreImage
import XCTest

@testable import Hukan

/// The QR code the antenna's hover carries. What is worth pinning here is not how it looks but
/// that it is *readable*: a code is the one surface in hukan drawn for a machine rather than for a
/// person, so the test decodes it back with the system's own detector — the same job a phone
/// camera does — rather than comparing pixels.
final class RemoteControlQRTests: XCTestCase {
  private let address = URL(string: "https://claude.ai/code/session_01UneaPqrbgAcZyc8Ke9AspV")!

  /// Read the bitmap the code was drawn into, not what `NSImage` would hand a caller asking at
  /// point size — that one resamples down to the points on a 2× image, which is the very thing
  /// the drawing goes to lengths to avoid. What a display puts on screen is the rep, so the rep
  /// is what is decoded.
  private func decode(_ image: NSImage) throws -> String? {
    let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
    let cgImage = try XCTUnwrap(rep.cgImage)
    let detector = try XCTUnwrap(
      CIDetector(
        ofType: CIDetectorTypeQRCode, context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
    let features = detector.features(in: CIImage(cgImage: cgImage))
    return (features.first as? CIQRCodeFeature)?.messageString
  }

  /// The round trip: what a camera pointed at the panel would read is the address the engine
  /// handed over, exactly.
  func testTheCodeDecodesBackToTheAddress() throws {
    let image = try XCTUnwrap(RemoteControlQR.image(for: address, points: 148, scale: 2))
    XCTAssertEqual(try decode(image), address.absoluteString)
  }

  /// The same at 1×, since the scale is the display's and a snapshot machine is not this one.
  func testTheCodeDecodesAtOneTimesToo() throws {
    let image = try XCTUnwrap(RemoteControlQR.image(for: address, points: 148, scale: 1))
    XCTAssertEqual(try decode(image), address.absoluteString)
  }

  /// The modules are scaled by a whole number, which is the property the readability rests on: a
  /// fractional multiple puts a module boundary halfway across a pixel, and a smoothed edge is
  /// what a reader gives up on. Asserted through the size — the drawn side is a whole number of
  /// modules, quiet zone included — rather than by reaching into the drawing.
  func testTheCodeIsScaledByAWholeNumberOfPixels() throws {
    let generator = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
    generator.setValue(Data(address.absoluteString.utf8), forKey: "inputMessage")
    generator.setValue("M", forKey: "inputCorrectionLevel")
    let modules = try XCTUnwrap(generator.outputImage).extent.width

    for scale in [CGFloat(1), 2] {
      let image = try XCTUnwrap(RemoteControlQR.image(for: address, points: 148, scale: scale))
      let pixels = (image.size.width * scale).rounded()
      // The zone is two modules each side, so the whole bitmap is `modules + 4` of them.
      XCTAssertEqual(
        pixels.truncatingRemainder(dividingBy: modules + 4), 0, accuracy: 0.001,
        "at \(scale)× the drawn side is a whole number of modules")
    }
  }

  /// It never exceeds the space it was asked for. The factor floors rather than rounds, so a code
  /// whose modules do not divide the panel comes back smaller — which is right, since the panel
  /// is a fixed size and a code overflowing it would be clipped, and a clipped code is unreadable
  /// in a way a slightly smaller one is not.
  func testTheCodeFitsTheSpaceAskedFor() throws {
    for scale in [CGFloat(1), 2] {
      let image = try XCTUnwrap(RemoteControlQR.image(for: address, points: 148, scale: scale))
      XCTAssertLessThanOrEqual(image.size.width, 148)
    }
  }
}
