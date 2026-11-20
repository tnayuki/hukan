import XCTest

@testable import Hukan

final class VirtualMachinesWindowTests: XCTestCase {
  func testRestoreImageTitles() {
    for name in ["UniversalMac_27.0_26A123_Restore.ipsw", "UniversalMac_27.0_26A123_Restore.IPSW"] {
      XCTAssertEqual(
        VirtualMachinesWindowController.imageTitle(URL(fileURLWithPath: name)),
        "macOS 27.0 (26A123)")
    }
    for name in ["Windows.iso", "custom.ipsw", "UniversalMac_27.ipsw", "Other_27_build.ipsw"] {
      XCTAssertEqual(VirtualMachinesWindowController.imageTitle(URL(fileURLWithPath: name)), name)
    }
  }
}
