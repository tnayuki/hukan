import AppKit
import XCTest

@testable import Hukan

/// ⌘S is hukan writing inside a worktree itself, and every watcher carries `IgnoreSelf` — so the
/// save raises no FSEvents event at all and nothing notices it unless the save says so. That is
/// what makes it the one write whose whole path has to be checked end to end: the buffer reaches
/// the file, and git is asked again about it, since git's answer is what the diffstat, the ±
/// scope and the rail are all drawn from. Built on a real repository driven by the `git` CLI, the
/// way `GitTests` is.
final class FileSaveTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    Git.initialize()
    // Resolve symlinks up front: temp dirs live under /var → /private/var, and libgit2 reports
    // resolved paths.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-save-\(UUID().uuidString)")
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

  /// One commit holding one file — the clean checkout a save has to make a change out of.
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

  private func textView(in view: NSView) -> NSTextView? {
    if let text = view as? NSTextView { return text }
    for subview in view.subviews { if let found = textView(in: subview) { return found } }
    return nil
  }

  /// The file's text lands off the main thread, so the pane is not editable the instant it opens.
  private func spin(until condition: () -> Bool, _ message: String) {
    let deadline = Date().addingTimeInterval(10)
    while !condition() && Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(condition(), message)
  }

  // MARK: tests

  /// The whole round trip: typing into the pane and saving puts the edit on disk *and* makes the
  /// change appear in what git says has changed — then editing it back to what HEAD holds and
  /// saving again takes it away. Both halves matter and both were broken: the save re-ran the
  /// panel's content hits but never re-asked git, so the ± scope, the toolbar's diffstat and the
  /// rail went on describing the worktree as it was before ⌘S.
  @MainActor
  func testSavingMakesTheChangeAppearAndGoAwayAgain() throws {
    try makeRepository()

    let workspace = Workspace()
    let worktree = workspace.addWorktree(root)
    // Two hops: the tracked list, then the working-tree diff. It is the second one this test
    // is measured against, so it waits for both.
    let loaded = expectation(description: "the first git read")
    loaded.expectedFulfillmentCount = 2
    workspace.loadFiles(worktreeID: worktree.id) { loaded.fulfill() }
    wait(for: [loaded], timeout: 10)
    XCTAssertEqual(worktree.changedFiles.map(\.path), [], "the checkout starts clean")

    let files = FileColumns()
    files.workspace = workspace
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = files.desk.view
    files.desk.reload(worktreeID: worktree.id)
    files.desk.openFile(worktree: worktree, path: "a.txt", preview: false)
    let content = try XCTUnwrap(files.desk.activeFileContent)
    let text = try XCTUnwrap(textView(in: content.view))
    spin(until: { text.isEditable }, "the file's text landed")

    // Typing, then ⌘S — the menu's own path.
    let appeared = expectation(description: "git sees the edit")
    workspace.onWorktreeFilesChanged = { id, _ in
      guard id == worktree.id, !worktree.changedFiles.isEmpty else { return }
      appeared.fulfill()
    }
    text.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertTrue(files.hasUnsavedEdit, "typing made the buffer dirty")
    files.saveCurrent()
    wait(for: [appeared], timeout: 10)

    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8),
      "edited hello\n", "the buffer reached the file")
    XCTAssertEqual(worktree.changedFiles.map(\.path), ["a.txt"], "and git was asked again")
    XCTAssertFalse(files.hasUnsavedEdit, "the save cleared the dot")

    // And back: a save that undoes the edit has to empty the changed set, not just fill it.
    let wentAway = expectation(description: "git sees the change go")
    workspace.onWorktreeFilesChanged = { id, _ in
      guard id == worktree.id, worktree.changedFiles.isEmpty else { return }
      wentAway.fulfill()
    }
    text.insertText("hello\n", replacementRange: NSRange(location: 0, length: text.string.count))
    files.saveCurrent()
    wait(for: [wentAway], timeout: 10)
    XCTAssertEqual(worktree.changedFiles.map(\.path), [], "the worktree is clean again")
  }

  /// A file hukan cannot read as text is not an empty one. The read used to fall back to `""`,
  /// which lands as a buffer the reader can type into — and ⌘S writes that buffer back, so a
  /// mis-clicked archive plus one keystroke was the archive gone. What is pinned here is the
  /// bytes surviving, which is the half that cannot be undone.
  @MainActor
  func testAFileThatIsNotTextCannotBeTypedOver() throws {
    try makeRepository()
    // A PNG's first byte is 0x89, which no UTF-8 sequence starts with.
    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0x00])
    let url = root.appendingPathComponent("blob.bin")
    try bytes.write(to: url)

    let workspace = Workspace()
    let worktree = workspace.addWorktree(root)
    let files = FileColumns()
    files.workspace = workspace
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = files.desk.view
    files.desk.reload(worktreeID: worktree.id)
    files.desk.openFile(worktree: worktree, path: "blob.bin", preview: false)
    let content = try XCTUnwrap(files.desk.activeFileContent)
    let text = try XCTUnwrap(textView(in: content.view))
    spin(until: { !text.string.isEmpty }, "the pane said what it found")

    // What it says is the type's own name, not "not text" — that one is true of every binary
    // alike and says nothing about any of them. The name is the system's, so only the half
    // hukan wrote is pinned.
    XCTAssertTrue(text.string.hasSuffix("— 10 bytes"), text.string)
    XCTAssertFalse(text.isEditable, "and refuses the keyboard over it")
    XCTAssertFalse(files.hasUnsavedEdit, "a note standing in for a file is not an unsaved edit")

    // The whole point: even asked to save outright, nothing is written.
    files.saveCurrent()
    XCTAssertEqual(try Data(contentsOf: url), bytes, "the file is untouched")
  }

  /// And an extension nothing has a name for keeps the flat answer, which is the one case it was
  /// ever right for.
  @MainActor
  func testAnUnknownKindOfFileStillSaysItIsNotText() throws {
    try makeRepository()
    try Data([0xFF, 0xFE, 0x00]).write(to: root.appendingPathComponent("blob.zzz"))

    let workspace = Workspace()
    let worktree = workspace.addWorktree(root)
    let files = FileColumns()
    files.workspace = workspace
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = files.desk.view
    files.desk.reload(worktreeID: worktree.id)
    files.desk.openFile(worktree: worktree, path: "blob.zzz", preview: false)
    let content = try XCTUnwrap(files.desk.activeFileContent)
    let text = try XCTUnwrap(textView(in: content.view))
    spin(until: { !text.string.isEmpty }, "the pane said what it found")
    XCTAssertEqual(text.string, "Not a text file — 3 bytes")
  }

  /// Closing the window, and quitting, ask about every unsaved edit the way ⌘W asks about one.
  /// Only the unobstructed half is checkable here — the other half is an `NSAlert` standing in
  /// front of the test — so what this pins is that a desk with nothing to save is not stopped by
  /// the new question, and that the dirty flag the question reads is the one the pane sets.
  @MainActor
  func testClosingIsUnobstructedUntilThereIsAnUnsavedEdit() throws {
    try makeRepository()

    let workspace = Workspace()
    let worktree = workspace.addWorktree(root)
    let files = FileColumns()
    files.workspace = workspace
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = files.desk.view
    files.desk.reload(worktreeID: worktree.id)
    files.desk.openFile(worktree: worktree, path: "a.txt", preview: false)
    let content = try XCTUnwrap(files.desk.activeFileContent)
    let text = try XCTUnwrap(textView(in: content.view))
    spin(until: { text.isEditable }, "the file's text landed")

    XCTAssertTrue(files.desk.confirmClosingWindow(), "a saved desk closes without a word")

    text.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertTrue(files.hasUnsavedEdit, "and this is what the question is asked about")
  }
}
