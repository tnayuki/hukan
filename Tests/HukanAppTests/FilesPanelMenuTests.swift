import AppKit
import XCTest

@testable import Hukan

/// The files panel's right-click menu — the one place hukan writes to a worktree itself.
///
/// The acts are checked through the seam the guarded scripting verbs use, which is the write
/// without the alert in front of it: the alert is the decision, and a test cannot answer one.
/// What the menu *offers* is checked separately, because which items a row carries is the half
/// that decides whether an act is even reachable, and it differs per row kind.
final class FilesPanelMenuTests: XCTestCase {
  private var temporaries: [URL] = []

  override func tearDown() {
    for url in temporaries { try? FileManager.default.removeItem(at: url) }
    temporaries = []
    super.tearDown()
  }

  /// A worktree that really is on disk: the menu's acts are FileManager calls, so unlike the
  /// tree's own tests this one cannot make do with a list of paths.
  private func makeWorktree(files: [String]) throws -> Worktree {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-files-menu-\(UUID().uuidString)")
    temporaries.append(root)
    for path in files {
      let file = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try "let a = 1\n".write(to: file, atomically: true, encoding: .utf8)
    }
    let repository = Repository(id: root.path)
    let worktree = Worktree(url: root, repository: repository)
    worktree.trackedFiles = files
    worktree.hasLoadedFiles = true
    repository.worktrees = [worktree]
    return worktree
  }

  @MainActor
  private func panel(on worktree: Worktree) -> FilesPanelViewController {
    let panel = FilesPanelViewController()
    panel.show(worktree: worktree)
    return panel
  }

  // MARK: What a row offers

  /// A file carries the lot; a directory has no tab to open, so Open in New Tab is simply not
  /// there rather than there and refusing; the background is the worktree root, which can be
  /// neither renamed nor deleted from inside it.
  @MainActor
  func testTheMenuOffersWhatTheRowCanActuallyDo() throws {
    let worktree = try makeWorktree(files: ["src/A.swift"])
    let panel = panel(on: worktree)

    let file = panel.menuForScripting(path: "src/A.swift").components(separatedBy: "\n")
    XCTAssertEqual(file.first, "Open in New Tab")
    XCTAssertTrue(file.contains("Copy Path"), "\(file)")
    XCTAssertTrue(file.contains("Copy Absolute Path"), "both paths are their own item")
    XCTAssertTrue(file.contains("Rename…") && file.contains("Delete…"), "\(file)")

    let directory = panel.menuForScripting(path: "src").components(separatedBy: "\n")
    XCTAssertFalse(directory.contains("Open in New Tab"), "a directory has no tab: \(directory)")
    XCTAssertTrue(directory.contains("Rename…"), "\(directory)")

    let background = panel.menuForScripting(path: "").components(separatedBy: "\n")
    XCTAssertTrue(background.contains("New File…"), "\(background)")
    XCTAssertFalse(background.contains("Copy Path"), "the root has no relative path")
    XCTAssertFalse(background.contains("Delete…"), "\(background)")
  }

  @MainActor
  func testAPathThatIsNotThereHasNoMenu() throws {
    let panel = panel(on: try makeWorktree(files: ["a.swift"]))
    XCTAssertEqual(panel.menuForScripting(path: "b.swift"), "no such path")
  }

  // MARK: New File

