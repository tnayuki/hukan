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
  ///
  /// "When hukan last stopped" is a fact about every hukan, not this one: the released app and a
  /// Dev build share this store, so one launched while the other was twenty minutes into an
  /// install took that install's directory too. What a running hukan is still making carries a
  /// claim, and a claim still held is passed over — the lock goes with the process that took it,
  /// so one left by a quit or a crash is no claim at all.
  static func discardUnfinished() {
    let fm = FileManager.default
    let building =
      ((try? fm.contentsOfDirectory(at: templatesURL, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.lastPathComponent.hasPrefix(".building-") }
    let downloads =
      ((try? fm.contentsOfDirectory(at: imagesURL, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension == "download" && !$0.lastPathComponent.hasPrefix(Claim.prefix) }
    let unclaimed = (building + downloads).compactMap { Claim.takeAbandoned($0) }
    let leftover = [templatesURL, imagesURL].flatMap { directory in
      ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasPrefix(Claim.prefix) }
    }
    .filter { claim in
      !(building + downloads).contains { Claim.file(for: $0) == claim }
    }
    .compactMap { Claim.abandonedClaim(file: $0) }
    DispatchQueue.global(qos: .utility).async {
      for (url, claim) in unclaimed {
        try? fm.removeItem(at: url)
        claim.release()
      }
      for claim in leftover { claim.release() }
    }
  }

  /// A lock on something this process is still making under an unfinished name, held in a file
  /// beside it — `.claim-<name>` — for as long as it is being made. `flock` is the whole of it:
  /// the kernel drops the lock when the process ends, however it ends.
  final class Claim {
    static let prefix = ".claim-"
    private var descriptor: Int32
    private let file: URL

    static func file(for url: URL) -> URL {
      url.deletingLastPathComponent().appendingPathComponent(prefix + url.lastPathComponent)
    }

    private init(descriptor: Int32, file: URL) {
      self.descriptor = descriptor
      self.file = file
    }

    /// Claims `url` for this process; nil only when the claim file cannot be made, which leaves
    /// the work unprotected rather than refused.
    static func take(_ url: URL) -> Claim? {
      lock(file(for: url), blocking: true)
    }

    /// The claim on `url` when no running process holds it, which is what makes `url` safe to
    /// remove; nil while another hukan is still making it.
    static func takeAbandoned(_ url: URL) -> (URL, Claim)? {
      lock(file(for: url), blocking: false).map { (url, $0) }
    }

    static func abandonedClaim(file claimFile: URL) -> Claim? {
      lock(claimFile, blocking: false)
    }

    private static func lock(_ file: URL, blocking: Bool) -> Claim? {
      let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
      guard fd >= 0 else { return nil }
      guard flock(fd, LOCK_EX | (blocking ? 0 : LOCK_NB)) == 0 else {
        close(fd)
        return nil
      }
      return Claim(descriptor: fd, file: file)
    }

    /// Done with: the file goes first, so no one can take a claim on a name about to be free.
    func release() {
      guard descriptor >= 0 else { return }
      unlink(file.path)
      close(descriptor)
      descriptor = -1
    }

    deinit { release() }
  }

  static func templates() -> [Machine] { machines(in: templatesURL) }
  static func sessions() -> [Machine] { machines(in: sessionsURL) }
  /// The copies made for one session — what deleting that session takes with it.
  static func sessions(of session: UUID) -> [Machine] {
    sessions().filter { $0.manifest.session == session }
  }

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
    return urls.filter { MachineKind(image: $0) != nil }
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
    manifest.ancestors = [template.manifest.id] + template.manifest.lineage
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
    let claim = Claim.take(building)
    defer { claim?.release() }
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
    // Whichever way a machine is deleted — its tab, its session, the window — a QEMU still on its
    // disk is stopped first: one a hukan that died left behind belongs to no tab that could.
    if machine.manifest.kind == .windows { QEMUMachine.stopLeftover(in: machine.url) }
    try FileManager.default.removeItem(at: machine.url)
    changed()
  }
}

enum MachineKind: String, Codable {
  case macOS
  case windows
  /// Run by Virtualization.framework in this process, like macOS, with Rosetta to run x86_64.
  case linux

  /// What a template made from `image` is: an IPSW is macOS, Ubuntu's desktop ISO Linux, and any
  /// other ISO Windows. Anything else is not an image a template is made from.
  init?(image: URL) {
    switch image.pathExtension.lowercased() {
    case "ipsw": self = .macOS
    case "iso": self = UbuntuRelease.isUbuntu(image) ? .linux : .windows
    default: return nil
    }
  }
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
  /// macOS: `VZMacMachineIdentifier.dataRepresentation`; Linux: `VZGenericMachineIdentifier`'s.
  /// Base64. A saved state restores only into the machine it was saved from, and this is part of
  /// what says which.
  var machineIdentifier: String?
  /// The template this was copied from, if it was.
  var parent: UUID?
  /// Every template behind it, nearest first, written when it is copied. A template can be
  /// deleted from under its copies, and its own manifest — the one place that named what it came
  /// from in turn — goes with it; a copy that knew only its parent would then read as sharing
  /// nothing with a template two steps back that still holds most of its disk. Absent on a
  /// machine made before this was recorded, which knows its parent alone.
  var ancestors: [UUID]?

  /// The templates behind this one, nearest first.
  var lineage: [UUID] { ancestors ?? parent.map { [$0] } ?? [] }
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
  /// Linux: whether the machine is set up for Rosetta (nil means yes — every template before this
  /// was). Chosen when the template is made, since the guest's binfmt and amd64 packages are set
  /// up then; without it the Rosetta share is not given either.
  var rosetta: Bool? = nil

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
    files.values.reduce(Int64(0)) { $0 + Self.allocatedSize(of: $1) }
  }

  /// What this machine holds that `parent` does not: file by file, the bytes that are not on the
  /// very blocks the parent's file has at the same place. A clone starts at nothing and grows as
  /// it is written, and the answer is the same whatever else has been cloned from either since —
  /// which APFS's own count of a file's private blocks is not, that one falling to nothing the
  /// moment a second clone is taken. It walks both files' extents, so it is not for the main
  /// thread: a disk a guest has worked in for a while is tens of thousands of them.
  func size(beyond parent: Machine) -> Int64 {
    let theirs = parent.files
    return files.reduce(Int64(0)) { sum, file in
      let own =
        theirs[file.key].flatMap { Self.bytes(of: file.value, notSharedWith: $0) }
        // A file the parent has not got, or a volume that will not say where a file's blocks are.
        ?? Self.allocatedSize(of: file.value)
      return sum + own
    }
  }

  /// Every file under the directory, by its path within it.
  private var files: [String: URL] {
    let base = url.resolvingSymlinksInPath().path + "/"
    let walk = FileManager.default.enumerator(
      at: url, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey])
    var files: [String: URL] = [:]
    while let file = walk?.nextObject() as? URL {
      guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
      else { continue }
      let path = file.resolvingSymlinksInPath().path
      files[path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path] = file
    }
    return files
  }

  private static func allocatedSize(of file: URL) -> Int64 {
    let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
    return Int64(values?.totalFileAllocatedSize ?? 0)
  }

  /// The bytes of `file` that sit somewhere other than where `other` has the same offset. Nil
  /// where the volume does not answer for a file's blocks.
  private static func bytes(of file: URL, notSharedWith other: URL) -> Int64? {
    let mine = open(file.path, O_RDONLY)
    let theirs = open(other.path, O_RDONLY)
    defer {
      if mine >= 0 { close(mine) }
      if theirs >= 0 { close(theirs) }
    }
    guard mine >= 0, theirs >= 0 else { return nil }
    /// Where on the device `offset` is, and how far the file runs on from there unbroken.
    func extent(_ descriptor: Int32, at offset: off_t, upTo length: off_t) -> (
      device: off_t, length: off_t
    )? {
      var query = log2phys()
      query.l2p_devoffset = offset
      query.l2p_contigbytes = length
      guard fcntl(descriptor, F_LOG2PHYS_EXT, &query) == 0, query.l2p_contigbytes > 0 else {
        return nil
      }
      return (query.l2p_devoffset, query.l2p_contigbytes)
    }
    let end = lseek(mine, 0, SEEK_END)
    let theirEnd = lseek(theirs, 0, SEEK_END)
    var offset: off_t = 0
    var own: Int64 = 0
    while offset < end {
      // Holes hold nothing, on either side's account.
      let data = lseek(mine, offset, SEEK_DATA)
      guard data >= 0 else { break }
      let hole = max(lseek(mine, data, SEEK_HOLE), data)
      offset = data
      while offset < hole {
        guard let here = extent(mine, at: offset, upTo: hole - offset) else { return nil }
        guard offset < theirEnd,
          let there = extent(theirs, at: offset, upTo: min(here.length, theirEnd - offset))
        else {
          own += here.length
          offset += here.length
          continue
        }
        let length = min(here.length, there.length)
        if here.device != there.device { own += length }
        offset += length
      }
      if hole == data { break }
    }
    return own
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
