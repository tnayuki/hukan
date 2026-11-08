import AppKit
import Virtualization

/// A macOS machine, run in this process by Virtualization.framework. In process, because that is
/// what puts the guest's own screen on the desk — `VZVirtualMachineView`, from the first frame of
/// the boot — with nothing between it and the person but a view.
///
/// It also means the machine lives exactly as long as hukan does: a quit that does not save it is
/// a power cut. So everything that lets go of one saves it first (`save`), and the next start
/// resumes from that.
final class MacMachine: NSObject, VZVirtualMachineDelegate, VZVirtioSocketListenerDelegate {
  let machine: Machine
  private(set) var vm: VZVirtualMachine?
  /// The worktree the guest sees as `/Volumes/My Shared Files/worktree`.
  private let sharedDirectory: URL?

  /// The guest stopped on its own — shut down from inside, or failed.
  var onStop: ((Error?) -> Void)?

  /// Which halves of the guest agent have said they are up — "user", "root". hukan dials an agent
  /// only once it has heard from it: a connection to a guest port nobody listens on has crashed
  /// Virtualization.framework, so finding out by trying is not an option.
  private(set) var agentsHeard: Set<String> = []
  /// Told each time an agent says hello, which it does at start and every fifteen seconds after.
  var onAgentHello: ((String) -> Void)?
  private let helloListener = VZVirtioSocketListener()
  static let helloPort: UInt32 = 7739

  init(machine: Machine, sharedDirectory: URL?) {
    self.machine = machine
    self.sharedDirectory = sharedDirectory
  }

  var isRunning: Bool {
    guard let vm else { return false }
    return vm.state == .running || vm.state == .paused || vm.state == .starting
      || vm.state == .resuming
  }

  // MARK: Lifecycle

  /// Boot, or wake from the state the last `save` left. A state that will not restore — saved
  /// under another configuration, a different worktree shared — is dropped and the machine boots
  /// cold, which is what it would have done with no state at all.
  /// `provisioning` is a `VZMacGuestProvisioningOptions`, which exists from macOS 27 — typed as
  /// `Any` so the rest of this builds against the older systems hukan still runs on.
  func start(
    provisioning: Any? = nil, recovery: Bool = false, completion: @escaping (Error?) -> Void
  ) {
    let vm: VZVirtualMachine
    do {
      let configuration = try Self.configuration(for: machine, sharedDirectory: sharedDirectory)
      try configuration.validate()
      vm = VZVirtualMachine(configuration: configuration)
    } catch {
      completion(error)
      return
    }
    vm.delegate = self
    helloListener.delegate = self
    (vm.socketDevices.first as? VZVirtioSocketDevice)?.setSocketListener(
      helloListener, forPort: Self.helloPort)
    self.vm = vm
    let state = machine.stateURL
    guard provisioning == nil, !recovery, FileManager.default.fileExists(atPath: state.path)
    else {
      coldStart(vm, provisioning: provisioning, recovery: recovery, completion: completion)
      return
    }
    vm.restoreMachineStateFrom(url: state) { [weak self] error in
      // A state is spent once read: resuming it twice would wake a second machine from the same
      // moment onto a disk that has moved on.
      try? FileManager.default.removeItem(at: state)
      guard error == nil else {
        self?.coldStart(vm, provisioning: nil, recovery: false, completion: completion)
        return
      }
      vm.resume { result in
        if case .failure(let error) = result { completion(error) } else { completion(nil) }
      }
    }
  }

