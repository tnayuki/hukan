import AppKit
import XCTest

@testable import Hukan

/// Look iteration for the window chrome itself — the toolbar's sections, the two full-height
/// columns, and where things land as those columns collapse. Rendered from a real
/// WorkspaceWindowController, because that geometry (traffic lights, section merging on collapse)
/// exists nowhere below the window. Not snapshot-pinned: real chrome pixels are the OS's, and
/// would break on every macOS update rather than on a hukan change.
///
/// Drawn by us, never captured from the screen. A capture — ScreenCaptureKit or otherwise —
/// wants the screen-recording grant even for the app's own window, and ad-hoc signing drops that
/// grant on every rebuild; a look-iteration loop that needs a trip through System Settings first
/// is not one. See `capture` for what hand-drawing costs.
///
/// One artefact worth knowing: a toolbar item that draws its own capsule (the worktree status)
/// comes out as a plain white pill, for the same reason the columns needed help — the capsule is
/// the window server's. Everything around it is real.
///
///     HUKAN_PREVIEW_WINDOW=1 xcodebuild test -project hukan.xcodeproj -scheme Hukan \
///         -only-testing:HukanAppTests/WindowPreviewTests/testPreview -derivedDataPath .build/DerivedData
///
/// then look at /tmp/hukan-preview-window-*.png (open, files-collapsed, both-collapsed,
/// rail-collapsed). Off by default — it writes files and asserts nothing.
final class WindowPreviewTests: XCTestCase {
  func testPreview() throws {
    guard ProcessInfo.processInfo.environment["HUKAN_PREVIEW_WINDOW"] == "1" else { return }
    NSApplication.shared.appearance = NSAppearance(named: .darkAqua)

    let workspace = RailPreviewTests.sampleWorkspace()
    let controller = WorkspaceWindowController(workspace: workspace)
    guard let window = controller.window else { return XCTFail("no window") }
    // Select a worktree so the status capsule — the worktree name over the session column — is
    // in the picture; unselected it hides, and its position is half of what this preview is for.
    workspace.selectedWorktreeID = workspace.worktrees.first?.id
    // On the window too, not just the app: a cached display resolves colours against the view's
    // effective appearance, and the stand-in path below draws with the window's.
    window.appearance = NSAppearance(named: .darkAqua)
    controller.reload()
    // On screen, not parked below it: the window server composites what is actually displayed,
    // and a window with nowhere to appear has no material to capture.
    window.setFrame(NSRect(x: 60, y: 60, width: 1200, height: 700), display: true)
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    controller.arrangeColumnsIfNeeded()
    spin(0.8)

    try capture(window, "open")
    controller.toggleFilesPanel(nil)
    spin(0.6)
    try capture(window, "files-collapsed")
    controller.toggleRail(nil)
    spin(0.6)
    try capture(window, "both-collapsed")
    controller.toggleFilesPanel(nil)
    spin(0.6)
    try capture(window, "rail-collapsed")
    window.close()
  }

  /// The full-height arrangement, pinned: the rail's view reaches the window's top edge (the
  /// traffic lights sit over it), while the content columns start below the titlebar. This is
  /// the assertable half of the chrome — the preview above is only for the eyes.
  func testRailRunsTheWindowsFullHeight() throws {
    let controller = WorkspaceWindowController(workspace: RailPreviewTests.sampleWorkspace())
    guard let window = controller.window,
      let split = window.contentViewController as? NSSplitViewController
    else { return XCTFail("no window") }
    window.setFrame(NSRect(x: 0, y: -4000, width: 1200, height: 700), display: true)
    window.orderFront(nil)
    spin(0.3)
    defer { window.close() }

    // A few points of top inset are the full-height sidebar's own; the broken arrangement —
    // .unifiedCompact silently opts the sidebar out of full-height layout — sits a whole
    // titlebar (~40pt) down, which is what the threshold tells apart.
    let rail = split.splitViewItems[0].viewController.view
    let railTop = rail.convert(rail.bounds, to: nil).maxY
    XCTAssertGreaterThanOrEqual(
      railTop, window.frame.height - 20,
      "the rail should rise through the titlebar to the window's top edge")

    // Everything that is not the rail hangs below the toolbar, and so does the divider between
    // the transcript and the desk: an outer-split divider view is as tall as the window, and
    // with the content view running full size it drew a line up through the toolbar's glass.
    guard
      let columns =
        (split.splitViewItems[1].viewController.children.first
        as? NSSplitViewController)?.splitView
    else { return XCTFail("the transcript/desk split should be nested one level down") }
    let columnsTop = columns.convert(columns.bounds, to: nil).maxY
    XCTAssertLessThanOrEqual(
      columnsTop, window.frame.height - 30,
      "the transcript/desk split — dividers and all — should start below the toolbar")
  }

