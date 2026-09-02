import AppKit
import Darwin
import SwiftTerm

/// One shell running under a PTY — a child of a Worktree like `AgentSession`, a process running
/// in this worktree. Where `ClaudeSession` stays pipes-only (stream-json is a pipe protocol; a
/// PTY would mix echo and control sequences into the JSON), this needs the terminal, so it rides
/// SwiftTerm's `LocalProcessTerminalView`, which forkpty's the shell and renders it.
///
/// The view *is* the process host, so the model holds it: switching tabs or worktrees must not
/// kill the shell, and only a live, retained view keeps it running. It is created lazily, so a
/// terminal that is never shown never forks.
///
/// The shell runs as `Apple_Terminal` (`TERM_PROGRAM`) so the stock `/etc/zshrc` machinery works
/// for us: it emits OSC 7 at each prompt (the working directory, which names the tab whenever
/// nothing is running in it) and, keyed on `TERM_SESSION_ID`, saves and restores that shell's own
/// command history under `~/.zsh_sessions`. Carrying the same session id across a relaunch is what
/// lets a restored terminal pick its history back up; carrying the directory is what reopens it
/// where it was.
final class TerminalSession: LocalProcessTerminalViewDelegate {
  let id: UUID
  let worktreeID: UUID
  /// A stable id for the shell's save/restore session (`TERM_SESSION_ID`). Persisted across a
  /// relaunch so the restored shell restores its own history.
  let sessionID: String
  /// Where the shell is now, tracked from OSC 7. Names the tab at an idle prompt and, saved, is
  /// where a restored terminal reopens.
  private var currentDirectory: URL
  /// The command holding the pty right now, or nil when the shell itself holds it — an idle
  /// prompt. Sampled rather than announced; see `refreshForegroundProcess`.
  private var foregroundProcess: String?
  /// The tab label, Terminal.app's rule: the running command, or the working directory's last
  /// component when nothing is running. Two idle tabs in one directory therefore read alike, which
  /// is the trade Terminal.app makes too and the right one — a name saying what the tab is *doing*
  /// beats one that is merely unique, and the busy tab is the one being looked for.
  var title: String { foregroundProcess ?? Self.directoryLabel(for: currentDirectory.path) }

  var currentDirectoryPath: String { currentDirectory.path }

  /// Relabel the tab when the working directory changes.
  var onTitleChange: (() -> Void)?
  /// The shell exited (`exit`, Ctrl-D, a crash). The owner drops the tab. Delivered on the main
  /// queue — SwiftTerm reports termination from its own background monitor.
  var onExit: (() -> Void)?

  /// Scrollback from a previous run, replayed as a static banner above the fresh shell on first
  /// display (restoration). Empty for a terminal created live. Cleared once fed so a re-show does
  /// not double it.
  private var restoredScrollback: String

  init(
    id: UUID = UUID(), worktreeID: UUID, cwd: URL, restoredDirectory: URL? = nil,
    sessionID: String? = nil, restoredScrollback: String = ""
  ) {
    self.id = id
    self.worktreeID = worktreeID
    self.sessionID = sessionID ?? id.uuidString
    self.currentDirectory = restoredDirectory ?? cwd
    self.restoredScrollback = restoredScrollback
  }

  private var spawned: LocalProcessTerminalView?
  var isSpawned: Bool { spawned != nil }
  /// Whether the shell is alive. False before the view spawns and after the process exits.
  var isRunning: Bool { spawned?.process.running ?? false }
  /// The live shell's pid, or nil before it spawns and after it exits. What the footprint reading
  /// needs to tell this window's terminal branch of the process tree from another window's.
  var shellPID: pid_t? {
    guard let spawned, spawned.process.running else { return nil }
    return spawned.process.shellPid
  }

