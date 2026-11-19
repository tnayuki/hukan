import AppKit
import Virtualization

/// A Linux machine's hardware: what Virtualization.framework is told to build for one. It runs in
/// this process like a macOS machine (`VirtualizationMachine`), on the framework's generic
/// platform, and differs from one in what the guest has to be given rather than what runs it —
/// EFI to boot, a virtio screen and a USB keyboard, the worktree as a share the guest mounts by
/// tag, and Rosetta, so the x86_64 programs a Linux on Arm has no build of run all the same.
enum LinuxMachine {
  /// The tag the guest mounts the worktree by, and where its template's fstab puts it.
  static let shareTag = "worktree"
  static let mountPath = "/worktree"
  /// Rosetta's share, which the template's fstab mounts here and binfmt hands x86_64 programs to.
  static let rosettaTag = "rosetta"
  static let rosettaPath = "/media/rosetta"

  /// Whether this Mac can give a guest Rosetta now. From macOS 27 the translation is part of the
  /// system and always is; before it, Rosetta has to have been installed.
  static var rosettaAvailable: Bool {
    VZLinuxRosettaDirectoryShare.availability == .installed
  }

  /// `installing` is the discs an install boots from, after the machine's own disk: hukan's boot
  /// disk, the ISO and the autoinstall disc, read-only and in that order.
  static func configuration(
    for machine: Machine, sharedDirectory: URL?, installing: [URL] = []
  ) throws
    -> VZVirtualMachineConfiguration
  {
    let manifest = machine.manifest
    guard
      let identifierData = manifest.machineIdentifier.flatMap({ Data(base64Encoded: $0) }),
      let identifier = VZGenericMachineIdentifier(dataRepresentation: identifierData)
    else { throw MachineError("\(manifest.title) has no machine identifier.") }
    let platform = VZGenericPlatformConfiguration()
    platform.machineIdentifier = identifier

    let configuration = VZVirtualMachineConfiguration()
    configuration.platform = platform
    let boot = VZEFIBootLoader()
    boot.variableStore = VZEFIVariableStore(url: machine.auxiliaryURL)
    configuration.bootLoader = boot
    configuration.cpuCount = manifest.cpuCount
    configuration.memorySize = manifest.memorySize

    // Cached, never automatic: a Linux guest on the automatic mode read back pages that were not
    // what it wrote — journald failing to start, systemd killed by SIGILL, the installer aborting —
    // and the same install on the cached mode went through clean (measured on an M4, 27.2).
    let attach = { (url: URL, readOnly: Bool) in
      VZVirtioBlockDeviceConfiguration(
        attachment: try VZDiskImageStorageDeviceAttachment(
          url: url, readOnly: readOnly, cachingMode: .cached, synchronizationMode: .full))
    }
    configuration.storageDevices =
      try [attach(machine.diskURL, false)] + installing.map { try attach($0, true) }

    let network = VZVirtioNetworkDeviceConfiguration()
    network.attachment = VZNATNetworkDeviceAttachment()
    if let mac = VZMACAddress(string: manifest.macAddress) { network.macAddress = mac }
    configuration.networkDevices = [network]

    let graphics = VZVirtioGraphicsDeviceConfiguration()
    graphics.scanouts = [
      VZVirtioGraphicsScanoutConfiguration(
        widthInPixels: manifest.display.width, heightInPixels: manifest.display.height)
    ]
    configuration.graphicsDevices = [graphics]
    configuration.keyboards = [VZUSBKeyboardConfiguration()]
    configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

    // The clipboard, both ways, through the SPICE agent the template installs (spice-vdagent).
    let spicePort = VZVirtioConsolePortConfiguration()
    spicePort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
    let spice = VZSpiceAgentPortAttachment()
    spice.sharesClipboard = true
    spicePort.attachment = spice
    let console = VZVirtioConsoleDeviceConfiguration()
    console.ports[0] = spicePort
    configuration.consoleDevices = [console]
    if !installing.isEmpty
      || FileManager.default.fileExists(
        atPath: machine.url.appendingPathComponent(LinuxTemplateBuilder.consoleLogName).path)
    {
      // The kernel's console and the installer's, written beside the template being made: the one
      // place a setup that went wrong says why, when its screen has already gone.
      let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
      serial.attachment = try VZFileSerialPortAttachment(
        url: machine.url.appendingPathComponent(LinuxTemplateBuilder.consoleLogName), append: true)
      configuration.serialPorts = [serial]
    }

    var shares: [VZDirectorySharingDeviceConfiguration] = []
    if let sharedDirectory {
      let share = VZVirtioFileSystemDeviceConfiguration(tag: shareTag)
      share.share = VirtualizationMachine.share(sharedDirectory, kind: .linux)
      shares.append(share)
    }
    if rosettaAvailable, manifest.rosetta != false {
      let rosetta = VZVirtioFileSystemDeviceConfiguration(tag: rosettaTag)
      rosetta.share = try VZLinuxRosettaDirectoryShare()
      shares.append(rosetta)
    }
    configuration.directorySharingDevices = shares
    return configuration
  }
}

/// An Ubuntu release a Linux template can be made from: its desktop or its server ISO for arm64,
/// each of which carries what it installs, so a template is made from it with no network — as a
/// macOS one is from its IPSW and a Windows one from its ISO. The server installs a fraction of
/// what the desktop does and has no screen to drive, for machines that are only given commands.
///
/// Nothing here is a table of releases. Which LTS releases are still supported is Canonical's
/// `meta-release-lts`, the list `do-release-upgrade` reads, and the newest point release of each
/// — 24.04.5, not 24.04 — is whichever ISO of an edition for arm64 that release's `SHA256SUMS`
/// names with the highest number, which also gives the checksum the download is held to. A
/// release with no such ISO drops out by itself. Both are GETs of Canonical's fixed addresses with
/// nothing sent, made only when someone asks to download one.
struct UbuntuRelease: Equatable {
  enum Edition: CaseIterable {
    case desktop, server

