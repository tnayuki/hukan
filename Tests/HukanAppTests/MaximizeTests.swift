import AppKit
import XCTest

@testable import Hukan

/// One column taking the whole window — the desk's tab and the rail's conversation, which are the
/// same act. Driven through a real `WorkspaceWindowController`, because the columns are the
/// window's: there is nothing below it that folds. The folds are read back from `showingColumns`
/// rather than from the screen, so nothing here depends on the window being visible.
final class MaximizeTests: XCTestCase {
  private func openWindow() -> (WorkspaceWindowController, Workspace, NSWindow) {
    let workspace = RailPreviewTests.sampleWorkspace()
    let controller = WorkspaceWindowController(workspace: workspace)
    let window = controller.window!
    let session = workspace.sessions.first!
    workspace.selectedWorktreeID = session.worktreeID
    workspace.selectedSessionID = session.id
    controller.reload()
    return (controller, workspace, window)
  }

  func testMaximizingASessionFoldsEveryOtherColumn() {
    let (controller, _, window) = openWindow()
    defer { window.close() }

    controller.focusComposer()
    controller.toggleMaximize(nil)

    XCTAssertEqual(controller.maximizedColumn, .session)
    let showing = controller.showingColumns
    XCTAssertTrue(showing.session)
    XCTAssertFalse(showing.rail)
    XCTAssertFalse(showing.desk)
    XCTAssertFalse(showing.panel)
  }

  /// Focus nowhere in the columns is the desk's, which is where ⌃⌘M started — and the desk
  /// maximized folds the transcript, not itself.
  func testFocusNowhereMaximizesTheDesk() {
    let (controller, _, window) = openWindow()
    defer { window.close() }

    controller.toggleMaximize(nil)

    XCTAssertEqual(controller.maximizedColumn, .desk)
    XCTAssertTrue(controller.showingColumns.desk)
    XCTAssertFalse(controller.showingColumns.session)
  }

  /// Leaving the mode puts back exactly what was showing when it was entered — a panel already
  /// hidden stays hidden.
  func testRestoringPutsBackWhatWasShowing() {
    let (controller, _, window) = openWindow()
    defer { window.close() }

    controller.toggleFilesPanel(nil)
    XCTAssertFalse(controller.showingColumns.panel)

    controller.focusComposer()
    controller.toggleMaximize(nil)
    controller.toggleMaximize(nil)

    XCTAssertNil(controller.maximizedColumn)
    let showing = controller.showingColumns
    XCTAssertTrue(showing.rail)
    XCTAssertTrue(showing.session)
    XCTAssertTrue(showing.desk)
    XCTAssertFalse(showing.panel)
  }

  /// Arranging a column by hand ends the mode: the column being asked for is left to the act,
  /// and the pair nothing else can unfold — the transcript and the desk — is put back, or the
  /// one the mode had folded would be a column with no way to it.
  func testTogglingAColumnByHandEndsTheMode() {
    let (controller, _, window) = openWindow()
    defer { window.close() }

    controller.focusComposer()
    controller.toggleMaximize(nil)
    controller.toggleFilesPanel(nil)

    XCTAssertNil(controller.maximizedColumn)
    XCTAssertTrue(controller.showingColumns.panel)
    XCTAssertTrue(controller.showingColumns.desk)
    XCTAssertTrue(controller.showingColumns.session)
    // The rail keeps what the mode made of it: it has a toggle of its own, and it is one
    // keystroke from the menu that says "Show Sidebar" while it is folded.
    XCTAssertFalse(controller.showingColumns.rail)
  }

  /// Neither middle column can be dragged shut, only maximized out of the way. They have no
  /// toggle of their own, so a fold a divider can reach is a fold with nothing to undo it —
  /// ⌃⌘M reads the layout it is entered from and puts that same fold straight back — and the
  /// desk's version of it outlived a relaunch, `recordColumnWidths` having no way to tell a
  /// transcript grown over the fold from a width somebody meant. A position past the minimum is
  /// how the drag and that replay both arrive, and it has to land on the minimum.
  func testTheMiddleColumnsCannotBeFoldedByADivider() {
    let (controller, _, window) = openWindow()
    defer { window.close() }
    window.setContentSize(NSSize(width: 1600, height: 900))
    window.layoutIfNeeded()

    // The inner split, reached the way the window builds it: the columns pair is the middle item
    // of the outer split, wrapped in the controller that insets it under the toolbar.
    let outer = window.contentViewController as! NSSplitViewController
    let columns = outer.splitViewItems[1].viewController.children.first as! NSSplitViewController

    columns.splitView.setPosition(columns.splitView.bounds.width, ofDividerAt: 0)
    columns.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(controller.showingColumns.desk, "the desk was squeezed out by its divider")

    columns.splitView.setPosition(0, ofDividerAt: 0)
    columns.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(
      controller.showingColumns.session, "the transcript was squeezed out by its divider")

    // What the fold is still for: maximizing sets `isCollapsed` outright, which is not the drag
    // the refusal above is about.
    controller.focusComposer()
    controller.toggleMaximize(nil)
    XCTAssertFalse(controller.showingColumns.desk)
    controller.toggleMaximize(nil)
    XCTAssertTrue(controller.showingColumns.desk)
  }

