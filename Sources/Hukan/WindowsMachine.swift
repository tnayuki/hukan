import Carbon
import CoreGraphics
import Foundation
import ImageIO
import OSLog

/// Where QEMU's sockets go. A socket's path has to fit in 104 bytes, which the store's own
/// directory does not, and `/tmp` is shared with every account on the Mac: another one could put a
/// socket at a name hukan is about to use and be spoken to as QEMU. The per-user temporary
/// directory is short enough and is this account's alone.
enum QEMUSocket {
  static func path(_ name: String) -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("hukan-\(name).sock").path
  }
}

/// Making a Windows template from a Windows on Arm ISO, on QEMU from Homebrew. Virtualization.framework
/// has no way to run Windows, so this is the one kind of machine hukan does not run in its own
/// process.
///
/// The install answers itself: a second small disc carries an `autounattend.xml`, which Windows
/// Setup looks for on removable media, so the ISO stays exactly as it was downloaded. The disc holds
/// the account's password in the clear, so it is deleted as soon as the install is over. There is no
/// TPM: Setup's requirement checks are turned off by the same file, and nothing a template is for
/// needs one — which is also one program fewer to run beside every machine.
final class WindowsTemplateBuilder {
  struct Request {
    var title: String
    var iso: URL
    var diskSize: UInt64
    var cpuCount: Int?
    var memorySize: UInt64?
    var username: String
  }

  static let qemu = "/opt/homebrew/bin/qemu-system-aarch64"

  /// Held while the template is being made, so another hukan launching meanwhile leaves it be.
  private var claim: MachineStore.Claim?