  /// The terminal view, spawning the shell on first access (forkpty). Retained here so the shell
  /// survives tab and worktree switches; the owner adds and removes it from the view hierarchy.
  var view: LocalProcessTerminalView {
    if let spawned { return spawned }
    let terminal = HukanTerminalView(frame: .zero)
    HukanTerminalView.enableWordJumpKeys()
    terminal.processDelegate = self
    // A restored terminal shows its old scrollback first, as a static record, then a dimmed rule —
    // the fresh shell's prompt starts below it, the way Terminal.app comes back.
    if !restoredScrollback.isEmpty {
      // The buffer is saved with plain LF line breaks, but a raw terminal needs CR too — fed bare,
      // each line would start where the last ended (a staircase). Normalise to CRLF.
      let replay =
        restoredScrollback
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\n", with: "\r\n")
      terminal.feed(text: replay + "\r\n\u{1b}[2m—— restored ——\u{1b}[0m\r\n")
      restoredScrollback = ""
    }
    // Pose as Apple_Terminal so /etc/zshrc emits OSC 7 and drives its history save/restore, keyed
    // on our stable TERM_SESSION_ID. PATH is intentionally absent (the login shell rebuilds it via
    // /etc/zprofile), matching SwiftTerm's own defaults.
    var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
    environment.append("TERM_PROGRAM=Apple_Terminal")
    environment.append("TERM_SESSION_ID=\(sessionID)")
    // The terminal's editor is hukan itself: the bundled helper by absolute path, so nothing
    // is installed on PATH, quoted because the Dev bundle has a space in its name. `git commit`
    // lands its message as a tab and returns when the tab closes (`edit … waiting`, matching
    // the `$EDITOR` contract: done when the editor exits). Injected, not forced — a profile
    // that exports its own EDITOR runs later and wins, the register-not-write rule again.
    // HUKAN_TERMINAL_ID is how the helper knows it is inside hukan (a self-addressed Apple
    // event, exempt from the automation prompt) and which worktree's desk an outside file
    // lands on.
    environment.append("HUKAN_TERMINAL_ID=\(sessionID)")
    if let helper = Bundle.main.resourceURL?.appendingPathComponent("hukan").path {
      environment.append("EDITOR='\(helper)' --wait")
      environment.append("VISUAL='\(helper)' --wait")
    }
    // The user's login shell — execName "-zsh" makes it a login shell so the usual profile runs.
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    terminal.startProcess(
      executable: shell, args: [], environment: environment,
      execName: "-" + (shell as NSString).lastPathComponent,
      currentDirectory: currentDirectory.path)
    spawned = terminal
    return terminal
  }

  /// Hang the shell up, the way closing a Terminal.app window does — one SIGHUP, no escalation.
  ///
  /// SwiftTerm's own teardown cannot do it: it sends SIGTERM, which an interactive zsh ignores
  /// outright, and its `io.close()` is a *graceful* DispatchIO close, which waits on the
  /// outstanding read — a 128 KB stream read that no idle shell will ever finish — so the
  /// cleanup handler that closes the pty master never runs either, and the kernel's own hangup
  /// never arrives. A closed tab therefore left its shell, and everything running in it, alive
  /// until the app quit and the exiting process finally dropped the fd. SIGHUP is both what a
  /// terminal is defined to send when the line drops and the one signal that shell does not
  /// ignore; zsh's own handling takes its jobs down with it, which is the point of sending it.
  ///
  /// Then reap: `LocalProcess.terminate()` cancels the exit monitor that would have waited on
  /// the child, so without this the shell trades being alive for being a zombie for as long as
  /// the app runs. The wait blocks, hence the queue — and it is a wait for a process that has
  /// just been hung up.
  func terminate() {
    guard let spawned, spawned.process.running else { return }
    let pid = spawned.process.shellPid
    kill(pid, SIGHUP)
    spawned.process.terminate()
    DispatchQueue.global(qos: .utility).async {
      var status: Int32 = 0
      waitpid(pid, &status, 0)
    }
  }

  /// ⌘K, Terminal.app's "Clear to Start": lift the current line to the top and drop everything
  /// before it. `clearScrollback` discards the history above the visible screen; Ctrl-L (0x0C)
  /// asks the shell's readline to clear the visible screen and redraw the prompt at the top — the
  /// visible lines alone would otherwise survive `clearScrollback`. Together they leave just the
  /// prompt. (At a full-screen program Ctrl-L is a harmless redraw.)
  func clearBuffer() {
    guard let spawned else { return }
    spawned.clearScrollback()
    spawned.send([0x0C])
  }