  /// The file is made under a name nobody chose, in the directory the click landed in, and the
  /// row is what it is named on — so the act reports a path and the desk gets a tab to open.
  @MainActor
  func testNewFileMakesAnUntitledFileInTheClickedDirectory() throws {
    let worktree = try makeWorktree(files: ["src/a.swift"])
    let panel = panel(on: worktree)
    var announced: [String] = []
    panel.onFileEdit = { edit in
      if case .created(let path) = edit { announced.append(path) }
    }

    XCTAssertEqual(panel.writeForScripting(create: "src"), "ok")

    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: worktree.url.appendingPathComponent("src/untitled").path))
    XCTAssertEqual(announced, ["src/untitled"], "the desk is told, so it can open the tab")
  }

  /// The untitled name is a real answer, because the file is made before it is named — so a
  /// second one cannot land on the first.
  @MainActor
  func testASecondNewFileDoesNotLandOnTheFirst() throws {
    let worktree = try makeWorktree(files: ["a.swift"])
    let panel = panel(on: worktree)

    XCTAssertEqual(panel.writeForScripting(create: ""), "ok")
    XCTAssertEqual(panel.writeForScripting(create: ""), "ok")

    let names = try FileManager.default.contentsOfDirectory(atPath: worktree.url.path).sorted()
    XCTAssertEqual(names, ["a.swift", "untitled", "untitled 2"])
  }

  /// A directory git produced no path for is still a row — the same reason an untracked file is
  /// one. git records no empty directory, so nothing but the panel can see it, and the read that
  /// finds it is done as the node opens rather than by walking the worktree.
  @MainActor
  func testAnEmptyDirectoryIsARow() throws {
    let worktree = try makeWorktree(files: ["src/a.swift"])
    try FileManager.default.createDirectory(
      at: worktree.url.appendingPathComponent("src/empty"), withIntermediateDirectories: true)
    let panel = panel(on: worktree)

    // It answers to the menu, which means the tree found it.
    let menu = panel.menuForScripting(path: "src/empty").components(separatedBy: "\n")
    XCTAssertFalse(menu.contains("Open in New Tab"), "a directory: \(menu)")
    XCTAssertTrue(menu.contains("New Folder…"), "\(menu)")
  }

  /// New Folder has no git read behind it — git's lists cannot move for an empty directory — so
  /// the panel rebuilds its own tree, and the row it makes goes into naming like a new file's.
  @MainActor
  func testNewFolderMakesTheRowAndNamesIt() throws {
    let worktree = try makeWorktree(files: ["src/a.swift"])
    // Hosted, because the row is handed a field editor and a field editor needs a window.
    let panel = FilesPanelViewController()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 260, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = panel.view
    panel.show(worktree: worktree)
    window.displayIfNeeded()
    var announced: [String] = []
    panel.onFileEdit = { edit in
      if case .createdFolder(let path) = edit { announced.append(path) }
    }

    XCTAssertEqual(panel.writeForScripting(createFolder: "src"), "ok")

    var isDirectory: ObjCBool = false
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: worktree.url.appendingPathComponent("src/untitled folder").path,
        isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
    XCTAssertEqual(announced, ["src/untitled folder"])
    XCTAssertTrue(panel.report.contains("naming:src/untitled folder"), panel.report)
  }

  // MARK: Rename

  @MainActor
  func testRenameMovesTheFileAndSaysBothHalves() throws {
    let worktree = try makeWorktree(files: ["src/A.swift"])
    let panel = panel(on: worktree)
    var announced: [String] = []
    panel.onFileEdit = { edit in
      if case .renamed(let from, let to) = edit { announced = [from, to] }
    }

    XCTAssertEqual(panel.writeForScripting(rename: "src/A.swift", to: "B.swift"), "ok")

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: worktree.url.appendingPathComponent("src/A.swift").path)
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: worktree.url.appendingPathComponent("src/B.swift").path)
    )
    XCTAssertEqual(
      announced, ["src/A.swift", "src/B.swift"], "the new name keeps the old one's directory")
  }

  /// A typed name may carry directories, and they are made on the way — which is the only way
  /// this panel can make a directory at all, git recording no empty ones. Read against the
  /// directory the row is in, so it is the same rule New File's untitled row follows.
  @MainActor
  func testATypedNameMayCarryDirectories() throws {
    let worktree = try makeWorktree(files: ["src/a.swift"])
    let panel = panel(on: worktree)
    var announced: [String] = []
    panel.onFileEdit = { edit in
      if case .renamed(let from, let to) = edit { announced = [from, to] }
    }

    XCTAssertEqual(panel.writeForScripting(rename: "src/a.swift", to: "deep/b.swift"), "ok")

    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: worktree.url.appendingPathComponent("src/deep/b.swift").path))
    XCTAssertEqual(announced, ["src/a.swift", "src/deep/b.swift"])
  }

  /// The one thing a name typed on a row must not be able to mean is a file somewhere else.
  @MainActor
  func testANameCannotClimbOutOfTheWorktree() throws {
    let worktree = try makeWorktree(files: ["src/a.swift"])
    let panel = panel(on: worktree)

    XCTAssertTrue(
      panel.writeForScripting(rename: "src/a.swift", to: "../escaped.swift").contains("room"))
    XCTAssertTrue(
      panel.writeForScripting(rename: "src/a.swift", to: "/tmp/escaped.swift").contains("room"))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: worktree.url.appendingPathComponent("src/a.swift").path))
  }

  /// This filesystem answers "exists" for the file being renamed, so the taken-name check has to
  /// let a case-only rename through — git very much sees that one.
  @MainActor
  func testRenameCanChangeOnlyTheCase() throws {
    let worktree = try makeWorktree(files: ["Model.swift"])
    let panel = panel(on: worktree)

    XCTAssertEqual(panel.writeForScripting(rename: "Model.swift", to: "model.swift"), "ok")

    let names = try FileManager.default.contentsOfDirectory(atPath: worktree.url.path)
    XCTAssertEqual(names, ["model.swift"])
  }

  // MARK: Delete

  @MainActor
  func testDeleteTakesTheDirectoryAndEverythingUnderIt() throws {
    let worktree = try makeWorktree(files: ["src/A.swift", "src/deep/B.swift", "keep.swift"])
    let panel = panel(on: worktree)
    var announced: [String] = []
    panel.onFileEdit = { edit in
      if case .deleted(let path) = edit { announced.append(path) }
    }

    XCTAssertEqual(panel.writeForScripting(delete: "src"), "ok")

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: worktree.url.appendingPathComponent("src").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: worktree.url.appendingPathComponent("keep.swift").path)
    )
    XCTAssertEqual(announced, ["src"])
  }
}