  /// The versioned type the bare `virt` stands for in the QEMU installed now, read off its own
  /// list (`virt … (alias of virt-11.1)`), or nil where QEMU cannot say.
  static func machineType() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: qemu)
    process.arguments = ["-machine", "help"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return machineType(inHelp: String(decoding: data, as: UTF8.self))
  }

  static func machineType(inHelp help: String) -> String? {
    for line in help.split(separator: "\n") where line.hasPrefix("virt ") {
      guard let alias = line.range(of: "alias of ") else { continue }
      return String(line[alias.upperBound...].prefix { $0 != ")" })
    }
    return nil
  }
  static let firmwareCode = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
  private static let firmwareVars = "/opt/homebrew/share/qemu/edk2-arm-vars.fd"
  private static let answerDiscName = "answers.iso"

  /// The QEMU of a build under way, for quitting: it is a process of its own and would outlive us.
  private(set) static var running: Process?

  let request: Request
  var onPhase: ((MacTemplateBuilder.Phase) -> Void)?
  /// Stopped from the window: nothing from here on may report a phase or publish.
  private var cancelled = false
  /// Whether the guest has restarted out of WinPE. Main thread.
  private var restarted = false
  private var machine: Machine?
  private let password = MacTemplateBuilder.makePassword()
  /// The install, for the Virtual Machines window to show.
  let screenView = QEMUScreenView()

  init(request: Request) {
    self.request = request
  }

  func run() {
    onPhase?(.preparing)
    guard FileManager.default.isExecutableFile(atPath: Self.qemu) else {
      onPhase?(
        .failed("Windows needs QEMU from Homebrew. Run `brew install qemu`, then try again."))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let prepared = Result {
        try Self.fetchDrivers()
        return try prepare()
      }
      DispatchQueue.main.async { [self] in
        if cancelled {
          if case .success(let machine) = prepared { discard(machine.url) }
          return
        }
        switch prepared {
        case .success(let machine):
          self.machine = machine
          start(machine)
        case .failure(let error): onPhase?(.failed(error.localizedDescription))
        }
      }
    }
  }

  // MARK: Before it boots

  /// The drivers Windows has none of for QEMU's virtual hardware: the network, and the serial port
  /// the guest agent speaks over. Red Hat's build, for every Windows on Arm alike, fetched once.
  /// One of the few requests hukan makes for itself: a GET of a fixed address, and nothing sent.
  private static let driversSource = URL(
    string:
      "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
  )!
  static var driversDisc: URL { MachineStore.driversURL.appendingPathComponent("virtio-win.iso") }

  private static func fetchDrivers() throws {
    MachineStore.prepare()
    guard !FileManager.default.fileExists(atPath: driversDisc.path) else { return }
    let done = DispatchSemaphore(value: 0)
    var outcome: Result<URL, Error> = .failure(MachineError("The drivers could not be fetched."))
    let task = URLSession.shared.downloadTask(with: driversSource) { file, response, error in
      if let file, (response as? HTTPURLResponse)?.statusCode == 200 {
        // Moved here because the file is gone once this returns, and only a whole one is kept.
        let partial = driversDisc.appendingPathExtension("download")
        try? FileManager.default.removeItem(at: partial)
        do {
          try FileManager.default.moveItem(at: file, to: partial)
          try FileManager.default.moveItem(at: partial, to: driversDisc)
          outcome = .success(driversDisc)
        } catch {
          outcome = .failure(error)
        }
      } else if let error {
        outcome = .failure(error)
      }
      done.signal()
    }
    task.delegate = SecureRedirects()
    task.resume()
    done.wait()
    _ = try outcome.get()
  }

  /// What WinPE runs in place of Setup's own install: the disk, the image, then Defender's services
  /// switched off, and updates by themselves, in the registry of a Windows that has never started —
  /// the one moment it can be done, since from the first boot Defender guards those keys against
  /// SYSTEM too, and Tamper Protection undoes anything said to it afterwards. Then the boot files,
  /// and the answer file where the image's own first boot looks for it. A failed step powers the
  /// guest off instead of restarting it, and QEMU leaving without the restart is how the builder
  /// knows: WinPE has nothing else to say it through.
  static let installScript = [
    "@echo off",
    "set SRC=",
    "for %%d in (C D E F G H I J K L) do if exist %%d:\\sources\\install.wim "
      + "set SRC=%%d:\\sources\\install.wim",
    "if not defined SRC for %%d in (C D E F G H I J K L) do if exist %%d:\\sources\\install.esd "
      + "set SRC=%%d:\\sources\\install.esd",
    "set ANS=",
    "for %%d in (C D E F G H I J K L) do if exist %%d:\\hukan-install.cmd set ANS=%%d:",
    "if not defined SRC goto failed",
    "(",
    "echo select disk 0",
    "echo clean",
    "echo convert gpt",
    "echo create partition efi size=300",
    "echo format quick fs=fat32 label=System",
    "echo assign letter=S",
    "echo create partition msr size=16",
    "echo create partition primary",
    "echo format quick fs=ntfs label=Windows",
    "echo assign letter=W",
    ") > X:\\hukan-diskpart.txt",
    "diskpart /s X:\\hukan-diskpart.txt || goto failed",
    "dism /Apply-Image /ImageFile:%SRC% /Name:\"Windows 11 Pro\" /ApplyDir:W:\\ || goto failed",
    "reg load HKLM\\hukan W:\\Windows\\System32\\config\\SYSTEM || goto failed",
    "for %%s in (Sense WdBoot WdFilter WdNisDrv WdNisSvc WinDefend) do "
      + "reg add HKLM\\hukan\\ControlSet001\\Services\\%%s /v Start /t REG_DWORD /d 4 /f",
    "reg unload HKLM\\hukan",
    // Nothing updates by itself: a machine an agent drives was otherwise restarted, or had a prompt
    // put over its work, by nobody's choice. Group Policy's values, written before the first boot,
    // since Windows looks for drivers for its devices there: Automatic Updates disabled, which Pro
    // honours; Windows Update not searched for a device's driver, nor its metadata fetched, nor
    // drivers taken with quality updates; the Store's apps not downloaded. Checking for updates by
    // hand still works.
    "reg load HKLM\\hukansw W:\\Windows\\System32\\config\\SOFTWARE || goto failed",
    "set P=HKLM\\hukansw\\Policies\\Microsoft",
    "reg add %P%\\Windows\\WindowsUpdate\\AU /v NoAutoUpdate /t REG_DWORD /d 1 /f || goto failed",
    "reg add %P%\\Windows\\WindowsUpdate "
      + "/v ExcludeWUDriversInQualityUpdate /t REG_DWORD /d 1 /f || goto failed",
    "reg add %P%\\Windows\\DriverSearching /v SearchOrderConfig /t REG_DWORD /d 0 /f || goto failed",
    "reg add \"%P%\\Windows\\Device Metadata\" "
      + "/v PreventDeviceMetadataFromNetwork /t REG_DWORD /d 1 /f || goto failed",
    "reg add %P%\\WindowsStore /v AutoDownload /t REG_DWORD /d 2 /f || goto failed",
    "reg unload HKLM\\hukansw",
    "bcdboot W:\\Windows /s S: /f UEFI || goto failed",
    "mkdir W:\\Windows\\Panther",
    "copy /y %ANS%\\autounattend.xml W:\\Windows\\Panther\\unattend.xml || goto failed",
    "wpeutil reboot",
    "goto :eof",
    ":failed",
    "wpeutil shutdown",
    "",
  ].joined(separator: "\r\n")

  /// The virtio-serial port the first logon's script reports through, and the file beside the
  /// template being made that it reaches.
  static let setupPort = "dev.hukan.setup"
  static let setupLogName = "setup.log"

  /// What went wrong, if anything, in a guest that powered off: WinPE stopped at a step if it never
  /// restarted, and the first logon's script failed a step, or never got to its end, by its report.
  // Internal so tests can read a report without running Windows.
  static func setupProblem(restarted: Bool, report: String?) -> String? {
    guard restarted else {
      return "Windows could not be laid down on the disk (WinPE stopped at a step). "
        + "The template's folder holds the disk as it was left."
    }
    let lines = (report ?? "").split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    let failed = lines.filter { $0.hasPrefix("failed: ") }.map { $0.dropFirst("failed: ".count) }
    if !failed.isEmpty {
      return "Windows' first sign-in could not set up: \(failed.joined(separator: ", "))."
    }
    guard lines.contains("done") else {
      return "Windows' first sign-in did not finish setting up."
    }
    return nil
  }

  /// What the first logon runs, from the answers disc: the drivers, the agent's two halves, and a
  /// sign-in that holds.
  /// Every step is left to fail on its own: a template without one of these still boots, and says
  /// so by not answering, where a script that stopped would leave the rest undone too.
  // Internal so tests can inspect setup without mounting or booting an ISO.
  static let setupScript = [
    "@echo off",
    "set D=",
    "for %%d in (D E F G H I J) do if exist %%d:\\vioserial\\w11\\ARM64\\vioser.inf set D=%%d:",
    "pnputil /add-driver %D%\\vioserial\\w11\\ARM64\\vioser.inf /install",
    // The serial driver first, since it is what the builder is told through: a step that fails
    // says so on this port, and the last line says the script got to its end.
    "set R=\\\\.\\Global\\\(setupPort)",
    "pnputil /add-driver %D%\\NetKVM\\w11\\ARM64\\netkvm.inf /install "
      + "|| (echo failed: NetKVM)> %R%",
    "pnputil /add-driver %D%\\viogpudo\\w11\\ARM64\\viogpudo.inf /install "
      + "|| (echo failed: viogpudo)> %R%",
    "set H=C:\\Program Files\\Hukan",
    "mkdir \"%H%\"",
    "copy /y \"%~dp0hukan-guest-agent.exe\" \"%H%\\\" || (echo failed: the agent's copy)> %R%",
    "sc create HukanGuestAgent binPath= \"\\\"%H%\\hukan-guest-agent.exe\\\" --root\" start= auto "
      + "|| (echo failed: the agent's service)> %R%",
    "schtasks /create /tn HukanGuestAgent /sc onlogon /rl highest /f "
      + "/tr \"\\\"%H%\\hukan-guest-agent.exe\\\" --user\" || (echo failed: the agent's task)> %R%",
    "reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System "
      + "/v EnableLUA /t REG_DWORD /d 0 /f || (echo failed: EnableLUA)> %R%",
    // The answer file's AutoLogon signs in at boot only, and for a counted number of boots: a
    // logoff would otherwise leave the machine at the sign-in screen, where the user half of the
    // agent is not running and nothing can sign it back in.
    "reg add \"HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon\" "
      + "/v ForceAutoLogon /t REG_SZ /d 1 /f || (echo failed: ForceAutoLogon)> %R%",
    "reg delete \"HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon\" "
      + "/v AutoLogonCount /f",
    "powercfg /change standby-timeout-ac 0 || (echo failed: standby)> %R%",
    "powercfg /change monitor-timeout-ac 0 || (echo failed: monitor)> %R%",
    "(echo done)> %R%",
    "",
  ].joined(separator: "\r\n")

  private func prepare() throws -> Machine {
    let id = UUID()
    let url = MachineStore.templatesURL.appendingPathComponent(".building-\(id.uuidString)")
    let manager = FileManager.default
    try manager.createDirectory(at: url, withIntermediateDirectories: true)
    claim = MachineStore.Claim.take(url)
    let performance = Self.performanceCores
    let manifest = MachineManifest(
      id: id, kind: .windows, title: request.title, cpuCount: request.cpuCount ?? performance,
      memorySize: request.memorySize ?? (6 << 30), display: .init(width: 1280, height: 800),
      macAddress: MachineManifest.randomMACAddress(), username: request.username,
      password: password, created: Date(), qemuMachine: Self.machineType())
    var machine = Machine(url: url, manifest: manifest)
    try machine.save()

    // Sparse: the file says the disk's size, and takes only what Windows has written.
    manager.createFile(atPath: machine.diskURL.path, contents: nil)
    let disk = try FileHandle(forWritingTo: machine.diskURL)
    try disk.truncate(atOffset: request.diskSize)
    try disk.close()
    try manager.copyItem(atPath: Self.firmwareVars, toPath: machine.auxiliaryURL.path)

    let language = try Self.language(of: request.iso)
    let answers = url.appendingPathComponent("answers")
    try manager.createDirectory(at: answers, withIntermediateDirectories: true)
    try answerFile(language: language).write(
      to: answers.appendingPathComponent("autounattend.xml"), atomically: true, encoding: .utf8)
    try Self.installScript.write(
      to: answers.appendingPathComponent("hukan-install.cmd"), atomically: true, encoding: .ascii)
    try Self.setupScript.write(
      to: answers.appendingPathComponent("hukan-setup.cmd"), atomically: true, encoding: .ascii)
    guard let agent = Bundle.main.url(forResource: "hukan-guest-agent", withExtension: "exe") else {
      throw MachineError("The Windows guest agent is missing from this build of hukan.")
    }
    try manager.copyItem(at: agent, to: answers.appendingPathComponent("hukan-guest-agent.exe"))
    try Self.tool(
      "/usr/bin/hdiutil",
      [
        "makehybrid", "-iso", "-joliet", "-o", url.appendingPathComponent(Self.answerDiscName).path,
        answers.path,
      ])
    try manager.removeItem(at: answers)
    return machine
  }

  /// The language the ISO installs, which every locale in the answer file has to agree with: Setup
  /// stops and asks when they do not. An ISO says so in `sources/lang.ini`.
  private static func language(of iso: URL) throws -> String {
    try mounted(iso) { mount in
      try language(in: Data(contentsOf: mount.appendingPathComponent("sources/lang.ini")))
    }
  }

  /// What a Windows 11 build is called, `Windows 11 25H2` for `26200.6899`: a build number is
  /// all Microsoft's catalog gives, never the `25H2` people call it by, so a release this table
  /// has not heard of is named by its build instead.
  static func title(ofBuild build: String) -> String {
    let releases = [22000: "21H2", 22621: "22H2", 22631: "23H2", 26100: "24H2", 26200: "25H2"]
    let major = build.split(separator: ".").first.flatMap { Int($0) }
    return major.flatMap { releases[$0] }.map { "Windows 11 \($0)" } ?? "Windows 11 (\(build))"
  }

  /// An ISO mounted read-only and out of sight for as long as `body` runs.
  private static func mounted<T>(_ iso: URL, _ body: (URL) throws -> T) throws -> T {
    let mount = FileManager.default.temporaryDirectory
      .appendingPathComponent("hukan-iso-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: mount) }
    // diskutil's, since `hdiutil attach` now says it is deprecated in its favour; it has no detach
    // of its own, and an eject is one.
    try tool(
      "/usr/sbin/diskutil",
      [
        "image", "attach", "--readOnly", "--mountOptions", "nobrowse", "--mountPoint", mount.path,
        iso.path,
      ])
    defer { try? tool("/usr/sbin/diskutil", ["eject", mount.path]) }
    return try body(mount)
  }

  // Internal so ISO metadata parsing can be tested without mounting an image.
  static func language(in data: Data) throws -> String {
    var inSection = false
    for raw in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        inSection = line.lowercased() == "[available ui languages]"
      } else if inSection, let name = line.split(separator: "=").first {
        return name.trimmingCharacters(in: .whitespaces)
      }
    }
    throw MachineError("This ISO does not say which language it installs.")
  }

  // Internal so tests can validate the generated XML without preparing a template.
  func answerFile(language: String) -> String {
    let inputLocale = language.lowercased().hasPrefix("ja") ? "0411:00000411" : "0409:00000409"
    let timeZone =
      TimeZone.current.identifier == "Asia/Tokyo" ? "Tokyo Standard Time" : "UTC"
    let user = Self.escaped(request.username)
    let component = { (name: String) in
      """
      name="\(name)" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" \
      language="neutral" versionScope="nonSxS"
      """
    }
    let locale = """
      <InputLocale>\(inputLocale)</InputLocale>
            <SystemLocale>\(language)</SystemLocale>
            <UILanguage>\(language)</UILanguage>
            <UserLocale>\(language)</UserLocale>
      """
    let checkNames = [
      "BypassTPMCheck", "BypassSecureBootCheck", "BypassCPUCheck", "BypassRAMCheck",
      "BypassStorageCheck",
    ]
    let checks = checkNames.enumerated().map { index, check in
      """
      <RunSynchronousCommand wcm:action="add"><Order>\(index + 1)</Order>\
      <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \(check) /t REG_DWORD /d 1 /f</Path>\
      </RunSynchronousCommand>
      """
    }.joined(separator: "\n        ")
    // Setup runs these before it touches the disk, and the last one never comes back: the image is
    // laid down by the script and WinPE restarts into it, so Setup's own install never starts.
    let install = """
      <RunSynchronousCommand wcm:action="add"><Order>\(checkNames.count + 1)</Order>\
      <Path>cmd /c for %d in (C D E F G H I J K L) do if exist %d:\\hukan-install.cmd \
      call %d:\\hukan-install.cmd</Path></RunSynchronousCommand>
      """
    let setup =
      "cmd /c for %d in (D E F G H I J) do if exist %d:\\hukan-setup.cmd call %d:\\hukan-setup.cmd"
    let firstLogon =
      (["cmd /c del /f /q C:\\Windows\\Panther\\unattend.xml", setup, "shutdown /s /t 5"])
      .enumerated().map { index, command in
        """
        <SynchronousCommand wcm:action="add">
                        <Order>\(index + 1)</Order>
                        <CommandLine>\(command)</CommandLine>
                      </SynchronousCommand>
        """
      }.joined(separator: "\n              ")
    // The key is Microsoft's published generic one: it selects the edition and activates nothing.
    return """
      <?xml version="1.0" encoding="utf-8"?>
      <unattend xmlns="urn:schemas-microsoft-com:unattend" \
      xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
        <settings pass="windowsPE">
          <component \(component("Microsoft-Windows-International-Core-WinPE"))>
            <SetupUILanguage><UILanguage>\(language)</UILanguage></SetupUILanguage>
            \(locale)
          </component>
          <component \(component("Microsoft-Windows-Setup"))>
            <RunSynchronous>
              \(checks)
              \(install)
            </RunSynchronous>
            <UserData>
              <AcceptEula>true</AcceptEula>
              <ProductKey><Key>VK7JG-NPHTM-C97JM-9MPGT-3V66T</Key></ProductKey>
            </UserData>
          </component>
        </settings>
        <settings pass="specialize">
          <component \(component("Microsoft-Windows-Shell-Setup"))>
            <ProductKey>VK7JG-NPHTM-C97JM-9MPGT-3V66T</ProductKey>
          </component>
        </settings>
        <settings pass="oobeSystem">
          <component \(component("Microsoft-Windows-International-Core"))>
            \(locale)
          </component>
          <component \(component("Microsoft-Windows-Shell-Setup"))>
            <TimeZone>\(timeZone)</TimeZone>
            <OOBE>
              <HideEULAPage>true</HideEULAPage>
              <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
              <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
              <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
            <UserAccounts>
              <LocalAccounts>
                <LocalAccount wcm:action="add">
                  <Name>\(user)</Name>
                  <Group>Administrators</Group>
                  <Password><Value>\(password)</Value><PlainText>true</PlainText></Password>
                </LocalAccount>
              </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
              <Enabled>true</Enabled>
              <Username>\(user)</Username>
              <Password><Value>\(password)</Value><PlainText>true</PlainText></Password>
              <LogonCount>9999</LogonCount>
            </AutoLogon>
            <FirstLogonCommands>
              \(firstLogon)
            </FirstLogonCommands>
          </component>
        </settings>
      </unattend>
      """
  }

  private static func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  /// The cores a guest should be given by default. More than these lands on the efficiency cores,
  /// and an install measured slower with eight than with four on a machine that has four of these.
  private static var performanceCores: Int {
    var cores: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 else {
      return 4
    }
    return Int(cores)
  }

  @discardableResult
  private static func tool(_ path: String, _ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw MachineError(
        "\((path as NSString).lastPathComponent) failed: "
          + String(decoding: data, as: UTF8.self))
    }
    return data
  }

  // MARK: The install

  private func start(_ machine: Machine) {
    let socket = QEMUSocket.path("qmp-\(machine.id.uuidString.prefix(8))")
    let display = QEMUSocket.path("vnc-\(machine.id.uuidString.prefix(8))")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: Self.qemu)
    process.arguments = arguments(machine, socket: socket, display: display)
    let log = machine.url.appendingPathComponent("qemu.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    if let handle = try? FileHandle(forWritingTo: log) {
      process.standardOutput = handle
      process.standardError = handle
    }
    process.terminationHandler = { [weak self] process in
      DispatchQueue.main.async {
        Self.running = nil
        try? FileManager.default.removeItem(atPath: socket)
        try? FileManager.default.removeItem(atPath: display)
        self?.screenView.disconnect()
        self?.finished(machine, status: process.terminationStatus, log: log)
      }
    }
    do {
      try process.run()
    } catch {
      onPhase?(.failed(error.localizedDescription))
      return
    }
    Self.running = process
    onPhase?(.installing(-1))
    screenView.connect(socket: display)
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard Self.ejectInstallerAtFirstReset(socket: socket) else { return }
      DispatchQueue.main.async { self?.restarted = true }
    }
  }

  /// The ISO is taken out when the guest first restarts, which is WinPE's reboot once Windows is
  /// on the disk: an ISO that boots without waiting for a key would otherwise be booted again by
  /// every restart Setup makes after, and the install begun again from its first step. Taken out
  /// rather than put behind the disk in the boot order, which was tried: Setup's own restart wrote
  /// the firmware's boot order, and the ISO came first again.
  /// Whether the guest has restarted: WinPE's reboot, which only an install that got through makes.
  @discardableResult
  private static func ejectInstallerAtFirstReset(socket: String) -> Bool {
    guard let qemu = QMPConnection(socket: socket), qemu.wait(for: "RESET") else { return false }
    // By the device the drive is in, which `usb-storage` makes and names itself: ejecting by the
    // drive's own name is deprecated.
    let drives = qemu.execute("query-block") as? [[String: Any]] ?? []
    guard let device = drives.first(where: { $0["device"] as? String == "cd0" })?["qdev"] else {
      return true
    }
    _ = qemu.execute("eject", ["id": device, "force": true])
    return true
  }

  private func arguments(_ machine: Machine, socket: String, display: String) -> [String] {
    let answers = machine.url.appendingPathComponent(Self.answerDiscName).path
    return [
      "-machine", "\(machine.manifest.qemuMachine ?? "virt"),highmem=on,gic-version=3",
      "-accel", "hvf", "-cpu", "host",
      "-smp", String(machine.manifest.cpuCount), "-m", String(machine.manifest.memorySize >> 20),
      "-drive", "if=pflash,format=raw,readonly=on,file=\(Self.firmwareCode)",
      "-drive", "if=pflash,format=raw,file=\(machine.auxiliaryURL.path)",
      "-device", "ramfb",
      "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
      "-device", "usb-tablet,bus=xhci.0",
      "-drive",
      "if=none,id=disk0,format=raw,cache=unsafe,discard=unmap,file=\(machine.diskURL.path)",
      "-device", "nvme,serial=hukan0,drive=disk0",
      // The ISO first: with the answers disc ahead of it the firmware never tried the ISO.
      "-drive", "if=none,id=cd0,media=cdrom,readonly=on,file=\(request.iso.path)",
      "-device", "usb-storage,bus=xhci.0,drive=cd0,removable=on",
      "-drive", "if=none,id=cd1,media=cdrom,readonly=on,file=\(answers)",
      "-device", "usb-storage,bus=xhci.0,drive=cd1,removable=on",
      "-drive", "if=none,id=cd2,media=cdrom,readonly=on,file=\(Self.driversDisc.path)",
      "-device", "usb-storage,bus=xhci.0,drive=cd2,removable=on",
      "-rtc", "base=localtime", "-nic", "none", "-display", "none", "-vnc", "unix:\(display)",
      "-qmp", "unix:\(socket),server=on,wait=off",
      // What the first logon's script reports, into a file beside the template being made.
      "-device", "virtio-serial-pci,id=serial0",
      "-chardev",
      "file,id=setup,path=\(machine.url.appendingPathComponent(Self.setupLogName).path)",
      "-device", "virtserialport,bus=serial0.0,chardev=setup,name=\(Self.setupPort)",
    ]
  }

  /// Stop where it stands and leave nothing behind — the window's −. Setup stopped on an error of
  /// its own leaves QEMU running for good, so this is the one way out of a build that will not end.
  func cancel() {
    guard !cancelled else { return }
    cancelled = true
    onPhase = nil
    // Still preparing: the preparation's own ending throws its machine away.
    guard let machine else { return }
    let process = Self.running
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      if let process, process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
      DispatchQueue.main.async { [self] in discard(machine.url) }
    }
  }

  private func discard(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    claim = nil
    MachineStore.changed()
  }

  /// The guest shuts itself down at its first logon, so QEMU leaving cleanly is the install done —
  /// once WinPE has restarted into the Windows it laid down, and the first logon's script has said
  /// it got to its end with no step failed.
  private func finished(_ machine: Machine, status: Int32, log: URL) {
    guard !cancelled else { return }
    let manager = FileManager.default
    try? manager.removeItem(at: machine.url.appendingPathComponent(Self.answerDiscName))
    guard status == 0 else {
      let tail = (try? String(contentsOf: log, encoding: .utf8))?.suffix(400) ?? ""
      onPhase?(.failed("QEMU stopped (status \(status)). \(tail)"))
      return
    }
    if let problem = Self.setupProblem(
      restarted: restarted,
      report: try? String(
        contentsOf: machine.url.appendingPathComponent(Self.setupLogName), encoding: .utf8))
    {
      onPhase?(.failed(problem))
      return
    }
    try? manager.removeItem(at: machine.url.appendingPathComponent(Self.setupLogName))
    try? manager.removeItem(at: log)
    let destination = MachineStore.templatesURL.appendingPathComponent(machine.id.uuidString)
    do {
      try manager.moveItem(at: machine.url, to: destination)
      claim = nil
      MachineStore.changed()
      onPhase?(.done)
    } catch {
      onPhase?(.failed(error.localizedDescription))
    }
  }
}