  private func coldStart(
    _ vm: VZVirtualMachine, provisioning: Any?, recovery: Bool,
    completion: @escaping (Error?) -> Void
  ) {
    let options = VZMacOSVirtualMachineStartOptions()
    options.startUpFromMacOSRecovery = recovery
    if #available(macOS 27, *), let provisioning = provisioning as? VZMacGuestProvisioningOptions {
      do {
        try options.setGuestProvisioning(provisioning)
      } catch {
        completion(error)
        return
      }
    }
    vm.start(options: options) { error in completion(error) }
  }

  /// Pause and write the state beside the disk, then stop — so the next start resumes here.
  func save(completion: @escaping () -> Void) {
    guard let vm, vm.state == .running || vm.state == .paused else {
      self.vm = nil
      completion()
      return
    }
    let state = machine.stateURL
    let write = {
      vm.saveMachineStateTo(url: state) { _ in
        vm.stop { [weak self] _ in
          self?.vm = nil
          completion()
        }
      }
    }
    if vm.state == .paused {
      write()
    } else {
      vm.pause { result in
        if case .success = result {
          write()
        } else {
          vm.stop { [weak self] _ in
            self?.vm = nil
            completion()
          }
        }
      }
    }
  }

  /// Ask the guest to shut down, the way the power button would.
  func requestShutdown() throws {
    try vm?.requestStop()
  }

  /// Stop at once, no questions asked — what deleting the machine is about to make moot.
  func forceStop(completion: @escaping () -> Void) {
    guard let vm, vm.state != .stopped else {
      completion()
      return
    }
    vm.stop { [weak self] _ in
      self?.vm = nil
      completion()
    }
  }

  // MARK: Agents saying hello

  func listener(
    _ listener: VZVirtioSocketListener,
    shouldAcceptNewConnection connection: VZVirtioSocketConnection,
    from socketDevice: VZVirtioSocketDevice
  ) -> Bool {
    let fd = fcntl(connection.fileDescriptor, F_DUPFD_CLOEXEC, 0)
    connection.close()
    guard fd >= 0 else { return false }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      var line = Data()
      var byte: UInt8 = 0
      while Darwin.read(fd, &byte, 1) == 1, byte != 0x0A, line.count < 4096 { line.append(byte) }
      close(fd)
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        let half = object["hello"] as? String
      else { return }
      DispatchQueue.main.async {
        guard let self else { return }
        self.agentsHeard.insert(half)
        self.onAgentHello?(half)
      }
    }
    return true
  }

  /// What was heard is about the guest as it was; after a restart only new hellos count.
  func forgetAgents() {
    agentsHeard = []
  }

  func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    agentsHeard = []
    vm = nil
    onStop?(nil)
  }

  func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
    agentsHeard = []
    vm = nil
    onStop?(error)
  }

  // MARK: Configuration

  /// The worktree under a name that never changes, `worktree`, rather than as the volume itself:
  /// the guest treats the volume's top as a disk of its own and writes `.Trashes` and
  /// `.fseventsd` there, which in a worktree is two folders git then reports. The fixed name is
  /// what keeps the path the same when the worktree changes under it.
  static func share(_ directory: URL) -> VZDirectoryShare {
    VZMultipleDirectoryShare(directories: [
      "worktree": VZSharedDirectory(url: directory, readOnly: false)
    ])
  }

  static func configuration(for machine: Machine, sharedDirectory: URL?) throws
    -> VZVirtualMachineConfiguration
  {
    let manifest = machine.manifest
    guard
      let modelData = manifest.hardwareModel.flatMap({ Data(base64Encoded: $0) }),
      let model = VZMacHardwareModel(dataRepresentation: modelData)
    else { throw MachineError("\(manifest.title) has no hardware model.") }
    guard model.isSupported else {
      throw MachineError("This Mac cannot run \(manifest.title)'s hardware model.")
    }
    guard
      let identifierData = manifest.machineIdentifier.flatMap({ Data(base64Encoded: $0) }),
      let identifier = VZMacMachineIdentifier(dataRepresentation: identifierData)
    else { throw MachineError("\(manifest.title) has no machine identifier.") }

    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = model
    platform.machineIdentifier = identifier
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: machine.auxiliaryURL)

    let configuration = VZVirtualMachineConfiguration()
    configuration.platform = platform
    configuration.bootLoader = VZMacOSBootLoader()
    configuration.cpuCount = manifest.cpuCount
    configuration.memorySize = manifest.memorySize

    let disk = try VZDiskImageStorageDeviceAttachment(
      url: machine.diskURL, readOnly: false, cachingMode: .automatic,
      synchronizationMode: .full)
    configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

    let network = VZVirtioNetworkDeviceConfiguration()
    network.attachment = VZNATNetworkDeviceAttachment()
    if let mac = VZMACAddress(string: manifest.macAddress) { network.macAddress = mac }
    configuration.networkDevices = [network]

    let graphics = VZMacGraphicsDeviceConfiguration()
    graphics.displays = [
      VZMacGraphicsDisplayConfiguration(
        widthInPixels: manifest.display.width, heightInPixels: manifest.display.height,
        pixelsPerInch: 144)
    ]
    configuration.graphicsDevices = [graphics]
    configuration.keyboards = [VZMacKeyboardConfiguration()]
    configuration.pointingDevices = [
      VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration(),
    ]
    configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

    // The clipboard, both ways, through the SPICE agent macOS guests carry since 15.
    let spicePort = VZVirtioConsolePortConfiguration()
    spicePort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
    let spice = VZSpiceAgentPortAttachment()
    spice.sharesClipboard = true
    spicePort.attachment = spice
    let console = VZVirtioConsoleDeviceConfiguration()
    console.ports[0] = spicePort
    configuration.consoleDevices = [console]

    if let sharedDirectory {
      // The automount tag puts the share at /Volumes/My Shared Files with nothing to run in the
      // guest first.
      let share = VZVirtioFileSystemDeviceConfiguration(
        tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
      share.share = Self.share(sharedDirectory)
      configuration.directorySharingDevices = [share]
    }
    return configuration
  }

  /// The framework's own sentence for the limit says nothing about why, and the limit is the
  /// failure most worth explaining: macOS allows two macOS guests at once, across every app.
  static func explain(_ error: Error) -> String {
    let nsError = error as NSError
    if nsError.domain == VZErrorDomain,
      nsError.code == VZError.Code.virtualMachineLimitExceeded.rawValue
    {
      return "Two macOS virtual machines are already running on this Mac, which is as many as"
        + " macOS allows at once. Close one and start again."
    }
    // The framework's top sentence is often the whole of nothing — "Installation failed." — while
    // the reason is a level or two down, so the chain is spelled out.
    var lines = [error.localizedDescription]
    var next = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
    while let underlying = next {
      lines.append("\(underlying.localizedDescription) (\(underlying.domain) \(underlying.code))")
      next = underlying.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    if lines.count == 1 { lines[0] += " (\(nsError.domain) \(nsError.code))" }
    return lines.joined(separator: "\n")
  }
}

