import XCTest

@testable import Hukan

/// The header picker's display contract: the glyph alone carries the default value, and text
/// appears only when the selection departs from it — so an all-default header reads as a row of
/// quiet glyphs, never "Default Auto Default".
final class HeaderPickerTests: XCTestCase {
  func testDefaultSelectionShowsGlyphOnly() {
    let picker = HeaderPicker(symbol: "gauge.medium")
    picker.setTitles(["Default", "Low", "High"], defaultAt: 0)
    XCTAssertEqual(picker.title, "")
    XCTAssertEqual(picker.imagePosition, .imageOnly)
  }

  func testDepartedSelectionSpellsItsValue() {
    let picker = HeaderPicker(symbol: "gauge.medium")
    picker.setTitles(["Default", "Low", "High"], defaultAt: 0)
    picker.select(2)
    XCTAssertEqual(picker.title, "High")
    XCTAssertEqual(picker.imagePosition, .imageLeft)
    // Returning to the default goes quiet again.
    picker.select(0)
    XCTAssertEqual(picker.title, "")
    XCTAssertEqual(picker.imagePosition, .imageOnly)
  }

  func testDefaultMaySitMidList() {
    let picker = HeaderPicker(symbol: "shield.lefthalf.filled")
    picker.setTitles(["Bypass", "Auto", "Plan"], defaultAt: 1)
    XCTAssertEqual(picker.title, "")
    picker.select(0)
    XCTAssertEqual(picker.title, "Bypass")
  }

  func testSetTitlesResetsSelectionToItsDefault() {
    let picker = HeaderPicker(symbol: "sparkles")
    picker.setTitles(["Default", "Opus"], defaultAt: 0)
    picker.select(1)
    // A roster refresh replaces the list; the selection resets to the default until the caller
    // reflects the session's actual value with select().
    picker.setTitles(["Default", "Opus", "Fable"], defaultAt: 0)
    XCTAssertEqual(picker.title, "")
    XCTAssertEqual(picker.imagePosition, .imageOnly)
  }

  func testOutOfRangeIndicesAreClampedOrIgnored() {
    let picker = HeaderPicker(symbol: "sparkles")
    // A bad default falls back to the first entry.
    picker.setTitles(["A", "B"], defaultAt: 5)
    XCTAssertEqual(picker.title, "")
    // A bad select leaves the selection where it was.
    picker.select(9)
    XCTAssertEqual(picker.title, "")
    picker.select(1)
    picker.select(-1)
    XCTAssertEqual(picker.title, "B")
  }
}