/// Which keyboard a Windows guest believes it has. Keys go by physical position, so that has to be
/// the keyboard on this Mac, and since a guest only takes a change by restarting, it is compared
/// when a machine starts rather than settled once when a template is made: a Mac whose keyboard has
/// changed needs no new template.
enum WindowsKeyboard {
  static let key = "HKLM\\SYSTEM\\CurrentControlSet\\Services\\i8042prt\\Parameters"

  /// Asked of the HID system rather than of the last key typed, which may be none yet.
  static var hostIsJIS: Bool {
    KBGetLayoutType(Int16(CGEventSource(stateID: .hidSystemState)?.keyboardType ?? 0))
      == kKeyboardJIS
  }

  /// The commands that make the guest's keyboard match, as argv.
  static func commands(jis: Bool) -> [[String]] {
    guard jis else {
      return [
        "LayerDriver JPN", "OverrideKeyboardIdentifier", "OverrideKeyboardType",
        "OverrideKeyboardSubtype",
      ]
      .map { ["reg.exe", "delete", key, "/v", $0, "/f"] }
    }
    return [
      ["LayerDriver JPN", "REG_SZ", "kbd106.dll"],
      ["OverrideKeyboardIdentifier", "REG_SZ", "PCAT_106KEY"],
      ["OverrideKeyboardType", "REG_DWORD", "7"],
      ["OverrideKeyboardSubtype", "REG_DWORD", "2"],
    ].map { ["reg.exe", "add", key, "/v", $0[0], "/t", $0[1], "/d", $0[2], "/f"] }
  }
}