struct MachineError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

/// Making a macOS template from an IPSW: a fresh machine directory, macOS installed onto its disk,
/// and the first boot set up with an account, automatic login and SSH — all by the framework, with
/// nothing to click through in the guest.
final class MacTemplateBuilder {
  struct Request {
    var title: String
    var ipsw: URL
    var diskSize: UInt64
    var cpuCount: Int?
    var memorySize: UInt64?
    var username: String
  }

  enum Phase: Equatable {
    case preparing
    case installing(Double)
    case firstBoot
    /// In Recovery, SIP being turned off by typed keystrokes.
    case disablingSIP
    /// SIP off; the agent's permissions being written.
    case granting
    /// The guest is up but hukan could not finish it; it has to be shut down by hand.
    case setupFailed(String)
    case done
    case failed(String)
  }

  let request: Request
  /// The guest account's password: made up here, written into the template's manifest, and used
  /// once by hukan to install its SSH key.
  let password = MacTemplateBuilder.makePassword()
  private(set) var machine: Machine?
  private(set) var running: MacMachine? {
    didSet { showOnScreen() }
  }

  /// The one view the build's machine is drawn into — lent to the window's detail pane while the
  /// build's row is selected, and kept in a window nobody sees otherwise, so the keystrokes typed
  /// into Recovery always have a view to go to. One view, because a machine is drawn into one:
  /// a second view for typing took the screen from the pane and left it black.
  let screenView = VZVirtualMachineView()
  private let parking = NSWindow(
    contentRect: NSRect(x: -10000, y: -10000, width: 960, height: 600), styleMask: [.borderless],
    backing: .buffered, defer: false)

  /// Point the view at whichever machine is up. Called when `installing` or `running` changes and
  /// again once a start has made the machine — `running` is set before its `vm` exists, and a
  /// view left on nil showed black and took Recovery's keystrokes nowhere.
  private func showOnScreen() {
    screenView.virtualMachine = installing ?? running?.vm
  }

