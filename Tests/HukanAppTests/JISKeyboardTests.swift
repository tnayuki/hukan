import AppKit
import XCTest

@testable import Hukan

final class JISKeyboardTests: XCTestCase {
  private func event(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code
    )!
  }

  func testJISSymbolsBecomeTheANSIStrokesThatPrintThem() throws {
    let table: [(UInt16, Bool, UInt16, Bool, Bool)] = [
      (19, true, 39, true, false), (22, true, 26, true, false),
      (26, true, 39, false, false), (28, true, 25, true, false),
      (25, true, 29, true, false), (27, true, 24, false, false),
      (24, false, 22, true, false), (24, true, 50, true, false),
      (93, false, 16, false, true), (93, true, 42, true, false),
      (33, false, 19, true, false), (33, true, 50, false, false),
      (30, false, 33, false, false), (30, true, 33, true, false),
      (41, true, 24, true, false), (39, false, 41, true, false),
      (39, true, 28, true, false), (42, false, 30, false, false),
      (42, true, 30, true, false), (94, false, 27, true, false),
      (94, true, 27, true, false),
    ]
    for (code, shift, target, targetShift, option) in table {
      let key = event(code, shift ? .shift : [])
      let translated = try XCTUnwrap(MachineScreenView.translation(of: key, isJIS: true))
      XCTAssertEqual(translated.code, target)
      XCTAssertEqual(translated.shift, targetShift)
      XCTAssertEqual(translated.option, option)
      XCTAssertNil(MachineScreenView.translation(of: key, isJIS: false))
      for shortcut: NSEvent.ModifierFlags in [.command, .control] {
        XCTAssertNil(
          MachineScreenView.translation(
            of: event(code, key.modifierFlags.union(shortcut)), isJIS: true))
      }
    }
  }

  func testOptionYenIsBackslashAndOtherOptionStrokesAreUntouched() throws {
    let translated = try XCTUnwrap(
      MachineScreenView.translation(of: event(93, .option), isJIS: true))
    XCTAssertEqual(translated.code, 42)
    XCTAssertFalse(translated.shift)
    XCTAssertFalse(translated.option)
    for flags: NSEvent.ModifierFlags in [
      [.option, .shift], [.option, .command], [.option, .control],
    ] {
      XCTAssertNil(MachineScreenView.translation(of: event(93, flags), isJIS: true))
    }
    XCTAssertNil(MachineScreenView.translation(of: event(93, .option), isJIS: false))
    for code: UInt16 in [0, 18, 36, 49] {
      for flags: NSEvent.ModifierFlags in [[], .shift, .option] {
        XCTAssertNil(MachineScreenView.translation(of: event(code, flags), isJIS: true))
      }
    }
  }

  func testInputSourceKeysSelectEnglishAndJapaneseWithoutRepeating() {
    let view = MachineScreenView()
    var selections: [Bool] = []
    view.onInputSourceKey = { selections.append($0) }
    view.keyDown(with: event(102))
    view.keyUp(with: event(102))
    view.keyDown(with: event(104))
    view.keyUp(with: event(104))
    let repeated = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: true, keyCode: 104)!
    view.keyDown(with: repeated)
    XCTAssertEqual(selections, [false, true])
  }
}