    /// What Canonical ends the ISO's name with.
    var suffix: String { self == .desktop ? "-desktop-arm64.iso" : "-live-server-arm64.iso" }
    var name: String { self == .desktop ? "Desktop" : "Server" }
  }

  /// `24.04.5`.
  let version: String
  let edition: Edition
  let isoName: String
  let sha256: String

  init(version: String, edition: Edition = .desktop, isoName: String, sha256: String) {
    self.version = version
    self.edition = edition
    self.isoName = isoName
    self.sha256 = sha256
  }

  static let metaRelease = URL(string: "https://changelogs.ubuntu.com/meta-release-lts")!
  static func checksums(for series: String) -> URL {
    URL(string: "https://cdimage.ubuntu.com/ubuntu/releases/\(series)/release/SHA256SUMS")!
  }

  var title: String { "Ubuntu \(version) LTS \(edition.name)" }
  var url: URL {
    Self.checksums(for: Self.series(of: version)).deletingLastPathComponent()
      .appendingPathComponent(isoName)
  }

  /// `24.04.5` is the `24.04` series.
  static func series(of version: String) -> String {
    version.split(separator: ".").prefix(2).joined(separator: ".")
  }

  /// The supported LTS series in `meta-release-lts`, oldest first: `["22.04", "24.04"]`.
  static func supportedSeries(inMetaRelease text: String) -> [String] {
    text.components(separatedBy: "\n\n").compactMap { stanza in
      var fields: [String: String] = [:]
      for line in stanza.split(separator: "\n") {
        guard let colon = line.firstIndex(of: ":") else { continue }
        fields[String(line[..<colon])] = line[line.index(after: colon)...]
          .trimmingCharacters(in: .whitespaces)
      }
      guard fields["Supported"] == "1", let version = fields["Version"]?.split(separator: " ").first
      else { return nil }
      return series(of: String(version))
    }
  }

  /// The newest ISO of `edition` for arm64 a `SHA256SUMS` lists, by its version's numbers.
  static func newest(inChecksums text: String, edition: Edition = .desktop) -> UbuntuRelease? {
    let releases = text.split(separator: "\n").compactMap { line -> UbuntuRelease? in
      let parts = line.split(separator: " ", maxSplits: 1)
      guard parts.count == 2 else { return nil }
      let name = parts[1].hasPrefix("*") ? String(parts[1].dropFirst()) : String(parts[1])
      guard name.hasPrefix("ubuntu-"), name.hasSuffix(edition.suffix) else { return nil }
      let version = String(name.dropFirst("ubuntu-".count).dropLast(edition.suffix.count))
      guard !version.isEmpty, version.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
      return UbuntuRelease(
        version: version, edition: edition, isoName: name, sha256: String(parts[0]))
    }
    return releases.max { a, b in
      a.version.compare(b.version, options: .numeric) == .orderedAscending
    }
  }

  /// The releases there are to download, newest first, or why not.
  static func fetchAvailable(completion: @escaping (Result<[UbuntuRelease], Error>) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      let result = Result { () -> [UbuntuRelease] in
        let list = try fetch(metaRelease)
        // Newest release first, its desktop before its server.
        let releases = try supportedSeries(inMetaRelease: list).reversed().flatMap { series in
          let sums = try fetch(checksums(for: series))
          return Edition.allCases.compactMap { newest(inChecksums: sums, edition: $0) }
        }
        guard !releases.isEmpty else {
          throw MachineError("Ubuntu lists no supported release for arm64.")
        }
        return releases
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  private static func fetch(_ url: URL) throws -> String {
    let done = DispatchSemaphore(value: 0)
    var outcome: Result<String, Error> = .failure(MachineError("\(url.host ?? "") did not answer."))
    URLSession.shared.dataTask(with: url) { data, response, error in
      if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
        outcome = .success(String(decoding: data, as: UTF8.self))
      } else if let error {
        outcome = .failure(error)
      }
      done.signal()
    }.resume()
    done.wait()
    return try outcome.get()
  }

  /// `ubuntu-24.04.5-desktop-arm64.iso` reads as `Ubuntu 24.04.5`, and its server's as
  /// `Ubuntu 24.04.5 Server`.
  static func title(ofImage url: URL) -> String? {
    let name = url.lastPathComponent
    guard isUbuntu(url),
      let version = name.dropFirst("ubuntu-".count).split(separator: "-").first,
      version.contains(".")
    else { return nil }
    return "Ubuntu \(version)" + (isServer(url) ? " Server" : "")
  }

  /// Ubuntu's server ISO, by the name Canonical gives it — which the window goes by before a
  /// template is made. What a template installs is read off the ISO itself (`UbuntuPackages`).
  static func isServer(_ url: URL) -> Bool {
    url.lastPathComponent.lowercased().contains("-live-server-")
  }

  /// An ISO is Ubuntu's by its name — the name Canonical gives it, which is the one it keeps when
  /// hukan downloads it. Every other ISO is taken for Windows, as one always was.
  static func isUbuntu(_ url: URL) -> Bool {
    url.lastPathComponent.lowercased().hasPrefix("ubuntu-")
  }
}

/// Making a Linux template from Ubuntu's desktop ISO: Ubuntu's own installer, run unattended, then
/// a first boot that sets up the account and says it is up. Three discs go in beside the empty
/// disk — a small boot disk of hukan's, the ISO, and the autoinstall answers — and come out once
/// the installer has powered the guest off.
///
/// The boot disk is the one thing here that is not Ubuntu's. The installer runs unattended only
/// when `autoinstall` is on the kernel's command line, and the ISO's GRUB starts the kernel with a
/// line of its own; a key typed at its menu could change it, but against a timeout. So the ISO's
/// GRUB is copied onto a FAT disk the firmware reaches first, with a menu that starts the ISO's
/// kernel with the line hukan needs — no keys, no timing, the same signed GRUB.
///
/// Ubuntu 26.04.1 already has its kernel in the minimal layer; 24.04.5 does not. Missing
/// kernels and Japanese input are authenticated and cached by the host before the VM starts.
final class LinuxTemplateBuilder {
  struct Request {
    var title: String
    var image: URL
    var diskSize: UInt64
    var cpuCount: Int?
    var memorySize: UInt64?
    var username: String
    /// Give its machines a GPU (`VirglGPU`). macOS 27 and later.
    var gpu = false
    /// Set its machines up for Rosetta: the share, the binfmt registration, amd64 packages.
    var rosetta = true
  }

