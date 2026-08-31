import AppKit
import XCTest

@testable import Hukan

/// The menu is where hukan's key equivalents are decided and the only place they are written down
/// — a table in the README or CLAUDE.md would be a second copy going stale in silence — so what a
/// test can usefully hold is the allocation itself: every key spent once, and the browser's four
/// on the keys a browser has them on.
final class MenuKeyTests: XCTestCase {
  /// Every item carrying a key equivalent, anywhere in the tree, as it would be matched: the
  /// character lowercased with the shift an uppercase one implies folded into the modifiers, so
  /// ⌘N and ⌘⇧N read as the two different keys they are.
  private func keyedItems(of menu: NSMenu) -> [(
    key: String, mask: NSEvent.ModifierFlags, item: String
  )] {
    menu.items.flatMap { item -> [(String, NSEvent.ModifierFlags, String)] in
      var found = item.submenu.map(keyedItems) ?? []
      guard !item.keyEquivalent.isEmpty else { return found }
      var mask = item.keyEquivalentModifierMask
      if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
      found.append((item.keyEquivalent.lowercased(), mask, item.title))
      return found
    }
  }

  /// Two items on one key is a shortcut that silently stops working: AppKit matches the first it
  /// walks to, and which one that is depends on the order the menus were built in.
  func testNoKeyIsSpentTwice() {
    var seen: [String: String] = [:]
    for entry in keyedItems(of: AppDelegate.makeMainMenu()) {
      let stroke = "\(entry.mask.rawValue)-\(entry.key)"
      if let taken = seen[stroke] {
        XCTFail("\(entry.item) takes the key \(taken) already has")
      }
      seen[stroke] = entry.item
    }
  }

  /// The web tab's four, on the keys they have everywhere else — ⌘[ / ⌘] for the history, ⌘R for
  /// the reload a page needs because it is the one surface on the desk that FSEvents does not
  /// re-read for you, and ⌘L for the address field.
  func testTheBrowserKeepsABrowsersKeys() {
    let found = keyedItems(of: AppDelegate.makeMainMenu())
      .filter { ["Back", "Forward", "Reload", "Open Location…"].contains($0.item) }
      .map { "\($0.item) \($0.key)" }
      .sorted()
    XCTAssertEqual(found, ["Back [", "Forward ]", "Open Location… l", "Reload r"])
    XCTAssertTrue(
      keyedItems(of: AppDelegate.makeMainMenu())
        .filter { ["Back", "Forward", "Reload", "Open Location…"].contains($0.item) }
        .allSatisfy { $0.mask == [.command] },
      "plain ⌘, the way a browser has them")
  }
}