/// The desk's half of the two acts that move a file out from under an open tab. A buffer is keyed
/// by `(Worktree, relative path)`, so a rename has to move the tab's identity rather than leave it
/// naming something that is gone, and a delete has to take the tab with it.
final class DeskFileEditTests: XCTestCase {
  private var temporaries: [URL] = []

  override func tearDown() {
    for url in temporaries { try? FileManager.default.removeItem(at: url) }
    temporaries = []
    super.tearDown()
  }

  @MainActor
  private func desk() throws -> (WorktreeDeskViewController, Worktree) {
    let workspace = Workspace()
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-desk-edit-\(UUID().uuidString)")
    temporaries.append(root)
    for path in ["src/A.swift", "src/B.swift", "src.md"] {
      let file = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try "let a = 1\n".write(to: file, atomically: true, encoding: .utf8)
    }
    let worktree = workspace.addWorktree(root)
    let desk = WorktreeDeskViewController()
    desk.workspace = workspace
    desk.reload(worktreeID: worktree.id)
    return (desk, worktree)
  }

  /// Renaming a directory carries every tab under it — and stops at the separator, so `src`
  /// moving does not claim `src.md`.
  @MainActor
  func testTabsFollowARenamedDirectoryWithoutClaimingItsNeighbour() throws {
    let (desk, worktree) = try desk()
    for path in ["src/A.swift", "src/B.swift", "src.md"] {
      desk.openFile(worktree: worktree, path: path, preview: false)
    }

    desk.fileRenamed(worktreeID: worktree.id, from: "src", to: "lib")

    XCTAssertEqual(desk.openFilePaths, ["lib/A.swift", "lib/B.swift", "src.md"])
  }

  @MainActor
  func testADeletedFileTakesItsTabWithIt() throws {
    let (desk, worktree) = try desk()
    for path in ["src/A.swift", "src/B.swift"] {
      desk.openFile(worktree: worktree, path: path, preview: false)
    }

    desk.fileDeleted(worktreeID: worktree.id, path: "src/A.swift")

    XCTAssertEqual(desk.openFilePaths, ["src/B.swift"])
  }

  @MainActor
  func testDeletingADirectoryClosesEveryTabUnderIt() throws {
    let (desk, worktree) = try desk()
    for path in ["src/A.swift", "src/B.swift", "src.md"] {
      desk.openFile(worktree: worktree, path: path, preview: false)
    }

    desk.fileDeleted(worktreeID: worktree.id, path: "src")

    XCTAssertEqual(desk.openFilePaths, ["src.md"])
  }
}

