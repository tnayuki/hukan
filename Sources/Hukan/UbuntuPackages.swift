import CryptoKit
import Foundation
import Security

/// The only archive used for template prerequisites. A completed, authenticated snapshot is kept
/// beside virtio-win in Machines/Drivers; installation itself reads only the two attached ISOs.
enum UbuntuPackages {
  struct Package: Equatable {
    let fields: [String: String]
    var name: String { fields["Package"] ?? "" }
    var version: String { fields["Version"] ?? "" }
    var filename: String { fields["Filename"] ?? "" }
    var sha256: String { fields["SHA256"] ?? "" }
    var dependencies: String {
      [fields["Pre-Depends"], fields["Depends"]].compactMap { $0 }.joined(separator: ", ")
    }
  }

  static func stanzas(_ text: String) -> [[String: String]] {
    text.components(separatedBy: "\n\n").compactMap { stanza in
      var fields: [String: String] = [:]
      var key = ""
      for line in stanza.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.first == " " || line.first == "\t" {
          fields[key, default: ""] += "\n" + line
        } else if let colon = line.firstIndex(of: ":") {
          key = String(line[..<colon])
          fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
      }
      return fields.isEmpty ? nil : fields
    }
  }

  static func manifest(_ text: String) -> [String: String] {
    var installed: [String: String] = [:]
    for line in text.split(separator: "\n") {
      let parts = line.split(whereSeparator: \.isWhitespace)
      if parts.count == 2, !parts[0].hasPrefix("---"), !parts[0].hasPrefix("+++") {
        let raw = parts[0].hasPrefix("+") ? parts[0].dropFirst() : parts[0][...]
        let name = String(raw.split(separator: ":")[0])
        if !name.hasPrefix("-") { installed[name] = String(parts[1]) }
      }
    }
    return installed
  }

