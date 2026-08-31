import AppKit
import XCTest

@testable import Hukan

/// ⌘Z is aimed by the focus, and what aims it is the manager the window vends: a nil-target
/// `undo:` resolves against the key window's responder chain, where nothing between a text view
/// and the window answers, so the window's own manager used to be every stack in the window at
/// once. Typing a prompt between two edits of a file was enough for ⌘Z in the editor to empty the
/// composer while the source sat unchanged — which read as ⌘Z not working in the editor at all —
/// and the same collision the other way round let ⌘Z in the composer revert a file nobody was
/// looking at. Built on a real window with a real repository behind it, since the whole question
/// is which of the window's text views the key reaches.
final class UndoTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    Git.initialize()
    // Resolve symlinks up front: temp dirs live under /var → /private/var, and libgit2 reports
    // resolved paths.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-undo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    root = tmp.resolvingSymlinksInPath()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: helpers

  @discardableResult
  private func git(_ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = root
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// One commit holding one file — the clean checkout an edit has to be made in.
  private func makeRepository() throws {
    git(["init", "-q", "-b", "main"])
    git(["config", "user.email", "test@example.com"])
    git(["config", "user.name", "Test"])
    git(["config", "commit.gpgsign", "false"])
    try "hello\n".write(
      to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    git(["add", "."])
    git(["commit", "-q", "-m", "Initial"])
  }

  private func textViews(in view: NSView, into found: inout [NSTextView]) {
    if let text = view as? NSTextView { found.append(text) }
    for subview in view.subviews { textViews(in: subview, into: &found) }
  }

  /// The file's text lands off the main thread, so the pane is not editable the instant it opens.
  private func spin(until condition: () -> Bool, _ message: String) {
    let deadline = Date().addingTimeInterval(10)
    while !condition() && Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(condition(), message)
  }

  private func spin(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  /// A window with a repository open, a session selected — so the composer is there to collide
  /// with — and `a.txt` showing on the desk.
  @MainActor
  private func openWindow() throws -> (WorkspaceWindowController, NSWindow, NSTextView, NSTextView)
  {
    try makeRepository()

    let workspace = Workspace()
    let worktree = workspace.addWorktree(root)
    let loaded = expectation(description: "the first git read")
    loaded.expectedFulfillmentCount = 2
    workspace.loadFiles(worktreeID: worktree.id) { loaded.fulfill() }
    wait(for: [loaded], timeout: 10)

    let session = AgentSession(worktreeID: worktree.id)
    session.title = "undo"
    workspace.sessions = [session]

    let controller = WorkspaceWindowController(workspace: workspace)
    let window = try XCTUnwrap(controller.window)
    workspace.selectedWorktreeID = worktree.id
    workspace.selectedSessionID = session.id
    controller.reload()
    // Below the screen rather than on it: the window has to be real for the responder chain to
    // be, but it has nothing to show anyone.
    window.setFrame(NSRect(x: 0, y: -4000, width: 1400, height: 800), display: true)
    window.orderFront(nil)
    controller.arrangeColumnsIfNeeded()
    spin(0.3)

    controller.openPath(root.appendingPathComponent("a.txt"))
    spin(0.3)
    let content = try XCTUnwrap(controller.deskForScripting.activeFileContent)
    var found: [NSTextView] = []
    textViews(in: content.view, into: &found)
    let editor = try XCTUnwrap(found.first)
    spin(until: { editor.isEditable }, "the file's text landed")

    found = []
    if let contentView = window.contentView { textViews(in: contentView, into: &found) }
    let composer = try XCTUnwrap(found.first { $0 is ComposerTextView })
    return (controller, window, editor, composer)
  }

  // MARK: tests

  /// The two places to type in one window keep two stacks, and the window hands back the one
  /// belonging to whatever holds the focus — which is what a nil-target `undo:` reaches.
  @MainActor
  func testTheWindowVendsTheFocusedViewsUndoStack() throws {
    let (_, window, editor, composer) = try openWindow()

    XCTAssertFalse(
      editor.undoManager === composer.undoManager, "the editor and the composer share no stack")

    window.makeFirstResponder(editor)
    XCTAssertTrue(window.undoManager === editor.undoManager, "the editor's, while it is focused")
    window.makeFirstResponder(composer)
    XCTAssertTrue(
      window.undoManager === composer.undoManager, "the composer's, while it is focused")

    // A field editor owns no stack, so it falls back to the one the window keeps for everything
    // that types into it — and never to a file's.
    window.makeFirstResponder(nil)
    let fallback = window.undoManager
    XCTAssertNotNil(fallback)
    XCTAssertFalse(fallback === editor.undoManager)
    XCTAssertFalse(fallback === composer.undoManager)

    window.close()
  }

  /// The regression: type in the file, then type a prompt, then ⌘Z in the file. The key resolves
  /// to the window, so `window.undoManager` is the whole of what it reaches — and it has to undo
  /// the edit that was made where the focus is, not the last thing typed anywhere.
  @MainActor
  func testUndoInTheEditorLeavesTheComposerAlone() throws {
    let (_, window, editor, composer) = try openWindow()

    window.makeFirstResponder(editor)
    editor.insertText("XYZ", replacementRange: NSRange(location: 0, length: 0))
    window.makeFirstResponder(composer)
    composer.insertText("ask the agent", replacementRange: NSRange(location: 0, length: 0))
    spin(0.2)

    window.makeFirstResponder(editor)
    window.undoManager?.undo()
    spin(0.2)
    XCTAssertEqual(editor.string, "hello\n", "the file's edit went back")
    XCTAssertEqual(composer.string, "ask the agent", "and the prompt stayed where it was typed")

    window.close()
  }

  /// Undoing every edit leaves the buffer saying what the file says, so there is nothing left to
  /// save: the dot comes down, and the closing question has nothing to ask about. The flag was
  /// latched by the first keystroke instead, which left a file that had been edited and undone
  /// offering to write itself back unchanged.
  @MainActor
  func testUndoingEveryEditTakesTheUnsavedDotDown() throws {
    let (controller, window, editor, _) = try openWindow()
    let content = try XCTUnwrap(controller.deskForScripting.activeFileContent)

    window.makeFirstResponder(editor)
    editor.insertText("XYZ", replacementRange: NSRange(location: 0, length: 0))
    spin(0.2)
    XCTAssertTrue(content.hasUnsavedEdit, "typing made the buffer dirty")

    window.undoManager?.undo()
    spin(0.2)
    XCTAssertEqual(editor.string, "hello\n")
    XCTAssertFalse(content.hasUnsavedEdit, "and undoing it left nothing to save")

    // Redo puts the edit back, dot and all — the flag reads the text, so it follows either way.
    window.undoManager?.redo()
    spin(0.2)
    XCTAssertEqual(editor.string, "XYZhello\n")
    XCTAssertTrue(content.hasUnsavedEdit, "the edit is back, and so is the dot")

    // Typing the difference away by hand answers the same, undo or no undo.
    editor.setSelectedRange(NSRange(location: 0, length: 3))
    editor.insertText("", replacementRange: NSRange(location: 0, length: 3))
    spin(0.2)
    XCTAssertEqual(editor.string, "hello\n")
    XCTAssertFalse(content.hasUnsavedEdit, "the buffer says what the file says")

    window.close()
  }

  /// And the other way round: a ⌘Z in the composer must not reach into a file that is open on
  /// the desk — the buffer would go back with nobody watching, dirty and unasked for.
  @MainActor
  func testUndoInTheComposerLeavesTheFileAlone() throws {
    let (_, window, editor, composer) = try openWindow()

    window.makeFirstResponder(editor)
    editor.insertText("XYZ", replacementRange: NSRange(location: 0, length: 0))
    window.makeFirstResponder(composer)
    composer.insertText("ask the agent", replacementRange: NSRange(location: 0, length: 0))
    spin(0.2)

    window.undoManager?.undo()
    spin(0.2)
    XCTAssertEqual(composer.string, "", "the prompt went back")
    XCTAssertEqual(editor.string, "XYZhello\n", "and the file kept its edit")

    window.close()
  }
}
