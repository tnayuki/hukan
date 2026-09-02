import AppKit
import XCTest

@testable import Hukan

/// The two readings the update check is made of: what the cask says, and whether that is ahead.
/// Neither is allowed to reach the network — the request itself is one fixed GET and there is
/// nothing in it to test — so what is pinned here is the parse and the ordering, which are the
/// two places a wrong answer would be silent.
final class AppUpdateTests: XCTestCase {
  /// The real file's shape, down to the comment block the version line sits under: this is the
  /// line the release workflow writes, and the parse is a match on it rather than a Ruby reader.
  private let cask = """
    # typed: false
    # frozen_string_literal: true

    cask "hukan" do
      version "0.4.4"
      sha256 "724337ede22c728b0c9a3b3920af0ec3e877cd8ab698faab991a2897bd3b9d23"

      url "https://github.com/tnayuki/hukan/releases/download/v#{version}/Hukan.zip"
      name "hukan"
    end
    """

  func testTheVersionIsReadOffTheCask() {
    XCTAssertEqual(AppUpdate.version(inCask: cask), "0.4.4")
  }

  /// A cask reformatted past recognition answers nothing rather than a guess — the toolbar shows
  /// an item only for a version it actually read, so "no answer" has to stay distinguishable.
  func testAnUnrecognisableCaskAnswersNothing() {
    XCTAssertNil(AppUpdate.version(inCask: "cask \"hukan\" do\nend"))
    XCTAssertNil(AppUpdate.version(inCask: ""))
    XCTAssertNil(AppUpdate.version(inCask: "  version \"\"\n"))
  }

  /// `sha256` also begins with a quoted value on its own line, and `url` carries the version
  /// interpolated into it. Neither may be mistaken for the version line.
  func testOnlyTheVersionLineIsRead() {
    let reordered = """
      cask "hukan" do
        sha256 "724337ede22c728b0c9a3b3920af0ec3e877cd8ab698faab991a2897bd3b9d23"
        url "https://example.com/v0.9.9/Hukan.zip"
        version "0.4.4"
      end
      """
    XCTAssertEqual(AppUpdate.version(inCask: reordered), "0.4.4")
  }

  /// Numerically, the Finder's rule. The dictionary's would put 0.10.0 below 0.9.0 and hold the
  /// toolbar's item back for the whole of a release series.
  func testVersionsCompareNumericallyRatherThanLexically() {
    XCTAssertEqual(AppUpdate.compare("0.4.4", "0.4.3"), .orderedDescending)
    XCTAssertEqual(AppUpdate.compare("0.10.0", "0.9.0"), .orderedDescending)
    XCTAssertEqual(AppUpdate.compare("0.4.3", "0.4.4"), .orderedAscending)
    XCTAssertEqual(AppUpdate.compare("0.4.4", "0.4.4"), .orderedSame)
  }

  /// The command is what the design turns on, so its two load-bearing halves are pinned: the cask
  /// is named in full (which is what drops Homebrew's auto-update interval from 24 hours to 5
  /// minutes, so a release published today is upgradable today), and nothing quits.
  func testTheUpgradeCommandNamesTheTapInFull() {
    XCTAssertTrue(AppUpdate.upgradeCommand.contains("tnayuki/hukan/hukan"))
    XCTAssertFalse(AppUpdate.upgradeCommand.contains("quit"))
    // It goes into an AppleScript string literal, so a double quote would end that literal early.
    XCTAssertFalse(AppUpdate.upgradeCommand.contains("\""))
  }
}

/// What the bar does with an answer — the half the parse tests cannot reach. The check itself is
/// one fixed GET, so the version is put in directly rather than served.
final class AppUpdateToolbarTests: XCTestCase {
  @MainActor
  override func tearDown() {
    // The checker is app-wide, so a version left in it would follow the next test into its window.
    AppUpdate.shared.apply(AppUpdate.shared.runningVersion)
    super.tearDown()
  }

  @MainActor
  func testTheItemAppearsOnlyWhileAReleaseIsAhead() throws {
    let workspace = RailPreviewTests.sampleWorkspace()
    let controller = WorkspaceWindowController(workspace: workspace)
    let window = try XCTUnwrap(controller.window)
    window.setFrame(NSRect(x: 0, y: -4000, width: 1600, height: 800), display: true)
    window.makeKeyAndOrderFront(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))

    let toolbar = try XCTUnwrap(window.toolbar)
    func item() throws -> NSToolbarItem {
      try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == .appUpdate })
    }

    // A build that is current says nothing at all.
    AppUpdate.shared.apply(AppUpdate.shared.runningVersion)
    XCTAssertTrue(try item().isHidden)

    AppUpdate.shared.apply("99.0.0")
    XCTAssertFalse(try item().isHidden)
    // Both numbers are in the tooltip, since the glyph can only carry that there is something to do.
    let tip = try XCTUnwrap(item().toolTip)
    XCTAssertTrue(tip.contains("99.0.0"))
    XCTAssertTrue(tip.contains(AppUpdate.shared.runningVersion))

    // And it goes again once the running build catches up — a released version that is merely
    // equal is not an update.
    AppUpdate.shared.apply(AppUpdate.shared.runningVersion)
    XCTAssertTrue(try item().isHidden)
    window.close()
  }
}
