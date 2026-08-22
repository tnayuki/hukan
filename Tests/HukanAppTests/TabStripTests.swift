import AppKit
import XCTest

@testable import Hukan

/// The tab strip past the point where the tabs stop fitting: it scrolls rather than squeezing
/// every label into a sliver, and the tab in play is scrolled back into sight. The strip's order
/// — what a drag makes of it, where a new tab goes, where closing one lands — is here too, driven
/// through `moveTab` since a drag session needs a pointer. Plus the ⌃⇥ / ⌃⇧⇥ match, which the
/// Window menu could not make (see `tabCyclingMonitor`).
final class TabStripTests: XCTestCase {
  /// A desk in a window of `width`, holding `files` lasting tabs on one worktree.
  private func desk(width: CGFloat, files: Int) -> (WorktreeDeskViewController, NSScrollView) {
    let workspace = Workspace()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let worktree = workspace.addWorktree(root)

    let desk = WorktreeDeskViewController()
    desk.workspace = workspace
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = desk.view
    desk.reload(worktreeID: worktree.id)

    for i in 0..<files {
      let name = "ReasonablyLongFileName\(i).swift"
      try? "let a = \(i)\n".write(
        to: root.appendingPathComponent(name), atomically: true,
        encoding: .utf8)
      desk.openFile(worktree: worktree, path: name, preview: false)
    }
    desk.view.layoutSubtreeIfNeeded()
    return (desk, scrollView(in: desk.view)!)
  }

  private func scrollView(in view: NSView) -> NSScrollView? {
    for subview in view.subviews {
      if let scroll = subview as? NSScrollView, scroll.documentView is NSStackView { return scroll }
      if let found = scrollView(in: subview) { return found }
    }
    return nil
  }

  /// Where a tab's button sits in the strip's own coordinates — a button's frame is its row's,
  /// two views down from the document, so it has to be converted before it can be compared with
  /// what is scrolled into view.
  private func tabRect(_ title: String, in scroll: NSScrollView) -> NSRect? {
    guard let button = tabButton(title, in: scroll), let document = scroll.documentView else {
      return nil
    }
    return button.convert(button.bounds, to: document)
  }

  /// Every button in the strip, by title — the tabs are views, so this is how one is found.
  private func tabButton(_ title: String, in scroll: NSScrollView) -> NSButton? {
    func walk(_ view: NSView) -> NSButton? {
      if let button = view as? NSButton, button.title == title { return button }
      for subview in view.subviews { if let found = walk(subview) { return found } }
      return nil
    }
    return scroll.documentView.flatMap(walk)
  }

  /// The strip used to answer a crowd of tabs by compressing all of them at once; now the tabs
  /// keep their width and the strip runs past the column, which is the thing that can be scrolled.
  func testManyTabsOverflowTheStripRatherThanSqueezingIt() {
    let (_, scroll) = desk(width: 600, files: 12)
    let content = scroll.documentView?.frame.width ?? 0
    XCTAssertGreaterThan(
      content, scroll.contentView.bounds.width,
      "twelve tabs in a 600pt desk should outrun the strip, not fit inside it")
    // Not squeezed: the first tab still reads as a file name rather than as an ellipsis.
    let first = tabButton("ReasonablyLongFileName0.swift", in: scroll)
    XCTAssertNotNil(first)
    XCTAssertGreaterThan(
      first?.frame.width ?? 0, 100, "a tab keeps its natural width once the strip can scroll")
  }

  /// Opening the twelfth tab scrolls it into view; picking the first scrolls back to it. A
  /// selection off the end of the strip is the same as no selection.
  func testTheSelectedTabIsScrolledIntoView() {
    let (desk, scroll) = desk(width: 600, files: 12)
    let last = tabRect("ReasonablyLongFileName11.swift", in: scroll)
    XCTAssertNotNil(last)
    XCTAssertTrue(
      scroll.documentVisibleRect.contains(last ?? .zero),
      "the tab just opened is off the end of the strip: \(scroll.documentVisibleRect)")
    XCTAssertGreaterThan(scroll.contentView.bounds.origin.x, 0, "the strip scrolled to reach it")

    desk.selectTab(at: 0)
    desk.view.layoutSubtreeIfNeeded()
    let first = tabRect("ReasonablyLongFileName0.swift", in: scroll)
    XCTAssertTrue(
      scroll.documentVisibleRect.contains(first ?? .zero),
      "⌘1 should bring the first tab back: \(scroll.documentVisibleRect)")
  }

