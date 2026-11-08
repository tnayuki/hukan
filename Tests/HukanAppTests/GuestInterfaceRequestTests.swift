import XCTest

@testable import Hukan

final class GuestInterfaceRequestTests: XCTestCase {
  func testInterfaceToolsMapToGuestOperationsAndKeepArguments() throws {
    let operations = [
      "guest_list_windows": "windows", "guest_ui_tree": "ui_tree", "guest_ui_press": "ui_press",
      "guest_ui_set_value": "ui_set", "guest_click": "click", "guest_type": "type",
      "guest_key": "key",
    ]
    let arguments: [String: Any] = [
      "machine": "host-only", "id": "0.1", "value": "hello", "window": 42, "x": 12.5, "y": 8,
      "modifiers": ["shift"], "op": "untrusted",
    ]
    for (tool, op) in operations {
      let request = try XCTUnwrap(
        WorktreeDeskViewController.interfaceRequest(for: .init(name: tool, arguments: arguments)))
      var expected = arguments
      expected.removeValue(forKey: "machine")
      expected["op"] = op
      XCTAssertEqual(request as NSDictionary, expected as NSDictionary)
      XCTAssertEqual(request["id"] as? String, "0.1")
      XCTAssertNil(request["element"])
    }
  }

  func testOtherToolsDoNotBecomeInterfaceRequests() {
    for name in ["guest_exec", "guest_screenshot", "vm_open", "browser_run", "unknown"] {
      XCTAssertNil(
        WorktreeDeskViewController.interfaceRequest(for: .init(name: name, arguments: [:])))
    }
  }
}
