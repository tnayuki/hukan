import AppKit
import XCTest

@testable import Hukan

final class MachineToolsTests: XCTestCase {
  func testMachineToolSchemasRequireTheirInputs() throws {
    let required: [String: Set<String>] = [
      "vm_open": [], "vm_list": [], "vm_stop": ["machine"], "vm_close": ["machine"],
      "vm_save_template": ["machine", "name"], "vm_set_resolution": ["machine"],
      "guest_exec": ["machine", "command"], "guest_read_file": ["machine", "path"],
      "guest_write_file": ["machine", "path", "content"], "guest_screenshot": ["machine"],
      "guest_list_windows": ["machine"], "guest_ui_tree": ["machine"],
      "guest_ui_press": ["machine", "id"], "guest_ui_set_value": ["machine", "id", "value"],
      "guest_click": ["machine", "x", "y"], "guest_type": ["machine", "text"],
      "guest_key": ["machine", "key"],
    ]
    XCTAssertEqual(Set(HukanMCP.machineTools.map(\.name)), Set(required.keys))
    XCTAssertEqual(HukanMCP.machineTools.count, required.count)
    for tool in HukanMCP.machineTools {
      XCTAssertEqual(Set(tool.inputSchema["required"] as? [String] ?? []), required[tool.name])
      let properties = try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
      XCTAssertTrue(required[tool.name]!.isSubset(of: Set(properties.keys)))
      XCTAssertEqual(tool.inputSchema["additionalProperties"] as? Bool, false)
      if ["vm_stop", "vm_close", "vm_save_template"].contains(tool.name) {
        XCTAssertTrue(tool.description.lowercased().contains("the user is asked"))
      }
    }
  }

  func testEachMachineActAsksItsOwnQuestion() {
    func labels(_ view: NSView) -> [String] {
      (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
    }
    let questions = [
      "Let the agent use “macOS”?", "Let the agent open a virtual machine from “macOS”?",
      "Let the agent stop “macOS”?", "Let the agent delete “macOS”?",
      "Let the agent save “With tools” as a template?",
    ]
    for (index, question) in questions.enumerated() {
      var grant = PendingGrant(
        tabID: UUID(), title: "macOS", url: "With tools", level: .drive, machine: true,
        decide: { _ in })
      grant.opening = index == 1
      grant.stopping = index == 2
      grant.closing = index == 3
      grant.saving = index == 4
      let card = GrantCard(grant: grant, onDecision: { _ in })
      XCTAssertTrue(labels(card).contains(question), question)
    }
  }
}