/// One half of the Windows guest agent, over its virtio-serial port. A serial port is a single
/// stream, so requests carry an id and answers are matched back to them.
final class QEMUGuestChannel {
  private let path: String
  private let half: String
  private let lock = NSLock()
  private var descriptor: Int32 = -1
  private var nextID = 1
  private var waiting: [Int: (Result<[String: Any], Error>) -> Void] = [:]
  private var stopped = false
  private let writes = DispatchQueue(label: "hukan.guest-channel.write")

  /// Whether the half has said hello on this connection. Main thread.
  private(set) var isHeard = false
  /// Told on the main thread each time the agent says hello, with the guest pid it names.
  var onHello: ((Int?) -> Void)?
  /// Told on the main thread when a connection that had been heard on ends.
  var onLost: (() -> Void)?

  init(socket path: String, half: String) {
    self.path = path
    self.half = half
  }

  // Internal so socketpair fixtures exercise framing without connecting to a guest.
  func receive(descriptor: Int32) {
    self.descriptor = descriptor
  }

  // Internal so tests can run one connection without the reconnect loop.
  func readConnection(replyLimit: Int = GuestAgent.replyLimit) {
    readLines(replyLimit: replyLimit)
    finishWaiting()
  }

  func start() {
    Thread.detachNewThread { [self] in
      while !isStopped {
        let connected = connectToPort()
        if connected { readLines() }
        finishWaiting()
        DispatchQueue.main.async { [self] in
          let wasHeard = isHeard
          isHeard = false
          if connected, wasHeard { onLost?() }
        }
        Thread.sleep(forTimeInterval: 0.5)
      }
    }
  }

