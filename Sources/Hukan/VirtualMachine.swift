import AppKit
import Carbon
import Virtualization

/// What a machine tab keeps across a relaunch: the desk it stands on and the session machine it
/// shows. The machine's state is saved beside its disk when hukan quits, so a relaunch only has to
/// find the directory again and resume it.
struct MachineTabState: Equatable {
  /// The tab's own id, which is what the agent was given, so it names the same tab after a
  /// relaunch.
  var tabID: UUID?
  var deskID: UUID
  var machineID: String
  var name: String
  /// The template's title, which is what the tab says.
  var title: String
  /// Stopped by hand or shut down, rather than left running: a relaunch leaves it stopped.
  var stopped = false
}

/// One machine on the screen of a desk tab: the session's own copy of a template, made when the
/// tab is opened, run in this process while the tab is open, saved when hukan quits or the tab's
/// session goes, and deleted when the tab is closed (after asking).
final class MachinePaneViewController: NSViewController {
  /// The session machine's id — nil until the copy has been made.
  private(set) var machineID: String?
  private(set) var name: String
  let machineTitle: String
  /// The template to copy, when the tab is opened rather than restored.
  private let templateID: UUID?
  /// The session whose desk the tab stands on, recorded in the copy it makes.
  var sessionID: UUID?
  /// The worktree to share into the guest, asked for when the machine starts, since a session can
  /// have moved worktree between the tab being made and the machine being booted.
  var sharedDirectory: () -> URL? = { nil }

  /// Told when the machine's identity is first known, so the window saves it.
  var onIdentified: (() -> Void)?
  /// Told when what the tab says changes.
  var onStateChange: (() -> Void)?
  /// Told when the resolution held changes, for the menu that shows it.
  var onResolutionChange: (() -> Void)?

  private(set) var stateDescription = "not started"
  /// Not yet asked to run — a restored tab waits until it is looked at.
  private(set) var isPending = true
  /// Stopped by hand or shut down, which a relaunch has to keep, where a machine saved by the
  /// quit is one that was running and is resumed.
  private(set) var isStopped = false

  private var runner: MacMachine?
  /// A Windows machine runs in QEMU rather than in this process, with a screen of its own.
  private var qemu: QEMUMachine?
  private let qemuScreen = QEMUScreenView()
  /// Whether this tab's machine is a Windows one, which has no resolution to change yet.
  private(set) var runsOnQEMU = false
  private let screen = MachineScreenView()
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  private let actionButton = NSButton(title: "", target: nil, action: nil)
  private let statusStack = NSStackView()

  init(template: Machine) {
    self.templateID = template.id
    self.runsOnQEMU = template.manifest.kind == .windows
    self.name = template.manifest.title
    self.machineTitle = template.manifest.title
    super.init(nibName: nil, bundle: nil)
  }

