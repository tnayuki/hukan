import AppKit
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
  private let screen = VZVirtualMachineView()
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  private let actionButton = NSButton(title: "", target: nil, action: nil)
  private let statusStack = NSStackView()

  init(template: Machine) {
    self.templateID = template.id
    self.name = template.manifest.title
    self.machineTitle = template.manifest.title
    super.init(nibName: nil, bundle: nil)
  }

  init(restoring state: MachineTabState) {
    self.templateID = nil
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
  var keyView: NSView? { screen.isHidden ? nil : screen }
  var isRunning: Bool { runner?.isRunning ?? false }
  /// The running machine, for the guest agent to be reached through.
  var virtualMachine: VZVirtualMachine? { runner?.vm }
  /// Which halves of the guest agent have said they are up; only those are dialled.
  /// Empty until the guest's agent is known to be the one hukan ships, since an agent about to be
  /// replaced is a port about to go away, and dialling one has crashed Virtualization.framework.
  var agentsHeard: Set<String> { agentUpdate == .ready ? runner?.agentsHeard ?? [] : [] }

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

  private func applyResolution() throws {
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
    root.addSubview(screen)
    screen.pin(to: root)

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
    if let directory = sharedDirectory() { runner?.share(directory) }
  }

  // MARK: Lifecycle

  /// Bring the machine onto the screen: copy the template if this tab has no machine yet, then
  /// boot it, or wake it from where the last save left it.
  func start() {
    loadViewIfNeeded()
    isPending = false
    isStopped = false
    guard runner == nil else { return }
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

  private func boot(_ machine: Machine) {
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
    runner.onAgentHello = { [weak self, weak runner] half in
      guard let self, let runner, self.runner === runner else { return }
      self.agentSaidHello(half, on: runner)
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
  private func askForGuestMode() {
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
    if runner == nil, !FileManager.default.fileExists(atPath: machine.stateURL.path) {
      copyToTemplate(machine, title: title, completion: completion)
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
    }
    shutDownOnceAnswering()
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
    if let runner { runner.forceStop(completion: finish) } else { finish() }
  }

  @objc private func actionPressed() {
    start()
  }

  // MARK: What the tab shows

  private func showScreen() {
    stateDescription = "running"
    screen.isHidden = false
    statusStack.isHidden = true
    onStateChange?()
  }

  private func show(status: String) {
    stateDescription = status
    screen.isHidden = true
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