  func stop() {
    lock.lock()
    stopped = true
    let fd = descriptor
    lock.unlock()
    if fd >= 0 { shutdown(fd, SHUT_RDWR) }
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  func send(
    _ body: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    lock.lock()
    let id = nextID
    nextID += 1
    waiting[id] = completion
    let fd = descriptor
    lock.unlock()
    var message = body
    message["id"] = id
    guard fd >= 0, var data = try? JSONSerialization.data(withJSONObject: message) else {
      answer(id, .failure(MachineError("The guest agent is not connected.")))
      return
    }
    data.append(0x0A)
    writes.async { [self] in
      var offset = 0
      while offset < data.count {
        let sent = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, data.count - offset) }
        if sent <= 0 {
          answer(id, .failure(MachineError("The guest agent hung up.")))
          return
        }
        offset += sent
      }
    }
  }

  private func answer(_ id: Int, _ result: Result<[String: Any], Error>) {
    lock.lock()
    let completion = waiting.removeValue(forKey: id)
    lock.unlock()
    if let completion { DispatchQueue.main.async { completion(result) } }
  }

  /// The agent at the other end has ended while the port stays connected — which the guest's
  /// driver never reports, so it is learnt from the other half. What was waiting on it fails now
  /// rather than never, and the half is not heard until a new agent says hello. Main thread.
  func abandon() {
    isHeard = false
    lock.lock()
    let pending = waiting
    waiting = [:]
    lock.unlock()
    for completion in pending.values {
      DispatchQueue.main.async {
        completion(.failure(MachineError("The guest agent went away.")))
      }
    }
  }

  private func finishWaiting() {
    lock.lock()
    let pending = waiting
    waiting = [:]
    descriptor = -1
    lock.unlock()
    for completion in pending.values {
      DispatchQueue.main.async {
        completion(.failure(MachineError("The guest agent went away.")))
      }
    }
  }

  private func connectToPort() -> Bool {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
    }
    guard result == 0 else {
      close(fd)
      return false
    }
    lock.lock()
    descriptor = fd
    lock.unlock()
    return true
  }

  private func readLines(replyLimit: Int = GuestAgent.replyLimit) {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while !isStopped {
      let count = read(descriptor, &chunk, chunk.count)
      guard count > 0 else { break }
      buffer.append(contentsOf: chunk[0..<count])
      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = Data(buffer[buffer.startIndex..<newline])
        buffer.removeSubrange(buffer.startIndex...newline)
        handle(line)
      }
      // A guest sending without end must not be able to spend this process's memory.
      if buffer.count > replyLimit { break }
    }
    close(descriptor)
  }

  private func handle(_ line: Data) {
    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
      return
    }
    if object["hello"] != nil {
      let process = (object["pid"] as? NSNumber)?.intValue
      DispatchQueue.main.async { [self] in
        isHeard = true
        onHello?(process)
      }
      return
    }
    guard let id = object["id"] as? Int else { return }
    if object["ok"] as? Bool == true {
      answer(id, .success(object))
    } else {
      answer(id, .failure(MachineError(object["error"] as? String ?? "The guest agent refused.")))
    }
  }
}

/// A Windows machine running on a tab: QEMU as a process of its own, with its display on one unix
/// socket and its control on another. Saved and resumed the way QEMU migrates, into a file beside
/// the disk, so it comes back where it was as a macOS machine does.
final class QEMUMachine: GuestLink {
  private(set) var machine: Machine
  let displaySocket: String
  private let controlSocket: String
  /// Where the guest agent's two halves are, each a virtio-serial port on a unix socket.
  let agentSockets: [String: String]
  private var process: Process?
  private var stopping: (() -> Void)?

  private var channels: [String: QEMUGuestChannel] = [:]
  /// Told, on the main thread, each time a half of the agent says hello.
  var onAgentHello: ((String) -> Void)?

  /// Which halves of the guest agent are there to be spoken to.
  var agentsHeard: Set<String> { Set(channels.filter { $0.value.isHeard }.keys) }