  /// A strip that fits still starts at the left, with the spacer taking the slack — the scroll
  /// view must not turn a two-tab desk into something that can be scrolled away from.
  func testAStripThatFitsDoesNotScroll() {
    let (_, scroll) = desk(width: 900, files: 2)
    XCTAssertLessThanOrEqual(
      scroll.documentView?.frame.width ?? 0, scroll.contentView.bounds.width,
      "two tabs fit inside the clip, so there is nothing to scroll to")
  }

  /// The strip's labels in reading order — what a drag rearranges, and what ⌘1…⌘9 count in.
  private func titles(in scroll: NSScrollView) -> [String] {
    func walk(_ view: NSView) -> [String] {
      // The ✕ beside each label is a button too, image-only; the labels are what read.
      if let button = view as? NSButton, button.imagePosition != .imageOnly {
        return [button.title]
      }
      return view.subviews.flatMap(walk)
    }
    return (scroll.documentView as? NSStackView)?.arrangedSubviews.flatMap(walk) ?? []
  }

  private func name(_ i: Int) -> String { "ReasonablyLongFileName\(i).swift" }

  /// The label wearing the selection: the one set in semibold.
  private func selectedTitle(in scroll: NSScrollView) -> String? {
    func walk(_ view: NSView) -> String? {
      if let button = view as? NSButton, button.imagePosition != .imageOnly,
        let font = button.font, NSFontManager.shared.weight(of: font) > 5
      {
        return button.title
      }
      for subview in view.subviews { if let found = walk(subview) { return found } }
      return nil
    }
    return scroll.documentView.flatMap(walk)
  }

  /// A tab dropped into a gap takes it, and the numbering follows: ⌘1 is whatever now stands
  /// first. Dropping a tab into its own gap — either side of it — moves nothing.
  func testADraggedTabTakesTheGapItWasDroppedIn() {
    let (desk, scroll) = desk(width: 900, files: 4)
    XCTAssertEqual(titles(in: scroll), [name(0), name(1), name(2), name(3)])

    desk.moveTab(at: 3, to: 0)
    XCTAssertEqual(titles(in: scroll), [name(3), name(0), name(1), name(2)])
    desk.moveTab(at: 0, to: 4)
    XCTAssertEqual(titles(in: scroll), [name(0), name(1), name(2), name(3)], "to the end")
    desk.moveTab(at: 1, to: 3)
    XCTAssertEqual(titles(in: scroll), [name(0), name(2), name(1), name(3)], "one to the right")

    desk.moveTab(at: 1, to: 1)
    desk.moveTab(at: 1, to: 2)
    XCTAssertEqual(titles(in: scroll), [name(0), name(2), name(1), name(3)], "its own gap")

    desk.selectTab(at: 0)
    XCTAssertEqual(selectedTitle(in: scroll), name(0))
    desk.selectTab(at: 1)
    XCTAssertEqual(selectedTitle(in: scroll), name(2), "⌘2 counts the strip as it reads now")
  }

  /// The order is the order opened, whatever kind a tab is, and a tab opened after a drag goes
  /// to the end of the strip rather than back among its own kind.
  func testANewTabOpensAtTheEndOfTheStrip() {
    let (desk, scroll) = desk(width: 900, files: 3)
    desk.moveTab(at: 2, to: 0)
    let worktree = desk.workspace!.worktrees[0]
    try? "let d = 4\n".write(
      to: worktree.url.appendingPathComponent(name(4)), atomically: true, encoding: .utf8)
    desk.openFile(worktree: worktree, path: name(4), preview: false)
    desk.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(titles(in: scroll), [name(2), name(0), name(1), name(4)])
  }

  /// Closing the active tab lands on the one to its right in the strip as it stood — the
  /// browser's rule — and on the one to its left when it was the last.
  func testClosingTheActiveTabLandsOnItsNeighbour() {
    let (desk, scroll) = desk(width: 900, files: 4)
    desk.moveTab(at: 3, to: 0)
    desk.selectTab(at: 1)
    XCTAssertEqual(selectedTitle(in: scroll), name(0))

    desk.closeActiveTab()
    XCTAssertEqual(titles(in: scroll), [name(3), name(1), name(2)])
    XCTAssertEqual(selectedTitle(in: scroll), name(1), "the right-hand neighbour")

    desk.selectTab(at: 2)
    desk.closeActiveTab()
    XCTAssertEqual(selectedTitle(in: scroll), name(1), "the last tab closed lands to its left")
  }