  /// Debian's epoch/upstream/revision ordering, including tilde and numeric runs (not SemVer).
  static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
    func parts(_ version: String) -> (Int, String, String) {
      let epoch = version.split(separator: ":", maxSplits: 1)
      let rest = epoch.count == 2 ? String(epoch[1]) : version
      if let dash = rest.lastIndex(of: "-") {
        return (
          epoch.count == 2 ? Int(epoch[0]) ?? 0 : 0, String(rest[..<dash]),
          String(rest[rest.index(after: dash)...])
        )
      }
      return (epoch.count == 2 ? Int(epoch[0]) ?? 0 : 0, rest, "0")
    }
    func order(_ c: UInt8?) -> Int {
      guard let c else { return 0 }
      if c == 126 { return -1 }
      if (65...90).contains(c) || (97...122).contains(c) { return Int(c) }
      return Int(c) + 256
    }
    func revision(_ a: String, _ b: String) -> Int {
      let a = Array(a.utf8)
      let b = Array(b.utf8)
      var i = 0
      var j = 0
      func digit(_ c: UInt8) -> Bool { (48...57).contains(c) }
      while i < a.count || j < b.count {
        while (i < a.count && !digit(a[i])) || (j < b.count && !digit(b[j])) {
          let x = order(i < a.count && !digit(a[i]) ? a[i] : nil)
          let y = order(j < b.count && !digit(b[j]) ? b[j] : nil)
          if x != y { return x < y ? -1 : 1 }
          if i < a.count && !digit(a[i]) { i += 1 }
          if j < b.count && !digit(b[j]) { j += 1 }
        }
        while i < a.count && a[i] == 48 { i += 1 }
        while j < b.count && b[j] == 48 { j += 1 }
        let ai = i
        let bj = j
        while i < a.count && digit(a[i]) { i += 1 }
        while j < b.count && digit(b[j]) { j += 1 }
        if i - ai != j - bj { return i - ai < j - bj ? -1 : 1 }
        let x = Array(a[ai..<i])
        let y = Array(b[bj..<j])
        if x != y { return x.lexicographicallyPrecedes(y) ? -1 : 1 }
      }
      return 0
    }
    let a = parts(lhs)
    let b = parts(rhs)
    let result = a.0 != b.0 ? (a.0 < b.0 ? -1 : 1) : revision(a.1, b.1)
    let final = result == 0 ? revision(a.2, b.2) : result
    return final == 0 ? .orderedSame : final < 0 ? .orderedAscending : .orderedDescending
  }

  struct Requirement {
    let name: String
    let relation: String?
    let version: String?

    init(_ text: String) throws {
      let parts = text.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace)
      guard let first = parts.first else { throw MachineError("Empty Ubuntu dependency.") }
      name = String(first.split(separator: ":", omittingEmptySubsequences: false)[0])
      guard !name.isEmpty,
        name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) })
      else {
        throw MachineError("Unsupported Ubuntu dependency: \(text)")
      }
      if parts.count == 1 {
        relation = nil
        version = nil
      } else {
        guard parts.count == 3, parts[1].hasPrefix("("), parts[2].hasSuffix(")") else {
          throw MachineError("Unsupported Ubuntu dependency: \(text)")
        }
        relation = String(parts[1].dropFirst())
        version = String(parts[2].dropLast())
        guard ["=", ">=", "<=", ">>", "<<"].contains(relation!) else {
          throw MachineError("Unsupported Ubuntu version relation: \(text)")
        }
      }
    }

    func accepts(_ candidate: String) -> Bool {
      guard let version, let relation else { return true }
      let result = compareVersions(candidate, version)
      switch relation {
      case "=": return result == .orderedSame
      case ">=": return result != .orderedAscending
      case "<=": return result != .orderedDescending
      case ">>": return result == .orderedDescending
      default: return result == .orderedAscending
      }
    }
  }

  /// Prefer the ISO's installed versions, then its pool, before archive candidates. Each newly
  /// selected package brings its complete Depends/Pre-Depends closure. Unsatisfied alternatives
  /// fail preparation rather than producing a partially populated disc.
  static func resolve(
    roots: [String], installed: [String: String], available: [Package]
  ) throws -> [Package] {
    let byName = Dictionary(grouping: available, by: \.name)
    var selected: [String: Package] = [:]
    func satisfy(_ expression: String) throws {
      let alternatives = try expression.split(separator: "|").map { try Requirement(String($0)) }
      for requirement in alternatives {
        if let p = selected[requirement.name], requirement.accepts(p.version) { return }
        if selected[requirement.name] == nil,
          let version = installed[requirement.name], requirement.accepts(version)
        {
          return
        }
        // Virtual dependencies are satisfied by installed or selected providers too.
        for p in available where installed[p.name] == p.version || selected[p.name] == p {
          for provided in (p.fields["Provides"] ?? "").split(separator: ",") {
            let r = try Requirement(String(provided))
            if r.name == requirement.name,
              requirement.version == nil || r.version.map(requirement.accepts) == true
            {
              return
            }
          }
        }
      }
      for requirement in alternatives {
        guard selected[requirement.name] == nil,
          let package = byName[requirement.name]?.first(where: { requirement.accepts($0.version) })
        else { continue }
        let saved = selected
        selected[package.name] = package
        do {
          for dependency in package.dependencies.split(separator: ",") {
            try satisfy(String(dependency))
          }
          return
        } catch { selected = saved }
      }
      throw MachineError("Cannot resolve Ubuntu dependency: \(expression)")
    }
    for root in roots { try satisfy(root) }
    return selected.values.sorted { $0.name < $1.name }
  }

  static func verify(_ data: Data, sha256: String, size: Int) throws {
    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard data.count == size, actual == sha256.lowercased() else {
      throw MachineError("Ubuntu package/index SHA256 or size mismatch.")
    }
  }

  struct Snapshot {
    let directory: URL
    let codename: String
    let kernel: String
  }

  private static let archive = URL(string: "https://ports.ubuntu.com/ubuntu-ports/")!
  private static let lock = NSLock()

  /// Where what an ISO lacks is kept: by the ISO's content, so a copy of it under another name
  /// finds the same packages.
  static func snapshot(identity: String) -> URL {
    MachineStore.driversURL.appendingPathComponent("ubuntu-\(identity)-v1")
  }

  /// The packages kept for `iso`, if any. Reads the whole ISO, so not on the main thread.
  static func snapshot(for iso: URL) -> URL? {
    RestoreImageDownload.sha256(of: iso).map { snapshot(identity: $0) }
  }

  static func prepare(
    iso: URL, cancellation: Progress = Progress(totalUnitCount: 1),
    progress: (String) -> Void = { _ in }, download: ((URL) throws -> Data)? = nil
  ) throws -> Snapshot {
    try checkCancellation(cancellation)
    let download = download ?? { try fetch($0, cancellation: cancellation) }
    lock.lock()
    defer { lock.unlock() }
    try checkCancellation(cancellation)
    progress("Reading Ubuntu ISO…")
    let release = String(
      decoding: try isoFile(iso, "dists/" + codename(iso) + "/Release"), as: UTF8.self)
    guard let code = stanzas(release).first?["Codename"],
      code.allSatisfy({ $0.isASCII && $0.isLetter })
    else {
      throw MachineError("The Ubuntu ISO has no release codename.")
    }
    let manifestData =
      try (try? isoFile(iso, "casper/minimal.manifest.full"))
      ?? (try isoFile(iso, "casper/minimal.manifest"))
    let baseline = manifest(String(decoding: manifestData, as: UTF8.self))
    let kernel = baseline.keys.filter {
      $0.hasPrefix("linux-image-") && $0.hasSuffix("-generic")
        && $0.dropFirst("linux-image-".count).first?.isNumber == true
    }.sorted().first
    let kernelPackage = kernel ?? "linux-generic-hwe-\(series(release))"
    // Hash the actual ISO, not its filename: a rebuilt point release must never share a snapshot.
    guard let identity = RestoreImageDownload.sha256(of: iso) else {
      throw MachineError("The Ubuntu ISO could not be hashed.")
    }
    let destination = snapshot(identity: identity)
    if FileManager.default.fileExists(atPath: destination.path) {
      try validateSnapshot(destination, iso: iso, codename: code)
      return Snapshot(directory: destination, codename: code, kernel: kernelPackage)
    }
    let manager = FileManager.default
    let partial = MachineStore.driversURL.appendingPathComponent(
      ".ubuntu-\(UUID().uuidString).download")
    try manager.createDirectory(at: partial, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: partial) }
    var pool: [Package] = []
    for component in ["main", "restricted"] {
      if let data = try? isoFile(iso, "dists/\(code)/\(component)/binary-arm64/Packages.gz") {
        pool += stanzas(String(decoding: try gunzip(data, in: partial), as: UTF8.self)).map(
          Package.init)
      }
    }
    var remote: [Package] = []
    let evidence = partial.appendingPathComponent("evidence")
    try manager.createDirectory(at: evidence, withIntermediateDirectories: true)
    progress("Checking Ubuntu archive…")
    for suite in [code, "\(code)-updates", "\(code)-security"] {
      let releaseData = try download(archive.appendingPathComponent("dists/\(suite)/Release"))
      let signature = try download(archive.appendingPathComponent("dists/\(suite)/Release.gpg"))
      try UbuntuArchiveSignature.verify(release: releaseData, signature: signature)
      let fields = stanzas(String(decoding: releaseData, as: UTF8.self)).first ?? [:]
      guard fields["Codename"] == code, fields["Suite"] == suite else {
        throw MachineError("Ubuntu archive release does not match \(suite).")
      }
      if let expiry = fields["Valid-Until"] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: expiry), date > Date() else {
          throw MachineError("Ubuntu archive release has expired.")
        }
      }
      try releaseData.write(to: evidence.appendingPathComponent("\(suite).Release"))
      try signature.write(to: evidence.appendingPathComponent("\(suite).Release.gpg"))
      for component in ["main", "universe"] {
        let path = "\(component)/binary-arm64/Packages.gz"
        let index = try download(archive.appendingPathComponent("dists/\(suite)/\(path)"))
        try verifyIndex(index, path: path, release: fields)
        try index.write(to: evidence.appendingPathComponent("\(suite)-\(component).gz"))
        remote += stanzas(String(decoding: try gunzip(index, in: partial), as: UTF8.self)).map(
          Package.init)
      }
    }
    remote.sort {
      $0.name == $1.name
        ? compareVersions($0.version, $1.version) == .orderedDescending : $0.name < $1.name
    }
    let chosen = try resolve(
      roots: (kernel == nil ? [kernelPackage] : []) + ["ibus-mozc"], installed: baseline,
      available: pool + remote)
    var local: [Package] = []
    for package in chosen {
      try checkCancellation(cancellation)
      progress("Preparing Ubuntu packages… \(local.count + 1)/\(chosen.count)")
      let data: Data
      if pool.contains(package) {
        data = try isoFile(iso, package.filename)
      } else {
        guard safePath(package.filename), package.filename.hasPrefix("pool/") else {
          throw MachineError("Unsafe Ubuntu package filename.")
        }
        data = try download(archive.appendingPathComponent(package.filename))
      }
      try verify(data, sha256: package.sha256, size: Int(package.fields["Size"] ?? "") ?? -1)
      let filename = "pool/\(package.name)_\(local.count).deb"
      try manager.createDirectory(
        at: partial.appendingPathComponent("pool"), withIntermediateDirectories: true)
      try data.write(to: partial.appendingPathComponent(filename))
      var fields = package.fields
      fields["Filename"] = filename
      local.append(Package(fields: fields))
    }
    try indexText(local).write(
      to: partial.appendingPathComponent("Packages"), atomically: true, encoding: .utf8)
    // Include the ISO pool too, so the installer's offline cdrom source sees both sets.
    try installIndex(pool: pool, local: local).write(
      to: partial.appendingPathComponent("InstallPackages"), atomically: true, encoding: .utf8)
    try checkCancellation(cancellation)
    try manager.moveItem(at: partial, to: destination)
    return Snapshot(directory: destination, codename: code, kernel: kernelPackage)
  }

  static func installIndex(pool: [Package], local: [Package]) -> String {
    let combined =
      pool.filter { original in !local.contains(where: { $0.name == original.name }) }
      + local.map { package in
        var fields = package.fields
        fields["Filename"] = "repository/" + package.filename
        return Package(fields: fields)
      }
    return indexText(combined)
  }

  private static func authenticatedIdentity(_ package: Package) -> String {
    var fields = package.fields
    fields.removeValue(forKey: "Filename")
    return SHA256.hash(data: Data(indexText([Package(fields: fields)]).utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  static func safePath(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/")
      && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
      }
  }

  static func indexText(_ packages: [Package]) -> String {
    packages.map { package in
      package.fields.keys.sorted().map { "\($0): \(package.fields[$0]!)" }.joined(separator: "\n")
    }.joined(separator: "\n\n") + "\n\n"
  }

  static func verifyIndex(_ data: Data, path: String, release: [String: String]) throws {
    let lines = (release["SHA256"] ?? "").split(separator: "\n")
    for line in lines {
      let parts = line.split(whereSeparator: \.isWhitespace)
      if parts.count == 3, parts[2] == path, let size = Int(parts[1]) {
        try verify(data, sha256: String(parts[0]), size: size)
        return
      }
    }
    throw MachineError("Ubuntu Release does not authenticate \(path).")
  }

  private static func validateSnapshot(_ directory: URL, iso: URL, codename: String) throws {
    var authenticated: Set<String> = []
    var pool: [Package] = []
    func remember(_ text: String) {
      for fields in stanzas(text) {
        authenticated.insert(authenticatedIdentity(Package(fields: fields)))
      }
    }
    for component in ["main", "restricted"] {
      if let data = try? isoFile(iso, "dists/\(codename)/\(component)/binary-arm64/Packages.gz") {
        let text = String(
          decoding: try gunzip(data, in: FileManager.default.temporaryDirectory), as: UTF8.self)
        pool += stanzas(text).map(Package.init)
        remember(text)
      }
    }
    let evidence = directory.appendingPathComponent("evidence")
    for suite in [codename, "\(codename)-updates", "\(codename)-security"] {
      let release = try Data(contentsOf: evidence.appendingPathComponent("\(suite).Release"))
      try UbuntuArchiveSignature.verify(
        release: release,
        signature: Data(contentsOf: evidence.appendingPathComponent("\(suite).Release.gpg")))
      let fields = stanzas(String(decoding: release, as: UTF8.self)).first ?? [:]
      guard fields["Codename"] == codename, fields["Suite"] == suite else {
        throw MachineError("Cached Ubuntu archive release does not match its suite.")
      }
      for component in ["main", "universe"] {
        let index = try Data(
          contentsOf: evidence.appendingPathComponent("\(suite)-\(component).gz"))
        try verifyIndex(index, path: "\(component)/binary-arm64/Packages.gz", release: fields)
        remember(
          String(
            decoding: try gunzip(index, in: FileManager.default.temporaryDirectory), as: UTF8.self))
      }
    }
    let packages = stanzas(
      try String(contentsOf: directory.appendingPathComponent("Packages"), encoding: .utf8)
    ).map(Package.init)
    guard !packages.isEmpty else {
      throw MachineError("Empty Ubuntu package cache; remove \(directory.path) and retry.")
    }
    for package in packages {
      guard safePath(package.filename),
        authenticated.contains(authenticatedIdentity(package))
      else {
        throw MachineError("The cached Ubuntu package metadata has changed: \(directory.path)")
      }
      try verify(
        Data(contentsOf: directory.appendingPathComponent(package.filename)),
        sha256: package.sha256, size: Int(package.fields["Size"] ?? "") ?? -1)
    }
    guard
      try String(contentsOf: directory.appendingPathComponent("InstallPackages"), encoding: .utf8)
        == installIndex(pool: pool, local: packages)
    else {
      throw MachineError("The cached Ubuntu install index has changed: \(directory.path)")
    }
  }

  private static func codename(_ iso: URL) throws -> String {
    let listing = String(
      decoding: try LinuxTemplateBuilder.tool("/usr/bin/tar", ["-tf", iso.path]), as: UTF8.self)
    guard
      let path = listing.split(separator: "\n").first(where: {
        $0.hasPrefix("dists/") && $0.hasSuffix("/Release")
      })
    else {
      throw MachineError("The Ubuntu ISO has no APT Release.")
    }
    return String(path.split(separator: "/")[1])
  }

  private static func series(_ release: String) -> String {
    stanzas(release).first?["Version"].map { UbuntuRelease.series(of: $0) } ?? ""
  }

  static func isoFile(_ iso: URL, _ path: String) throws -> Data {
    try LinuxTemplateBuilder.tool("/usr/bin/tar", ["-xOf", iso.path, path])
  }

  private static func gunzip(_ data: Data, in directory: URL) throws -> Data {
    let url = directory.appendingPathComponent("index-\(UUID().uuidString).gz")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try LinuxTemplateBuilder.tool("/usr/bin/gzip", ["-dc", url.path])
  }

  static func checkCancellation(_ cancellation: Progress) throws {
    if cancellation.isCancelled { throw CancellationError() }
  }

  private static func fetch(_ url: URL, cancellation: Progress) throws -> Data {
    try checkCancellation(cancellation)
    let done = DispatchSemaphore(value: 0)
    var outcome: Result<Data, Error> = .failure(
      MachineError("Ubuntu archive did not answer: \(url)"))
    let task = URLSession.shared.dataTask(with: url) { data, response, error in
      if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
        outcome = .success(data)
      } else if let error {
        outcome = .failure(error)
      }
      done.signal()
    }
    task.delegate = SecureRedirects()
    task.resume()
    while done.wait(timeout: .now() + 0.1) == .timedOut {
      if cancellation.isCancelled {
        task.cancel()
        done.wait()
        throw CancellationError()
      }
    }
    try checkCancellation(cancellation)
    return try outcome.get()
  }
}