  /// Why a half last stopped being heard, with when — the one error a tool could give covered a
  /// port that closed, an agent that ended and a share being mapped alike, and which of them was
  /// keeping a guest's tools shut for minutes at a time could not be told from it.
  private var losses: [String: (reason: String, at: Date)] = [:]
  static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "hukan", category: "guest")

  /// Why a half is not there to be spoken to, in a sentence for the agent asking.
  func absence(of half: String) -> String {
    guard let loss = losses[half] else {
      return "The guest agent has not said hello since the machine started — it comes up with the"
        + " guest's login, and says so within fifteen seconds. Try again shortly."
    }
    let ago = Int(Date().timeIntervalSince(loss.at))
    return "The guest agent's \(half) half is not answering: \(loss.reason) \(ago)s ago, and it"
      + " has not said hello since. It says hello every fifteen seconds once it is back."
  }

  private func lose(_ half: String, _ reason: String) {
    losses[half] = (reason, Date())
    Self.log.notice("\(half, privacy: .public) half lost: \(reason, privacy: .public)")
  }

  /// How many user halves have arrived on this run: each is a new process, so a new logon or a
  /// restarted agent, and a drive mapped for the one before is not there for it.
  private(set) var userArrivals = 0
  /// The user half's guest pid, from its hello; nil for an agent too old to say.
  private var userProcess: Int?
  private var userPresent = false
  private var watchingUser = false

  func guestRequest(
    _ body: [String: Any], admin: Bool,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    guard let channel = channels[admin ? "root" : "user"] else {
      completion(.failure(MachineError("The machine is not running.")))
      return
    }
    channel.send(body, completion: completion)
  }

  /// A picture of the screen as the guest is drawing it, from QEMU rather than the guest: it needs
  /// no agent, no permission, and works before anyone has logged on.
  func screenshot(completion: @escaping (Result<Data, Error>) -> Void) {
    let control = controlSocket
    let file = machine.url.appendingPathComponent("screen.png")
    DispatchQueue.global(qos: .userInitiated).async {
      let result = Result { () throws -> Data in
        guard
          let qemu = QMPConnection(socket: control),
          qemu.execute("screendump", ["filename": file.path, "format": "png"]) != nil
        else { throw MachineError("QEMU could not take a screenshot.") }
        defer { try? FileManager.default.removeItem(at: file) }
        return try Data(contentsOf: file)
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  private func startChannels() {
    for (half, socket) in agentSockets {
      let channel = QEMUGuestChannel(socket: socket, half: half)
      adopt(channel, as: half)
      channel.start()
    }
  }

  // Internal so tests can hand in channels over socketpairs instead of QEMU's sockets.
  func adopt(_ channel: QEMUGuestChannel, as half: String) {
    channel.onHello = { [weak self] process in self?.heard(half, process: process) }
    channel.onLost = { [weak self] in self?.lose(half, "its connection to the guest ended") }
    channels[half] = channel
  }

  private func heard(_ half: String, process: Int?) {
    if half == "user", !userPresent || process != userProcess {
      Self.log.notice(
        "user half arrived: pid \(process ?? -1) after \(self.userProcess ?? -1), arrival \(self.userArrivals + 1)"
      )
      userPresent = true
      userProcess = process
      userArrivals += 1
      watchingUser = false
    }
    watchUser()
    onAgentHello?(half)
  }

  /// Asks the root half to answer when the user half's process ends. A failure is the root half
  /// going away, and its next hello asks again.
  private func watchUser() {
    guard !watchingUser, userPresent, let process = userProcess,
      let root = channels["root"], root.isHeard
    else { return }
    watchingUser = true
    root.send(["op": "await_exit", "pid": process]) { [weak self] result in
      guard let self, self.userPresent, self.userProcess == process else { return }
      self.watchingUser = false
      guard case .success = result else {
        Self.log.notice("await_exit for user pid \(process) failed; asked again at the next hello")
        return
      }
      self.userPresent = false
      self.channels["user"]?.abandon()
      self.lose("user", "the root half reported its process (pid \(process)) ended")
    }
  }

  private func stopChannels() {
    for channel in channels.values { channel.stop() }
    channels = [:]
  }

  /// Whether this run carried on from a save, leaving the guest's clock where it was then.
  private(set) var resumedFromSave = false

  /// The machine stopped because its saved state could not be loaded. A state only loads into the
  /// same virtual hardware it was saved from, so one saved before hukan changed that never will.
  private(set) var resumeFailed = false

  /// Told, on the main thread, when the machine has stopped of its own accord.
  var onStop: ((Error?) -> Void)?

  var isRunning: Bool { process?.isRunning ?? false }

  // Injectable share paths let tests stay isolated from Homebrew and production share files.
  init(
    machine: Machine, temporaryDirectory: URL = FileManager.default.temporaryDirectory,
    sambaExecutable: String = QEMUMachine.smbd
  ) {
    self.temporaryDirectory = temporaryDirectory
    self.sambaExecutable = sambaExecutable
    self.machine = machine
    let tag = machine.id.uuidString.prefix(8)
    displaySocket = QEMUSocket.path("vnc-\(tag)")
    controlSocket = QEMUSocket.path("qmp-\(tag)")
    agentSockets = [
      "user": QEMUSocket.path("ga-\(tag)-user"), "root": QEMUSocket.path("ga-\(tag)-root"),
    ]
  }

  /// The worktree the guest sees as `W:\`, set before `start` and moved with `share`.
  var sharedDirectory: URL?
  /// Whether the guest has a share to map: samba was there when the machine started.
  private(set) var sharesWorktree = false

  /// Samba's server, as Homebrew names it beside the one macOS ships. Looked for rather than
  /// required: without it the machine runs, only without the worktree.
  static let smbd = "/opt/homebrew/sbin/samba-dot-org-smbd"

  /// The share, spoken to the way QEMU's own `smb=` does it — a server started for each
  /// connection the guest makes to 10.0.2.4, on stdin and stdout, so nothing listens on this Mac
  /// — but with a configuration of hukan's. What it shares is a link to the worktree, so a move
  /// is the link repointed; samba resolves it at each connection, so the move also ends the ones
  /// open, once nothing is open through them (`dropShareConnections`). The link is the share's root rather than an entry inside one,
  /// because samba's wide links are all or nothing: let out for one link at the top, they let out
  /// every link in the worktree too, and a repository carrying `host -> /` handed the guest the
  /// whole of this Mac as the user hukan runs as.
  private let temporaryDirectory: URL
  private let sambaExecutable: String

  // Internal so tests can inspect share files without starting Samba.
  var shareRoot: URL {
    temporaryDirectory.appendingPathComponent(
      "hukan-smb-\(machine.id.uuidString.prefix(8))")
  }

  // Internal so tests can inspect configuration without running QEMU.
  func prepareShare() -> String? {
    guard let sharedDirectory, FileManager.default.isExecutableFile(atPath: sambaExecutable) else {
      return nil
    }
    let root = shareRoot
    let state = root.appendingPathComponent("state")
    let manager = FileManager.default
    try? manager.createDirectory(at: state, withIntermediateDirectories: true)
    // Where the link stood before it was the root; removing it removes the link, not the worktree.
    try? manager.removeItem(at: root.appendingPathComponent("share"))
    let conf = root.appendingPathComponent("smb.conf")
    let link = root.appendingPathComponent("worktree")
    let lines = [
      "[global]",
      "private dir=\(state.path)", "pid directory=\(state.path)", "lock directory=\(state.path)",
      "state directory=\(state.path)", "cache directory=\(state.path)",
      "ncalrpc dir=\(state.path)/ncalrpc", "log file=\(state.path)/log.smbd",
      "smb passwd file=\(state.path)/smbpasswd",
      "interfaces=127.0.0.1", "bind interfaces only=yes",
      "security = user", "map to guest = Bad User",
      "load printers = no", "printing = bsd", "disable spoolss = yes",
      "usershare max shares = 0",
      "unix extensions = no",
      "[hukan]",
      "path=\(link.path)", "read only=no", "guest ok=yes", "force user=\(NSUserName())",
      // A link inside the worktree is followed while it stays inside it, and refused past it.
      "follow symlinks = yes", "wide links = no",
      "",
    ]
    guard
      (try? lines.joined(separator: "\n").write(to: conf, atomically: true, encoding: .utf8))
        != nil
    else { return nil }
    self.share(sharedDirectory)
    return "guestfwd=tcp:10.0.2.4:445-cmd:\(sambaExecutable) -l \(state.path) -s \(conf.path)"
  }

  /// Point the share at another worktree, the running guest included.
  func share(_ directory: URL?) {
    let moved = directory != sharedDirectory
    sharedDirectory = directory
    guard let directory else { return }
    let link = shareRoot.appendingPathComponent("worktree")
    let staged = shareRoot.appendingPathComponent("worktree-next")
    try? FileManager.default.removeItem(at: staged)
    // Made beside it and renamed over it, so the guest never finds no link at all.
    guard
      (try? FileManager.default.createSymbolicLink(at: staged, withDestinationURL: directory))
        != nil
    else { return }
    _ = rename(staged.path, link.path)
    if moved { dropShareConnections() }
  }

  /// The worktree the guest's open connections were made on, which a move leaves behind until
  /// they are ended.
  private var connectedDirectory: URL?
  private var dropGeneration = 0

  /// A connection holds the worktree it was opened on — samba resolves the share's path once, at
  /// the tree connect, and opens everything after relative to it — so a guest already connected
  /// is cut off and reconnects onto the new one, which Windows does by itself on the next access.
  /// Not while it has a file open there, though: ending a connection under a write leaves the
  /// file half-written and loses what the client was still holding, so the cut waits for the
  /// first moment nothing is open, and until then the guest goes on seeing the worktree it had.
  /// Each connection is a samba of its own that QEMU started, so these are this machine's sambas
  /// and nobody else's.
  private func dropShareConnections() {
    dropGeneration += 1
    let generation = dropGeneration
    guard let qemu = process?.processIdentifier, let connected = connectedDirectory else { return }
    guard connected != sharedDirectory else { return }
    let sambas = Self.processes(running: sambaExecutable, under: qemu)
    if sambas.contains(where: { Self.hasFileOpen($0, under: connected) }) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        guard let self, self.dropGeneration == generation else { return }
        self.dropShareConnections()
      }
      return
    }
    for pid in sambas { kill(pid, SIGTERM) }
    connectedDirectory = sharedDirectory
  }

  /// Whether `pid` holds a file open inside `directory` — a regular file, since samba holds the
  /// share's root open as a directory for as long as the connection lasts.
  static func hasFileOpen(_ pid: pid_t, under directory: URL) -> Bool {
    // realpath, not `resolvingSymlinksInPath`, which hands back `/var` for the kernel's
    // `/private/var` and so never matched a file under the temporary directory.
    guard let resolved = realpath(directory.path, nil) else { return false }
    let root = String(cString: resolved) + "/"
    free(resolved)
    let stride = MemoryLayout<proc_fdinfo>.stride
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return false }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
    let listed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
    return fds.prefix(Int(max(listed, 0)) / stride).contains { fd in
      guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return false }
      var info = vnode_fdinfowithpath()
      let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
      guard
        proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize,
        (info.pvip.vip_vi.vi_stat.vst_mode & S_IFMT) == S_IFREG
      else { return false }
      let path = withUnsafeBytes(of: info.pvip.vip_path) {
        String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
      }
      return path.hasPrefix(root)
    }
  }

  /// The processes descended from `parent` that are running `executable`.
  static func processes(running executable: String, under parent: pid_t) -> [pid_t] {
    guard let resolved = realpath(executable, nil) else { return [] }
    let target = String(cString: resolved)
    free(resolved)
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 16)
    let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
    return pids.prefix(Int(max(listed, 0))).filter { pid in
      pid > 1 && pid != parent && proc_pidpath(pid, &path, UInt32(path.count)) > 0
        && String(cString: path) == target && isDescendant(pid, of: parent)
    }
  }

  func start() throws {
    guard FileManager.default.isExecutableFile(atPath: WindowsTemplateBuilder.qemu) else {
      throw MachineError("Windows needs QEMU from Homebrew. Run `brew install qemu`.")
    }
    // A machine made before the type was recorded was made on the bare `virt` of a QEMU no older
    // than the one here, so it is held at today's from now on.
    if machine.manifest.qemuMachine == nil, let type = WindowsTemplateBuilder.machineType() {
      machine.manifest.qemuMachine = type
      try? machine.save()
    }
    Self.stopLeftover(in: machine.url)
    for path in [displaySocket, controlSocket] + agentSockets.values {
      try? FileManager.default.removeItem(atPath: path)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: WindowsTemplateBuilder.qemu)
    let smb = prepareShare()
    sharesWorktree = smb != nil
    connectedDirectory = sharedDirectory
    let resuming = FileManager.default.fileExists(atPath: machine.stateURL.path)
    resumedFromSave = resuming
    process.arguments = arguments(resuming: resuming, smb: smb)
    let log = machine.url.appendingPathComponent("qemu.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    if let handle = try? FileHandle(forWritingTo: log) {
      process.standardOutput = handle
      process.standardError = handle
    }
    process.terminationHandler = { [weak self] process in
      DispatchQueue.main.async {
        guard let self else { return }
        self.process = nil
        self.stopChannels()
        for path in [self.displaySocket, self.controlSocket] {
          try? FileManager.default.removeItem(atPath: path)
        }
        if let stopping = self.stopping {
          self.stopping = nil
          stopping()
          return
        }
        let failed = process.terminationStatus != 0
        // Still there means it never got as far as running: QEMU could not load it. Then it never
        // will, so it goes now rather than waiting on a disk for someone to throw it away.
        self.resumeFailed =
          failed && FileManager.default.fileExists(atPath: self.machine.stateURL.path)
        if self.resumeFailed { try? FileManager.default.removeItem(at: self.machine.stateURL) }
        self.onStop?(
          failed ? MachineError("QEMU stopped (status \(process.terminationStatus)).") : nil)
      }
    }
    try process.run()
    self.process = process
    startChannels()
    guard resuming else { return }
    // A saved state belongs to the disk as it was: once running again it describes nothing.
    let control = controlSocket
    let state = machine.stateURL
    DispatchQueue.global(qos: .utility).async {
      // A connection for each look: the socket takes one client, and held for the whole of a
      // resume it kept out the save that quitting asks for.
      for _ in 0..<600 {
        let qemu = QMPConnection(socket: control)
        let status = (qemu?.execute("query-status") as? [String: Any])?["status"] as? String
        // Saved while stopped, it comes back stopped, and has to be told to carry on.
        if status == "paused" { _ = qemu?.execute("cont") }
        if status == "running" {
          try? FileManager.default.removeItem(at: state)
          return
        }
        Thread.sleep(forTimeInterval: 0.5)
      }
    }
  }

  // Internal pure argument construction lets tests avoid starting QEMU.
  func arguments(resuming: Bool, smb: String? = nil) -> [String] {
    let manifest = machine.manifest
    var arguments = [
      "-machine", "\(manifest.qemuMachine ?? "virt"),highmem=on,gic-version=3",
      "-accel", "hvf", "-cpu", "host",
      "-smp", String(manifest.cpuCount), "-m", String(manifest.memorySize >> 20),
      "-drive", "if=pflash,format=raw,readonly=on,file=\(WindowsTemplateBuilder.firmwareCode)",
      "-drive", "if=pflash,format=raw,file=\(machine.auxiliaryURL.path)",
      "-device", "virtio-gpu-pci,xres=1280,yres=800",
      "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
      "-device", "usb-tablet,bus=xhci.0",
      "-drive",
      "if=none,id=disk0,format=raw,cache=writeback,discard=unmap,file=\(machine.diskURL.path)",
      "-device", "nvme,serial=hukan0,drive=disk0",
      // Windows reads the hardware clock as local time, and QEMU keeps it in UTC unless told.
      "-rtc", "base=localtime", "-nic",
      ["user", "model=virtio-net-pci", smb].compactMap { $0 }.joined(separator: ","),
      "-display", "none",
      "-vnc", "unix:\(displaySocket)",
      "-device", "virtio-serial-pci,id=serial0",
      "-qmp", "unix:\(controlSocket),server=on,wait=off",
      "-pidfile", pidFile,
    ]
    for (half, socket) in agentSockets {
      arguments += [
        "-chardev", "socket,id=agent\(half),path=\(socket),server=on,wait=off",
        "-device", "virtserialport,bus=serial0.0,chardev=agent\(half),name=dev.hukan.agent.\(half)",
      ]
    }
    if resuming { arguments += ["-incoming", "file:\(machine.stateURL.path)"] }
    return arguments
  }

  private var pidFile: String { Self.pidFile(in: machine.url) }

  private static func pidFile(in directory: URL) -> String {
    directory.appendingPathComponent("qemu.pid").path
  }

  /// A QEMU left behind by a hukan that died has this machine's disk open. Two of them on one disk
  /// is the disk's end, so the old one goes before a new one starts — and before the machine is
  /// deleted, or it runs on for good over a disk nobody can reach.
  static func stopLeftover(in directory: URL) {
    guard let text = try? String(contentsOfFile: pidFile(in: directory), encoding: .utf8),
      let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
    else { return }
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
      String(cString: path).contains("qemu-system")
    else { return }
    kill(pid, SIGTERM)
    for _ in 0..<50 where kill(pid, 0) == 0 { Thread.sleep(forTimeInterval: 0.1) }
    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
  }

  /// Press the machine's power button, which Windows answers by shutting down.
  func requestShutdown() {
    let control = controlSocket
    DispatchQueue.global(qos: .userInitiated).async {
      _ = QMPConnection(socket: control)?.execute("system_powerdown")
    }
  }

  /// Save the machine beside its disk and stop QEMU. Written under another name and moved into
  /// place once whole: a save cut short had replaced the state it was saving, and the machine
  /// could not be resumed at all.
  func save(completion: @escaping () -> Void) {
    guard isRunning else { return completion() }
    stopping = completion
    let control = controlSocket
    let state = machine.stateURL
    let partial = state.appendingPathExtension("saving")
    let process = self.process
    DispatchQueue.global(qos: .userInitiated).async {
      defer { process?.terminate() }
      let manager = FileManager.default
      try? manager.removeItem(at: partial)
      // Stopped first. Saved while it ran, the guest went on dirtying memory, the file came to
      // twice its RAM, and what it held did not resume: Windows came back by restarting.
      guard let qemu = QMPConnection(socket: control), qemu.execute("stop") != nil,
        qemu.execute("migrate", ["uri": "file:\(partial.path)"]) != nil
      else { return }
      for _ in 0..<1200 {
        let info = qemu.execute("query-migrate") as? [String: Any]
        let status = info?["status"] as? String
        if status == "completed" {
          _ = try? manager.replaceItemAt(state, withItemAt: partial)
          return
        }
        if status == "failed" {
          try? manager.removeItem(at: partial)
          return
        }
        Thread.sleep(forTimeInterval: 0.25)
      }
      try? manager.removeItem(at: partial)
    }
  }

  func forceStop(completion: @escaping () -> Void) {
    guard isRunning else { return completion() }
    stopping = completion
    process?.terminate()
  }
}