  /// After a relaunch the saved tabs stand where they stood: the order is rebuilt from the rows
  /// naming each tab's kind, walked against the two lists that were saved in strip order — and
  /// it is that order the strip reports back for saving again.
  func testRestoredTabsTakeTheOrderTheyWereSavedIn() {
    let (desk, scroll) = desk(width: 900, files: 0)
    let workspace = desk.workspace!
    let worktree = workspace.worktrees[0]
    let shellA = TerminalSession(worktreeID: worktree.id, cwd: worktree.url)
    let shellB = TerminalSession(worktreeID: worktree.id, cwd: worktree.url)
    workspace.terminals = [shellA, shellB]
    desk.restoreBrowserTabs([
      BrowserTabState(
        worktreeID: worktree.id, url: "https://a.example", title: "A", interactionState: nil),
      BrowserTabState(
        worktreeID: worktree.id, url: "https://b.example", title: "B", interactionState: nil),
    ])
    desk.reload(worktreeID: worktree.id)
    XCTAssertEqual(titles(in: scroll).count, 4)

    // Saved as: B, shell A, A, shell B — the web tabs and terminals each in that order.
    desk.restoreTabOrder([
      .init(worktreeID: worktree.id, kind: .browser),
      .init(worktreeID: worktree.id, kind: .terminal),
      .init(worktreeID: worktree.id, kind: .browser),
      .init(worktreeID: worktree.id, kind: .terminal),
    ])
    let expected = ["A", shellA.title, "B", shellB.title]
    XCTAssertEqual(titles(in: scroll), expected)

    desk.moveTab(at: 3, to: 0)
    XCTAssertEqual(titles(in: scroll), [shellB.title, "A", shellA.title, "B"])
    XCTAssertEqual(
      desk.restorableTabOrder.map(\.kind), [.terminal, .browser, .terminal, .browser],
      "the rows report the strip as it stands")
    XCTAssertEqual(
      desk.restorableTerminals(workspace.terminals).map(\.id), [shellB.id, shellA.id],
      "and the terminals are handed over in that order")
    XCTAssertEqual(desk.restorableBrowserTabs.map(\.title), ["A", "B"])
  }

  /// Where a drop lands is read off the tabs' middles: over the near half of a tab the drop is
  /// before it, over the far half it is after, and past the last tab it is the end.
  func testTheDropGapFollowsTheTabMiddles() throws {
    let (_, scroll) = desk(width: 900, files: 3)
    let strip = try XCTUnwrap(scroll.documentView as? TabStrip)
    XCTAssertEqual(strip.tabViews.count, 3)
    let middle = strip.tabViews[1].frame
    XCTAssertEqual(strip.dropIndex(at: NSPoint(x: middle.midX - 1, y: middle.midY)), 1)
    XCTAssertEqual(strip.dropIndex(at: NSPoint(x: middle.midX + 1, y: middle.midY)), 2)
    XCTAssertEqual(strip.dropIndex(at: NSPoint(x: 0, y: middle.midY)), 0)
    XCTAssertEqual(strip.dropIndex(at: NSPoint(x: strip.frame.maxX, y: middle.midY)), 3)
  }

  /// ⌃⇥ forward, ⌃⇧⇥ back. Matched on the Tab key's code: Shift-Tab arrives as 0x19, which is
  /// why the menu item's `"\t"` never matched it and ⌃⇧⇥ did nothing at all.
  func testTabCycleDeltaMatchesControlTabBothWays() {
    func key(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String) -> NSEvent {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
        keyCode: keyCode)!
    }
    XCTAssertEqual(WorkspaceWindowController.tabCycleDelta(for: key(48, [.control], "\t")), 1)
    XCTAssertEqual(
      WorkspaceWindowController.tabCycleDelta(for: key(48, [.control, .shift], "\u{19}")), -1)
    // A bare Tab is focus traversal, ⌘⇥ is the app switcher's, and no other key is the strip's.
    XCTAssertNil(WorkspaceWindowController.tabCycleDelta(for: key(48, [], "\t")))
    XCTAssertNil(WorkspaceWindowController.tabCycleDelta(for: key(48, [.command], "\t")))
    XCTAssertNil(
      WorkspaceWindowController.tabCycleDelta(for: key(48, [.control, .option], "\t")))
    XCTAssertNil(WorkspaceWindowController.tabCycleDelta(for: key(0, [.control], "a")))
  }
}
