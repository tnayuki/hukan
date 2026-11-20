import XCTest

@testable import Hukan

final class ImageCacheTests: XCTestCase {
  private func images(_ names: String...) -> [URL] {
    names.map { URL(fileURLWithPath: "/cache").appendingPathComponent($0) }
  }

  func testANewImageReplacesOnlyItsOwnLine() {
    let cache = images(
      "UniversalMac_27.1_26B100_Restore.ipsw", "UniversalMac_27.2_26C200_Restore.ipsw",
      "ubuntu-24.04.4-desktop-arm64.iso", "ubuntu-24.04.5-desktop-arm64.iso",
      "ubuntu-24.04.5-live-server-arm64.iso", "ubuntu-26.04.1-desktop-arm64.iso",
      "Windows11_26100.4349_ja-jp_arm64.iso", "Windows11_26200.6899_ja-jp_arm64.iso",
      "Windows11_26200.6899_en-us_arm64.iso", "Win11_24H2_Japanese_Arm64.iso")
    func superseded(by name: String) -> [String] {
      MachineStore.superseded(by: images(name)[0], among: cache).map(\.lastPathComponent)
    }
    XCTAssertEqual(
      superseded(by: "UniversalMac_27.2_26C200_Restore.ipsw"),
      ["UniversalMac_27.1_26B100_Restore.ipsw"])
    // The same series and edition only: not the server, not the next LTS.
    XCTAssertEqual(
      superseded(by: "ubuntu-24.04.5-desktop-arm64.iso"), ["ubuntu-24.04.4-desktop-arm64.iso"])
    XCTAssertEqual(superseded(by: "ubuntu-24.04.5-live-server-arm64.iso"), [])
    // The same language only, and never an ISO hukan did not name.
    XCTAssertEqual(
      superseded(by: "Windows11_26200.6899_ja-jp_arm64.iso"),
      ["Windows11_26100.4349_ja-jp_arm64.iso"])
    XCTAssertEqual(superseded(by: "Win11_24H2_Japanese_Arm64.iso"), [])
  }
}