/// A blocking client for QEMU's machine protocol, on a unix socket. Called off the main thread.
final class QMPConnection {
  private let descriptor: Int32
  private var buffer = Data()

  /// Waits for QEMU to have opened the socket, and gets past the greeting.
  init?(socket path: String) {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    descriptor = fd
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    var connected = false
    for _ in 0..<100 {
      let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
      }
      if result == 0 {
        connected = true
        break
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    guard connected, readObject() != nil, execute("qmp_capabilities") != nil else {
      close(fd)
      return nil
    }
  }

  deinit { close(descriptor) }

  /// The command's reply, or nil if QEMU answered with an error or has gone.
  func execute(_ name: String, _ arguments: [String: Any] = [:]) -> Any? {
    let body: [String: Any] = ["execute": name, "arguments": arguments]
    guard var data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
    data.append(0x0A)
    let sent = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    guard sent == data.count else { return nil }
    while let object = readObject() {
      if object["error"] != nil { return nil }
      if let reply = object["return"] { return reply }
    }
    return nil
  }

  /// Blocks until QEMU reports the event, or false once it has gone.
  func wait(for event: String) -> Bool {
    while let object = readObject() {
      if object["event"] as? String == event { return true }
    }
    return false
  }

  private func readObject() -> [String: Any]? {
    while true {
      if let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<newline]
        buffer.removeSubrange(buffer.startIndex...newline)
        return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
      }
      var chunk = [UInt8](repeating: 0, count: 4096)
      let count = read(descriptor, &chunk, chunk.count)
      guard count > 0 else { return nil }
      buffer.append(contentsOf: chunk[0..<count])
    }
  }
}

/// Follows a redirect over https only. The drivers' address answers https with a redirect to plain
/// http on the same host, which App Transport Security refuses — rightly, since what comes back
/// is installed into every Windows template. The same address is there over https, so that is
/// where the redirect is taken instead.
// Internal so tests can drive redirects without a network request.
final class SecureRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let url = request.url, url.scheme == "http",
      var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return completionHandler(request) }
    parts.scheme = "https"
    var secure = request
    secure.url = parts.url
    completionHandler(secure)
  }
}