  /// The current buffer as plain text, bounded to the last `maxLines`, for restoration. Trailing
  /// blank lines (the buffer pads to its height) are dropped so restore adds no gap. A terminal
  /// not yet spawned — or already restored and not re-shown — has nothing to save.
  func scrollbackText(maxLines: Int = 4000) -> String {
    if let spawned {
      let data = spawned.getTerminal().getBufferAsData()
      guard let text = String(data: data, encoding: .utf8) else { return "" }
      var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.removeLast()
      }
      if lines.count > maxLines { lines = Array(lines.suffix(maxLines)) }
      return lines.joined(separator: "\n")
    }
    // Never displayed since restore: carry its old scrollback straight through unchanged.
    return restoredScrollback
  }

  // MARK: Tab label

  private func updateDirectory(_ url: URL) {
    let before = title
    currentDirectory = url
    if title != before { onTitleChange?() }
  }

  /// Re-read what holds the pty, and relabel if it changed. This is polled, where the directory is
  /// not: OSC 7 says when the shell is back at a prompt, but nothing at all says a command has
  /// started — `sleep 60` writes no byte — so the window drives this on a timer.
  func refreshForegroundProcess() {
    guard let spawned, spawned.process.running else { return }
    let before = title
    foregroundProcess = Self.foregroundProcessName(
      pty: spawned.process.childfd, shell: spawned.process.shellPid)
    if title != before { onTitleChange?() }
  }

  /// A directory's tab label: its last component, as in Terminal.app. The root has none and stands
  /// for itself.
  static func directoryLabel(for path: String) -> String {
    let name = URL(fileURLWithPath: path).standardizedFileURL.lastPathComponent
    return name.isEmpty ? "/" : name
  }

  /// The command in the pty's foreground process group — nil when that group is the shell itself
  /// (an idle prompt) or the tty will not say. The master side reads the same tty state the slave's
  /// foreground group lives in, so this is one `tcgetpgrp` syscall plus one small `sysctl`, which
  /// is what makes polling every terminal twice a second affordable.
  static func foregroundProcessName(pty fd: Int32, shell: pid_t) -> String? {
    guard fd >= 0 else { return nil }
    let group = tcgetpgrp(fd)
    guard group > 0, group != shell else { return nil }
    return processName(pid: group)
  }

  /// A pid's executable name, read out of the kernel's process table (`KERN_PROC_PID`'s `p_comm`).
  /// Not `proc_name`, which refuses any process this one does not own: `top` is setuid root, so
  /// the command most likely to be left running in a watched tab was exactly the one that could
  /// not be named. The trade is length — `p_comm` is 16 characters where `proc_name` gives 31 —
  /// and a tab is the wrong place to spend the difference.
  ///
  /// It is the file's name, not `argv[0]` (a login shell's `-zsh` reads as `zsh` here), and never
  /// the arguments: those are a second, far larger `KERN_PROCARGS2` read, and `git` fits a tab
  /// where `git log --oneline --graph` does not.
  static func processName(pid: pid_t) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    // A fixed-width field of bytes, not a string: read up to the kernel's NUL, not to its end.
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    return name.isEmpty ? nil : name
  }

  // MARK: LocalProcessTerminalViewDelegate

  /// OSC 7 at each prompt — a `file://host/path` URL, or a bare path on some setups. Drives the
  /// tab label and the directory a restart reopens in.
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
    guard let directory else { return }
    let path = directory.hasPrefix("file:") ? (URL(string: directory)?.path ?? "") : directory
    guard !path.isEmpty else { return }
    updateDirectory(URL(fileURLWithPath: path))
  }

  func processTerminated(source: TerminalView, exitCode: Int32?) {
    DispatchQueue.main.async { [weak self] in self?.onExit?() }
  }

  // The shell-set window title is not used: the tab is named for the directory or the command
  // running in it, which is what Terminal.app shows and what a shell's own title would repeat.
  func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
  func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
}

