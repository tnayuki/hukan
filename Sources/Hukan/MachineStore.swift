import Foundation

/// Where hukan's virtual machines live, and what one is on disk.
///
/// hukan is the owner of these, which is the one place it holds master data of its own: nothing
/// else on the machine makes them, and every one is a directory under one root, so the store is
/// the directory listing and nothing more — there is no index to drift from what is on disk.
///
///     Machines/
///       Templates/<id>/   what a session's machine is copied from; backed up
///       Sessions/<id>/    a session's own copy; out of Time Machine
///       Images/           installers (IPSW, ISO) — fetched again if lost; out of Time Machine
///
/// A copy is an APFS clone of its template, so it costs nothing until it is written to, and the
/// Time Machine mark is on the `Sessions` and `Images` directories rather than on each item, so a
/// copy made into them is excluded by being there and a template saved out of one is not.
enum MachineStore {
  // Internal so tests can isolate all store operations from the real machines.
  static var rootOverride: URL?

  static var root: URL {
    if let rootOverride { return rootOverride }
    return
      FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/hukan/Machines")
  }
  static var templatesURL: URL { root.appendingPathComponent("Templates") }
  static var sessionsURL: URL { root.appendingPathComponent("Sessions") }
  static var imagesURL: URL { root.appendingPathComponent("Images") }

  /// Make the store's directories, and keep the two that hold nothing worth backing up out of Time
  /// Machine. Idempotent; the mark is sticky, so setting it again costs nothing.
  /// What a Windows guest needs from outside itself: not an image a template is made from, so not
  /// listed with them.
  static var driversURL: URL {
    imagesURL.deletingLastPathComponent().appendingPathComponent("Drivers")
  }

  static func prepare() {
    let fm = FileManager.default
    for url in [templatesURL, sessionsURL, imagesURL, driversURL] {
      try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    }
    for var url in [sessionsURL, imagesURL, driversURL] {
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? url.setResourceValues(values)
    }
  }