/// Naming a row happens on the row. Both acts that need a name go through one mechanism — New
/// File makes the file under an untitled name and then hands it to the same edit — so what these
/// pin is that mechanism: that the tree holds still while a name is being typed (an agent writing
/// in this worktree rebuilds it every second, and a rebuild takes the field editor down), and
/// that Escape leaves the name alone.
final class FilesPanelNamingTests: XCTestCase {
  private var temporaries: [URL] = []

  override func tearDown() {
    for url in temporaries { try? FileManager.default.removeItem(at: url) }
    temporaries = []
    super.tearDown()
  }

  private func makeWorktree(files: [String]) throws -> Worktree {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-naming-\(UUID().uuidString)")
    temporaries.append(root)
    for path in files {
      let file = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try "let a = 1\n".write(to: file, atomically: true, encoding: .utf8)
    }
    let repository = Repository(id: root.path)
    let worktree = Worktree(url: root, repository: repository)
    worktree.trackedFiles = files
    worktree.hasLoadedFiles = true
    repository.worktrees = [worktree]
    return worktree
  }

  @MainActor
  private func hosted(_ worktree: Worktree) -> (FilesPanelViewController, NSWindow) {
    let panel = FilesPanelViewController()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 260, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = panel.view
    panel.show(worktree: worktree)
    window.displayIfNeeded()
    return (panel, window)
  }

