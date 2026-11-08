import XCTest

@testable import Hukan

final class VirtualMachinesWindowTests: XCTestCase {
  func testRestoreImageTitles() {
    XCTAssertEqual(VirtualMachinesWindowController.imageTitle(name: nil), "macOS")
    for name in ["UniversalMac_27.0_26A123_Restore.ipsw", "UniversalMac_27.0_26A123_Restore.IPSW"] {
      XCTAssertEqual(VirtualMachinesWindowController.imageTitle(name: name), "macOS 27.0 (26A123)")
    }
    for name in ["Windows.iso", "custom.ipsw", "UniversalMac_27.ipsw", "Other_27_build.ipsw"] {
      XCTAssertEqual(VirtualMachinesWindowController.imageTitle(name: name), name)
    }
  }
}