  /// Take the view back from the pane when the build's row is no longer the one shown.
  func parkScreen() {
    guard screenView.window !== parking else { return }
    screenView.removeFromSuperview()
    parking.contentView = screenView
  }

  /// Where the build is, which decides what the guest stopping means.
  private enum Stage {
    /// Account made, agent going in, SSH about to be turned off.
    case firstBoot
    /// In macOS Recovery, SIP being turned off.
    case recovery
    /// Booted again with SIP off, the agent's permissions being written.
    case granting
  }
  private var stage = Stage.firstBoot
  private var keyboard: GuestKeyboard?
  /// Times Recovery may be gone through again after the keystrokes did not take.
  private var recoveryRetriesLeft = 2
  /// The machine the installer is restoring into, while it is — shown on screen like the first
  /// boot is, since an install the person can watch is one they can tell from a hang.
  private(set) var installing: VZVirtualMachine? {
    didSet { showOnScreen() }
  }
  /// What is on screen now: the installer's machine, then the first boot's.
  var screenMachine: VZVirtualMachine? { installing ?? running?.vm }
  var onPhase: ((Phase) -> Void)?
  private var progressObservation: NSKeyValueObservation?
  /// Installs left before giving up. The restore service fails now and then with nothing wrong
  /// (`AMRestorePerformRestoreModeRestoreWithError … error: 1`) and passes the next time, so one
  /// failure costs a fresh disk and another go rather than the build.
  private var installsLeft = 2
  private var image: VZMacOSRestoreImage?

  init(request: Request) {
    self.request = request
    parking.isReleasedWhenClosed = false
    // Scaled to fit rather than asking the guest to match: an install, Recovery and a first boot
    // cannot change their resolution.
    screenView.automaticallyReconfiguresDisplay = false
    screenView.capturesSystemKeys = true
    parking.contentView = screenView
  }