  /// A template half-made when hukan last stopped — quit, or killed, mid-install — is tens of
  /// gigabytes under a dot-name nothing lists. Its install cannot be resumed, so it goes; and the
  /// same for a download that never became whole. Run once at launch, before anything could be
  /// building. What goes is decided here, on the caller's thread, and only the removing is left
  /// for later: the whole of this on a background queue could run after a build had begun, and took
  /// that build's directory out from under a running install, twenty minutes before anyone found out.
  static func discardUnfinished() {
    let fm = FileManager.default
    let building =
      ((try? fm.contentsOfDirectory(at: templatesURL, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.lastPathComponent.hasPrefix(".building-") }
    let downloads =
      ((try? fm.contentsOfDirectory(at: imagesURL, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension == "download" }
    DispatchQueue.global(qos: .utility).async {
      for url in building + downloads { try? fm.removeItem(at: url) }
    }
  }

  static func templates() -> [Machine] { machines(in: templatesURL) }
  static func sessions() -> [Machine] { machines(in: sessionsURL) }

  static func session(id: UUID) -> Machine? {
    Machine(url: sessionsURL.appendingPathComponent(id.uuidString))
  }

  static func template(id: UUID) -> Machine? {
    Machine(url: templatesURL.appendingPathComponent(id.uuidString))
  }

  /// The installers in `Images`, newest first.
  static func images() -> [URL] {
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: imagesURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return urls.filter { ["ipsw", "iso"].contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }

  private static func machines(in directory: URL) -> [Machine] {
    let urls =
      (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
      ?? []
    // A template still being made lives under a dot-name until it is ready (`MacTemplateBuilder`),
    // so it is never offered to be copied half-installed.
    return urls.filter { !$0.lastPathComponent.hasPrefix(".") }
      .compactMap(Machine.init(url:)).sorted {
        $0.manifest.title.localizedStandardCompare($1.manifest.title) == .orderedAscending
      }
  }

  /// A session's own copy of `template`: an APFS clone of the whole directory, then given an
  /// identity of its own — a new id, and a new MAC address, since two copies on one NAT with the
  /// same one would take each other's leases.
  static func copy(_ template: Machine, for session: UUID? = nil) throws -> Machine {
    let id = UUID()
    let url = sessionsURL.appendingPathComponent(id.uuidString)
    // `copyItem` clones on APFS, block for block; the disk is shared with the template until
    // either side writes.
    try FileManager.default.copyItem(at: template.url, to: url)
    var manifest = template.manifest
    manifest.id = id
    manifest.parent = template.manifest.id
    manifest.session = session
    manifest.macAddress = MachineManifest.randomMACAddress()
    manifest.created = Date()
    // A template is shut down, never suspended, but a stale state file would be resumed into a
    // disk that has since moved on.
    try? FileManager.default.removeItem(at: url.appendingPathComponent(Machine.stateFileName))
    var machine = Machine(url: url, manifest: manifest)
    try machine.save()
    changed()
    return machine
  }

  /// A shut-down session machine made into a template of its own: a clone under a name nothing
  /// lists, given an identity, then moved into place, so a copy cut short never shows as a
  /// template. Its `parent` stays the template it was copied from, which is what files it under
  /// that one in the window; a template made from such a template nests one level further.
  static func saveAsTemplate(_ machine: Machine, title: String) throws -> Machine {
    let id = UUID()
    let building = templatesURL.appendingPathComponent(".building-\(id.uuidString)")
    try FileManager.default.copyItem(at: machine.url, to: building)
    var manifest = machine.manifest
    manifest.id = id
    manifest.title = title
    manifest.session = nil
    // A way the session's tab was showing it, which says nothing about the copies to come.
    manifest.fitsWindow = nil
    manifest.macAddress = MachineManifest.randomMACAddress()
    manifest.created = Date()
    try? FileManager.default.removeItem(
      at: building.appendingPathComponent(Machine.stateFileName))
    try? FileManager.default.removeItem(at: building.appendingPathComponent("qemu.log"))
    var copy = Machine(url: building, manifest: manifest)
    try copy.save()
    let url = templatesURL.appendingPathComponent(id.uuidString)
    try FileManager.default.moveItem(at: building, to: url)
    changed()
    return Machine(url: url, manifest: manifest)
  }

  /// Posted when a machine is made or deleted somewhere other than the Virtual Machines window — a
  /// tab copying a template, a tab closed — so the window lists what is on disk without having to
  /// be reopened.
  static let didChange = Notification.Name("MachineStoreDidChange")

  static func changed() {
    DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
  }

  static func delete(_ machine: Machine) throws {
    try FileManager.default.removeItem(at: machine.url)
    changed()
  }
}

enum MachineKind: String, Codable {
  case macOS
  case windows
}

/// What a machine is, written beside its disk as `machine.json`. hukan's own format: it is read
/// by nothing else, so it carries what a boot needs and what the window shows, and no more.
struct MachineManifest: Codable, Equatable {
  struct Display: Codable, Equatable {
    var width: Int
    var height: Int
  }

  var id: UUID
  var kind: MachineKind
  /// What the menu and the tab call it — "macOS 27", "macOS 27 + Xcode".
  var title: String
  var cpuCount: Int
  var memorySize: UInt64
  var display: Display
  var macAddress: String
  /// Whether the guest's resolution follows its tab (nil means yes). Off, the guest keeps
  /// `display` and the tab scales it — what an agent driving the screen by coordinates wants,
  /// since a tab dragged narrower would otherwise move every pixel under it.
  var fitsWindow: Bool?
  /// macOS: `VZMacHardwareModel.dataRepresentation`, base64.
  var hardwareModel: String?
  /// macOS: `VZMacMachineIdentifier.dataRepresentation`, base64.
  var machineIdentifier: String?
  /// The template this was copied from, if it was.
  var parent: UUID?
  /// The session a copy belongs to — whose desk its tab stands on. Written on the machine itself,
  /// so the tab can be found again from the disk when the window's saved state does not have it.
  var session: UUID?
  /// The guest account the template was made with. The password is hukan's own invention, kept
  /// here in the clear rather than in the keychain: it opens a guest reachable only from this
  /// Mac's NAT, so whoever can read this file can already reach the machine itself — and the file
  /// is the owner's alone (`save`). It is here for the prompts a GUI still puts up (System
  /// Settings, an installer), since SSH uses hukan's key and sudo asks for nothing.
  var username: String?
  var password: String?
  var created: Date
  /// Windows: the QEMU machine type it was made on, `virt-11.1` — never the bare `virt`, which is
  /// whatever the installed QEMU is newest at. A saved state only loads into the hardware it was
  /// saved from, and a versioned type is QEMU's promise that a later QEMU still builds that.
  var qemuMachine: String? = nil

  static func randomMACAddress() -> String {
    // Locally administered, unicast: the first octet's low bits are 10.
    var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
    bytes[0] = (bytes[0] & 0xFC) | 0x02
    return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
  }
}

/// One machine directory: its manifest and the files a boot reads beside it.
struct Machine: Equatable {
  static let manifestFileName = "machine.json"
  static let diskFileName = "disk.img"
  static let auxiliaryFileName = "aux.img"
  static let stateFileName = "state.vzvmsave"

  let url: URL
  var manifest: MachineManifest

  var id: UUID { manifest.id }
  var diskURL: URL { url.appendingPathComponent(Self.diskFileName) }
  var auxiliaryURL: URL { url.appendingPathComponent(Self.auxiliaryFileName) }
  var stateURL: URL { url.appendingPathComponent(Self.stateFileName) }

  init(url: URL, manifest: MachineManifest) {
    self.url = url
    self.manifest = manifest
  }

  init?(url: URL) {
    guard let data = try? Data(contentsOf: url.appendingPathComponent(Self.manifestFileName)),
      let manifest = try? Self.decoder.decode(MachineManifest.self, from: data)
    else { return nil }
    self.url = url
    self.manifest = manifest
  }

  func save() throws {
    let data = try Self.encoder.encode(manifest)
    let file = url.appendingPathComponent(Self.manifestFileName)
    try data.write(to: file, options: .atomic)
    // It carries the guest's password, so it is the owner's alone.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  /// How big the guest is told its disk is. The file is sparse, so this is a ceiling, not a cost.
  var diskSize: Int64 {
    Int64(
      (try? FileManager.default.attributesOfItem(atPath: diskURL.path)[.size] as? NSNumber)?
        .int64Value ?? 0)
  }

  /// What the directory occupies on this Mac — the blocks written, sparse holes not counted, but
  /// blocks it shares with a clone counted in full, since they are its as much as the clone's.
  var allocatedSize: Int64 {
    files.reduce(Int64(0)) { sum, file in
      let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
      return sum + Int64(values?.totalFileAllocatedSize ?? 0)
    }
  }

  /// What only this machine holds: the blocks no clone shares with it, which is what deleting it
  /// gives back. APFS answers it per file (`ATTR_CMNEXT_PRIVATESIZE`), so it costs a call per
  /// file and no walk of the disk image's blocks. Nil where the volume does not say.
  var privateSize: Int64? {
    var total: Int64 = 0
    for file in files {
      guard let size = Self.privateSize(of: file.path) else { return nil }
      total += size
    }
    return total
  }

  private var files: [URL] {
    (try? FileManager.default.contentsOfDirectory(
      at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
  }

  private static func privateSize(of path: String) -> Int64? {
    var list = attrlist()
    list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
    list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
    // The reply: its length, the attributes returned, then the size.
    var buffer = [UInt8](repeating: 0, count: 64)
    let result = getattrlist(
      path, &list, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED))
    guard result == 0 else { return nil }
    let returned = buffer.withUnsafeBytes {
      $0.load(fromByteOffset: MemoryLayout<UInt32>.size, as: attribute_set_t.self)
    }
    guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
    return buffer.withUnsafeBytes {
      $0.loadUnaligned(
        fromByteOffset: MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size,
        as: Int64.self)
    }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