  /// The panel is a column of the window — full height on the trailing edge — and its chrome is
  /// one row of the toolbar over it: filter, ±, then the toggle at the far end. Three separate
  /// items, because two controls packed into one are drawn inside a single capsule, which read
  /// as the ± and the toggle sitting inside the field's bezel. Inside the panel instead, they
  /// sat a row below everything else on the bar.
  func testFilesPanelIsAFullHeightColumn() throws {
    let controller = WorkspaceWindowController(workspace: RailPreviewTests.sampleWorkspace())
    guard let window = controller.window else { return XCTFail("no window") }
    window.setFrame(NSRect(x: 0, y: -4000, width: 1200, height: 700), display: true)
    window.orderFront(nil)
    spin(0.3)
    controller.arrangeColumnsIfNeeded()
    spin(0.4)
    defer { window.close() }

    let items = window.toolbar?.items ?? []
    func item(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
      items.first { $0.itemIdentifier == identifier }
    }
    guard let filter = item(.filesFilter), let scope = item(.filesScope),
      let toggle = item(.toggleFiles)
    else { return XCTFail("the panel's row should be filter, ± and toggle") }
    XCTAssertTrue(
      filter.view is NSSearchField, "the filter item should host the field itself")
    XCTAssertEqual(
      scope.image?.size.height, toggle.image?.size.height,
      "the ± should be sized like the toggle beside it")
    XCTAssertFalse(scope.isBordered, "the bar carries glyphs, not a row of capsules")
    XCTAssertFalse(toggle.isBordered)
    // Order matters: the filter opens the panel's row, the ± and the toggle close it, in that
    // order, with the flexible space between pushing the pair to the far end.
    let row = (window.toolbar?.items ?? []).map(\.itemIdentifier)
      .filter { [.filesFilter, .filesScope, .toggleFiles].contains($0) }
    XCTAssertEqual(row, [.filesFilter, .filesScope, .toggleFiles])
    let visible = window.toolbar?.visibleItems?.map(\.itemIdentifier) ?? []
    for identifier in [NSToolbarItem.Identifier.filesFilter, .filesScope, .toggleFiles] {
      XCTAssertTrue(
        visible.contains(identifier),
        "\(identifier.rawValue) should be on the bar, not pushed into the overflow menu")
    }

    guard let split = window.contentViewController as? NSSplitViewController,
      let panel = split.splitViewItems.last
    else { return XCTFail("no split") }
    let view = panel.viewController.view
    XCTAssertGreaterThanOrEqual(
      view.convert(view.bounds, to: nil).maxY, window.frame.height - 20,
      "the panel should run the window's full height, as the rail does")
    XCTAssertGreaterThanOrEqual(
      view.safeAreaInsets.top, 30,
      "its own header should be held clear of the toolbar by the safe area")
  }

  /// The rail's filter rides the sidebar section, beside the traffic lights and the toggle, and
  /// leaves with the rail: collapsed, the section is the toggle alone.
  func testSessionFilterRidesTheSidebarSection() throws {
    let controller = WorkspaceWindowController(workspace: RailPreviewTests.sampleWorkspace())
    guard let window = controller.window,
      let split = window.contentViewController as? NSSplitViewController
    else { return XCTFail("no window") }
    window.setFrame(NSRect(x: 0, y: -4000, width: 1200, height: 700), display: true)
    window.orderFront(nil)
    spin(0.3)
    // The first-run column widths a real window gets. It is not automatic here: the window
    // arranges itself only once the app has finished launching, which a test bundle never does,
    // and the split view's own fallback is nothing like the real layout.
    controller.arrangeColumnsIfNeeded()
    spin(0.4)
    defer { window.close() }

    guard let filter = window.toolbar?.items.first(where: { $0.itemIdentifier == .sessionFilter })
    else { return XCTFail("the rail should have a filter item") }
    guard let field = filter.view as? NSSearchField else {
      return XCTFail("the rail's filter should host the field itself, not a collapsing search item")
    }
    XCTAssertFalse(filter.isHidden)
    XCTAssertGreaterThan(
      field.bounds.width, 100,
      "the rail's width should leave its filter a field, not a magnifier button")

    // Dragged to the rail's narrowest, the field still has to be there: an item that does not
    // fit is not shrunk, it is moved to the toolbar's overflow menu — the field disappears and a
    // ≫ appears at the far end of the bar. The rail's minimum thickness is set to prevent that.
    split.splitView.setPosition(split.splitViewItems[0].minimumThickness, ofDividerAt: 0)
    spin(0.5)
    XCTAssertTrue(
      window.toolbar?.visibleItems?.contains(where: { $0.itemIdentifier == .sessionFilter })
        == true,
      "the filter should survive the rail being dragged to its minimum")

    controller.toggleRail(nil)
    spin(0.6)
    XCTAssertTrue(filter.isHidden, "a collapsed rail should take its filter with it")
  }