  func run() {
    onPhase?(.preparing)
    VZMacOSRestoreImage.load(from: request.ipsw) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .failure(let error): self.onPhase?(.failed(error.localizedDescription))
        case .success(let image): self.prepare(image)
        }
      }
    }
  }

  private func prepare(_ image: VZMacOSRestoreImage) {
    self.image = image
    guard let requirements = image.mostFeaturefulSupportedConfiguration,
      requirements.hardwareModel.isSupported
    else {
      onPhase?(.failed("This Mac cannot run the macOS in \(request.ipsw.lastPathComponent)."))
      return
    }
    MachineStore.prepare()
    let id = UUID()
    // Made under a dot-name and moved into place once the first boot has set it up, so a template
    // half-installed is never listed.
    let url = MachineStore.templatesURL.appendingPathComponent(".building-\(id.uuidString)")
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      let cpus = max(
        requirements.minimumSupportedCPUCount,
        request.cpuCount ?? min(ProcessInfo.processInfo.processorCount / 2, 8))
      let memory = max(requirements.minimumSupportedMemorySize, request.memorySize ?? 8 << 30)
      let manifest = MachineManifest(
        id: id, kind: .macOS, title: request.title, cpuCount: cpus, memorySize: memory,
        display: .init(width: 1920, height: 1200),
        macAddress: MachineManifest.randomMACAddress(),
        hardwareModel: requirements.hardwareModel.dataRepresentation.base64EncodedString(),
        machineIdentifier: VZMacMachineIdentifier().dataRepresentation.base64EncodedString(),
        parent: nil, username: request.username, password: password, created: Date())
      let machine = Machine(url: url, manifest: manifest)
      // Sparse: the disk costs what the guest writes, not what it is told it has.
      FileManager.default.createFile(atPath: machine.diskURL.path, contents: nil)
      let handle = try FileHandle(forWritingTo: machine.diskURL)
      try handle.truncate(atOffset: request.diskSize)
      try handle.close()
      _ = try VZMacAuxiliaryStorage(
        creatingStorageAt: machine.auxiliaryURL, hardwareModel: requirements.hardwareModel,
        options: [])
      try machine.save()
      self.machine = machine
      install(machine)
    } catch {
      try? FileManager.default.removeItem(at: url)
      onPhase?(.failed(error.localizedDescription))
    }
  }

  private func install(_ machine: Machine) {
    let runner = MacMachine(machine: machine, sharedDirectory: nil)
    let vm: VZVirtualMachine
    do {
      let configuration = try MacMachine.configuration(for: machine, sharedDirectory: nil)
      try configuration.validate()
      vm = VZVirtualMachine(configuration: configuration)
    } catch {
      onPhase?(.failed(error.localizedDescription))
      return
    }
    let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: request.ipsw)
    installing = vm
    progressObservation = installer.progress.observe(\.fractionCompleted, options: [.new]) {
      [weak self] progress, _ in
      DispatchQueue.main.async { self?.onPhase?(.installing(progress.fractionCompleted)) }
    }
    onPhase?(.installing(0))
    installer.install { [weak self] result in
      guard let self else { return }
      self.progressObservation = nil
      switch result {
      case .failure(let error):
        self.installing = nil
        self.discard(machine)
        self.installsLeft -= 1
        if self.installsLeft > 0, let image = self.image {
          // A new machine directory, not the old disk: a restore that failed part-way leaves it
          // in no state to restore into again.
          self.waitForStop(vm) { self.prepare(image) }
        } else {
          self.onPhase?(.failed(MacMachine.explain(error)))
        }
      case .success:
        // The installer's machine goes on running for a moment after it reports, holding the
        // auxiliary storage's lock — a machine started before it stops fails with "Failed to lock
        // auxiliary storage" (EAGAIN). So the first boot waits for it to stop.
        self.onPhase?(.installing(1))
        self.waitForStop(vm) {
          self.installing = nil
          self.firstBoot(machine, runner: runner, attemptsLeft: 10)
        }
      }
    }
  }

  private func waitForStop(_ vm: VZVirtualMachine, then: @escaping () -> Void) {
    var waited = 0
    func check() {
      if vm.state == .stopped || vm.state == .error || waited >= 120 {
        then()
      } else {
        waited += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: check)
      }
    }
    check()
  }

  /// Once the first boot has made the account: put the guest agent in over SSH, check both its
  /// halves answer over vsock, then — through the agent, not SSH — turn Remote Login back off and
  /// shut the guest down, whose stopping is what publishes the template. What the template keeps
  /// is the agent and nothing else: no key, no passwordless sudo, no SSH listening. If any step
  /// cannot be done, the guest keeps running and the window's button shuts it down instead.
  private func finishSetup(_ machine: Machine) {
    let mac = machine.manifest.macAddress
    let user = request.username
    let password = self.password
    DispatchQueue.global(qos: .utility).async { [weak self] in
      do {
        try MachineGuest.installAgent(
          macAddress: mac, user: user, password: password,
          deadline: Date().addingTimeInterval(15 * 60))
        DispatchQueue.main.async { self?.closeTheDoor() }
      } catch {
        DispatchQueue.main.async { self?.onPhase?(.setupFailed(error.localizedDescription)) }
      }
    }
  }

  /// Wait for both agents to say they are up, then switch SSH off and shut down as root through
  /// the agent. The user half only starts at login, so once the daemon has said hello and the
  /// user half has not, the daemon restarts the guest and automatic login brings it up. Nothing
  /// here dials an agent that has not been heard from — see `MacMachine.agentsHeard`.
  private func closeTheDoor() {
    guard let runner = running else { return }
    var restarted = false
    let deadline = Date().addingTimeInterval(10 * 60)
    func check() {
      guard let vm = runner.vm else { return }
      let heard = runner.agentsHeard
      if heard.contains("user"), heard.contains("root") {
        runner.onAgentHello = nil
        // Recovery comes next and is typed into blind; it takes its language and keyboard from
        // this variable, and one that came up in another language took the keystrokes elsewhere.
        let off =
          "nvram 'prev-lang:kbd=en-US:0';"
          + " launchctl disable system/com.openssh.sshd; launchctl bootout system/com.openssh.sshd;"
          + " shutdown -h now"
        // The reply may not make it back before the guest goes down, and its stopping is what
        // finishes the template either way.
        GuestAgent.exec(["sh", "-c", off], on: vm, admin: true) { _ in }
        return
      }
      if heard.contains("root"), !restarted {
        // The user half is not running yet and will not be until a login: restart, and forget
        // what was heard, since the next hellos are the ones that count.
        restarted = true
        GuestAgent.exec(["shutdown", "-r", "now"], on: vm, admin: true) { _ in }
        runner.forgetAgents()
        return
      }
      if Date() > deadline {
        runner.onAgentHello = nil
        onPhase?(.setupFailed("the guest agent did not start"))
      }
    }
    runner.onAgentHello = { _ in check() }
    check()
  }

  static func makePassword() -> String {
    // Letters and digits only: it is typed into a GUI prompt now and then, by a person.
    let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    return String((0..<20).map { _ in alphabet.randomElement()! })
  }

  /// "Failed to lock auxiliary storage", with EAGAIN somewhere down its chain.
  private static func isLockContention(_ error: Error) -> Bool {
    var next: NSError? = error as NSError
    while let error = next {
      if error.domain == NSPOSIXErrorDomain, error.code == Int(EAGAIN) { return true }
      next = error.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
  }

  private func publish(_ machine: Machine) {
    let destination = MachineStore.templatesURL.appendingPathComponent(machine.id.uuidString)
    do {
      try FileManager.default.moveItem(at: machine.url, to: destination)
      onPhase?(.done)
    } catch {
      onPhase?(.failed(error.localizedDescription))
    }
  }

  private func discard(_ machine: Machine) {
    try? FileManager.default.removeItem(at: machine.url)
  }

  /// The guest reads the account only on this boot, then sets itself up and logs in.
  private func firstBoot(_ machine: Machine, runner: MacMachine, attemptsLeft: Int) {
    guard #available(macOS 27, *) else {
      onPhase?(
        .failed("Setting up the guest's account needs macOS 27 on this Mac; macOS is installed."))
      return
    }
    let provisioning = VZMacGuestProvisioningOptions()
    provisioning.fullName = request.username
    provisioning.username = request.username
    provisioning.password = password
    provisioning.logsInAutomatically = true
    provisioning.enablesRemoteLogin = true
    do {
      try provisioning.validate()
    } catch {
      onPhase?(.failed(error.localizedDescription))
      return
    }
    running = runner
    runner.start(provisioning: provisioning) { [weak self] error in
      guard let self else { return }
      self.showOnScreen()
      if let error {
        self.running = nil
        // The lock outliving the installer by a little more than its stop is still the likeliest
        // reason, and it passes; the install is minutes of work not to throw away for it.
        if attemptsLeft > 1, Self.isLockContention(error) {
          DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.firstBoot(
              machine, runner: MacMachine(machine: machine, sharedDirectory: nil),
              attemptsLeft: attemptsLeft - 1)
          }
          return
        }
        self.discard(machine)
        self.onPhase?(.failed(MacMachine.explain(error)))
      } else {
        self.onPhase?(.firstBoot)
        self.finishSetup(machine)
      }
    }
    runner.onStop = { [weak self] error in self?.stopped(machine, error: error) }
  }

  /// The guest stopped — each stage ends by shutting it down, and what comes next depends on
  /// which one did.
  private func stopped(_ machine: Machine, error: Error?) {
    running = nil
    if let error {
      onPhase?(.failed(MacMachine.explain(error)))
      return
    }
    switch stage {
    case .firstBoot:
      stage = .recovery
      bootRecovery(machine)
    case .recovery:
      keyboard = nil
      stage = .granting
      bootToGrant(machine)
    case .granting:
      publish(machine)
    }
  }

  // MARK: SIP and permissions

  /// macOS Recovery, to turn SIP off: the one thing nothing inside a running macOS can do, and
  /// what lets the next boot write the agent's permissions straight into TCC. Every template is
  /// made this way — they are throwaway machines for automation, where a permission prompt with
  /// nobody to answer it is a wall. The keystrokes are the ones tart's image templates send. They
  /// are typed blind, against fixed waits, so a Recovery that came up late misses them: the machine
  /// is then stopped and sent through again, which costs a minute or two where a failed build
  /// costs the whole install, and leaves nothing behind since Recovery changed nothing.
  private func bootRecovery(_ machine: Machine) {
    onPhase?(.disablingSIP)
    let runner = MacMachine(machine: machine, sharedDirectory: nil)
    running = runner
    runner.onStop = { [weak self] error in self?.stopped(machine, error: error) }
    runner.start(recovery: true) { [weak self] error in
      guard let self, let vm = runner.vm else {
        if let error { self?.onPhase?(.setupFailed(MacMachine.explain(error))) }
        return
      }
      // The machine exists only now that it has started; the view was set while it did not.
      self.screenView.virtualMachine = vm
      let keyboard = GuestKeyboard(view: self.screenView)
      self.keyboard = keyboard
      keyboard.type([
        // The startup picker: past the disk to Options, which is Recovery.
        .wait(60), .key(GuestKeyboard.rightArrow), .key(GuestKeyboard.rightArrow),
        .key(GuestKeyboard.returnKey),
        // Utilities ▸ Terminal.
        .wait(20), .commandShiftKey(17),
        .wait(10), .text("csrutil disable"), .key(GuestKeyboard.returnKey),
        .wait(10), .text("y"), .key(GuestKeyboard.returnKey),
        // Only the password: with one admin on the disk, Recovery names the user itself — tart's
        // templates type one line here too. Typing the name first spent the prompt on it.
        .wait(10), .text(self.password), .key(GuestKeyboard.returnKey),
        .wait(15), .text("halt"), .key(GuestKeyboard.returnKey),
      ]) { [weak self] in
        // `halt` stops the machine, which is what moves the build on; if it is still up a
        // minute later, Recovery did not go the way the keystrokes assumed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
          guard let self, self.stage == .recovery, self.running === runner, runner.vm != nil
          else { return }
          if self.recoveryRetriesLeft > 0 {
            self.recoveryRetriesLeft -= 1
            runner.onStop = nil
            runner.forceStop { [weak self] in self?.bootRecovery(machine) }
            return
          }
          self.onPhase?(
            .setupFailed(
              "Recovery did not go as expected. Turn SIP off in its Terminal with `csrutil disable`"
                + " and `halt`, and the build carries on"))
        }
      }
    }
  }

  /// Booted again, SIP off: check it is, write the agent's permissions into both TCC databases,
  /// and shut down — the template is then ready.
  private func bootToGrant(_ machine: Machine) {
    onPhase?(.granting)
    let runner = MacMachine(machine: machine, sharedDirectory: nil)
    running = runner
    runner.onStop = { [weak self] error in self?.stopped(machine, error: error) }
    runner.start { [weak self] error in
      self?.showOnScreen()
      if let error { self?.onPhase?(.setupFailed(MacMachine.explain(error))) }
    }
    let deadline = Date().addingTimeInterval(10 * 60)
    var granted = false
    func check() {
      guard !granted, let vm = runner.vm else { return }
      // The user's TCC database is the one its tccd has open, which needs the login to have run —
      // so both halves, not only the daemon.
      guard runner.agentsHeard.contains("root"), runner.agentsHeard.contains("user") else {
        if Date() > deadline {
          runner.onAgentHello = nil
          onPhase?(.setupFailed("the guest agent did not start after Recovery"))
        }
        return
      }
      granted = true
      runner.onAgentHello = nil
      GuestAgent.exec(
        ["/bin/sh", "-c", Self.grantScript(user: request.username)], on: vm, admin: true
      ) { [weak self] result in
        switch result {
        case .success(let run) where run.exit == 0:
          self?.keepAwake(vm) {
            // Shutting down publishes the template (`stopped`, stage .granting).
            GuestAgent.exec(["shutdown", "-h", "now"], on: vm, admin: true) { _ in }
          }
        case .success(let run):
          let message = String(decoding: run.stderr + run.stdout, as: UTF8.self)
          self?.onPhase?(.setupFailed("could not grant the permissions: \(message)"))
        case .failure(let error):
          self?.onPhase?(.setupFailed(error.localizedDescription))
        }
      }
    }
    runner.onAgentHello = { _ in check() }
  }

  /// A machine driven by an agent has nobody at it, so nothing may put it to sleep or lock it: a
  /// display that sleeps after ten minutes and a screen that locks behind it stopped both the
  /// screenshots and the UI at the first long build. The sleep settings are the system's (root);
  /// the lock and the screen saver are the user's, and turning the lock off asks for their
  /// password, which hukan made and is handing over on stdin. A failure here leaves the template
  /// usable, so it only notes itself and carries on.
  private func keepAwake(_ vm: VZVirtualMachine, then: @escaping () -> Void) {
    GuestAgent.exec(
      ["pmset", "-a", "displaysleep", "0", "sleep", "0", "disksleep", "0"], on: vm, admin: true
    ) { _ in
      let user =
        "sysadminctl -screenLock off -password \"$(cat)\";"
        + " defaults -currentHost write com.apple.screensaver idleTime -int 0"
      GuestAgent.exec(
        ["/bin/sh", "-c", user], on: vm, stdin: Data(self.password.utf8)
      ) { _ in
        GuestAgent.exec(["/bin/sh", "-c", Self.screenCaptureScript], on: vm) { _ in
          // Killed, not quit: a replayd that exits cleanly writes back what it holds, which is the
          // date the script replaced. The next one reads the file.
          GuestAgent.exec(["killall", "-9", "replayd"], on: vm, admin: true) { _ in then() }
        }
      }
    }
  }

  /// macOS asks again, every thirty days, whether an app that captures the screen without the
  /// system's window picker may go on doing so — a dialog in the guest, over whatever the agent is
  /// trying to look at, and kept apart from TCC, so the grant below does not answer it. What it
  /// keeps is replayd's own record: a capture made now writes the agent's entry, saying it was
  /// asked now and next asks in thirty days, and that date is moved to one no copy will reach.
  private static var screenCaptureScript: String {
    let agent = GuestAgent.guestBinaryPath
    return """
      f="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
      screencapture -x /tmp/hukan-capture.png; rm -f /tmp/hukan-capture.png
      for i in $(seq 1 30); do
        plutil -extract "\(agent)" xml1 -o /dev/null "$f" 2>/dev/null && break
        sleep 1
      done
      plutil -replace "\(agent).kScreenCapturePrivacyHintDate" -date 2100-01-01T00:00:00Z "$f"
      plutil -replace "\(agent).kScreenCapturePrivacyHintPolicy" -integer 2147483647 "$f"
      """
  }

  /// What tart's image templates write, for hukan's agent: Accessibility, Screen Recording, posting
  /// events and the microphone, and Apple Events to System Events — into the system database and
  /// the user's. By path, with no code requirement, so a rebuilt agent keeps them. macOS 27 keeps
  /// the user's database in a ProtectedSystem container, found by asking which file the user's
  /// tccd has open; older systems keep it in the home folder.
  private static func grantScript(user: String) -> String {
    let agent = GuestAgent.guestBinaryPath
    let rows =
      [
        "kTCCServiceAccessibility", "kTCCServiceScreenCapture", "kTCCServicePostEvent",
        "kTCCServiceMicrophone",
      ]
      .map { "('\($0)', 1, '\(agent)', 2, 0, 1, NULL, 'UNUSED')" }
      + ["('kTCCServiceAppleEvents', 1, '\(agent)', 2, 0, 1, 0, 'com.apple.systemevents')"]
    let sql =
      "INSERT OR REPLACE INTO access (service, client_type, client, auth_value, auth_reason,"
      + " auth_version, indirect_object_identifier_type, indirect_object_identifier) VALUES "
      + rows.joined(separator: ", ") + ";"
    return """
      set -e
      csrutil status | grep -q disabled || { echo "SIP is still on" >&2; exit 3; }
      uid=$(id -u \(user))
      db=$(lsof -a -u "$uid" -c tccd -Fn 2>/dev/null \\
        | sed -n 's|^n\\(/private/var/containers/Data/ProtectedSystem/.*/com.apple.TCC/TCC.db\\)$|\\1|p' \\
        | head -n 1)
      [ -n "$db" ] || db="/Users/\(user)/Library/Application Support/com.apple.TCC/TCC.db"
      sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "\(sql)"
      sqlite3 "$db" "\(sql)"
      killall tccd 2>/dev/null || true
      """
  }
}
