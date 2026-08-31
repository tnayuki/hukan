import AppKit
import SwiftTerm
import XCTest

@testable import Hukan

/// The terminal's core is a real PTY-backed shell. These exercise the spawn end to end — a
/// process actually forks — rather than mocking it, since the whole point of the model is that
/// accessing `view` starts a live shell in the worktree and retains it.
final class TerminalSessionTests: XCTestCase {
  func testViewSpawnsAndRetainsAShell() {
    let terminal = TerminalSession(
      worktreeID: UUID(), cwd: URL(fileURLWithPath: NSTemporaryDirectory()))
    XCTAssertFalse(terminal.isSpawned, "no shell before the view is touched")
    XCTAssertFalse(terminal.isRunning)

    let view = terminal.view
    XCTAssertTrue(terminal.isSpawned, "touching the view forks the shell")
    XCTAssertTrue(terminal.isRunning, "the shell is running once the view has spawned it")
    XCTAssertGreaterThan(view.process.shellPid, 0)
    XCTAssertTrue(terminal.view === view, "the view is retained, not remade each access")

    terminal.terminate()
  }

  func testTabLabelIsTheDirectoryName() {
    // Terminal.app's rule: the last component, wherever the shell is.
    XCTAssertEqual(TerminalSession.directoryLabel(for: "/Users/x/dev/hukan"), "hukan")
    XCTAssertEqual(TerminalSession.directoryLabel(for: "/Users/x/dev/hukan/Sources/Hukan"), "Hukan")
    XCTAssertEqual(TerminalSession.directoryLabel(for: "/tmp/"), "tmp")
    // The root has no last component and stands for itself.
    XCTAssertEqual(TerminalSession.directoryLabel(for: "/"), "/")
  }

  func testForegroundProcessNameReadsTheProcess() {
    // These run inside the app, a process we own, so libproc will name it — the executable's
    // name, which is what `processName` reports too.
    XCTAssertEqual(TerminalSession.processName(pid: getpid()), ProcessInfo.processInfo.processName)
    // No pty, nothing to name — the label falls back to the directory.
    XCTAssertNil(TerminalSession.foregroundProcessName(pty: -1, shell: 0))
  }

  func testTabLabelFollowsTheCommandHoldingThePTY() {
    let terminal = TerminalSession(worktreeID: UUID(), cwd: URL(fileURLWithPath: "/tmp"))
    XCTAssertEqual(terminal.title, "tmp", "an idle terminal is named for its directory")

    let view = terminal.view
    defer { terminal.terminate() }
    // Wait for the shell's first prompt: anything typed before it exists may not survive the
    // profile the login shell is still running.
    XCTAssertTrue(
      spin(untilTrue: {
        !terminal.scrollbackText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }),
      "the shell never reached a prompt")

    view.send(txt: "sleep 2\n")
    XCTAssertTrue(
      spin(untilTrue: {
        terminal.refreshForegroundProcess()
        return terminal.title == "sleep"
      }), "a running command names the tab")

    XCTAssertTrue(
      spin(untilTrue: {
        terminal.refreshForegroundProcess()
        return terminal.title == "tmp"
      }), "the directory comes back when the command ends")
  }

  /// Closing a terminal has to end the shell and whatever was running in it. SwiftTerm's own
  /// teardown does not: SIGTERM is what it sends and an interactive zsh ignores it, so every
  /// close hukan has — the tab's, the worktree's, the repository's — used to leave the shell
  /// alive and invisible until the app quit. Both halves are pinned here: the command, which is
  /// not our child and so is reaped by launchd once its shell hangs up, and the shell itself,
  /// which is ours and would otherwise linger as a zombie.
  func testTerminateHangsUpTheShellAndTheCommandItWasRunning() {
    let terminal = TerminalSession(worktreeID: UUID(), cwd: URL(fileURLWithPath: "/tmp"))
    let view = terminal.view
    XCTAssertTrue(
      spin(untilTrue: {
        !terminal.scrollbackText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }),
      "the shell never reached a prompt")

    view.send(txt: "sleep 600\n")
    XCTAssertTrue(
      spin(untilTrue: {
        terminal.refreshForegroundProcess()
        return terminal.title == "sleep"
      }), "the command never took the pty")
    let shell = view.process.shellPid
    let command = tcgetpgrp(view.process.childfd)
    XCTAssertGreaterThan(command, 0, "no foreground process group to watch")
    XCTAssertNotEqual(command, shell, "the shell itself still holds the pty")

    terminal.terminate()
    XCTAssertTrue(spin(untilTrue: { kill(command, 0) != 0 }), "the command outlived the close")
    XCTAssertTrue(spin(untilTrue: { kill(shell, 0) != 0 }), "the shell outlived the close")
  }

  /// Closing the window is the other way a shell can be left behind, and the one nothing else
  /// catches: the app outlives its last window, so a workspace released with terminals in it left
  /// them running as hukan's children, invisible, until the app quit. SwiftTerm's `deinit` is no
  /// backstop — it closes its I/O and says outright that it sends no signal.
  func testClosingTheWindowHangsUpItsShells() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL
    let repository = Repository(id: directory.path)
    let worktree = Worktree(url: directory, branch: "main", repository: repository)
    repository.worktrees = [worktree]
    let workspace = Workspace()
    workspace.repositories = [repository]
    workspace.selectedWorktreeID = worktree.id

