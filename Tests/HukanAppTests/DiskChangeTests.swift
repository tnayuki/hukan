import AppKit
import XCTest

@testable import Hukan

/// An agent rewriting a file under an open tab. The tab on the desk being looked at always
/// re-read; the two cases here are the ones that did not, and both of them are a pane refusing
/// the disk for a good reason and then never taking it: a tab on another session's desk, which
/// must not pay a whole-file parse off screen, and a buffer holding an unsaved edit, which must
/// not lose it. Each notes the change instead, and spends the note at the one moment it can —
/// the desk coming up, the undo taking the edit back off.
///
/// What is not here is the alert ⌘S puts in front of an overwrite: `runModal` would stand in
/// front of the test, the way it does in `FileSaveTests`. What that alert reads is
/// `hasDiskChangeUnderEdit`, and that is pinned.
final class DiskChangeTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    Git.initialize()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-disk-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    root = tmp.resolvingSymlinksInPath()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: helpers

  private func textView(in view: NSView) -> NSTextView? {
    if let text = view as? NSTextView { return text }
    for subview in view.subviews { if let found = textView(in: subview) { return found } }
    return nil
  }

  private func spin(until condition: () -> Bool, _ message: String) {
    let deadline = Date().addingTimeInterval(10)
    while !condition() && Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(condition(), message)
  }

  /// A second session in the same checkout, so there are two desks to put a tab on each of. The
  /// transcript is written for the reason `deskSession` writes one — the session list is rebuilt
  /// from the transcripts — and the worktree's existing session is left alone.
  private func extraSession(in worktree: Worktree, of workspace: Workspace) -> AgentSession {
    let session = AgentSession(worktreeID: worktree.id, isDetached: true)
    let store = ClaudeSessionStore.directory(for: worktree.url)
    try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: ClaudeSessionStore.transcriptURL(id: session.id, worktree: worktree.url).path,
      contents: Data())
    addTeardownBlock { try? FileManager.default.removeItem(at: store) }
    workspace.sessions.append(session)
    return session
  }

  /// A window holding the desk, which the pane needs to lay out in.
  private func host(_ files: FileColumns) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = files.desk.view
    return window
  }

  // MARK: tests

  /// Two sessions in one checkout, a tab on the same file on each desk. A desk is a session's and
  /// the write is the checkout's, so the tab off screen has to hear about it — and it hears
  /// without reading: it keeps the text it was opened with until its desk comes up, which is when
  /// the parse is worth paying for. Before this it never read again at all, since `realize` only
  /// reads a tab nobody has opened yet, so switching back showed the file as it stood an hour ago.
  @MainActor
  func testATabOnAnotherDeskTakesTheChangeWhenItsDeskComesUp() throws {
    let file = root.appendingPathComponent("a.txt")
    try "first\n".write(to: file, atomically: true, encoding: .utf8)

    let workspace = Workspace()
    let worktree = workspace.addWorktree(root)
    let first = deskSession(in: worktree, of: workspace)
    let second = extraSession(in: worktree, of: workspace)

    let files = FileColumns()
    files.workspace = workspace
    _ = host(files)

    files.desk.reload(deskID: first.id)
    files.desk.openFile(worktree: worktree, path: "a.txt", preview: false)
    let hidden = try XCTUnwrap(files.desk.activeFileContent)
    let hiddenText = try XCTUnwrap(textView(in: hidden.view))
    spin(until: { hiddenText.string == "first\n" }, "the first desk's tab read the file")

    files.desk.reload(deskID: second.id)
    files.desk.openFile(worktree: worktree, path: "a.txt", preview: false)
    let showing = try XCTUnwrap(files.desk.activeFileContent)
    let showingText = try XCTUnwrap(textView(in: showing.view))
    spin(until: { showingText.string == "first\n" }, "and so did the second desk's")

    try "second\n".write(to: file, atomically: true, encoding: .utf8)
    files.filesChangedOnDisk(worktreeID: worktree.id, changed: ["a.txt"])

    spin(until: { showingText.string == "second\n" }, "the desk on screen re-read at once")
    XCTAssertEqual(hiddenText.string, "first\n", "the one off screen did not pay for the parse")

    files.desk.reload(deskID: first.id)
    spin(until: { hiddenText.string == "second\n" }, "and took it when its desk came up")
  }

  /// A write landing under an unsaved edit keeps the edit — that much always held, silently. What
  /// is new is that the pane remembers, so the tab can mark it and ⌘S can ask: before this the
  /// refresh returned without a word and the next save replaced the agent's file with the buffer,
  /// no question anywhere.
  @MainActor
  func testAnEditKeepsTheBufferAndRemembersThatTheDiskMoved() throws {
    let file = root.appendingPathComponent("a.txt")
    try "first\n".write(to: file, atomically: true, encoding: .utf8)

    let workspace = Workspace()
    let worktree = workspace.addWorktree(root)
    let files = FileColumns()
    files.workspace = workspace
    _ = host(files)
    files.desk.reload(deskID: deskSession(in: worktree, of: workspace).id)
    files.desk.openFile(worktree: worktree, path: "a.txt", preview: false)
    let content = try XCTUnwrap(files.desk.activeFileContent)
    let text = try XCTUnwrap(textView(in: content.view))
    spin(until: { text.isEditable }, "the file's text landed")

    text.insertText("mine ", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertTrue(content.hasUnsavedEdit, "typing made the buffer dirty")
    XCTAssertFalse(content.hasDiskChangeUnderEdit, "and nothing has moved under it yet")

    try "second\n".write(to: file, atomically: true, encoding: .utf8)
    files.filesChangedOnDisk(worktreeID: worktree.id, changed: ["a.txt"])

    XCTAssertEqual(text.string, "mine first\n", "the edit outweighs the file")
    XCTAssertTrue(content.hasDiskChangeUnderEdit, "and the tab has something to mark")
  }

  /// Undoing the edit back to what the pane last read leaves nothing to protect, so the file it
  /// had been refusing arrives — the one moment the refusal can end without anybody deciding
  /// anything. Typed back by hand rather than through the undo manager, since what the pane reads
  /// is the text and not how it got there.
  @MainActor
  func testTakingTheEditBackOffTakesTheFile() throws {
    let file = root.appendingPathComponent("a.txt")
    try "first\n".write(to: file, atomically: true, encoding: .utf8)

    let workspace = Workspace()
    let worktree = workspace.addWorktree(root)
    let files = FileColumns()
    files.workspace = workspace
    _ = host(files)
    files.desk.reload(deskID: deskSession(in: worktree, of: workspace).id)
    files.desk.openFile(worktree: worktree, path: "a.txt", preview: false)
    let content = try XCTUnwrap(files.desk.activeFileContent)
    let text = try XCTUnwrap(textView(in: content.view))
    spin(until: { text.isEditable }, "the file's text landed")

    text.insertText("mine ", replacementRange: NSRange(location: 0, length: 0))
    try "second\n".write(to: file, atomically: true, encoding: .utf8)
    files.filesChangedOnDisk(worktreeID: worktree.id, changed: ["a.txt"])
    XCTAssertTrue(content.hasDiskChangeUnderEdit, "the note is up")

    text.insertText("first\n", replacementRange: NSRange(location: 0, length: text.string.count))
    XCTAssertFalse(content.hasUnsavedEdit, "the buffer says what it was read as again")
    spin(until: { text.string == "second\n" }, "so the file it was refusing arrives")
    XCTAssertFalse(content.hasDiskChangeUnderEdit, "and there is nothing left to mark")
  }

  /// The narrowing still holds: a batch naming one file costs the other tabs nothing, which is
  /// the whole reason the paths are carried through at all.
  @MainActor
  func testATabNobodyWroteToIsNotReread() throws {
    try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "two\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

    let workspace = Workspace()
    let worktree = workspace.addWorktree(root)
    let files = FileColumns()
    files.workspace = workspace
    _ = host(files)
    files.desk.reload(deskID: deskSession(in: worktree, of: workspace).id)
    files.desk.openFile(worktree: worktree, path: "b.txt", preview: false)
    let other = try XCTUnwrap(files.desk.activeFileContent)
    let otherText = try XCTUnwrap(textView(in: other.view))
    spin(until: { otherText.string == "two\n" }, "the other tab read its file")
    files.desk.openFile(worktree: worktree, path: "a.txt", preview: false)
    let content = try XCTUnwrap(files.desk.activeFileContent)
    let text = try XCTUnwrap(textView(in: content.view))
    spin(until: { text.string == "one\n" }, "and this one read its own")

    try "one changed\n".write(
      to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "two changed\n".write(
      to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    files.filesChangedOnDisk(worktreeID: worktree.id, changed: ["a.txt"])

    spin(until: { text.string == "one changed\n" }, "the file the batch named was re-read")
    XCTAssertEqual(otherText.string, "two\n", "the one it did not name was left alone")
  }
}