  init(restoring state: MachineTabState) {
    self.templateID = nil
    self.runsOnQEMU =
      UUID(uuidString: state.machineID).flatMap(MachineStore.session(id:))?.manifest.kind
      == .windows
    self.machineID = state.machineID
    self.isStopped = state.stopped
    // Stopped is what it is, whether or not the tab has been looked at since.
    if state.stopped { stateDescription = "stopped" }
    self.name = state.name
    self.machineTitle = state.title
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  var tabTitle: String { machineTitle }
  /// What the keyboard goes to when the tab comes up.
  var keyView: NSView? {
    qemu != nil ? (qemuScreen.isHidden ? nil : qemuScreen) : (screen.isHidden ? nil : screen)
  }
  var isRunning: Bool { qemu?.isRunning ?? runner?.isRunning ?? false }
  /// The running machine, for the guest agent to be reached through.
  var virtualMachine: VZVirtualMachine? { runner?.vm }
  /// Which halves of the guest agent have said they are up; only those are dialled.
  /// Empty until the guest's agent is known to be the one hukan ships, since an agent about to be
  /// replaced is a port about to go away, and dialling one has crashed Virtualization.framework.
  var agentsHeard: Set<String> {
    if let qemu {
      return keyboardSettled && (shareMapped || !qemu.sharesWorktree) ? qemu.agentsHeard : []
    }
    return agentUpdate == .ready ? runner?.agentsHeard ?? [] : []
  }
  /// How the guest's agent is reached, whichever kind of machine this is.
  var guestLink: (any GuestLink)? { qemu ?? runner?.vm }
  /// A picture of the screen when QEMU can take it, which it can with no agent at all.
  var qemuMachine: QEMUMachine? { qemu }

  // MARK: Resolution

  /// The sizes offered when the guest's resolution is fixed: the common desktop ones, in pixels.
  static let fixedResolutions: [(Int, Int)] = [
    (1280, 800), (1440, 900), (1680, 1050), (1920, 1080), (1920, 1200), (2560, 1440),
  ]

  /// nil while the guest follows the tab; otherwise the pixels it is held at.
  private(set) var fixedResolution: (width: Int, height: Int)?

  /// Hold the guest at a size, or let it follow the tab again (nil). Saved in the machine's
  /// manifest, so it outlives the tab and a relaunch; applied to a running guest at once.
  /// `settled` hears how the guest took it — the mode it is drawing, or why not — once there is an
  /// answer; a newer request answers the older one's as superseded.
  func setResolution(
    _ size: (width: Int, height: Int)?, settled: ((String) -> Void)? = nil
  ) throws {
    resolutionSettled?("superseded by a newer resolution")
    resolutionSettled = settled
    resolutionBeforeChange = fixedResolution
    fixedResolution = size
    onResolutionChange?()
    if let id = machineID.flatMap(UUID.init(uuidString:)),
      var machine = MachineStore.session(
        id: id)
    {
      machine.manifest.fitsWindow = size == nil
      if let size { machine.manifest.display = .init(width: size.width, height: size.height) }
      try machine.save()
    }
    try applyResolution()
  }

  private var resolutionBeforeChange: (width: Int, height: Int)?

  private func keepResolution(_ size: (width: Int, height: Int)?) {
    fixedResolution = size
    onResolutionChange?()
    guard let size, let id = machineID.flatMap(UUID.init(uuidString:)),
      var machine = MachineStore.session(id: id)
    else { return }
    machine.manifest.display = .init(width: size.width, height: size.height)
    try? machine.save()
  }

  private func applyResolution() throws {
    if let qemu {
      guard let size = fixedResolution else { return }
      // A mode is the session's, so the user half sets it, and Windows keeps it across a restart.
      GuestAgent.request(
        ["op": "display", "width": size.width, "height": size.height], to: qemu
      ) { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let reply):
          // The screen is black for a few seconds after a mode changes, and the answer is what a
          // screenshot follows.
          let mode = reply["mode"] as? String ?? ""
          DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.settle("guest mode \(mode)")
          }
        case .failure(let error):
          // Refused means it is still at the old size, so that is what stays on record.
          self.keepResolution(self.resolutionBeforeChange)
          self.settle(error.localizedDescription)
        }
      }
      return
    }
    guard let size = fixedResolution else {
      screen.automaticallyReconfiguresDisplay = true
      return
    }
    // Fixed: the view scales the guest into the tab instead of asking it to match.
    screen.automaticallyReconfiguresDisplay = false
    guard let display = runner?.vm?.graphicsDevices.first?.displays.first else {
      if runner?.vm == nil { return }  // applied when it boots
      throw NSError(
        domain: "hukan", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "The machine has no display to resize."])
    }
    let target = CGSize(width: size.width, height: size.height)
    resolutionRequest += 1
    reconfigure(display, to: target, request: resolutionRequest, triesLeft: 60)
  }

  /// After the panel: the guest's own mode, so it draws the panel's pixels rather than a scaled
  /// mode shrunk onto them. Asked of the user half of the guest agent, a moment after the resize
  /// so the guest has seen the new panel and lists its modes; retried while it has not, and left
  /// for the agent's hello when it is not up yet.
  private func matchGuestMode(to target: CGSize, request: Int, triesLeft: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self, request == self.resolutionRequest, let vm = self.runner?.vm else { return }
      guard self.agentsHeard.contains("user") else {
        self.settle("the panel is resized; the guest's mode follows when its agent is up")
        return
      }
      GuestAgent.setDisplay(width: Int(target.width), height: Int(target.height), on: vm) {
        [weak self] result in
        guard let self, request == self.resolutionRequest else { return }
        switch result {
        case .success(let mode):
          self.settle("guest mode \(mode)")
        case .failure(let error):
          guard triesLeft > 0 else {
            self.settle("the guest did not take the mode: \(error.localizedDescription)")
            return
          }
          self.matchGuestMode(to: target, request: request, triesLeft: triesLeft - 1)
        }
      }
    }
  }

  private var resolutionSettled: ((String) -> Void)?

  private func settle(_ report: String) {
    let settled = resolutionSettled
    resolutionSettled = nil
    settled?(report)
  }

  /// Counts resolution requests, so a retry still waiting gives way to a newer one.
  private var resolutionRequest = 0

  /// Ask the display for `target`, and keep asking: the display refuses a resize while the guest
  /// is not ready for one ("does not support reconfiguration at this time") — a machine just
  /// resumed, or still booting — and the refusal is about the moment, not the size.
  private func reconfigure(
    _ display: VZGraphicsDisplay, to target: CGSize, request: Int, triesLeft: Int
  ) {
    guard request == resolutionRequest, runner?.vm != nil else { return }
    do {
      try display.reconfigure(sizeInPixels: target)
      matchGuestMode(to: target, request: request, triesLeft: 10)
    } catch {
      guard triesLeft > 0 else {
        settle("the display refused the size: \(error.localizedDescription)")
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        self?.reconfigure(display, to: target, request: request, triesLeft: triesLeft - 1)
      }
    }
  }

  /// What the tab is showing the guest at, for `vm_list` and the menu: "fit", or the pixels.
  var resolutionDescription: String {
    if let size = fixedResolution { return "\(size.width)x\(size.height)" }
    // No number: while the view resizes the guest under it, the display's `sizeInPixels` cannot
    // be relied on — it has reported 1920x1200 for a guest at 2048x2788.
    return "fit"
  }
  /// Whether the user has let the agent use this machine. Asked once per tab, never saved: an
  /// answer back after a relaunch would be hukan giving it again on nobody's behalf.
  var agentAllowed = false

  override func loadView() {
    let root = NSView()
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor.black.cgColor
    screen.capturesSystemKeys = true
    // The guest's resolution follows the tab, so a column dragged wider is more desktop rather
    // than the same desktop scaled up.
    screen.automaticallyReconfiguresDisplay = fixedResolution == nil
    screen.isHidden = true
    screen.onInputSourceKey = { [weak self] japanese in self?.selectInputSource(japanese) }
    root.addSubview(screen)
    screen.pin(to: root)
    qemuScreen.isHidden = true
    root.addSubview(qemuScreen)
    qemuScreen.pin(to: root)

    statusLabel.alignment = .center
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.isSelectable = true
    actionButton.target = self
    actionButton.action = #selector(actionPressed)
    actionButton.isHidden = true
    statusStack.orientation = .vertical
    statusStack.spacing = 12
    statusStack.addArrangedSubview(statusLabel)
    statusStack.addArrangedSubview(actionButton)
    statusStack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(statusStack)
    NSLayoutConstraint.activate([
      statusStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      statusStack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      statusStack.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40),
    ])
    view = root
  }

  /// The session moved to another worktree: the guest is shown the new one where it stands.
  func shareChanged() {
    let directory = sharedDirectory()
    qemu?.share(directory)
    if let directory { runner?.share(directory) }
  }

  // MARK: Lifecycle

  /// Bring the machine onto the screen: copy the template if this tab has no machine yet, then
  /// boot it, or wake it from where the last save left it.
  func start() {
    loadViewIfNeeded()
    isPending = false
    isStopped = false
    guard runner == nil, qemu == nil else { return }
    if let machineID, let id = UUID(uuidString: machineID) {
      guard let machine = MachineStore.session(id: id) else {
        show(failure: "\(name) is no longer on this Mac.", retry: false)
        return
      }
      boot(machine)
    } else if let templateID {
      copyTemplate(templateID)
    }
  }

  private func copyTemplate(_ templateID: UUID) {
    guard let template = MachineStore.template(id: templateID) else {
      show(failure: "The template \(machineTitle) is gone.", retry: false)
      return
    }
    show(status: "Copying \(machineTitle)…")
    DispatchQueue.global(qos: .userInitiated).async {
      let session = self.sessionID
      let result = Result { try MachineStore.copy(template, for: session) }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        switch result {
        case .success(let machine):
          self.machineID = machine.id.uuidString
          self.name = machine.id.uuidString
          self.onIdentified?()
          self.boot(machine)
        case .failure(let error):
          self.show(failure: error.localizedDescription, retry: true)
        }
      }
    }
  }

  private func bootWindows(_ machine: Machine) {
    show(
      status: FileManager.default.fileExists(atPath: machine.stateURL.path)
        ? "Resuming \(machineTitle)…" : "Starting \(machineTitle)…")
    let qemu = QEMUMachine(machine: machine)
    qemu.sharedDirectory = sharedDirectory()
    self.qemu = qemu
    keyboardSettled = false
    keyboardBusy = false
    clockSet = false
    agentChecked = false
    resolutionRestored = false
    if machine.manifest.fitsWindow == false {
      fixedResolution = (machine.manifest.display.width, machine.manifest.display.height)
    }
    qemu.onAgentHello = { [weak self, weak qemu] half in
      guard let self, let qemu, self.qemu === qemu else { return }
      // A resumed guest comes back at a mode of its own choosing, whatever it was saved at.
      if half == "user", qemu.resumedFromSave, !self.resolutionRestored {
        self.resolutionRestored = true
        try? self.applyResolution()
      }
      // Every boot, since a restart for the keyboard loses the mapping; a resumed one still has it.
      if qemu.agentsHeard.isSuperset(of: ["user", "root"]) { self.mapShare(on: qemu) }
      guard half == "root" else { return }
      self.setClock(on: qemu)
      self.settleKeyboard(on: qemu)
    }
    qemu.onStop = { [weak self] error in
      guard let self else { return }
      self.qemuScreen.disconnect()
      self.qemu = nil
      if let whenStopped = self.whenStopped {
        self.whenStopped = nil
        whenStopped(error)
        return
      }
      if qemu.resumeFailed {
        // The saved state is gone with the failure, so this boots from the disk — what a macOS
        // machine does too, its state spent on the one attempt. What is lost is what was in
        // memory, as if the power had gone.
        self.start()
      } else if let error {
        self.show(failure: error.localizedDescription, retry: true)
      } else {
        self.show(stopped: "\(self.machineTitle) shut down.")
      }
    }
    do {
      try qemu.start()
    } catch {
      self.qemu = nil
      show(failure: error.localizedDescription, retry: true)
      return
    }
    qemuScreen.onFocus = { [weak self] focused in self?.carryClipboard(intoGuest: focused) }
    qemuScreen.connect(socket: qemu.displaySocket)
    showScreen()
  }

  private var clockSet = false

  /// The text last carried either way, so a round trip does not carry it back.
  private var carriedText: String?
  private var carriedChangeCount = -1

  /// A Windows guest's clipboard, as text, through its agent: this Mac's into the guest when its
  /// screen takes the keyboard, and the guest's out when the screen lets it go. Carried at those
  /// two moments rather than watched, so nothing moves while nobody is crossing between the two —
  /// a macOS guest has the framework's own sharing instead.
  private func carryClipboard(intoGuest: Bool) {
    guard let qemu, agentsHeard.contains("user") else { return }
    let pasteboard = NSPasteboard.general
    if intoGuest {
      guard pasteboard.changeCount != carriedChangeCount,
        let text = pasteboard.string(forType: .string), text != carriedText
      else { return }
      carriedChangeCount = pasteboard.changeCount
      carriedText = text
      GuestAgent.request(["op": "clipboard_set", "text": text], to: qemu) { _ in }
    } else {
      GuestAgent.request(["op": "clipboard_get"], to: qemu) { [weak self] result in
        guard case .success(let reply) = result, let text = reply["text"] as? String,
          !text.isEmpty
        else { return }
        DispatchQueue.main.async {
          guard let self, text != self.carriedText else { return }
          self.carriedText = text
          pasteboard.clearContents()
          pasteboard.setString(text, forType: .string)
          self.carriedChangeCount = pasteboard.changeCount
        }
      }
    }
  }

  /// The share as `W:`, the worktree at `W:\worktree` as it is under `/Volumes/My Shared Files` on
  /// macOS, for the user the agent's commands run as. Windows 11 turns away a share
  /// that takes guests and does not sign, which is what one only the guest can reach is, so the
  /// client is told to accept it first.
  private var shareMapped = false

  private func mapShare(on qemu: QEMUMachine) {
    guard qemu.sharesWorktree else { return }
    shareMapped = false
    GuestAgent.exec(
      [
        "powershell.exe", "-NoProfile", "-Command",
        "Set-SmbClientConfiguration -EnableInsecureGuestLogons $true"
          + " -RequireSecuritySignature $false -Confirm:$false",
      ], on: qemu, admin: true
    ) { _ in
      GuestAgent.exec(
        [
          "cmd.exe", "/c",
          "if not exist W:\\ net use W: \\\\10.0.2.4\\hukan /persistent:no",
        ], on: qemu
      ) { [weak self] _ in
        // Mapped or not, the machine is handed over: a share that would not map is no reason to
        // keep the rest of it from the agent.
        DispatchQueue.main.async { self?.shareMapped = true }
      }
    }
  }

  /// A resumed guest's clock says when it was saved, however long ago that was.
  private func setClock(on qemu: QEMUMachine) {
    guard qemu.resumedFromSave, !clockSet else { return }
    clockSet = true
    let now = ISO8601DateFormatter().string(from: Date())
    GuestAgent.exec(
      ["powershell.exe", "-NoProfile", "-Command", "Set-Date -Date ([DateTime]::Parse('\(now)'))"],
      on: qemu, admin: true
    ) { _ in }
  }

  private var keyboardSettled = false
  private var keyboardBusy = false

  /// Make the guest believe in the keyboard on this Mac, restarting it once if it has to change.
  /// The tools wait for this: an agent about to be restarted is not one to hand out.
  private func settleKeyboard(on qemu: QEMUMachine) {
    guard !keyboardSettled, !keyboardBusy else { return }
    keyboardBusy = true
    guard !agentChecked else {
      compareKeyboard(on: qemu)
      return
    }
    agentChecked = true
    updateWindowsAgent(on: qemu)
  }

  private var agentChecked = false
  private var resolutionRestored = false

  /// The agent is compared byte for byte with the one this build ships, as on macOS. It cannot be
  /// replaced from inside itself, since Windows will not overwrite a program that is running, so a
  /// script left behind stops both halves, moves the new file in and starts them again.
  private func updateWindowsAgent(on qemu: QEMUMachine) {
    let directory = "C:\\Program Files\\Hukan"
    let path = directory + "\\hukan-guest-agent.exe"
    GuestAgent.read(path, on: qemu, admin: true) { [weak self] result in
      guard let self, self.qemu === qemu else { return }
      guard case .success(let installed) = result,
        let bundled = Bundle.main.url(forResource: "hukan-guest-agent", withExtension: "exe")
          .flatMap({ try? Data(contentsOf: $0) }),
        installed != bundled
      else {
        self.compareKeyboard(on: qemu)
        return
      }
      let script = Self.windowsAgentUpdateScript(path: path)
      GuestAgent.write(bundled, to: path + ".new", on: qemu, admin: true) { _ in
        GuestAgent.write(Data(script.utf8), to: directory + "\\update.cmd", on: qemu, admin: true) {
          _ in
          let launch =
            "Start-Process cmd.exe -WindowStyle Hidden -ArgumentList '/c', "
            + "'\"\(directory)\\update.cmd\"'"
          GuestAgent.exec(
            ["powershell.exe", "-NoProfile", "-Command", launch], on: qemu, admin: true
          ) { _ in }
          // Both halves go away and come back; their next hello starts the check over.
          DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.keyboardBusy = false
          }
        }
      }
    }
  }

  // Internal so update ordering can be checked without a running Windows agent.
  static func windowsAgentUpdateScript(path: String) -> String {
    return [
      "@echo off", "ping -n 3 127.0.0.1 >nul", "sc stop HukanGuestAgent",
      "taskkill /f /im hukan-guest-agent.exe", "ping -n 3 127.0.0.1 >nul",
      "move /y \"\(path).new\" \"\(path)\"", "sc start HukanGuestAgent",
      "schtasks /run /tn HukanGuestAgent", "del \"%~f0\"", "",
    ].joined(separator: "\r\n")
  }

  private func compareKeyboard(on qemu: QEMUMachine) {
    let jis = WindowsKeyboard.hostIsJIS
    GuestAgent.exec(
      ["reg.exe", "query", WindowsKeyboard.key, "/v", "OverrideKeyboardIdentifier"], on: qemu,
      admin: true
    ) { [weak self] result in
      guard let self, self.qemu === qemu else { return }
      let isJIS: Bool
      if case .success(let run) = result {
        isJIS = String(decoding: run.stdout, as: UTF8.self).contains("PCAT_106KEY")
      } else {
        // Not there to ask: leave the guest as it is rather than restart it on a guess.
        self.keyboardBusy = false
        self.keyboardSettled = true
        return
      }
      guard isJIS != jis else {
        self.keyboardBusy = false
        self.keyboardSettled = true
        return
      }
      self.applyKeyboard(WindowsKeyboard.commands(jis: jis)[...], on: qemu)
    }
  }

  private func applyKeyboard(_ commands: ArraySlice<[String]>, on qemu: QEMUMachine) {
    guard let command = commands.first else {
      GuestAgent.exec(["shutdown.exe", "/r", "/t", "0"], on: qemu, admin: true) { _ in }
      // Once it is gone: a hello from the old agent must not start this over.
      DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
        self?.keyboardBusy = false
      }
      return
    }
    GuestAgent.exec(command, on: qemu, admin: true) { [weak self] _ in
      self?.applyKeyboard(commands.dropFirst(), on: qemu)
    }
  }

  private func boot(_ machine: Machine) {
    if machine.manifest.kind == .windows {
      bootWindows(machine)
      return
    }
    if machine.manifest.fitsWindow == false {
      fixedResolution = (machine.manifest.display.width, machine.manifest.display.height)
    }
    try? applyResolution()
    let resuming = FileManager.default.fileExists(atPath: machine.stateURL.path)
    show(status: resuming ? "Resuming \(machineTitle)…" : "Starting \(machineTitle)…")
    let runner = MacMachine(machine: machine, sharedDirectory: sharedDirectory())
    self.runner = runner
    agentUpdate = .unchecked
    modeAsked = false
    guestPrepared = false
    runner.onAgentHello = { [weak self, weak runner] half in
      guard let self, let runner, self.runner === runner else { return }
      self.agentSaidHello(half, on: runner)
    }
    // The guest stopping on its own — shut down from inside, or by the save that asked it to —
    // as a Windows machine's QEMU leaving is: a save carries on to its copy, and anything else
    // says the machine shut down and offers to start it, rather than leaving a dark screen.
    runner.onStop = { [weak self, weak runner] error in
      DispatchQueue.main.async {
        guard let self, let runner, self.runner === runner else { return }
        self.runner = nil
        self.screen.virtualMachine = nil
        if let whenStopped = self.whenStopped {
          self.whenStopped = nil
          whenStopped(error)
        } else if let error {
          self.show(failure: MacMachine.explain(error), retry: true)
        } else {
          self.show(stopped: "\(self.machineTitle) shut down.")
        }
      }
    }
    runner.start { [weak self] error in
      guard let self else { return }
      if let error {
        self.runner = nil
        self.show(failure: MacMachine.explain(error), retry: true)
        return
      }
      self.screen.virtualMachine = runner.vm
      self.showScreen()
      // A fixed size asked for while it was starting is put to the guest now it has a display.
      if self.fixedResolution != nil { try? self.applyResolution() }
    }
  }

  /// The tab is going without being closed — the window closing, the session going away: the
  /// machine is saved, so the next start resumes it where it was.
  func suspendMachine(completion: @escaping () -> Void = {}) {
    if let qemu {
      qemuScreen.disconnect()
      qemu.save { [weak self] in
        self?.qemu = nil
        completion()
      }
      return
    }
    guard let runner else {
      completion()
      return
    }
    screen.virtualMachine = nil
    runner.save { [weak self] in
      self?.runner = nil
      completion()
    }
  }

  /// Stopped by the agent: saved like a suspend, and the tab says so and offers to start it.
  func stopMachine(completion: @escaping () -> Void) {
    suspendMachine { [weak self] in
      guard let self else { return completion() }
      self.show(stopped: "\(self.machineTitle) is stopped, saved where it was.")
      self.onStateChange?()
      completion()
    }
  }

  // MARK: Keeping the guest's agent current

  /// Where this boot has got to in making the guest's agent the one this build of hukan ships.
  private enum AgentUpdate {
    case unchecked, checking, updating
    /// The old agents are gone; a hello from now on is one of the new ones.
    case restarting
    case ready
  }
  private var agentUpdate = AgentUpdate.unchecked
  /// A fixed size is put to the guest once per boot, when its agent is first usable.
  private var modeAsked = false

  private func agentSaidHello(_ half: String, on runner: MacMachine) {
    switch agentUpdate {
    case .unchecked:
      if half == "root", let vm = runner.vm {
        agentUpdate = .checking
        checkAgent(on: vm, runner: runner)
      }
    case .restarting:
      if runner.agentsHeard.isSuperset(of: ["user", "root"]) { agentUpdate = .ready }
    case .checking, .updating, .ready:
      break
    }
    askForGuestMode()
  }

  /// The guest's mode is set through its agent, which comes up after the display does.
  private var guestPrepared = false

  /// What a guest is told each boot rather than once in its template, since what it describes —
  /// the Mac's keyboard and its time zone — can change under a template made long before: the
  /// Japanese input a JIS keyboard expects, and the zone this Mac is in.
  private func prepareGuest() {
    guard !guestPrepared, let vm = runner?.vm, agentsHeard.isSuperset(of: ["user", "root"]) else {
      return
    }
    guestPrepared = true
    let zone = TimeZone.current.identifier
    GuestAgent.exec(
      [
        "/bin/sh", "-c",
        "systemsetup -settimezone \"$1\" >/dev/null 2>&1"
          + " || ln -sf \"/usr/share/zoneinfo/$1\" /etc/localtime",
        "sh", zone,
      ], on: vm, admin: true
    ) { _ in }
    guard MachineScreenView.hostIsJIS else { return }
    for id in [
      "com.apple.inputmethod.Kotoeri.RomajiTyping",
      "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
    ] {
      GuestAgent.request(["op": "input_source", "id": id, "enable": true], to: vm) { _ in }
    }
  }

  /// かな or 英数, pressed on the guest's screen.
  private func selectInputSource(_ japanese: Bool) {
    guard let vm = runner?.vm, agentsHeard.contains("user") else { return }
    let id =
      japanese ? "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese" : "com.apple.keylayout.ABC"
    GuestAgent.request(["op": "input_source", "id": id], to: vm) { _ in }
  }

  private func askForGuestMode() {
    prepareGuest()
    guard !modeAsked, agentsHeard.contains("user"), let size = fixedResolution else { return }
    modeAsked = true
    matchGuestMode(
      to: CGSize(width: size.width, height: size.height), request: resolutionRequest, triesLeft: 10)
  }

  /// Compared byte for byte rather than by a version number, so a build nobody remembered to
  /// number is still delivered. A machine this cannot be read from carries on with what it has.
  private func checkAgent(on vm: VZVirtualMachine, runner: MacMachine) {
    GuestAgent.read(GuestAgent.guestBinaryPath, on: vm, admin: true) { result in
      DispatchQueue.main.async { [weak self, weak runner] in
        guard let self, let runner, self.runner === runner else { return }
        guard case .success(let installed) = result,
          let bundled = GuestAgent.bundledBinary.flatMap({ try? Data(contentsOf: $0) }),
          installed != bundled
        else {
          self.agentUpdate = .ready
          self.askForGuestMode()
          return
        }
        self.replaceAgent(with: bundled, on: vm, runner: runner)
      }
    }
  }

  /// Written beside the old one and moved over it, so the two running copies keep the file they
  /// started from; then both are killed and launchd's KeepAlive starts the new one. What was heard
  /// is forgotten once the old ones are gone, since only a hello from the new ones says there is a
  /// port to dial. The permissions are written again first: a row goes in by path, but the first
  /// capture has tccd add the code requirement of the binary that made it, and an ad-hoc signature's
  /// requirement is its hash, so the new binary lost Screen Recording until the row was rewritten.
  private func replaceAgent(with bundled: Data, on vm: VZVirtualMachine, runner: MacMachine) {
    agentUpdate = .updating
    let path = GuestAgent.guestBinaryPath
    let incoming = path + ".new"
    let install =
      "chmod 755 '\(incoming)' && chown root:wheel '\(incoming)' && mv -f '\(incoming)' '\(path)'"
      + " && { (sleep 0.5; killall hukan-guest-agent) >/dev/null 2>&1 & }"
    let username = machineID.flatMap(UUID.init(uuidString:)).flatMap(MachineStore.session(id:))?
      .manifest.username
    let grant = username.map { MacTemplateBuilder.grantScript(user: $0) } ?? "true"
    GuestAgent.write(bundled, to: incoming, on: vm, admin: true) { written in
      guard case .success = written else {
        DispatchQueue.main.async { [weak self] in self?.agentUpdate = .ready }
        return
      }
      GuestAgent.exec(["/bin/sh", "-c", grant], on: vm, admin: true) { _ in
        GuestAgent.exec(["/bin/sh", "-c", install], on: vm, admin: true) { _ in
          // A hello the old ones sent on their way out must not count as the new ones being up,
          // which is what `.updating` ignoring them is for: it read as ready, `vm_open` answered
          // with nothing there to talk to, and a size put to a dying agent was never asked again.
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak runner] in
            runner?.forgetAgents()
            self?.modeAsked = false
            self?.agentUpdate = .restarting
          }
        }
      }
    }
  }

  // MARK: Saving as a template

  /// Waiting on the guest shutting itself down, to go on to the copy.
  private var whenStopped: ((Error?) -> Void)?

  /// Make this machine a template: shut it down, copy the disk, start it again. A template is
  /// shut down and never suspended, or every copy would resume into a disk that has moved on, so
  /// a machine that is merely saved is started first to be shut down properly.
  func saveAsTemplate(title: String, completion: @escaping (Result<Machine, Error>) -> Void) {
    guard
      let machine = machineID.flatMap(UUID.init(uuidString:)).flatMap(MachineStore.session(id:))
    else {
      completion(.failure(MachineError("The machine has not been made yet.")))
      return
    }
    if runner == nil, qemu == nil, !FileManager.default.fileExists(atPath: machine.stateURL.path) {
      copyToTemplate(machine, title: title, completion: completion)
      return
    }
    if machine.manifest.kind == .windows {
      shutDownWindows(machine, title: title, completion: completion)
      return
    }
    if runner == nil { start() }
    let deadline = Date().addingTimeInterval(5 * 60)
    func shutDownOnceAnswering() {
      guard let vm = runner?.vm, agentsHeard.contains("root") else {
        guard Date() < deadline, stateDescription.hasPrefix("failed") == false else {
          completion(
            .failure(MachineError("The guest agent did not answer, so it cannot be shut down.")))
          return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: shutDownOnceAnswering)
        return
      }
      show(status: "Shutting \(machineTitle) down to save it…")
      whenStopped = { [weak self] error in
        if let error {
          completion(.failure(error))
          self?.show(failure: MacMachine.explain(error), retry: true)
        } else {
          self?.copyToTemplate(machine, title: title, completion: completion)
        }
      }
      GuestAgent.exec(["shutdown", "-h", "now"], on: vm, admin: true) { _ in }
      // A shutdown can stall — an app asking whether to save, a process that will not quit — and
      // nothing then ever stops the machine, so the save waited for good behind a dark tab. It is
      // given up on instead, with the guest's screen put back so whatever stopped it can be seen;
      // the machine is not pulled from under it, since a template copied from a machine cut off
      // mid-shutdown would carry that half-finished state into every copy made from it.
      DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
        guard let self, self.whenStopped != nil, self.runner?.vm === vm else { return }
        self.whenStopped = nil
        completion(
          .failure(
            MachineError(
              "\(self.machineTitle) did not shut down within three minutes. Something in it may"
                + " be waiting for an answer; its screen is in the tab.")))
        self.showScreen()
      }
    }
    shutDownOnceAnswering()
  }

  /// Windows has no agent to ask yet, so it is asked the way a person would: the power button. A
  /// machine that is only saved is resumed first, since a template is shut down and never suspended.
  private func shutDownWindows(
    _ machine: Machine, title: String, completion: @escaping (Result<Machine, Error>) -> Void
  ) {
    if qemu == nil { start() }
    guard let qemu else {
      completion(.failure(MachineError("The machine could not be started.")))
      return
    }
    show(status: "Shutting \(machineTitle) down to save it…")
    whenStopped = { [weak self] error in
      if let error {
        completion(.failure(error))
        self?.show(failure: error.localizedDescription, retry: true)
      } else {
        self?.copyToTemplate(machine, title: title, completion: completion)
      }
    }
    // Asked more than once: a machine still resuming does not hear the first.
    func press(_ tries: Int) {
      guard self.qemu === qemu, whenStopped != nil else { return }
      guard tries > 0 else {
        whenStopped = nil
        completion(.failure(MachineError("Windows did not shut down.")))
        showScreen()
        return
      }
      qemu.requestShutdown()
      DispatchQueue.main.asyncAfter(deadline: .now() + 15) { press(tries - 1) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { press(20) }
  }

  private func copyToTemplate(
    _ machine: Machine, title: String, completion: @escaping (Result<Machine, Error>) -> Void
  ) {
    show(status: "Saving \(title)…")
    DispatchQueue.global(qos: .userInitiated).async {
      let result = Result { try MachineStore.saveAsTemplate(machine, title: title) }
      DispatchQueue.main.async { [weak self] in
        completion(result)
        self?.start()
      }
    }
  }

  /// Every pane given, saved before hukan goes — the machines run in this process, so one not
  /// saved by then is a power cut.
  static func suspendAll(_ panes: [MachinePaneViewController], completion: @escaping () -> Void) {
    let group = DispatchGroup()
    for pane in panes where pane.isRunning {
      group.enter()
      pane.suspendMachine { group.leave() }
    }
    group.notify(queue: .main, execute: completion)
  }

  /// The tab was closed and the deletion confirmed: the machine goes, disk and all.
  func deleteMachine() {
    let machine = machineID.flatMap(UUID.init(uuidString:)).flatMap(MachineStore.session(id:))
    screen.virtualMachine = nil
    let finish = { [weak self] in
      self?.runner = nil
      if let machine { try? MachineStore.delete(machine) }
    }
    qemuScreen.disconnect()
    if let qemu {
      qemu.forceStop { [weak self] in
        self?.qemu = nil
        finish()
      }
    } else if let runner {
      runner.forceStop(completion: finish)
    } else {
      finish()
    }
  }

  @objc private func actionPressed() {
    start()
  }

  // MARK: What the tab shows

  private func showScreen() {
    stateDescription = "running"
    if qemu != nil { qemuScreen.isHidden = false } else { screen.isHidden = false }
    statusStack.isHidden = true
    onStateChange?()
  }

  private func show(status: String) {
    stateDescription = status
    screen.isHidden = true
    qemuScreen.isHidden = true
    statusStack.isHidden = false
    statusLabel.stringValue = status
    statusLabel.textColor = .secondaryLabelColor
    actionButton.isHidden = true
    onStateChange?()
  }

  /// A restored tab, the first time it is looked at: resumed if the quit saved it running, and
  /// otherwise left as it was, waiting for Start.
  func startIfLeftRunning() {
    guard isStopped else { return start() }
    loadViewIfNeeded()
    isPending = false
    show(stopped: "\(machineTitle) is stopped.")
  }

  private func show(stopped: String) {
    isStopped = true
    show(status: stopped)
    stateDescription = "stopped"
    actionButton.title = "Start"
    actionButton.isHidden = false
  }

  private func show(failure: String, retry: Bool) {
    stateDescription = "failed: \(failure)"
    screen.isHidden = true
    qemuScreen.isHidden = true
    statusStack.isHidden = false
    statusLabel.stringValue = failure
    statusLabel.textColor = .labelColor
    actionButton.title = "Try Again"
    actionButton.isHidden = !retry
    onStateChange?()
  }
}

/// File ▸ New Virtual Machine: the templates in the store, each copied for the session on the way
/// in, and the window where templates are made.
final class VirtualMachinesMenu: NSMenu, NSMenuDelegate {
  override init(title: String) {
    super.init(title: title)
    delegate = self
  }

  required init(coder: NSCoder) { fatalError() }

  func menuNeedsUpdate(_ menu: NSMenu) {
    removeAllItems()
    let templates = MachineStore.templates()
    if templates.isEmpty {
      addItem(withTitle: "No Templates", action: nil, keyEquivalent: "")
    }
    for template in templates {
      let item = addItem(
        withTitle: template.manifest.title,
        action: #selector(WorkspaceWindowController.newVirtualMachine(_:)), keyEquivalent: "")
      item.representedObject = template.id.uuidString
      item.toolTip = "Copy \(template.manifest.title) for this session and start it"
    }
    addItem(.separator())
    addItem(
      withTitle: "Virtual Machines…",
      action: #selector(AppDelegate.showVirtualMachines(_:)), keyEquivalent: "")
  }
}

/// The guest's screen, with what a JIS keyboard means put into the ANSI keyboard the guest is
/// given. Virtualization.framework offers no other kind, so a key sent by its position comes out
/// as the ANSI key in that place: ⇧2 is @, and 英数 and かな are ignored outright.
///
/// So on a JIS Mac the symbols are sent as the ANSI keys that type them — modifiers changed for
/// the one stroke and put back — and 英数 and かな are not sent at all but handed to the window,
/// which asks the guest's agent for the input source. Letters and digits keep their places, which
/// is all romaji input reads, and a shortcut held with ⌘ or ⌃ goes by position as it always has.
final class MachineScreenView: VZVirtualMachineView {
  /// 英数 (false) or かな (true) was pressed.
  var onInputSourceKey: ((Bool) -> Void)?

  static var hostIsJIS: Bool {
    KBGetLayoutType(Int16(CGEventSource(stateID: .hidSystemState)?.keyboardType ?? 0))
      == kKeyboardJIS
  }

  /// A JIS key, with ⇧ or without, and the ANSI key and modifiers that type the same character.
  private struct Stroke: Hashable {
    let code: UInt16
    let shift: Bool
  }
  private static let jisToANSI: [Stroke: (code: UInt16, shift: Bool, option: Bool)] = [
    Stroke(code: 19, shift: true): (39, true, false),  // "
    Stroke(code: 22, shift: true): (26, true, false),  // &
    Stroke(code: 26, shift: true): (39, false, false),  // '
    Stroke(code: 28, shift: true): (25, true, false),  // (
    Stroke(code: 25, shift: true): (29, true, false),  // )
    Stroke(code: 27, shift: true): (24, false, false),  // =
    Stroke(code: 24, shift: false): (22, true, false),  // ^
    Stroke(code: 24, shift: true): (50, true, false),  // ~
    Stroke(code: 93, shift: false): (16, false, true),  // ¥, which ABC types as ⌥Y
    Stroke(code: 93, shift: true): (42, true, false),  // |
    Stroke(code: 33, shift: false): (19, true, false),  // @
    Stroke(code: 33, shift: true): (50, false, false),  // `
    Stroke(code: 30, shift: false): (33, false, false),  // [
    Stroke(code: 30, shift: true): (33, true, false),  // {
    Stroke(code: 41, shift: true): (24, true, false),  // +
    Stroke(code: 39, shift: false): (41, true, false),  // :
    Stroke(code: 39, shift: true): (28, true, false),  // *
    Stroke(code: 42, shift: false): (30, false, false),  // ]
    Stroke(code: 42, shift: true): (30, true, false),  // }
    Stroke(code: 94, shift: false): (27, true, false),  // _
    Stroke(code: 94, shift: true): (27, true, false),  // _
  ]

  /// Keys whose press was sent as something else, so their release is not sent at all.
  private var translated: Set<UInt16> = []

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 102 || event.keyCode == 104 {
      if !event.isARepeat { onInputSourceKey?(event.keyCode == 104) }
      return
    }
    if let target = Self.translation(of: event) {
      translated.insert(event.keyCode)
      type(target.code, shift: target.shift, option: target.option, over: event)
      return
    }
    super.keyDown(with: event)
  }

  override func keyUp(with event: NSEvent) {
    if event.keyCode == 102 || event.keyCode == 104 { return }
    if translated.remove(event.keyCode) != nil { return }
    super.keyUp(with: event)
  }

  // Internal with an explicit keyboard type so tests do not depend on the host keyboard.
  static func translation(of event: NSEvent, isJIS: Bool = hostIsJIS) -> (
    code: UInt16, shift: Bool, option: Bool
  )? {
    guard isJIS else { return nil }
    let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if held.contains(.command) || held.contains(.control) { return nil }
    if held.contains(.option) {
      // ⌥¥ is the backslash on a JIS Mac.
      return event.keyCode == 93 && !held.contains(.shift) ? (42, false, false) : nil
    }
    return jisToANSI[Stroke(code: event.keyCode, shift: held.contains(.shift))]
  }

  /// One stroke of `code` with exactly ⇧ and ⌥ as asked, the modifiers really held put back after.
  /// The guest learns modifiers from their own events, so they are changed as events, with the
  /// device-dependent bits a real keyboard sets — without those a modifier reaches it as none.
  private func type(_ code: UInt16, shift: Bool, option: Bool, over event: NSEvent) {
    let held = event.modifierFlags
    var flags = held.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .option])
    if shift { flags.insert(.shift) }
    if option { flags.insert(.option) }
    var raw = flags.rawValue | 0x100
    if shift { raw |= 0x02 }
    if option { raw |= 0x20 }
    let wanted = NSEvent.ModifierFlags(rawValue: raw)
    func send(_ type: NSEvent.EventType, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags) {
      guard
        let synthetic = NSEvent.keyEvent(
          with: type, location: event.locationInWindow, modifierFlags: modifiers,
          timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
          characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
      else { return }
      switch type {
      case .keyDown: super.keyDown(with: synthetic)
      case .keyUp: super.keyUp(with: synthetic)
      default: super.flagsChanged(with: synthetic)
      }
    }
    let shiftChanges = shift != held.contains(.shift)
    let optionChanges = option != held.contains(.option)
    if shiftChanges { send(.flagsChanged, 56, wanted) }
    if optionChanges { send(.flagsChanged, 58, wanted) }
    send(.keyDown, code, wanted)
    send(.keyUp, code, wanted)
    if optionChanges { send(.flagsChanged, 58, held) }
    if shiftChanges { send(.flagsChanged, 56, held) }
  }
}
