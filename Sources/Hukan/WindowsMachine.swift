import Carbon
import CoreGraphics
import Foundation
import ImageIO
import Vision

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
  private let password = MacTemplateBuilder.makePassword()
  private var hostKeyboardIsJIS = false
  /// The install, for the Virtual Machines window to show.
  let screenView = QEMUScreenView()

  init(request: Request) {
    self.request = request
  }

  func run() {
    onPhase?(.preparing)
    hostKeyboardIsJIS =
      KBGetLayoutType(Int16(CGEventSource(stateID: .hidSystemState)?.keyboardType ?? 0))
      == kKeyboardJIS
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
      // Off the main thread and before QEMU, which is what the prompt's three seconds need.
      Self.warmUpRecognition()
      DispatchQueue.main.async { [self] in
        switch prepared {
        case .success(let machine): start(machine)
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

  /// What the first logon runs, from the answers disc: the drivers, then the agent's two halves.
  /// Every step is left to fail on its own: a template without one of these still boots, and says
  /// so by not answering, where a script that stopped would leave the rest undone too.
  // Internal so tests can inspect setup without mounting or booting an ISO.
  static let setupScript = [
    "@echo off",
    "set D=",
    "for %%d in (D E F G H I J) do if exist %%d:\\vioserial\\w11\\ARM64\\vioser.inf set D=%%d:",
    "pnputil /add-driver %D%\\vioserial\\w11\\ARM64\\vioser.inf /install",
    "pnputil /add-driver %D%\\NetKVM\\w11\\ARM64\\netkvm.inf /install",
    "pnputil /add-driver %D%\\viogpudo\\w11\\ARM64\\viogpudo.inf /install",
    "set H=C:\\Program Files\\Hukan",
    "mkdir \"%H%\"",
    "copy /y \"%~dp0hukan-guest-agent.exe\" \"%H%\\\"",
    "sc create HukanGuestAgent binPath= \"\\\"%H%\\hukan-guest-agent.exe\\\" --root\" start= auto",
    "schtasks /create /tn HukanGuestAgent /sc onlogon /rl highest /f "
      + "/tr \"\\\"%H%\\hukan-guest-agent.exe\\\" --user\"",
    "reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System "
      + "/v EnableLUA /t REG_DWORD /d 0 /f",
    "powercfg /change standby-timeout-ac 0",
    "powercfg /change monitor-timeout-ac 0",
    "",
  ].joined(separator: "\r\n")

  private func prepare() throws -> Machine {
    let id = UUID()
    let url = MachineStore.templatesURL.appendingPathComponent(".building-\(id.uuidString)")
    let manager = FileManager.default
    try manager.createDirectory(at: url, withIntermediateDirectories: true)
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

  /// What a Windows ISO is, `Windows 11 24H2`, read off the image it installs. A WIM keeps a
  /// description of its images as XML, uncompressed, at a place its header names — so no tool is
  /// needed to read it, only the header's 24-byte record at offset 72: a 7-byte size, a flags
  /// byte, then the offset.
  static func title(ofISO iso: URL) throws -> String? {
    try mounted(iso) { mount in
      let sources = mount.appendingPathComponent("sources")
      guard
        let wim = ["install.wim", "install.esd"].map({ sources.appendingPathComponent($0) })
          .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
        let handle = try? FileHandle(forReadingFrom: wim)
      else { return nil }
      defer { try? handle.close() }
      guard let range = xmlRange(inWIMHeader: try handle.read(upToCount: 208) ?? Data()) else {
        return nil
      }
      try handle.seek(toOffset: range.offset)
      guard let xml = try handle.read(upToCount: range.size) else { return nil }
      return String(data: xml, encoding: .utf16).flatMap(title(fromWIMXML:))
    }
  }

  static func xmlRange(inWIMHeader header: Data) -> (offset: UInt64, size: Int)? {
    guard header.count >= 96, header.prefix(8) == Data("MSWIM\0\0\0".utf8) else { return nil }
    let record = header.subdata(in: 72..<96)
    let size = record.prefix(7).reversed().reduce(0) { $0 << 8 | Int($1) }
    let offset = record.subdata(in: 8..<16).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    guard size > 0, size < 16 << 20 else { return nil }
    return (offset, size)
  }

  /// The product from the first image's name and the release from its build — the XML carries a
  /// build number and never the `24H2` people call it by, so a release this table has not heard
  /// of is named by its build instead.
  static func title(fromWIMXML xml: String) -> String? {
    func first(_ tag: String) -> String? {
      guard let start = xml.range(of: "<\(tag)>"),
        let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex)
      else { return nil }
      return String(xml[start.upperBound..<end.lowerBound])
    }
    guard let name = first("NAME"),
      let product = name.range(of: #"^Windows \d+"#, options: .regularExpression).map({
        String(name[$0])
      })
    else { return nil }
    guard let build = first("BUILD").flatMap(Int.init) else { return product }
    let releases = [22000: "21H2", 22621: "22H2", 22631: "23H2", 26100: "24H2", 26200: "25H2"]
    return releases[build].map { "\(product) \($0)" } ?? "\(product) (\(build))"
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

  /// Keys reach the guest by position, so the guest has to believe in the keyboard that is really
  /// on this Mac: left at Windows' 101-key default, a JIS keyboard's symbols come out wrong and its
  /// IME keys do nothing. A guest cannot change this without restarting, so it is settled here, once,
  /// from the keyboard the template is made on.
  private var keyboardCommands: [String] {
    guard hostKeyboardIsJIS else { return [] }
    let key = "HKLM\\SYSTEM\\CurrentControlSet\\Services\\i8042prt\\Parameters"
    return [
      "/v &quot;LayerDriver JPN&quot; /t REG_SZ /d kbd106.dll",
      "/v OverrideKeyboardIdentifier /t REG_SZ /d PCAT_106KEY",
      "/v OverrideKeyboardType /t REG_DWORD /d 7",
      "/v OverrideKeyboardSubtype /t REG_DWORD /d 2",
    ].map { "reg add &quot;\(key)&quot; \($0) /f" }
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
    let checks = [
      "BypassTPMCheck", "BypassSecureBootCheck", "BypassCPUCheck", "BypassRAMCheck",
      "BypassStorageCheck",
    ].enumerated().map { index, check in
      """
      <RunSynchronousCommand wcm:action="add"><Order>\(index + 1)</Order>\
      <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \(check) /t REG_DWORD /d 1 /f</Path>\
      </RunSynchronousCommand>
      """
    }.joined(separator: "\n        ")
    let setup =
      "cmd /c for %d in (D E F G H I J) do if exist %d:\\hukan-setup.cmd call %d:\\hukan-setup.cmd"
    let firstLogon =
      (["cmd /c del /f /q C:\\Windows\\Panther\\unattend.xml"] + keyboardCommands
      + [setup, "shutdown /s /t 5"]).enumerated().map { index, command in
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
            </RunSynchronous>
            <DiskConfiguration>
              <Disk wcm:action="add">
                <DiskID>0</DiskID>
                <WillWipeDisk>true</WillWipeDisk>
                <CreatePartitions>
                  <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
                  <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
                  <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
                </CreatePartitions>
                <ModifyPartitions>
                  <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
                  <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
                </ModifyPartitions>
              </Disk>
            </DiskConfiguration>
            <ImageInstall>
              <OSImage>
                <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>Windows 11 Pro</Value></MetaData></InstallFrom>
                <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
              </OSImage>
            </ImageInstall>
            <UserData>
              <AcceptEula>true</AcceptEula>
              <ProductKey><Key>VK7JG-NPHTM-C97JM-9MPGT-3V66T</Key></ProductKey>
            </UserData>
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
    let screen = machine.url.appendingPathComponent("screen.png").path
    DispatchQueue.global(qos: .utility).async {
      Self.passBootPrompt(socket: socket, screen: screen)
    }
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
    ]
  }

  /// A Windows ISO waits about three seconds at "Press any key to boot from CD or DVD", in English
  /// whatever language it installs, and with no key it gives up and the firmware falls through to
  /// its shell. So the screen is read, and Return goes once, when the words are on it: sent blind
  /// and repeatedly, the keys carried on into Setup and pressed its Cancel button.
  /// The prompt stands for about three seconds, and Vision's first recognition loads its model,
  /// which can take longer than that — so the model is loaded before QEMU starts, and a prompt
  /// missed all the same is not the end of the install: the firmware falls into its shell, which
  /// is told to run the installer's loader again, and the prompt comes back.
  private static func passBootPrompt(socket: String, screen: String) {
    guard let qemu = QMPConnection(socket: socket) else { return }
    let deadline = Date().addingTimeInterval(120)
    var shellTries = 0
    while Date() < deadline {
      guard qemu.execute("screendump", ["filename": screen, "format": "png"]) != nil else {
        Thread.sleep(forTimeInterval: 0.3)
        continue
      }
      let seen = text(in: screen).lowercased()
      if seen.contains("press any key") {
        _ = qemu.execute("send-key", ["keys": [["type": "qcode", "data": "ret"]]])
        break
      }
      if seen.contains("shell>"), shellTries < 3 {
        shellTries += 1
        type("fs0:\\efi\\boot\\bootaa64.efi\n", into: qemu)
        Thread.sleep(forTimeInterval: 1)
        continue
      }
      Thread.sleep(forTimeInterval: 0.3)
    }
    try? FileManager.default.removeItem(atPath: screen)
  }

  /// Loads Vision's recognition model, so the first screen read while the prompt stands is fast.
  static func warmUpRecognition() {
    guard
      let context = CGContext(
        data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
      let image = context.makeImage()
    else { return }
    try? VNImageRequestHandler(cgImage: image).perform([VNRecognizeTextRequest()])
  }

  /// Types into the firmware a key at a time, as QEMU's key codes; enough for a path.
  private static func type(_ text: String, into qemu: QMPConnection) {
    let named: [Character: (String, Bool)] = [
      ":": ("semicolon", true), "\\": ("backslash", false), ".": ("dot", false),
      "\n": ("ret", false),
    ]
    for character in text {
      let (code, shift): (String, Bool)
      if let key = named[character] {
        (code, shift) = key
      } else {
        (code, shift) = (String(character), false)
      }
      let keys: [[String: String]] =
        (shift ? [["type": "qcode", "data": "shift"]] : []) + [["type": "qcode", "data": code]]
      _ = qemu.execute("send-key", ["keys": keys])
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  private static func text(in path: String) -> String {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return "" }
    let request = VNRecognizeTextRequest()
    try? VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: " ")
  }

  /// The guest shuts itself down at its first logon, so QEMU leaving cleanly is the install done.
  private func finished(_ machine: Machine, status: Int32, log: URL) {
    let manager = FileManager.default
    try? manager.removeItem(at: machine.url.appendingPathComponent(Self.answerDiscName))
    guard status == 0 else {
      let tail = (try? String(contentsOf: log, encoding: .utf8))?.suffix(400) ?? ""
      onPhase?(.failed("QEMU stopped (status \(status)). \(tail)"))
      return
    }
    try? manager.removeItem(at: log)
    let destination = MachineStore.templatesURL.appendingPathComponent(machine.id.uuidString)
    do {
      try manager.moveItem(at: machine.url, to: destination)
      MachineStore.changed()
      onPhase?(.done)
    } catch {
      onPhase?(.failed(error.localizedDescription))
    }
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