/// A deliberately narrow OpenPGP verifier: Ubuntu's pinned 2018 archive RSA key, v4 detached
/// binary signatures, SHA256/SHA512. Security.framework does RSA; no downloaded executable,
/// Homebrew GnuPG, keyserver or system trust store is involved. Unknown formats fail closed.
enum UbuntuArchiveSignature {
  // F6ECB3762474EDA9D21B7022871920D1991BC93C, from Ubuntu's project/ubuntu-archive-keyring.gpg.
  private static let keyDER =
    "MIICCgKCAgEA7/xscrcfy3El2LjNDMCqI2wcnvNbNBtZxMfpc+lQFKSFGZ25KnVwRwvncKxkvwnni7gIz0S1PAKMRP4472VafMRRhFh2HZJalxmf4CXz+Xd3yFAbWR2RCZfAfJvaTB3/wEEHbAvmM4s0hubeTIZ6LcNOOC17XRBJMdreic9Dhq4fuSKMal+6WYqugr9fQaIWlIqCjHaexEukWHze6Jeh0ixZazF7VX4f4o6TfY92YVRlXkQvJCh0LCeT5CG5r8QYlIe0iZn2VMdCEITTGgx133WQBjbZ4c8zUXm9RajS0lZK0vz57AEMzIRtQQ5tlTkheuI3myl33xajOS10UE3qky7I1G266kerPxgjvFBe431I+iO7Wi8oJrBzvyQ+I6SkQtIG6VAX2oici77nqcd5FqKi97DdC4ZTCPNPnwOxk76DseLaalZc5ROk2o2Lvo31t0KThUuXsBDHS9uoc8bGYP4Hmb02wK3D/jrCSkZob+JDaOgMnch0P92Vf391/Zk9/0jy2yWrppIKd2M3ereT3gbvmUJP5jeVjTbmooTRFe5ZW9WYb2NBcbvQVXfwTZdK87sad6yIpwdk19kgoO8BOcV5MF7kP9nkwxNL9B5Rp7ZLmYxqMA2ZMR2UEsWVTs3WQkVWl/1hBS6SmtgEKcOUSa0OKGfzn4n18icz9u6NN8ECAwEAAQ=="