  static let consoleLogName = "console.log"
  private static let bootDiskName = "boot.img"
  private static let answersName = "answers.iso"

  let request: Request
  /// The guest account's password: made up here and kept in the template's manifest, for the
  /// prompts a desktop still puts up (unlocking a keyring) — sudo asks for none, as Windows' UAC
  /// is off and a macOS guest's sudo asks for none, and the agent's root half needs none.
  let password = MacTemplateBuilder.makePassword()
  var onPhase: ((MacTemplateBuilder.Phase) -> Void)?
  /// The guest's screen while it installs and sets itself up: scaled to fit, since an installer
  /// cannot change its resolution.
  let screenView = VZVirtualMachineView()
  private(set) var running: VirtualizationMachine? {
    didSet { screenView.virtualMachine = running?.vm }
  }
  private var claim: MachineStore.Claim?

  private enum Stage {
    /// Ubuntu's installer, from the ISO; it powers the guest off when it is done.
    case installing
    /// The installed system's first boot: cloud-init makes the account, the desktop signs in, and
    /// both halves of the agent say hello.
    case firstBoot
    /// The root half is running the script that finishes the template and shuts it down.
    case finishing
  }
  private var stage = Stage.installing
  /// Shut down from the window once setup said it could not finish: published as it stands.
  private var shutDownByHand = false
  private var gaveUp = false
  /// Stopped from the window: nothing from here on may start another stage or report one.
  private var cancelled = false
  private var machineURL: URL?

  init(request: Request) {
    self.request = request
    screenView.automaticallyReconfiguresDisplay = false
    screenView.capturesSystemKeys = true
  }

  func run() {
    onPhase?(.preparing)
    // Before macOS 27, Rosetta for a guest is the system's Rosetta, which asks to be installed.
    if request.rosetta, VZLinuxRosettaDirectoryShare.availability == .notInstalled {
      VZLinuxRosettaDirectoryShare.installRosetta { [weak self] _ in
        DispatchQueue.main.async { self?.prepareInBackground() }
      }
      return
    }
    prepareInBackground()
  }

  private func prepareInBackground() {
    guard !cancelled else { return }
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let prepared = Result { try prepare() }
      DispatchQueue.main.async { [self] in
        if cancelled {
          if case .success(let machine) = prepared { discard(machine.url) }
          return
        }
        switch prepared {
        case .success(let machine):
          machineURL = machine.url
          install(machine)
        case .failure(let error): onPhase?(.failed(error.localizedDescription))
        }
      }
    }
  }

  // MARK: Before it boots

  private func prepare() throws -> Machine {
    let packages = try UbuntuPackages.cached(iso: request.image)
    // A GPU is for a desktop to draw with; a server has none to draw.
    guard !(packages.server && request.gpu) else {
      throw MachineError("A machine made from Ubuntu's server ISO has no desktop to give a GPU.")
    }
    MachineStore.prepare()
    let id = UUID()
    let url = MachineStore.templatesURL.appendingPathComponent(".building-\(id.uuidString)")
    let manager = FileManager.default
    try manager.createDirectory(at: url, withIntermediateDirectories: true)
    claim = MachineStore.Claim.take(url)
    do {
      let manifest = MachineManifest(
        id: id, kind: .linux, title: request.title,
        cpuCount: request.cpuCount ?? min(ProcessInfo.processInfo.processorCount / 2, 8),
        memorySize: request.memorySize ?? (8 << 30), display: .init(width: 1920, height: 1200),
        macAddress: MachineManifest.randomMACAddress(),
        machineIdentifier: VZGenericMachineIdentifier().dataRepresentation.base64EncodedString(),
        username: request.username, password: password, created: Date(),
        gpu: request.gpu ? true : nil, rosetta: request.rosetta ? nil : false,
        server: packages.server ? true : nil)
      let machine = Machine(url: url, manifest: manifest)
      try machine.save()
      // Sparse: the disk costs what the guest writes, not what it is told it has.
      manager.createFile(atPath: machine.diskURL.path, contents: nil)
      let disk = try FileHandle(forWritingTo: machine.diskURL)
      try disk.truncate(atOffset: request.diskSize)
      try disk.close()
      _ = try VZEFIVariableStore(creatingVariableStoreAt: machine.auxiliaryURL)
      let grub = try Self.readFromISO(request.image, path: "efi/boot/grubaa64.efi")
      try Self.makeBootDisk(at: url.appendingPathComponent(Self.bootDiskName), grub: grub)
      try makeAnswers(for: machine, packages: packages)
      return machine
    } catch {
      try? manager.removeItem(at: url)
      claim = nil
      throw error
    }
  }

  /// The menu on hukan's boot disk: the ISO's kernel, found by a file only the ISO has, with the
  /// installer told to run unattended and its console written to the serial port.
  static let bootMenu = """
    set timeout=0
    search --no-floppy --file --set=iso /casper/vmlinuz
    menuentry "Install Ubuntu for hukan" {
      linux ($iso)/casper/vmlinuz autoinstall console=tty0 console=hvc0 systemd.journald.forward_to_console=1 ---
      initrd ($iso)/casper/initrd
    }

    """