    let controller = WorkspaceWindowController(workspace: workspace)
    let window = controller.window
    controller.newTerminal(nil)
    guard let terminal = workspace.terminals.first else { return XCTFail("no terminal") }
    XCTAssertTrue(
      spin(untilTrue: {
        !terminal.scrollbackText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }),
      "the shell never reached a prompt")
    guard let shell = terminal.shellPID else { return XCTFail("no shell to watch") }

    window?.close()
    XCTAssertTrue(spin(untilTrue: { kill(shell, 0) != 0 }), "the shell outlived its window")
    XCTAssertTrue(workspace.terminals.isEmpty, "and the model still held it")
  }

  /// The window's poll, which is the half the model cannot show: in the app nothing calls
  /// `refreshForegroundProcess` by hand, a timer does, and a timer that never starts leaves every
  /// tab named for its directory forever — indistinguishable, on an idle terminal, from working.
  func testTheWindowRelabelsATabWithoutBeingAsked() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL
    let repository = Repository(id: directory.path)
    let worktree = Worktree(url: directory, branch: "main", repository: repository)
    repository.worktrees = [worktree]
    let workspace = Workspace()
    workspace.repositories = [repository]
    workspace.selectedWorktreeID = worktree.id

    let controller = WorkspaceWindowController(workspace: workspace)
    _ = controller.window
    controller.newTerminal(nil)
    guard let terminal = workspace.terminals.first else { return XCTFail("no terminal") }
    let view = terminal.view
    defer { terminal.terminate() }
    XCTAssertTrue(
      spin(untilTrue: {
        !terminal.scrollbackText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }),
      "the shell never reached a prompt")

    // A full-screen program, the case a poll could plausibly miss — it takes the terminal into raw
    // mode and stops the shell writing prompts. No refresh call here: the timer is under test.
    view.send(txt: "top\n")
    XCTAssertTrue(spin(untilTrue: { terminal.title == "top" }), "the model never saw the command")
    // And the strip itself, which is the half a title on the model does not prove: the tab is an
    // NSButton, and it is `reload` on the desk that has to repaint it.
    XCTAssertTrue(
      spin(untilTrue: { Self.tabTitles(in: controller.window).contains("top") }),
      "the tab strip still reads \(Self.tabTitles(in: controller.window))")

    view.send(txt: "q")
    XCTAssertTrue(
      spin(untilTrue: { Self.tabTitles(in: controller.window).contains(terminal.title) }),
      "the strip never came back to the directory")
  }

  /// Every tab label the window is actually showing, read off the strip's buttons.
  private static func tabTitles(in window: NSWindow?) -> [String] {
    guard let root = window?.contentView else { return [] }
    var titles: [String] = []
    var stack = [root]
    while let view = stack.popLast() {
      if let button = view as? NSButton, !button.title.isEmpty { titles.append(button.title) }
      stack.append(contentsOf: view.subviews)
    }
    return titles
  }

  /// Spin the run loop until the condition holds — the shell is a real process on a real PTY, so
  /// what these wait on is the OS, not hukan.
  private func spin(seconds: TimeInterval = 15, untilTrue condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
  }

  func testWordJumpBytesMatchesOptionArrowsPastTheirFunctionFlags() {
    func key(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
        keyCode: keyCode)!
    }
    // Every arrow key also carries .function/.numericPad; the match must look past them and still
    // fire on plain Option. ⌥← → ESC-b, ⌥→ → ESC-f — what Terminal.app sends.
    XCTAssertEqual(
      HukanTerminalView.wordJumpBytes(for: key(123, [.option, .function, .numericPad])),
      [0x1b, 0x62])
    XCTAssertEqual(
      HukanTerminalView.wordJumpBytes(for: key(124, [.option, .function, .numericPad])),
      [0x1b, 0x66])
    // Any extra ⇧/⌘/⌃, a missing Option, or a non-arrow key leaves the event to the terminal.
    XCTAssertNil(HukanTerminalView.wordJumpBytes(for: key(124, [.option, .shift, .function])))
    XCTAssertNil(HukanTerminalView.wordJumpBytes(for: key(124, [.command, .function])))
    XCTAssertNil(HukanTerminalView.wordJumpBytes(for: key(124, [.function])))
    XCTAssertNil(HukanTerminalView.wordJumpBytes(for: key(0, [.option])))
  }

  func testRemoveTerminalDropsItFromTheWorkspace() {
    let workspace = Workspace()
    let worktreeID = UUID()
    let terminal = TerminalSession(
      worktreeID: worktreeID, cwd: URL(fileURLWithPath: NSTemporaryDirectory()))
    workspace.terminals.append(terminal)
    XCTAssertEqual(workspace.terminals(inWorktree: worktreeID).count, 1)

    workspace.removeTerminal(id: terminal.id)
    XCTAssertTrue(workspace.terminals(inWorktree: worktreeID).isEmpty)
  }
}
