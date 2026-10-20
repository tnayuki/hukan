import AppKit
import XCTest

@testable import Hukan

/// A desk is a session's, not a worktree's: its tabs go where the session goes. Pinned here are
/// the three things that follow from that — a session moved by its agent takes its tabs with it,
/// two sessions in one checkout keep two desks, and a window saved while desks were worktrees'
/// hands its tabs to the sessions once.
final class DeskOwnershipTests: XCTestCase {
  private func worktreeRoot(_ files: [String]) -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in files {
      try? "let a = 1\n".write(
        to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  private func desk(_ workspace: Workspace) -> WorktreeDeskViewController {
    let desk = WorktreeDeskViewController()
    desk.workspace = workspace
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = desk.view
    return desk
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

  // MARK: The desk follows its session

  /// `EnterWorktree` is the task carrying on in another checkout, so a file tab opens the same
  /// path there — and a file that checkout does not have has nothing left to show.
  func testATabFollowsItsSessionIntoTheNextCheckout() {
    let workspace = Workspace()
    let main = workspace.addWorktree(worktreeRoot(["a.swift", "b.swift"]))
    let task = workspace.addWorktree(worktreeRoot(["a.swift"]))
    let session = deskSession(in: main, of: workspace)
    let desk = desk(workspace)
    desk.reload(deskID: session.id)
    desk.openFile(worktree: main, path: "b.swift", preview: false)
    desk.openFile(worktree: main, path: "a.swift", preview: false)

    session.worktreeID = task.id
    desk.sessionMoved(session, from: main.id)

    XCTAssertEqual(desk.openFilePaths, ["a.swift"], "b.swift is not in the task's checkout")
    XCTAssertEqual(
      desk.activeFileContent?.currentWorktreeID, task.id,
      "the tab showing is the task's a.swift now, read on the spot")
    XCTAssertFalse(
      desk.tabStripReport.contains("(in "), "a tab on its session's worktree names no other")
  }

  /// An unsaved edit is that checkout's, so the tab holding it stays on the buffer it was typed
  /// into — and the strip says which worktree that is, since the name alone now means the other.
  func testAnUnsavedEditStaysOnTheCheckoutItWasTypedIn() throws {
    let workspace = Workspace()
    let main = workspace.addWorktree(worktreeRoot(["a.swift"]))
    let task = workspace.addWorktree(worktreeRoot(["a.swift"]))
    let session = deskSession(in: main, of: workspace)
    let desk = desk(workspace)
    desk.reload(deskID: session.id)
    desk.openFile(worktree: main, path: "a.swift", preview: false)
    let content = try XCTUnwrap(desk.activeFileContent)
    let text = try XCTUnwrap(textView(in: content.view))
    spin(until: { text.isEditable }, "the file's text landed")
    text.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertTrue(content.hasUnsavedEdit)

    session.worktreeID = task.id
    desk.sessionMoved(session, from: main.id)

    XCTAssertEqual(desk.activeFileContent?.currentWorktreeID, main.id)
    XCTAssertTrue(
      desk.tabStripReport.contains("(in \(main.displayName))"),
      "the strip names the worktree the edit is on:\n\(desk.tabStripReport)")
  }

  /// Two conversations in one checkout are two desks: what one has open is not the other's.
  func testTwoSessionsInOneCheckoutKeepTwoDesks() {
    let workspace = Workspace()
    let worktree = workspace.addWorktree(worktreeRoot(["a.swift", "b.swift"]))
    let first = AgentSession(worktreeID: worktree.id, isDetached: true)
    let second = AgentSession(worktreeID: worktree.id, isDetached: true)
    workspace.sessions = [first, second]
    let desk = desk(workspace)

    desk.reload(deskID: first.id)
    desk.openFile(worktree: worktree, path: "a.swift", preview: false)
    desk.reload(deskID: second.id)
    desk.openFile(worktree: worktree, path: "b.swift", preview: false)

    XCTAssertEqual(desk.openFilePaths, ["b.swift"])
    desk.reload(deskID: first.id)
    XCTAssertEqual(desk.openFilePaths, ["a.swift"])
  }

  /// No session, no desk: there is nobody whose tab it would be.
  func testWithNoSessionThereIsNowhereToOpenATab() {
    let workspace = Workspace()
    let worktree = workspace.addWorktree(worktreeRoot(["a.swift"]))
    let desk = desk(workspace)
    desk.reload(deskID: nil)
    desk.openFile(worktree: worktree, path: "a.swift", preview: false)
    desk.openBrowser()
    XCTAssertEqual(desk.tabCount, 0)
  }

  // MARK: A window saved while desks were worktrees'

  private func git(_ arguments: [String], in directory: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-c", "user.name=t", "-c", "user.email=t@t"] + arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
  }

  /// A transcript on disk for `id` in the checkout at `path`, which is what the next discovery
  /// builds a session from.
  private func transcript(_ id: UUID, at path: String) {
    let checkout = URL(fileURLWithPath: path)
    let store = ClaudeSessionStore.directory(for: checkout)
    try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: ClaudeSessionStore.transcriptURL(id: id, worktree: checkout).path, contents: Data())
    addTeardownBlock { try? FileManager.default.removeItem(at: store) }
  }

  /// The tabs of a worktree go to the session instructed there last. A worktree no session stands
  /// in keeps only its web tabs, handed to the repository's latest session; its files and
  /// terminals were a click and a fresh shell away anyway.
  func testALegacyStateHandsEachWorktreesTabsToItsSessions() throws {
    let main = worktreeRoot(["a.swift"])
    git(["init", "-q", "-b", "main"], in: main)
    git(["add", "."], in: main)
    git(["commit", "-qm", "init"], in: main)
    let linked = main.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    git(["worktree", "add", "-q", linked.path], in: main)
    addTeardownBlock { try? FileManager.default.removeItem(at: linked) }
    let mainPath = main.resolvingSymlinksInPath().path
    let linkedPath = linked.resolvingSymlinksInPath().path

    let mainID = UUID()
    let linkedID = UUID()
    let older = UUID()
    let newer = UUID()
    transcript(older, at: mainPath)
    transcript(newer, at: mainPath)

    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    func strings(_ values: [String], _ key: String) {
      archiver.encode(values as NSArray, forKey: key)
    }
    strings([mainPath, linkedPath], "worktrees.paths")
    strings([mainID, linkedID].map(\.uuidString), "worktrees.ids")
    strings([older, newer].map(\.uuidString), "instructed.ids")
    archiver.encode(
      [NSNumber(value: 1), NSNumber(value: 2)] as NSArray, forKey: "instructed.dates")
    strings([mainID, linkedID].map(\.uuidString), "browsers.worktreeIDs")
    strings(["https://example.com/main", "https://example.com/linked"], "browsers.urls")
    strings(["Main", "Linked"], "browsers.titles")
    strings(["", ""], "browsers.states")
    strings([mainID, linkedID].map(\.uuidString), "files.worktreeIDs")
    strings(["a.swift", "a.swift"], "files.paths")
    strings([mainID].map(\.uuidString), "terminals.worktreeIDs")
    strings([mainPath], "terminals.directories")
    strings(["shell"], "terminals.sessionIDs")
    strings([""], "terminals.scrollbacks")
    strings([mainID].map(\.uuidString), "tabs.orderWorktreeIDs")
    strings(["browser"], "tabs.orderKinds")
    strings([mainID].map(\.uuidString), "tabs.selectedWorktreeIDs")
    archiver.encode([NSNumber(value: 0)] as NSArray, forKey: "tabs.selectedIndexes")
    archiver.finishEncoding()

    let restored = Workspace()
    restored.decodeState(from: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData))
    XCTAssertEqual(Set(restored.sessions.map(\.id)), [older, newer])

    XCTAssertEqual(
      restored.takeRestoredBrowserTabs().map { [$0.title, $0.deskID.uuidString] },
      [["Main", newer.uuidString], ["Linked", newer.uuidString]],
      "the main checkout's latest session takes its own web tab and the session-less worktree's")
    XCTAssertEqual(
      restored.takeRestoredFileTabs().map { [$0.deskID, $0.worktreeID] }, [[newer, mainID]],
      "a file tab of a worktree with no session does not come back")
    XCTAssertEqual(restored.takeRestoredTerminals().map(\.deskID), [newer])
    XCTAssertEqual(
      restored.takeRestoredTabOrder(), [],
      "a desk handed another worktree's tabs drops the order, which named another strip")
    XCTAssertEqual(restored.takeRestoredTabSelection(), [:])
  }

  /// A session stranded by its worktree going comes back after a relaunch: its transcript is
  /// under the gone checkout, which no listing of the worktrees there are reaches, so the mark it
  /// carries is what discovery looks there by.
  func testAStrandedSessionComesBackAfterARelaunch() throws {
    let main = worktreeRoot([]).resolvingSymlinksInPath()
    let gone = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let id = UUID()
    transcript(id, at: gone.path)

    let workspace = Workspace()
    let home = workspace.addWorktree(main)
    let session = AgentSession(id: id, worktreeID: home.id, isDetached: true)
    session.goneWorktree = GoneWorktree(url: gone, branch: "feature")
    workspace.sessions = [session]

    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    workspace.encodeState(to: archiver)
    archiver.finishEncoding()
    let restored = Workspace()
    restored.decodeState(from: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData))

    let back = try XCTUnwrap(restored.session(id: id), "discovery found it under the gone checkout")
    XCTAssertEqual(back.goneWorktree, GoneWorktree(url: gone, branch: "feature"))
    XCTAssertEqual(restored.worktree(id: back.worktreeID)?.url.path, main.path)
    XCTAssertEqual(restored.transcriptHome(of: back), gone)
  }