/// SwiftTerm's default colours are the dynamic system ones (`textColor` / `textBackgroundColor`),
/// so a fresh terminal already matches light or dark. But SwiftTerm resolves them to fixed RGB
/// once, at creation, and never overrides `viewDidChangeEffectiveAppearance` — so a terminal left
/// open across an appearance flip keeps its old colours. Re-set them (resolved in the new
/// appearance) when it changes, and the terminal follows the system live.
final class HukanTerminalView: LocalProcessTerminalView {
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    effectiveAppearance.performAsCurrentDrawingAppearance {
      nativeForegroundColor = .textColor
      nativeBackgroundColor = .textBackgroundColor
    }
  }

  /// ⌥←/⌥→ jump by word, the way Terminal.app's default key map does — it sends ESC-b / ESC-f, the
  /// readline/zle backward-word / forward-word. SwiftTerm instead encodes Option+arrow as a CSI
  /// modified-cursor key (`\u{1b}[1;3D`), which a plain zsh does not bind, so the jump was dead and
  /// the tail of the sequence leaked as text (`;3D`). SwiftTerm's `keyDown` is `public`, not `open`,
  /// so it cannot be overridden, and an arrow key without ⌘ never reaches `performKeyEquivalent`
  /// (macOS routes it straight to `keyDown`). A local key-down monitor is the one hook that always
  /// fires ahead of the view, so install one and, when a terminal is focused, rewrite ⌥←/→ into the
  /// bytes Terminal.app sends and swallow the event. Installed once, lazily, on the first terminal.
  static func enableWordJumpKeys() { _ = wordJumpMonitor }

  private static let wordJumpMonitor: Any? = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
    event in
    guard let terminal = event.window?.firstResponder as? HukanTerminalView,
      let bytes = wordJumpBytes(for: event)
    else { return event }
    terminal.send(bytes)
    return nil
  }

  /// The word-jump bytes for a key-down, or nil when it is not ⌥←/⌥→. Split out so the match — which
  /// must accept the `.function`/`.numericPad` flags every arrow key also carries, yet reject any
  /// ⌘/⌃/⇧ combination — can be tested without a live view or a monitor.
  static func wordJumpBytes(for event: NSEvent) -> [UInt8]? {
    guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .option else {
      return nil
    }
    switch event.keyCode {
    case 123: return [0x1b, 0x62]  // ⌥←  ESC b (backward-word)
    case 124: return [0x1b, 0x66]  // ⌥→  ESC f (forward-word)
    default: return nil
    }
  }

  /// Terminal.app's context menu, or the slice of it hukan carries. SwiftTerm implements the
  /// actions (`copy:`/`paste:`/`selectAll:`, with `validateUserInterfaceItem` gating Copy on an
  /// active selection) but never overrides `menu(for:)`, so a right-click did nothing. The first
  /// three target the view itself; Clear rides the responder chain to the window controller, the
  /// same route as ⌘K, and validates there the same way. No key equivalents — the main menu
  /// carries those.
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
      .target = self
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Clear Terminal",
      action: #selector(WorkspaceWindowController.clearTerminal(_:)), keyEquivalent: "")
    return menu
  }
}

/// Terminal.app, asked to run one command — the other kind of terminal hukan has, and the one it
/// reaches for when the work cannot happen inside the window.
///
/// Two things need it, for the same reason from opposite directions. `/login` and `/logout` need a
/// real TTY for their browser flow, which the stream-json engine has not got. The Homebrew upgrade
/// needs a process that is not hukan's child, since what it replaces is the bundle hukan is running
/// out of. Both are handed over the same way rather than two ways, which is also what keeps the
/// thing handed over to one shape: a single command line, never a script with quoting inside it.
///
/// Terminal.app runs a login shell that sources the user's profile, so `claude` and `brew` are on
/// PATH there the same way they are for the agent — which is the whole reason this is Terminal.app
/// and not a `Process` of our own.
enum ExternalTerminal {
  /// Open Terminal.app and run `command` in a new window. The caller is not told when it finishes;
  /// nothing here waits, and the window is the report.
  ///
  /// `command` is composed here, never taken from a document or a page: it goes into an AppleScript
  /// string literal, so a double quote in it would end that literal early. Every caller passes a
  /// fixed literal with at most a fixed verb spliced in.
  static func run(_ command: String) throws {
    let script = "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    try task.run()
  }
}