  /// A FAT disk with the ISO's GRUB as the firmware's fallback loader, and the menu where that GRUB
  /// looks for one: beside itself, and at `/boot/grub` on a disk with `/.disk/info`, which is the
  /// search its built-in configuration makes.
  private static func makeBootDisk(at url: URL, grub: Data) throws {
    let manager = FileManager.default
    manager.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 64 << 20)
    try handle.close()
    let attached = String(
      decoding: try tool("/usr/sbin/diskutil", ["image", "attach", "--noMount", url.path]),
      as: UTF8.self)
    guard let device = attached.split(whereSeparator: \.isWhitespace).first.map(String.init),
      device.hasPrefix("/dev/disk")
    else { throw MachineError("The boot disk could not be attached: \(attached)") }
    defer { try? tool("/usr/sbin/diskutil", ["eject", device]) }
    try tool(
      "/sbin/newfs_msdos",
      [
        "-F", "32", "-v", "HUKANBOOT",
        device.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk"),
      ])
    let mount = manager.temporaryDirectory.appendingPathComponent("hukan-boot-\(UUID().uuidString)")
    try manager.createDirectory(at: mount, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: mount) }
    try tool("/usr/sbin/diskutil", ["mount", "-mountPoint", mount.path, device])
    defer { try? tool("/usr/sbin/diskutil", ["unmount", mount.path]) }
    for directory in ["EFI/BOOT", "boot/grub", ".disk"] {
      try manager.createDirectory(
        at: mount.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    try grub.write(to: mount.appendingPathComponent("EFI/BOOT/BOOTAA64.EFI"))
    for path in ["EFI/BOOT/grub.cfg", "boot/grub/grub.cfg"] {
      try bootMenu.write(to: mount.appendingPathComponent(path), atomically: false, encoding: .utf8)
    }
    try "hukan\n".write(
      to: mount.appendingPathComponent(".disk/info"), atomically: false, encoding: .utf8)
  }

  /// A file out of an ISO. Ubuntu's ISO carries a partition table beside its ISO 9660 filesystem,
  /// which the system's own attach will not mount, so the whole device is mounted as a CD.
  static func readFromISO(_ iso: URL, path: String) throws -> Data {
    let attached = String(
      decoding: try tool(
        "/usr/sbin/diskutil", ["image", "attach", "--noMount", "--readOnly", iso.path]),
      as: UTF8.self)
    guard let device = attached.split(whereSeparator: \.isWhitespace).first.map(String.init),
      device.hasPrefix("/dev/disk")
    else { throw MachineError("The ISO could not be attached: \(attached)") }
    defer { try? tool("/usr/sbin/diskutil", ["eject", device]) }
    let mount = FileManager.default.temporaryDirectory
      .appendingPathComponent("hukan-iso-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: mount) }
    try tool("/sbin/mount_cd9660", ["-r", device, mount.path])
    defer { try? tool("/sbin/umount", [mount.path]) }
    guard let found = Self.resolve(path, under: mount),
      let data = FileManager.default.contents(atPath: found.path)
    else {
      throw MachineError("\(iso.lastPathComponent) has no \(path); is it Ubuntu's desktop ISO?")
    }
    return data
  }

  /// `path` under `root`, each component matched without regard to case: the mounted ISO is
  /// case-sensitive, and the releases spell the same directory differently — 24.04.5 has
  /// `efi/boot`, 26.04.1 `EFI/boot`.
  static func resolve(_ path: String, under root: URL) -> URL? {
    var url = root
    for component in path.split(separator: "/").map(String.init) {
      let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
      guard
        let name = names.first(where: { $0 == component })
          ?? names.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame })
      else { return nil }
      url = url.appendingPathComponent(name)
    }
    return url
  }

  /// The disc the installer reads its answers from, by its label: the autoinstall, and the agent's
  /// binary for the install to put in place.
  func makeAnswers(for machine: Machine, packages: UbuntuPackages.Snapshot) throws {
    let manager = FileManager.default
    let directory = machine.url.appendingPathComponent("answers")
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    try "instance-id: hukan-\(machine.id.uuidString.lowercased())\n".write(
      to: directory.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)
    try userData(kernel: packages.kernel, server: packages.server).write(
      to: directory.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
    try Self.setupScript.write(
      to: directory.appendingPathComponent("hukan-setup"), atomically: true, encoding: .utf8)
    try Self.offlineScript.write(
      to: directory.appendingPathComponent("hukan-offline"), atomically: true, encoding: .utf8)
    let repository = directory.appendingPathComponent("repository")
    try manager.createDirectory(at: repository, withIntermediateDirectories: true)
    // ISO9660 mangles long names and embedded dots even when Joliet is also present.
    // Use short, portable names on the disc, including for snapshots made by older builds.
    let local = UbuntuPackages.stanzas(
      try String(contentsOf: packages.directory.appendingPathComponent("Packages"), encoding: .utf8)
    ).map(UbuntuPackages.Package.init)
    var installIndex = try String(
      contentsOf: packages.directory.appendingPathComponent("InstallPackages"), encoding: .utf8)
    try manager.createDirectory(
      at: repository.appendingPathComponent("pool"), withIntermediateDirectories: true)
    var renamed: [UbuntuPackages.Package] = []
    for (index, package) in local.enumerated() {
      let filename = "pool/p\(index).deb"
      try manager.copyItem(
        at: packages.directory.appendingPathComponent(package.filename),
        to: repository.appendingPathComponent(filename))
      installIndex = installIndex.replacingOccurrences(
        of: "Filename: repository/" + package.filename + "\n",
        with: "Filename: repository/" + filename + "\n")
      var fields = package.fields
      fields["Filename"] = filename
      renamed.append(.init(fields: fields))
    }
    try UbuntuPackages.indexText(renamed).write(
      to: repository.appendingPathComponent("packages"), atomically: true, encoding: .utf8)
    try installIndex.write(
      to: repository.appendingPathComponent("installpackages"), atomically: true, encoding: .utf8)
    try packages.codename.write(
      to: repository.appendingPathComponent("codename"), atomically: true, encoding: .utf8)
    guard let agent = GuestAgent.bundledBinary(for: .linux) else {
      throw MachineError("The Linux guest agent is missing from this build of hukan.")
    }
    try manager.copyItem(at: agent, to: directory.appendingPathComponent("hukan-guest-agent"))
    // Rosetta's MAP_32BIT, preloaded into x86_64 programs, and the empty arm64 library under the
    // same name that keeps arm64 ones from reporting it missing (Vendor/rosetta-low32).
    if request.rosetta {
      for arch in ["x86_64", "arm64"] {
        guard
          let library = Bundle.main.url(
            forResource: "hukan-rosetta-low32-\(arch)", withExtension: "so")
        else {
          throw MachineError("Rosetta's \(arch) library is missing from this build of hukan.")
        }
        try manager.copyItem(
          at: library, to: directory.appendingPathComponent("hukan-rosetta-low32-\(arch).so"))
      }
    }
    try Self.tool(
      "/usr/bin/hdiutil",
      [
        "makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata", "-o",
        machine.url.appendingPathComponent(Self.answersName).path, directory.path,
      ])
  }

  /// The autoinstall: the desktop or the server from the ISO onto the whole disk, unattended, then
  /// hukan's setup into what was installed, and the guest powered off. The account is not the
  /// installer's — it is made on the first boot from the `user-data` handed on, which is what lets
  /// it take this Mac's user id, so what it writes into the shared worktree is this Mac user's from
  /// either side. On a server nobody signs in, so the account lingers: its user manager starts at
  /// boot, and with it the agent's user half.
  // Internal so tests can read the answers without building a template.
  func userData(kernel: String = UbuntuPackages.kernelMeta, server: Bool = false) -> String {
    let user = request.username
    // Codecs are the desktop installer's; the server's is not asked about them.
    // Spelt out rather than as literals: these sit inside the YAML below, at its indentation.
    let codecs = server ? "" : "\n  codecs:\n    install: false"
    let linger = server ? "\n    runcmd:\n      - [loginctl, enable-linger, \(user)]" : ""
    return """
      #cloud-config
      autoinstall:
        version: 1
        interactive-sections: []
        source:
          id: \(server ? "ubuntu-server" : "ubuntu-desktop-minimal")
        storage:
          layout:
            name: direct
        locale: en_US.UTF-8
        timezone: \(TimeZone.current.identifier)
        refresh-installer:
          update: false
        kernel:
          package: \(kernel)
        network:
          version: 2
          ethernets:
            offline:
              match:
                name: "en*"
              dhcp4: false
              dhcp6: false
              link-local: []
        apt:
          geoip: false
          fallback: offline-install
          conf: |
            Acquire::Retries "5";
            Acquire::AllowInsecureRepositories "true";
            Acquire::AllowDowngradeToInsecureRepositories "true";
            APT::Get::AllowUnauthenticated "true";
        early-commands:
          - sh -exc 'exec >/dev/hvc0 2>&1; trap "echo hukan-early exit=\\$?" EXIT; blkid; cat /proc/self/mountinfo; mkdir -p /run/hukan; device=$(blkid -L cidata || blkid -L CIDATA); test -n "$device"; mount -o ro "$device" /run/hukan; sh /run/hukan/hukan-offline'\(codecs)
        drivers:
          install: false
        late-commands:
          - sh -exc 'exec >/dev/hvc0 2>&1; trap "echo hukan-late exit=\\$?" EXIT; sh /run/hukan/hukan-setup /target \(user) \(request.rosetta ? "rosetta" : "no-rosetta") \(server ? "server" : "desktop") && umount /run/hukan'
        user-data:
          hostname: hukan
          users:
            - name: \(user)
              gecos: \(user)
              uid: \(getuid())
              groups: [adm, sudo]
              sudo: ALL=(ALL) NOPASSWD:ALL
              shell: /bin/bash
              lock_passwd: false
              plain_text_passwd: \(password)\(linger)
        shutdown: poweroff

      """
  }

  /// A single merged mount survives Subiquity's non-recursive bind into its APT roots.
  /// Stage writable metadata in a dedicated tmpfs; ISO trees stay read-only and are not copied.
  static let offlineScript = #"""
    #!/bin/sh
    exec >/dev/hvc0 2>&1
    PS4='+ hukan-offline: '
    set -eux
    trap 'status=$?; echo "hukan-offline exit=$status"; if [ "$status" -ne 0 ]; then cat /proc/self/mountinfo; dmesg | tail -80; fi' EXIT
    blkid
    cat /proc/self/mountinfo
    command -v python3
    python3 -c 'import gzip, hashlib, pathlib'
    test -r /run/hukan/repository/installpackages
    test -d /cdrom/dists
    mkdir -p /run/hukan-cdrom/lower /run/hukan-cdrom/ram /run/hukan-cdrom/view
    mount --bind /cdrom /run/hukan-cdrom/lower
    mount -t tmpfs -o mode=755 tmpfs /run/hukan-cdrom/ram
    mkdir /run/hukan-cdrom/ram/upper /run/hukan-cdrom/ram/work
    cp -a /cdrom/dists /run/hukan-cdrom/ram/upper/
    chmod -R u+w /run/hukan-cdrom/ram/upper/dists
    # hdiutil's ISO9660 namespace appears lowercase in Linux (even with -joliet).
    # APT requires the case-sensitive Packages name, so normalize only the RAM copy.
    cp -a /run/hukan/repository /run/hukan-cdrom/ram/upper/
    mv /run/hukan-cdrom/ram/upper/repository/packages /run/hukan-cdrom/ram/upper/repository/Packages
    mount -t overlay overlay -o lowerdir=/run/hukan-cdrom/lower,upperdir=/run/hukan-cdrom/ram/upper,workdir=/run/hukan-cdrom/ram/work,index=off,xino=off,metacopy=off,redirect_dir=off /run/hukan-cdrom/view
    mount --bind /run/hukan-cdrom/view /cdrom
    python3 - <<'PY'
    import gzip, hashlib, pathlib
    repository = pathlib.Path('/cdrom/repository')
    for stanza in (repository / 'Packages').read_text().strip().split('\n\n'):
        fields = dict(line.split(': ', 1) for line in stanza.splitlines() if line and not line[0].isspace())
        package = repository / fields['Filename']
        if package.stat().st_size != int(fields['Size']) or hashlib.sha256(package.read_bytes()).hexdigest() != fields['SHA256']:
            raise RuntimeError('Offline package verification failed: ' + str(package))
    root = pathlib.Path('/cdrom/dists')
    code = pathlib.Path('/run/hukan/repository/codename').read_text().strip()
    if not code or not code.isascii() or not code.isalpha():
        raise ValueError('Invalid repository codename: ' + repr(code))
    suite = root / code
    if not suite.is_dir():
        raise RuntimeError('ISO suite missing: ' + str(suite))
    for name in ('InRelease', 'Release.gpg'):
        (suite / name).unlink(missing_ok=True)
    release = ['Origin: Ubuntu', 'Label: Ubuntu', 'Suite: ' + code,
               'Codename: ' + code, 'Architectures: arm64', 'Components: main restricted', 'SHA256:']
    for component in ('main', 'restricted'):
        directory = suite / component / 'binary-arm64'
        directory.mkdir(parents=True, exist_ok=True)
        data = pathlib.Path('/cdrom/repository/installpackages').read_bytes() if component == 'main' else b''
        for name, contents in [('Packages', data), ('Packages.gz', gzip.compress(data))]:
            (directory / name).write_bytes(contents)
            release.append(' %s %d %s/binary-arm64/%s' % (hashlib.sha256(contents).hexdigest(), len(contents), component, name))
    (suite / 'Release').write_text('\n'.join(release) + '\n')
    print('hukan-offline: repository ready:', suite, flush=True)
    PY
    """#

  /// What the install's late commands run, with the installed system at `$1`, the account's name in
  /// `$2`, `rosetta` or `no-rosetta` in `$3` and `desktop` or `server` in `$4`: the agent and its
  /// two services, the shares, Rosetta unless told not to, amd64 packages for apt to fetch, and —
  /// on a desktop — one that signs in by itself on X11 and never locks. Then the finishing script
  /// hukan runs at the end of the first boot.
  static let setupScript = #"""
    #!/bin/sh
    exec >/dev/hvc0 2>&1
    PS4='+ hukan-setup: '
    set -x
    trap 'echo "hukan-setup exit=$?"' EXIT
    T="$1"
    U="$2"
    install -D -m 755 /run/hukan/hukan-guest-agent "$T/usr/local/libexec/hukan-guest-agent"
    cat > "$T/etc/systemd/system/hukan-guest-agent-root.service" <<'EOF'
    [Unit]
    Description=hukan guest agent (root)
    [Service]
    ExecStart=/usr/local/libexec/hukan-guest-agent --root
    Restart=always
    RestartSec=2
    [Install]
    WantedBy=multi-user.target
    EOF
    # The user half lives in the signed-in desktop; a server has none, and its account lingers
    # instead (the user-data's runcmd), so the half starts with the user manager at boot.
    if [ "$4" = server ]; then
    cat > "$T/etc/systemd/user/hukan-guest-agent.service" <<'EOF'
    [Unit]
    Description=hukan guest agent (user)
    [Service]
    ExecStart=/usr/local/libexec/hukan-guest-agent --user
    Restart=always
    RestartSec=2
    [Install]
    WantedBy=default.target
    EOF
    else
    cat > "$T/etc/systemd/user/hukan-guest-agent.service" <<'EOF'
    [Unit]
    Description=hukan guest agent (user)
    PartOf=graphical-session.target
    After=graphical-session.target
    [Service]
    ExecStart=/usr/local/libexec/hukan-guest-agent --user
    Restart=always
    RestartSec=2
    [Install]
    WantedBy=graphical-session.target
    EOF
    fi
    chroot "$T" systemctl enable hukan-guest-agent-root.service
    chroot "$T" systemctl --global enable hukan-guest-agent.service
    # The worktree, a share the host may or may not give; Rosetta, unless the template was made
    # without it, which also leaves out the amd64 packages it is there to run.
    mkdir -p "$T/worktree"
    echo 'worktree /worktree virtiofs rw,nofail 0 0' >> "$T/etc/fstab"
    if [ "$3" != no-rosetta ]; then
    mkdir -p "$T/media/rosetta"
    echo 'rosetta /media/rosetta virtiofs ro,nofail 0 0' >> "$T/etc/fstab"
    printf '%s\n' ':rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/media/rosetta/rosetta:CF' > "$T/usr/lib/binfmt.d/rosetta.conf"
    mkdir -p "$T/etc/systemd/system/systemd-binfmt.service.d"
    printf '[Unit]\nAfter=media-rosetta.mount\n' > "$T/etc/systemd/system/systemd-binfmt.service.d/rosetta.conf"
    # Rosetta ignores MAP_32BIT, which Mono's JIT — Unity's editor — depends on: a library in every
    # x86_64 process puts those mappings below 2GB. `$LIB` is spelt per architecture by the loader,
    # so arm64 processes find the empty one under the same name and say nothing.
    install -D -m 644 /run/hukan/hukan-rosetta-low32-x86_64.so \
      "$T/usr/local/lib/x86_64-linux-gnu/libhukan-rosetta-low32.so"
    install -D -m 644 /run/hukan/hukan-rosetta-low32-arm64.so \
      "$T/usr/local/lib/aarch64-linux-gnu/libhukan-rosetta-low32.so"
    echo '/usr/local/$LIB/libhukan-rosetta-low32.so' >> "$T/etc/ld.so.preload"
    # amd64 packages, for what Rosetta runs: Ubuntu keeps arm64 on its ports mirror and amd64 on
    # the main one, so each source is told which architecture it serves. Nothing is fetched now.
    sed -i '/^Types:/a Architectures: arm64' "$T/etc/apt/sources.list.d/ubuntu.sources"
    . "$T/etc/os-release"
    cat > "$T/etc/apt/sources.list.d/amd64.sources" <<EOF
    Types: deb
    URIs: http://archive.ubuntu.com/ubuntu/
    Suites: $VERSION_CODENAME $VERSION_CODENAME-updates $VERSION_CODENAME-backports
    Components: main restricted universe multiverse
    Architectures: amd64

    Types: deb
    URIs: http://security.ubuntu.com/ubuntu/
    Suites: $VERSION_CODENAME-security
    Components: main restricted universe multiverse
    Architectures: amd64
    EOF
    chroot "$T" dpkg --add-architecture amd64
    fi
    # The host has authenticated this repository. Keep APT restricted to it even if a future
    # installer leaves online sources enabled. Failure here must abort template creation.
    mkdir -p "$T/cdrom/hukan"
    mount --bind /cdrom/repository "$T/cdrom/hukan"
    printf 'deb [trusted=yes] file:/cdrom/hukan ./\n' > "$T/etc/apt/sources.list.d/hukan.list"
    chroot "$T" apt-get -o Dir::Etc::sourcelist=sources.list.d/hukan.list -o Dir::Etc::sourceparts=- update || exit 1
    if [ "$4" != server ]; then
    chroot "$T" apt-get -o Dir::Etc::sourcelist=sources.list.d/hukan.list -o Dir::Etc::sourceparts=- -o Acquire::Retries=5 --no-install-recommends install -y ibus-mozc || exit 1
    fi
    umount "$T/cdrom/hukan"
    rm -f "$T/etc/apt/sources.list.d/hukan.list"
    rmdir "$T/cdrom/hukan" "$T/cdrom" 2>/dev/null || true
    # Curtin writes apt.conf as 94curtin-config. Remove the temporary trust relaxation and
    # leave retries for ordinary apt use after the template has been made.
    rm -f "$T/etc/apt/apt.conf.d/94curtin-config"
    printf 'Acquire::Retries "5";\n' > "$T/etc/apt/apt.conf.d/80hukan-retries"
    rm -f "$T"/var/lib/apt/lists/*cdrom* "$T"/var/lib/apt/lists/*hukan*
    # The installer is deliberately offline. Normal DHCP starts on the installed first boot, by
    # whichever renderer the system has: a server has networkd and no NetworkManager. The offline
    # stanza is also handed to cloud-init, which wrote it back on that first boot as
    # 50-cloud-init.yaml — a second en* match with no DHCP, and NetworkManager picked either one —
    # so cloud-init is kept off the network, and the file is gone again when the template is done.
    rm -f "$T"/etc/netplan/*.yaml
    mkdir -p "$T/etc/cloud/cloud.cfg.d"
    printf 'network: {config: disabled}\n' > "$T/etc/cloud/cloud.cfg.d/99-hukan-network.cfg"
    R=NetworkManager
    if [ "$4" = server ]; then R=networkd; fi
    cat > "$T/etc/netplan/50-hukan.yaml" <<EOF
    network:
      version: 2
      renderer: $R
      ethernets:
        ethernet:
          match:
            name: "en*"
          dhcp4: true
          dhcp6: true
    EOF
    chmod 600 "$T/etc/netplan/50-hukan.yaml"
    echo hukan > "$T/etc/hostname"
    # Everything from here to the finishing script is the desktop's: a server has no sign-in, no
    # screen to put on a GPU, and nothing to lock.
    if [ "$4" != server ]; then
    # Signed in by itself, on X11 where the release still has it: what the guest's screen tools
    # speak, and what Unity's editor is supported on.
    printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=%s\n' "$U" > "$T/etc/gdm3/custom.conf"
    if ls "$T"/usr/share/xsessions/*.desktop >/dev/null 2>&1; then
      echo 'WaylandEnable=false' >> "$T/etc/gdm3/custom.conf"
    fi
    # A machine with a GPU has two virtio screens: VZ's own, which carries the keyboard and the
    # pointer and which the guest leaves alone, and the GPU's, which draws. The GPU's is found at
    # each boot from the VIRGL bit in its virtio features (bit 0, the file's first character), so
    # whatever slot it lands in is found, and a machine without one writes nothing. Two desktops
    # are told: Xorg, pinned to it by PCI address — not by device path, since Xorg runs as the user
    # and gets the device from logind, which a path it opens itself would bypass, leaving it no DRM
    # master — and mutter on Wayland, the only session 26.04 has, by udev tags: the GPU's card its
    # primary, VZ's ignored.
    cat > "$T/usr/local/libexec/hukan-pin-gpu" <<'EOF'
    #!/bin/sh
    conf=/etc/X11/xorg.conf.d/10-hukan-gpu.conf
    rules=/run/udev/rules.d/61-hukan-gpu.rules
    rm -f "$conf" "$rules"
    gpu=
    others=
    for card in /sys/class/drm/card*; do
      case "$card" in *-*) continue ;; esac
      dev=$(readlink -f "$card/device")
      for v in "$dev"/virtio*; do
        [ -r "$v/features" ] || continue
        if [ "$(cut -c1 "$v/features")" = 1 ]; then gpu=$(basename "$dev"); else others="$others $(basename "$dev")"; fi
      done
    done
    [ -n "$gpu" ] || exit 0
    dom=$((0x$(echo "$gpu" | cut -d: -f1))); bus=$((0x$(echo "$gpu" | cut -d: -f2)))
    slot=$((0x$(echo "$gpu" | cut -d: -f3 | cut -d. -f1))); fn=$(echo "$gpu" | cut -d. -f2)
    mkdir -p /etc/X11/xorg.conf.d /run/udev/rules.d
    printf 'Section "ServerFlags"\n  Option "AutoAddGPU" "false"\nEndSection\nSection "Device"\n  Identifier "hukan-gpu"\n  Driver "modesetting"\n  BusID "PCI:%d@%d:%d:%d"\nEndSection\n' "$bus" "$dom" "$slot" "$fn" > "$conf"
    echo "SUBSYSTEM==\"drm\", KERNEL==\"card*\", KERNELS==\"$gpu\", TAG+=\"mutter-device-preferred-primary\"" > "$rules"
    for other in $others; do
      echo "SUBSYSTEM==\"drm\", KERNEL==\"card*\", KERNELS==\"$other\", TAG+=\"mutter-device-ignore\"" >> "$rules"
    done
    udevadm control --reload
    udevadm trigger --subsystem-match=drm --action=change
    udevadm settle
    EOF
    chmod 755 "$T/usr/local/libexec/hukan-pin-gpu"
    cat > "$T/etc/systemd/system/hukan-pin-gpu.service" <<'EOF'
    [Unit]
    Description=Put the desktop on hukan's GPU
    Wants=systemd-udev-settle.service
    After=systemd-udev-settle.service
    Before=display-manager.service
    [Service]
    Type=oneshot
    ExecStart=/usr/local/libexec/hukan-pin-gpu
    [Install]
    WantedBy=display-manager.service
    EOF
    chroot "$T" systemctl enable hukan-pin-gpu.service
    # The welcome a first sign-in shows is a window over whatever the agent is looking at; the
    # account is made from /etc/skel on the first boot, so it starts out having seen it.
    mkdir -p "$T/etc/skel/.config"
    echo yes > "$T/etc/skel/.config/gnome-initial-setup-done"
    # A machine an agent drives has nobody at it: nothing locks, blanks or sleeps.
    printf 'user-db:user\nsystem-db:local\n' > "$T/etc/dconf/profile/user"
    mkdir -p "$T/etc/dconf/db/local.d"
    cat > "$T/etc/dconf/db/local.d/00-hukan" <<'EOF'
    [org/gnome/desktop/screensaver]
    lock-enabled=false
    [org/gnome/desktop/session]
    idle-delay=uint32 0
    [org/gnome/settings-daemon/plugins/power]
    sleep-inactive-ac-type='nothing'
    EOF
    chroot "$T" dconf update
    fi
    cat > "$T/usr/local/libexec/hukan-finish-template" <<'EOF'
    #!/bin/sh
    exec >/dev/hvc0 2>&1
    PS4='+ hukan-finish: '
    set -ex
    trap 'echo "hukan-finish exit=$?"' EXIT
    # Run by hukan once both halves of the agent have said hello: cloud-init does not run again,
    # and each copy makes its own machine id on its first boot.
    touch /etc/cloud/cloud-init.disabled
    cloud-init clean --logs --machine-id
    rm -f /etc/netplan/50-cloud-init.yaml
    apt-get clean
    shutdown -h now
    EOF
    chmod 755 "$T/usr/local/libexec/hukan-finish-template"

    """#

  // MARK: The install

  private func install(_ machine: Machine) {
    stage = .installing
    onPhase?(.provisioning)
    boot(
      machine,
      installing: [Self.bootDiskName, request.image.path, Self.answersName].map {
        $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : machine.url.appendingPathComponent($0)
      })
  }

  private func boot(_ machine: Machine, installing: [URL]) {
    let runner = VirtualizationMachine(
      machine: machine, sharedDirectory: nil, installing: installing)
    running = runner
    runner.onStop = { [weak self] error in
      DispatchQueue.main.async { self?.stopped(machine, error: error) }
    }
    runner.onAgentHello = { [weak self] _ in self?.check() }
    runner.start { [weak self] error in
      guard let self else { return }
      self.screenView.virtualMachine = runner.vm
      if let error {
        self.running = nil
        self.fail(machine, VirtualizationMachine.explain(error))
      }
    }
    // The install is minutes and the first boot under a minute; an hour without either finishing
    // is a setup that has stopped somewhere, and the console says where.
    let deadline = Date().addingTimeInterval(60 * 60)
    let watched = stage
    func watch() {
      guard stage == watched, !gaveUp, running === runner else { return }
      if Date() > deadline {
        onPhase?(
          .setupFailed(
            "it did not finish — \(Self.consoleLogName) in the template's folder says how far it got"
          ))
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: watch)
    }
    watch()
  }

  /// Both halves up on the first boot is the setup done: the root half finishes the template.
  private func check() {
    guard stage == .firstBoot, let runner = running, let vm = runner.vm,
      runner.agentsHeard.isSuperset(of: ["user", "root"])
    else { return }
    stage = .finishing
    GuestAgent.exec(["/usr/local/libexec/hukan-finish-template"], on: vm, admin: true) { _ in }
  }

  private func stopped(_ machine: Machine, error: Error?) {
    guard !cancelled else { return }
    running = nil
    if let error {
      fail(machine, VirtualizationMachine.explain(error))
      return
    }
    if shutDownByHand || stage == .finishing {
      publish(machine)
      return
    }
    switch stage {
    case .installing:
      // The installer powered off: its discs come out and the installed system boots.
      for name in [Self.bootDiskName, Self.answersName] {
        try? FileManager.default.removeItem(at: machine.url.appendingPathComponent(name))
      }
      stage = .firstBoot
      onPhase?(.firstBoot)
      boot(machine, installing: [])
    case .firstBoot:
      fail(machine, "the installed system stopped before its agent came up")
    case .finishing:
      publish(machine)
    }
  }

  private func fail(_ machine: Machine, _ message: String) {
    gaveUp = true
    try? FileManager.default.removeItem(at: machine.url)
    claim = nil
    onPhase?(.failed(message))
  }

  private func publish(_ machine: Machine) {
    let manager = FileManager.default
    for name in [Self.bootDiskName, Self.answersName, Self.consoleLogName] {
      try? manager.removeItem(at: machine.url.appendingPathComponent(name))
    }
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

  /// Stop where it stands and leave nothing behind — the window's −. Ubuntu's installer, failing,
  /// does not power off but waits on its error screen, so a build has to be stoppable from outside
  /// at any point, not only once it has said it cannot finish.
  func cancel() {
    guard !cancelled else { return }
    cancelled = true
    gaveUp = true
    onPhase = nil
    // Still preparing: the preparation's own ending throws its machine away.
    guard let machineURL else { return }
    guard let running else {
      discard(machineURL)
      return
    }
    self.running = nil
    running.forceStop { [self] in discard(machineURL) }
  }

  private func discard(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    claim = nil
    MachineStore.changed()
  }

  /// Ask the guest to shut down, the way the power button would — the window's button, once
  /// setup has said it cannot finish by itself.
  func requestShutdown() {
    shutDownByHand = true
    try? running?.requestShutdown()
  }

  @discardableResult
  static func tool(_ path: String, _ arguments: [String]) throws -> Data {
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
}
