import XCTest

@testable import Hukan

final class WindowsImageTests: XCTestCase {
  /// An ISO's first sectors as `hdiutil` leaves them: an El Torito boot record at sector 17 naming
  /// a catalog at sector 24, whose default entry says 4 sectors.
  private func isoWithBootCatalog() throws -> URL {
    var data = Data(count: 26 * 2048)
    let record = 17 * 2048
    data[record] = 0
    data.replaceSubrange((record + 1)..<(record + 6), with: Data("CD001".utf8))
    data[record + 6] = 1
    data.replaceSubrange(
      (record + 7)..<(record + 30), with: Data("EL TORITO SPECIFICATION".utf8))
    data.replaceSubrange((record + 0x47)..<(record + 0x4B), with: Data([24, 0, 0, 0]))
    let catalog = 24 * 2048
    data[catalog] = 1
    data[catalog + 1] = 0xEF
    data[catalog + 32] = 0x88
    data.replaceSubrange((catalog + 38)..<(catalog + 40), with: Data([4, 0]))
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("hukan-eltorito-\(UUID().uuidString).iso")
    try data.write(to: url)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func testTheBootEntryCoversTheWholeBootImage() throws {
    let iso = try isoWithBootCatalog()
    try WindowsImage.setBootImageSectors(in: iso, to: 1_720_320 / 512)
    let data = try Data(contentsOf: iso)
    let catalog = 24 * 2048
    XCTAssertEqual(Int(data[catalog + 38]) | Int(data[catalog + 39]) << 8, 3360)
    // Nothing else in the entry moves: still bootable, still no emulation.
    XCTAssertEqual(data[catalog + 32], 0x88)
    XCTAssertEqual(data[catalog + 33], 0)
    XCTAssertEqual(data[catalog + 1], 0xEF)
  }

  func testAnImageWithoutABootRecordIsRefused() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("hukan-noboot-\(UUID().uuidString).iso")
    try Data(count: 20 * 2048).write(to: url)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    XCTAssertThrowsError(try WindowsImage.setBootImageSectors(in: url, to: 3360))
  }

  func testTheCatalogHasEveryImageOnce() {
    let languages = WindowsCatalog.images.map(\.language)
    XCTAssertEqual(Set(languages).count, languages.count)
    XCTAssertTrue(languages.contains("en-us"))
    for image in WindowsCatalog.images {
      XCTAssertEqual(image.sha256.count, 64)
      XCTAssertEqual(image.url.host, "dl.delivery.mp.microsoft.com")
      XCTAssertTrue(image.isoName.hasPrefix("Windows11_\(WindowsCatalog.build)_"))
    }
  }
}