  /// The field the row is being typed in, wherever the outline put it.
  private func editingField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable, !(field is NSSearchField) {
      return field
    }
    for subview in view.subviews {
      if let found = editingField(in: subview) { return found }
    }
    return nil
  }

  @MainActor
  func testTypingANameOnTheRowRenamesTheFile() throws {
    let worktree = try makeWorktree(files: ["a.swift"])
    let (panel, window) = hosted(worktree)

    panel.beginNaming(path: "a.swift")
    let field = try XCTUnwrap(editingField(in: panel.view), "the row is in edit")
    XCTAssertEqual(field.stringValue, "a.swift")
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.string = "b.swift"
    XCTAssertTrue(
      panel.control(
        field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    _ = window

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: worktree.url.appendingPathComponent("a.swift").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: worktree.url.appendingPathComponent("b.swift").path))
  }

  /// A rebuild reloads the outline, which takes the field editor down mid-word — and in a
  /// worktree an agent is writing in, one arrives every second.
  @MainActor
  func testTheTreeHoldsStillWhileANameIsBeingTyped() throws {
    let worktree = try makeWorktree(files: ["a.swift", "b.swift"])
    let (panel, _) = hosted(worktree)

    panel.beginNaming(path: "a.swift")
    worktree.trackedFiles = ["a.swift"]
    panel.filesChangedOnDisk()

    XCTAssertNotNil(editingField(in: panel.view), "still being typed in")
    XCTAssertTrue(panel.report.contains("naming:a.swift"), panel.report)
  }

  /// And then catches up. A refresh held back and never run would leave the panel answering for
  /// a worktree it stopped reading, which is worse than the flicker holding it back avoids.
  @MainActor
  func testTheTreeCatchesUpOnceTheNameIsFinished() throws {
    let worktree = try makeWorktree(files: ["a.swift", "b.swift"])
    let (panel, window) = hosted(worktree)

    panel.beginNaming(path: "a.swift")
    worktree.trackedFiles = ["b.swift", "c.swift"]
    worktree.changedFiles = []
    panel.filesChangedOnDisk()
    // Escape: the name is left alone, so what lands is only what was held back.
    let field = try XCTUnwrap(editingField(in: panel.view))
    panel.controlTextDidEndEditing(
      Notification(
        name: NSControl.textDidEndEditingNotification, object: field,
        userInfo: ["NSTextMovement": NSTextMovement.cancel.rawValue]))

    let deadline = Date().addingTimeInterval(2)
    let outline = try XCTUnwrap(findOutline(in: panel.view))
    while outline.numberOfRows != 2, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    XCTAssertEqual(outline.numberOfRows, 2, "the held-back read landed")
    XCTAssertTrue(panel.report.contains("naming:—"), panel.report)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: worktree.url.appendingPathComponent("a.swift").path),
      "Escape left the name alone")
    window.displayIfNeeded()
  }

  /// Escape has to put the row back the way it was — the label as well as the box. The rebuild
  /// that normally redraws it has nothing to rebuild when the name did not change, so a row left
  /// to it kept whatever was in the field: an empty one, if that is what was typed.
  @MainActor
  func testEscapeLeavesNeitherTheTypedNameNorTheBoxBehind() throws {
    let worktree = try makeWorktree(files: ["a.swift"])
    let (panel, _) = hosted(worktree)

    panel.beginNaming(path: "a.swift")
    let field = try XCTUnwrap(editingField(in: panel.view))
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "the field editor is up")
    editor.string = ""
    // The route Escape really takes. Inside a table it does *not* arrive as an end-editing
    // notification, which is the whole of why this failed in the app and passed in a test that
    // posted one by hand.
    XCTAssertTrue(
      panel.control(
        field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    settle(panel)

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: worktree.url.appendingPathComponent("a.swift").path))
    XCTAssertFalse(field.isEditable, "the box is gone")
    XCTAssertFalse(field.isBezeled, "and so is its frame")
    XCTAssertEqual(try label(of: "a.swift", in: panel), "a.swift", "the row says the name again")
  }

  /// A name cleared and committed is not a rename. The file keeps its name, and so does the row.
  @MainActor
  func testAnEmptyNameLeavesTheFileAlone() throws {
    let worktree = try makeWorktree(files: ["a.swift"])
    let (panel, window) = hosted(worktree)

    panel.beginNaming(path: "a.swift")
    let field = try XCTUnwrap(editingField(in: panel.view))
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.string = "   "
    // Return, the way the field editor delivers it.
    XCTAssertTrue(
      panel.control(
        field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    settle(panel)
    _ = window

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: worktree.url.path), ["a.swift"])
    XCTAssertEqual(try label(of: "a.swift", in: panel), "a.swift", "the row says the name again")
    XCTAssertFalse(field.isBezeled)
  }

  /// What the row for `path` reads as now — off whichever cell view the outline has for it,
  /// since a redraw may hand the row a different one than the edit began in.
  @MainActor
  private func label(of path: String, in panel: FilesPanelViewController) throws -> String {
    let outline = try XCTUnwrap(findOutline(in: panel.view))
    let row = try XCTUnwrap(
      (0..<outline.numberOfRows).first {
        (outline.item(atRow: $0) as? FileNode)?.relativePath == path
      }, "a row for \(path)")
    let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
    return try XCTUnwrap(cell?.textField?.stringValue)
  }

  /// Starting a name on one row while another is being typed commits the first — and must not
  /// read the first field's end of editing, which the second field taking focus causes, as the
  /// second row's. Before this was pinned, that read renamed the second file to the first's name.
  @MainActor
  func testNamingASecondRowCommitsTheFirstToItsOwnFile() throws {
    let worktree = try makeWorktree(files: ["a.swift", "b.swift"])
    let (panel, _) = hosted(worktree)

    panel.beginNaming(path: "a.swift")
    let first = try XCTUnwrap(editingField(in: panel.view))
    let editor = try XCTUnwrap(first.currentEditor() as? NSTextView)
    editor.string = "renamed.swift"
    panel.beginNaming(path: "b.swift")
    settle(panel)

    let names = try FileManager.default.contentsOfDirectory(atPath: worktree.url.path).sorted()
    XCTAssertEqual(names, ["b.swift", "renamed.swift"], "a took its own name; b kept its own")
    XCTAssertTrue(panel.report.contains("naming:b.swift"), panel.report)
  }

  /// The row is put back a turn later, out of the field editor's own notification.
  @MainActor
  private func settle(_ panel: FilesPanelViewController) {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline, panel.report.contains("naming:a.swift") {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
  }

  private func findOutline(in view: NSView) -> NSOutlineView? {
    if let outline = view as? NSOutlineView { return outline }
    for subview in view.subviews {
      if let found = findOutline(in: subview) { return found }
    }
    return nil
  }
}
