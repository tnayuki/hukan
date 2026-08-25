import AppKit
import XCTest

@testable import Hukan

/// The panel's chrome lives in the toolbar's row over it, so the panel cannot be narrower than
/// that row: squeeze it and the filter runs out past the panel's leading edge into the content
/// section, reading as a field belonging to nothing. The minimum was measured for three items and
/// has to be re-measured whenever one is added — which is what this asserts, so the next button
/// fails here rather than silently spilling.
///
/// Both display modes, because the row's width is one of them: the bar's own right-click menu
/// offers `Icon and Text`, and the caption it writes under every glyph is what the floors in
/// `filesPanelMinimumWidth(labelled:)` are paying for. The rail is measured on the same run —
/// what runs out of room there is its own filter, and an item that no longer fits is moved to
/// the overflow menu rather than shrunk, so the field does not narrow, it disappears.
final class ToolbarRowFitsTests: XCTestCase {
  @MainActor
  func testTheFilesRowFitsThePanelAtItsMinimumWidth() throws {
    try assertTheRowsFit(labelled: false)
  }

  @MainActor
  func testTheFilesRowFitsThePanelWithLabelsUnderTheGlyphs() throws {
    try assertTheRowsFit(labelled: true)
  }

  /// The floors are only half of it: the promise is that a window already open at the icon
  /// widths widens itself when the captions arrive, and hands the width back when they go. A
  /// panel that stayed at 280 would spill exactly as it did before there were two numbers, and
  /// one that kept the widened width would carry a mode that is never saved into every window
  /// after it.
  @MainActor
  func testTheColumnsFollowTheDisplayModeWhileTheWindowIsOpen() throws {
    let workspace = RailPreviewTests.sampleWorkspace()
    let controller = WorkspaceWindowController(workspace: workspace)
    let window = try XCTUnwrap(controller.window)
    workspace.selectedWorktreeID = workspace.worktrees.first?.id
    controller.reload()
    window.setFrame(NSRect(x: 0, y: -4000, width: 1600, height: 800), display: true)
    window.makeKeyAndOrderFront(nil)
    controller.arrangeColumnsIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))

    let toolbar = try XCTUnwrap(window.toolbar)
    let columns = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
    let panelItem = try XCTUnwrap(columns.splitViewItems.last)
    let panelView = panelItem.viewController.view
    func panelWidth() -> CGFloat { panelView.convert(panelView.bounds, to: nil).width }

    columns.splitView.setPosition(
      window.frame.width - WorkspaceWindowController.filesPanelMinimumWidth(labelled: false),
      ofDividerAt: 1)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    let narrow = panelWidth()
    let recorded = workspace.columnWidths

    toolbar.displayMode = .iconAndLabel
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    XCTAssertGreaterThanOrEqual(
      panelWidth(), WorkspaceWindowController.filesPanelMinimumWidth(labelled: true),
      "the panel stayed at \(panelWidth()) when the captions arrived")
    XCTAssertEqual(
      workspace.columnWidths, recorded,
      "the width the mode's floor forced was recorded as though it had been dragged there")

    toolbar.displayMode = .iconOnly
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    XCTAssertEqual(
      panelWidth(), narrow, accuracy: 1,
      "the panel kept the captions' width after the bar went back to icons")
  }

  /// The rail's toggle sits at the rail's trailing edge — against the divider it moves — however
  /// wide the rail is. The section is packed from its leading edge, and that edge is not a fixed
  /// distance from the divider: the traffic lights take the first ~70pt of it in a window and
  /// none of it in full screen, so a toggle placed by what precedes it landed in the middle of
  /// the rail the moment the lights went. A rail wider than its minimum opens the same gap in a
  /// window, which is what is measured here.
  @MainActor
  func testTheRailToggleKeepsTheRailsTrailingEdge() throws {
    let workspace = RailPreviewTests.sampleWorkspace()
    let controller = WorkspaceWindowController(workspace: workspace)
    let window = try XCTUnwrap(controller.window)
    workspace.selectedWorktreeID = workspace.worktrees.first?.id
    controller.reload()
    window.setFrame(NSRect(x: 0, y: -4000, width: 1600, height: 800), display: true)
    window.makeKeyAndOrderFront(nil)
    controller.arrangeColumnsIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))

    let columns = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
    let railView = try XCTUnwrap(columns.splitViewItems.first).viewController.view
    func railEdge() -> CGFloat { railView.convert(railView.bounds, to: nil).maxX }
    func toggleEdge() throws -> CGFloat {
      let toggle = try XCTUnwrap(
        sidebarToggle(in: try XCTUnwrap(window.contentView?.superview)),
        "no sidebar toggle in the toolbar")
      return toggle.convert(toggle.bounds, to: nil).maxX
    }

    for width in [WorkspaceWindowController.railMinimumWidth(labelled: false), 420] {
      columns.splitView.setPosition(width, ofDividerAt: 0)
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))
      let gap = railEdge() - (try toggleEdge())
      XCTAssertGreaterThanOrEqual(gap, 0, "the toggle runs past the rail's edge at \(width)pt")
      XCTAssertLessThan(
        gap, 24, "the toggle sits \(gap)pt in from the rail's trailing edge at \(width)pt")
    }
  }

  /// The toggle AppKit builds for `.toggleSidebar`: a button in the bar wired to the split view
  /// controller's own action, which is the one thing that names it.
  private func sidebarToggle(in view: NSView) -> NSView? {
    if let button = view as? NSButton,
      button.action == #selector(NSSplitViewController.toggleSidebar(_:))
    {
      return button
    }
    for subview in view.subviews {
      if let found = sidebarToggle(in: subview) { return found }
    }
    return nil
  }

  @MainActor
  private func assertTheRowsFit(labelled: Bool) throws {
    let workspace = RailPreviewTests.sampleWorkspace()
    let controller = WorkspaceWindowController(workspace: workspace)
    let window = try XCTUnwrap(controller.window)
    workspace.selectedWorktreeID = workspace.worktrees.first?.id
    controller.reload()
    let toolbar = try XCTUnwrap(window.toolbar)
    toolbar.displayMode = labelled ? .iconAndLabel : .iconOnly
    // Parked below every screen: a test run should not flash a window over the desktop. Wide
    // enough for both modes' floors, since the point is the columns at their minimums and not
    // the window at its own.
    window.setFrame(NSRect(x: 0, y: -4000, width: 1600, height: 800), display: true)
    window.makeKeyAndOrderFront(nil)
    controller.arrangeColumnsIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))

    let filter = try XCTUnwrap(
      toolbar.items.first { $0.itemIdentifier == .filesFilter }?.view)
    let columns = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
    let panelItem = try XCTUnwrap(columns.splitViewItems.last)
    let railItem = try XCTUnwrap(columns.splitViewItems.first)

    XCTAssertEqual(
      panelItem.minimumThickness,
      WorkspaceWindowController.filesPanelMinimumWidth(labelled: labelled),
      "the panel's floor did not follow the display mode")

    // Drag both edges as narrow as they go. Nothing else puts them there — a narrow window leaves
    // them at their default widths — and the tight case is each column on its own minimum, since
    // that is the width its row was measured against.
    columns.splitView.setPosition(railItem.minimumThickness, ofDividerAt: 0)
    columns.splitView.setPosition(
      window.frame.width - panelItem.minimumThickness / 2, ofDividerAt: 1)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))

    let panelView = panelItem.viewController.view
    let panel = panelView.convert(panelView.bounds, to: nil)
    let field = try XCTUnwrap(filter.superview).convert(filter.frame, to: nil)

    XCTAssertGreaterThanOrEqual(
      field.minX, panel.minX,
      "the files filter starts at \(field.minX), left of the panel's \(panel.minX) — the row no "
        + "longer fits the panel's minimum width in \(labelled ? "Icon and Text" : "Icon Only")")

    let visible = Set(toolbar.visibleItems?.map(\.itemIdentifier) ?? [])
    XCTAssertTrue(
      visible.contains(.sessionFilter),
      "the rail's filter was dropped into the overflow menu at the rail's minimum width in "
        + "\(labelled ? "Icon and Text" : "Icon Only")")
  }
}