  /// Both fields say the same word, and both say what ⏎ adds — but only while they have the
  /// focus that makes ⏎ mean anything. The sentence used to be there all the time, where it was
  /// too wide for the field and read as noise.
  func testFieldsNameTheirGestures() throws {
    let controller = WorkspaceWindowController(workspace: RailPreviewTests.sampleWorkspace())
    guard let window = controller.window else { return XCTFail("no window") }
    window.setFrame(NSRect(x: 0, y: -4000, width: 1200, height: 700), display: true)
    window.makeKeyAndOrderFront(nil)
    spin(0.3)
    controller.arrangeColumnsIfNeeded()
    spin(0.4)
    defer { window.close() }

    let fields = (window.toolbar?.items ?? []).compactMap { $0.view as? NSSearchField }
    XCTAssertEqual(fields.count, 2, "the rail's filter and the panel's")
    for field in fields {
      XCTAssertEqual(field.placeholderString, "Filter", "at rest, both name the live gesture")
    }

    // The second gesture is named by the column, under the field, and only while the field has
    // the focus that makes Return mean anything.
    func hint(in view: NSView) -> NSTextField? {
      if let label = view as? NSTextField, label.stringValue.hasPrefix("⏎ to search") {
        return label
      }
      for subview in view.subviews {
        if let found = hint(in: subview) { return found }
      }
      return nil
    }
    guard let content = window.contentView else { return XCTFail("no content") }
    let hints = [hint(in: content)].compactMap { $0 }
    XCTAssertFalse(hints.isEmpty, "the columns should carry a hint line")
    for label in hints { XCTAssertTrue(label.isHidden, "hidden until the field is focused") }

    for field in fields {
      XCTAssertTrue(window.makeFirstResponder(field), "the field should take focus")
      spin(0.2)
    }
  }

  /// Let collapse animations and the toolbar's lazy layout settle.
  private func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  /// Ask the window server for the window as it is displayed. Falling back to `cacheDisplay`
  /// when that is refused keeps the preview working without the grant — but says so, because the
  /// fallback is exactly the picture that cannot show a sidebar.
  /// Draw the window ourselves.
  ///
  /// `cacheDisplay` is the obvious call and the wrong one: it fills an opaque background first,
  /// and the two full-height columns have no background of their own to fill it with — their
  /// material is composited by the window server — so both came back flat white, which is most
  /// of this window. `displayIgnoringOpacity` draws the same hierarchy into a context we own
  /// *without* that fill, so a stand-in colour laid down first shows through wherever a material
  /// would be. Colours are approximate; layout, text and glyphs are the real thing.
  private func capture(_ window: NSWindow, _ name: String) throws {
    guard let frameView = window.contentView?.superview else { return XCTFail("no frame view") }
    let bounds = frameView.bounds
    let scale = window.backingScaleFactor
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale),
        pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return XCTFail("no bitmap for the window") }
    rep.size = bounds.size

    // The bitmap is in pixels and the view hierarchy in points.
    context.cgContext.scaleBy(x: scale, y: scale)

    // Tahoe draws a sidebar's background through backdrop views the window server composites —
    // pockets, portals, luminance adjustments. Drawn by hand they come out opaque white, which
    // is how both full-height columns kept turning up blank. Take them out for the duration and
    // let the stand-in colour below show through; only the leaves go, so the content they sit
    // behind still draws.
    var hidden: [NSView] = []
    func hideBackdrops(_ view: NSView) {
      let name = String(describing: type(of: view))
      let isBackdrop =
        view is NSVisualEffectView || name.contains("Pocket") || name.contains("Backdrop")
        || name.contains("Portal") || name.contains("Luminance")
      if isBackdrop, view.subviews.isEmpty, !view.isHidden {
        view.isHidden = true
        hidden.append(view)
      }
      for subview in view.subviews { hideBackdrops(subview) }
    }
    hideBackdrops(frameView)
    defer { for view in hidden { view.isHidden = false } }

    let appearance = window.appearance ?? NSApp.effectiveAppearance
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    appearance.performAsCurrentDrawingAppearance {
      NSColor.windowBackgroundColor.setFill()
      bounds.fill()
      frameView.displayIgnoringOpacity(bounds, in: context)

      // The frame pass leaves the two full-height columns white however they are drawn — the
      // glass that stands in for their background is the window server's, and what it leaves
      // behind is opaque. Paint each one over: a flat colour, then that column's own view drawn
      // on top of it.
      guard let split = window.contentViewController as? NSSplitViewController else { return }
      for item in split.splitViewItems where item.allowsFullHeightLayout && !item.isCollapsed {
        let view = item.viewController.view
        let rect = view.convert(view.bounds, to: nil)
        NSGraphicsContext.saveGraphicsState()
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        context.cgContext.translateBy(x: rect.minX, y: rect.minY)
        view.displayIgnoringOpacity(view.bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()
      }

      // A column runs the window's full height, so overpainting it just wiped the toolbar items
      // standing over it — the two filters and the two toggles, which is most of what these
      // previews are for. Put the titlebar back on top.
      guard
        let titlebar = frameView.subviews.first(where: {
          String(describing: type(of: $0)).contains("Titlebar")
        })
      else { return }
      let rect = titlebar.convert(titlebar.bounds, to: nil)
      NSGraphicsContext.saveGraphicsState()
      context.cgContext.translateBy(x: rect.minX, y: rect.minY)
      titlebar.displayIgnoringOpacity(titlebar.bounds, in: context)
      NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
      return XCTFail("no png for the window")
    }
    let out = URL(fileURLWithPath: "/tmp/hukan-preview-window-\(name).png")
    try data.write(to: out)
    print("wrote \(out.path)")
  }
}