  static func verify(release: Data, signature: Data) throws {
    let error = MachineError("Ubuntu archive Release signature is invalid or unsupported.")
    var bytes = Array(signature)
    if let armored = String(data: signature, encoding: .utf8),
      armored.contains("-----BEGIN PGP SIGNATURE-----")
    {
      let lines = armored.components(separatedBy: "\n")
      guard let start = lines.firstIndex(of: "") else { throw error }
      let body = lines.dropFirst(start + 1).prefix { !$0.hasPrefix("=") && !$0.hasPrefix("-----") }
        .joined()
      guard let decoded = Data(base64Encoded: body) else { throw error }
      bytes = Array(decoded)
    }
    var offset = 0
    while offset < bytes.count {
      let header = bytes[offset]
      offset += 1
      guard header & 128 != 0, offset < bytes.count else { throw error }
      let tag: Int
      let length: Int
      if header & 64 != 0 {
        tag = Int(header & 63)
        let first = Int(bytes[offset])
        offset += 1
        if first < 192 {
          length = first
        } else if first < 224 {
          guard offset < bytes.count else { throw error }
          length = (first - 192) * 256 + Int(bytes[offset]) + 192
          offset += 1
        } else if first == 255 {
          guard offset + 4 <= bytes.count else { throw error }
          length = bytes[offset..<offset + 4].reduce(0) { $0 * 256 + Int($1) }
          offset += 4
        } else {
          throw error
        }
      } else {
        tag = Int((header >> 2) & 15)
        let count = 1 << Int(header & 3)
        guard count <= 4, offset + count <= bytes.count else { throw error }
        length = bytes[offset..<offset + count].reduce(0) { $0 * 256 + Int($1) }
        offset += count
      }
      guard length <= bytes.count - offset else { throw error }
      let packet = Array(bytes[offset..<offset + length])
      offset += length
      guard tag == 2 else { continue }
      if try verifyPacket(packet, release: release) { return }
    }
    throw error
  }