  /// A desk that took only its own worktree's tabs keeps the order and the showing tab as they
  /// were saved.
  func testALegacyStateKeepsTheOrderOfADeskThatTookOnlyItsOwn() throws {
    let path = worktreeRoot(["a.swift"]).resolvingSymlinksInPath().path
    let worktreeID = UUID()
    let session = UUID()
    transcript(session, at: path)

    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    func strings(_ values: [String], _ key: String) {
      archiver.encode(values as NSArray, forKey: key)
    }
    strings([path], "worktrees.paths")
    strings([worktreeID.uuidString], "worktrees.ids")
    strings([worktreeID.uuidString, worktreeID.uuidString], "browsers.worktreeIDs")
    strings(["https://example.com/a", "https://example.com/b"], "browsers.urls")
    strings(["A", "B"], "browsers.titles")
    strings(["", ""], "browsers.states")
    strings([worktreeID.uuidString, worktreeID.uuidString], "tabs.orderWorktreeIDs")
    strings(["browser", "browser"], "tabs.orderKinds")
    strings([worktreeID.uuidString], "tabs.selectedWorktreeIDs")
    archiver.encode([NSNumber(value: 1)] as NSArray, forKey: "tabs.selectedIndexes")
    archiver.finishEncoding()

    let restored = Workspace()
    restored.decodeState(from: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData))
    XCTAssertEqual(
      restored.takeRestoredTabOrder(),
      [.init(deskID: session, kind: .browser), .init(deskID: session, kind: .browser)])
    XCTAssertEqual(restored.takeRestoredTabSelection(), [session: 1])
  }
}
