import Foundation

/// One language of the Windows 11 image Microsoft publishes for ARM64 — not an ISO but an ESD, the
/// compressed form the Media Creation Tool fetches and builds its media from. The catalog that
/// lists them is read once, by `Vendor/update-windows-catalog.sh`, and only what it says about the
/// ARM64 consumer image is kept in `WindowsCatalog`: an ISO's own address is issued per visit by a
/// web page, so there is nothing stable to fetch one from, and an ESD is.
///
/// An ESD does not boot. The ISO is put back together here, the way the Media Creation Tool does
/// it on Windows: Setup's files, WinPE and Setup in `boot.wim`, the editions in `install.esd`.
struct WindowsImage: Equatable {
  /// `ja-jp`, as the catalog spells it.
  let language: String
  /// `Japanese (Japan)`.
  let languageName: String
  let size: Int64
  let sha256: String
  /// Plain http, which is all Microsoft serves these from; the catalog's checksum is what the
  /// download is held to, and the catalog was taken only with Microsoft's signature on it.
  let address: String

  var url: URL { URL(string: address)! }

  /// The build in the name, so two releases in Images are told apart before either is opened.
  var isoName: String { "Windows11_\(WindowsCatalog.build)_\(language)_arm64.iso" }

  /// The image in the first of this Mac's languages the catalog has, else US English.
  static var preferred: WindowsImage {
    let images = WindowsCatalog.images
    for identifier in Locale.preferredLanguages {
      let code = identifier.lowercased()
      if let exact = images.first(where: { $0.language == code }) { return exact }
      let base = code.split(separator: "-").first.map(String.init) ?? code
      if let near = images.first(where: { $0.language.hasPrefix(base + "-") }) { return near }
    }
    return images.first { $0.language == "en-us" } ?? images[0]
  }

  static let wimlib = "/opt/homebrew/bin/wimlib-imagex"

  /// The ISO built from `esd` at `iso`, with `work` for the tree it is made from. The first image
  /// is Setup's files; the second WinPE and the third Setup, which goes into `boot.wim` marked as
  /// the one to boot or Setup does not start; the rest are the editions. Copied as they are, still
  /// solidly compressed: DISM applies an `install.esd` as it does an `install.wim`, and it is over
  /// 4GB, so the ISO carries UDF beside its ISO9660.
  static func makeISO(from esd: URL, at iso: URL, in work: URL, cancellation: Progress) throws {
    let tree = work.appendingPathComponent("tree")
    try? FileManager.default.removeItem(at: tree)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    let sources = tree.appendingPathComponent("sources")
    let count = try imageCount(of: esd)
    guard count >= 4 else { throw MachineError("The ESD holds no Windows edition.") }
    var steps: [[String]] = [
      ["apply", esd.path, "1", tree.path],
      ["export", esd.path, "2", sources.appendingPathComponent("boot.wim").path, "--compress=LZX"],
      [
        "export", esd.path, "3", sources.appendingPathComponent("boot.wim").path, "--compress=LZX",
        "--boot",
      ],
    ]
    for index in 4...count {
      steps.append([
        "export", esd.path, String(index), sources.appendingPathComponent("install.esd").path,
        "--compress=LZMS", "--solid",
      ])
    }
    for step in steps {
      guard !cancellation.isCancelled else { throw MachineError("Cancelled") }
      try run(wimlib, step)
    }
    // Left by the apply, and on no ISO Microsoft makes.
    try? FileManager.default.removeItem(at: tree.appendingPathComponent("__chunk_data"))
    guard !cancellation.isCancelled else { throw MachineError("Cancelled") }
    // The boot image that does not wait for a key: nobody is there to press one. Every restart
    // after WinPE's would boot it again, which is why the template builder takes the ISO out at
    // the first one.
    let boot = tree.appendingPathComponent("efi/microsoft/boot/efisys_noprompt.bin")
    try? FileManager.default.removeItem(at: iso)
    try run(
      "/usr/bin/hdiutil",
      [
        "makehybrid", "-o", iso.path, tree.path, "-iso", "-joliet", "-udf", "-udf-version", "1.02",
        "-eltorito-boot", boot.path, "-no-emul-boot", "-eltorito-platform", "0xEF",
        "-default-volume-name", "CCCOMA_A64FRE",
      ])
    let bootSize = try FileManager.default.attributesOfItem(atPath: boot.path)[.size] as? Int ?? 0
    try setBootImageSectors(in: iso, to: bootSize / 512)
    try? FileManager.default.removeItem(at: tree)
  }

  /// `hdiutil` writes the boot entry's sector count as 4 — 2KB of a boot image over a megabyte —
  /// and the firmware reads no further: it finds an empty FAT and drops to its shell. Microsoft's
  /// ISOs give the image's whole size there, in 512-byte sectors, and so does this.
  static func setBootImageSectors(in iso: URL, to sectors: Int) throws {
    let handle = try FileHandle(forUpdating: iso)
    defer { try? handle.close() }
    try handle.seek(toOffset: 17 * 2048)
    let record = try handle.read(upToCount: 2048) ?? Data()
    guard record.count == 2048, record[0] == 0, record.subdata(in: 1..<6) == Data("CD001".utf8),
      String(decoding: record.subdata(in: 7..<30), as: UTF8.self) == "EL TORITO SPECIFICATION"
    else { throw MachineError("The ISO has no El Torito boot record.") }
    let catalog = record.subdata(in: 0x47..<0x4B).reversed().reduce(UInt64(0)) {
      $0 << 8 | UInt64($1)
    }
    // The default entry follows the 32-byte validation entry; its count is at byte 6.
    try handle.seek(toOffset: catalog * 2048 + 32 + 6)
    let count = UInt16(clamping: sectors)
    try handle.write(contentsOf: Data([UInt8(count & 0xFF), UInt8(count >> 8)]))
  }

  private static func imageCount(of esd: URL) throws -> Int {
    let info = String(decoding: try run(wimlib, ["info", esd.path, "--header"]), as: UTF8.self)
    guard
      let line = info.split(separator: "\n").first(where: { $0.hasPrefix("Image Count") }),
      let count = line.split(whereSeparator: { $0 == "=" || $0 == ":" }).last.flatMap({
        Int($0.trimmingCharacters(in: .whitespaces))
      })
    else { throw MachineError("wimlib could not read the ESD.") }
    return count
  }

  @discardableResult
  private static func run(_ path: String, _ arguments: [String]) throws -> Data {
    guard FileManager.default.isExecutableFile(atPath: path) else {
      throw MachineError("\((path as NSString).lastPathComponent) is not installed.")
    }
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
          + String(decoding: data.suffix(400), as: UTF8.self))
    }
    return data
  }
}