  /// The transcript's counterpart to the desk's last tab closing: the session gone, the column
  /// has nothing left it was given the window for.
  func testTheSessionGoingAwayEndsTheMode() {
    let (controller, workspace, window) = openWindow()
    defer { window.close() }

    controller.focusComposer()
    controller.toggleMaximize(nil)
    XCTAssertEqual(controller.maximizedColumn, .session)

    // The sessions gone from the model is what a delete, or the repository closing, leaves
    // behind — clearing the selection alone would only fall through to the worktree's next one.
    workspace.sessions = []
    workspace.selectedSessionID = nil
    controller.reload()

    XCTAssertNil(controller.maximizedColumn)
    XCTAssertTrue(controller.showingColumns.rail)
    XCTAssertTrue(controller.showingColumns.desk)
  }

  /// The gesture's own half. A label is an NSControl that swallows the click it is handed, so
  /// the title and the figures beside it have to read as the bar itself — and the pickers, which
  /// have a menu to open, must not.
  func testTheHeaderTakesTheDoubleClickOffItsLabelsOnly() {
    let title = NSTextField(labelWithString: "Bump the libgit2 version")
    let picker = HeaderPicker(symbol: "sparkles")
    let bar = HeaderBar(views: [title], trailing: [picker])
    bar.frame = NSRect(x: 0, y: 0, width: 400, height: 36)
    bar.layoutSubtreeIfNeeded()

    // Nil until a column has something for the gesture to mean — the commit tab's header keeps
    // its labels' clicks.
    XCTAssertTrue(bar.hitTest(bar.convert(NSPoint(x: 4, y: 8), from: title)) === title)

    var maximizes = 0
    bar.onDoubleClick = { maximizes += 1 }
    XCTAssertTrue(bar.hitTest(bar.convert(NSPoint(x: 4, y: 8), from: title)) === bar)
    XCTAssertTrue(bar.hitTest(bar.convert(NSPoint(x: 4, y: 8), from: picker)) === picker)

    bar.mouseDown(with: click(in: bar, count: 1))
    XCTAssertEqual(maximizes, 0)
    bar.mouseDown(with: click(in: bar, count: 2))
    XCTAssertEqual(maximizes, 1)
  }

  /// The mode changes the transcript's width twice, and a re-wrap moves every point offset in
  /// the document — so the round trip has to land the reader back on their own text. What broke
  /// it: the clip view is clamped to the re-wrapped document's new height, which arrives as a
  /// scroll like any other and overwrote the anchor about to be restored to.
  func testTheRoundTripLeavesTheReaderWhereTheyWere() {
    let workspace = Workspace()
    let repo = Repository(id: "/repo/hukan")
    let main = Worktree(
      url: URL(fileURLWithPath: "/repo/hukan"), branch: "main", repository: repo)
    repo.worktrees = [main]
    workspace.repositories = [repo]
    let session = AgentSession(worktreeID: main.id)
    session.transcript.append(
      NSAttributedString(
        string: (1...400)
          .map { line("Paragraph \($0)") }
          .joined(),
        attributes: [.font: NSFont.systemFont(ofSize: 13)]))
    workspace.sessions = [session]
    workspace.selectedWorktreeID = main.id
    workspace.selectedSessionID = session.id

    let column = RunningColumnViewController()
    column.workspace = workspace
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.contentView = column.view
    column.reload()
    window.contentView?.layoutSubtreeIfNeeded()

    column.jumpToOffset(session.transcript.length / 2, length: 1)
    window.contentView?.layoutSubtreeIfNeeded()
    let before = column.transcriptReaderOffset
    XCTAssertGreaterThan(before, 0, "the reader has to be somewhere in the middle to be moved")

    for width in [1240.0, 520.0] {
      window.setContentSize(NSSize(width: width, height: 400))
      window.contentView?.layoutSubtreeIfNeeded()
      // The turn the width change happened in has to end: the re-wrap's own last word — the
      // view re-measured, the clip view clamped again — lands at the end of it, and so does the
      // pass that puts the reader back after it. See `beginRewrapSettling`.
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    }

    // The anchor is a character and the offset it comes back at is the head of the line holding
    // it, so a line's worth of drift is the resolution of the thing, not a slip.
    XCTAssertEqual(
      Double(column.transcriptReaderOffset), Double(before), accuracy: 200,
      "the reader left \(before) and came back at \(column.transcriptReaderOffset)")
  }

  /// Long enough to wrap more than once in a narrow column and not at all in a wide one, which
  /// is what makes the width change move the text under the reader.
  private func line(_ head: String) -> String {
    head + " — a paragraph of the conversation, long enough that the column's width decides how"
      + " many rows it takes and therefore where in the document it sits.\n"
  }

  private func click(in view: NSView, count: Int) -> NSEvent {
    NSEvent.mouseEvent(
      with: .leftMouseDown, location: NSPoint(x: view.bounds.midX, y: view.bounds.midY),
      modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
      clickCount: count, pressure: 1)!
  }

  /// Being sent to a session is being sent to the rail as much as to the transcript, and the
  /// rail is folded whichever column has the window.
  func testBeingSentToASessionEndsTheMode() {
    let (controller, workspace, window) = openWindow()
    defer { window.close() }

    controller.focusComposer()
    controller.toggleMaximize(nil)
    controller.focusNextPending(nil)

    XCTAssertNil(controller.maximizedColumn)
    XCTAssertTrue(controller.showingColumns.rail)
    _ = workspace
  }
}