  private static func verifyPacket(_ p: [UInt8], release: Data) throws -> Bool {
    guard p.count >= 10, p[0] == 4, p[1] == 0, p[2] == 1, [8, 10].contains(p[3]) else {
      return false
    }
    let hashedEnd = 6 + Int(p[4]) * 256 + Int(p[5])
    guard hashedEnd + 2 <= p.count else { return false }
    let unhashed = Int(p[hashedEnd]) * 256 + Int(p[hashedEnd + 1])
    let mpi = hashedEnd + 2 + unhashed + 2
    guard mpi + 2 <= p.count else { return false }
    let size = (Int(p[mpi]) * 256 + Int(p[mpi + 1]) + 7) / 8
    guard size <= 512, mpi + 2 + size == p.count else { return false }
    var message = release
    message.append(contentsOf: p[..<hashedEnd])
    message.append(contentsOf: [
      4, 255, UInt8((hashedEnd >> 24) & 255), UInt8((hashedEnd >> 16) & 255),
      UInt8((hashedEnd >> 8) & 255), UInt8(hashedEnd & 255),
    ])
    guard let der = Data(base64Encoded: keyDER),
      let key = SecKeyCreateWithData(
        der as CFData,
        [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
          as CFDictionary, nil)
    else { return false }
    let sig = Data(repeating: 0, count: 512 - size) + Data(p[(mpi + 2)...])
    return SecKeyVerifySignature(
      key, p[3] == 8 ? .rsaSignatureMessagePKCS1v15SHA256 : .rsaSignatureMessagePKCS1v15SHA512,
      message as CFData, sig as CFData, nil)
  }
}
