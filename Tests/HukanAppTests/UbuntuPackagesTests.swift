import XCTest

@testable import Hukan

final class UbuntuPackagesTests: XCTestCase {
  private func package(
    _ name: String, _ version: String = "1", depends: String = "", provides: String = ""
  ) -> UbuntuPackages.Package {
    .init(fields: ["Package": name, "Version": version, "Depends": depends, "Provides": provides])
  }

  func testCancelledImageDownloadIgnoresRestart() {
    let download = RestoreImageDownload(.file(URL(fileURLWithPath: "/missing.iso")))
    download.cancel()
    var changes = 0
    download.onChange = { changes += 1 }
    download.start()
    XCTAssertEqual(download.state, .failed("Cancelled"))
    XCTAssertEqual(changes, 0)
  }

  func testCancelledPreparationDoesNotReadISOOrFetch() {
    let cancellation = Progress(totalUnitCount: 1)
    cancellation.cancel()
    XCTAssertThrowsError(
      try UbuntuPackages.prepare(
        iso: URL(fileURLWithPath: "/missing.iso"), cancellation: cancellation,
        download: { _ in
          XCTFail("A cancelled preparation must not fetch")
          return Data()
        })
    ) { error in
      XCTAssertTrue(error is CancellationError)
    }
  }

  func testDebianVersions() {
    for (a, b) in [
      ("1~rc1", "1"), ("1.9", "1.10"), ("1.01-1", "1.1-2"), ("9", "1:1"), ("1+a", "1.1"),
      ("1-1", "1-1ubuntu1"),
    ] {
      XCTAssertEqual(UbuntuPackages.compareVersions(a, b), .orderedAscending, "\(a), \(b)")
      XCTAssertEqual(UbuntuPackages.compareVersions(b, a), .orderedDescending)
    }
    XCTAssertEqual(UbuntuPackages.compareVersions("1.01", "0:1.1-0"), .orderedSame)
  }

  func testManifestAcceptsFullAndDiffAndNormalizesArchitecture() {
    XCTAssertEqual(
      UbuntuPackages.manifest(
        "libc6:arm64\t2.43\n+linux-image-7.0.0-30-generic\t7.0.0-30.30\n--- old\n+++ new\n-removed\t1\n"
      ), ["libc6": "2.43", "linux-image-7.0.0-30-generic": "7.0.0-30.30"])
  }

  func testALayersManifestIsADiffAgainstTheOneBelow() {
    // The server ISO's `ubuntu-server` layer, over `ubuntu-server-minimal`.
    let minimal = UbuntuPackages.manifest(
      "--- /build/a\n+++ /build/b\n+adduser\t3.137\n+less\t590\n+netplan.io\t1.1.2\n")
    let server = UbuntuPackages.manifest(
      "--- /build/b\n+++ /build/c\n+apt-utils\t2.8.3\n-less\t590\n", over: minimal)
    XCTAssertEqual(server, ["adduser": "3.137", "netplan.io": "1.1.2", "apt-utils": "2.8.3"])
  }

  func testDependencyClosureKeepsISOVersionsAndResolvesAlternativesAndCycles() throws {
    let available = [
      package("kernel", depends: "image (= 7), libc6 (>= 2)"),
      package("image", "8"), package("image", "7", depends: "modules (= 7)"),
      package("modules", "7", depends: "image (= 7)"),
      package("ibus-mozc", depends: "missing | mozc-server, libc6 (>= 2)"),
      package("mozc-server"), package("libc6", "3"),
    ]
    let chosen = try UbuntuPackages.resolve(
      roots: ["kernel", "ibus-mozc"], installed: ["libc6": "2"], available: available)
    XCTAssertEqual(chosen.map(\.name), ["ibus-mozc", "image", "kernel", "modules", "mozc-server"])
    XCTAssertEqual(chosen.first(where: { $0.name == "image" })?.version, "7")
  }

  func testHWESelectionDropsHardwareMetaDependencies() throws {
    let available = [
      package("linux-generic-hwe-24.04", depends: "linux-image-generic-hwe-24.04 (= 7), headers"),
      package(
        "linux-image-generic-hwe-24.04", "7",
        depends: "linux-image-7.0.0-43-generic (= 7), firmware, zfs"),
      package("linux-image-7.0.0-43-generic", "7", depends: "linux-modules-7.0.0-43-generic (= 7)"),
      package("linux-modules-7.0.0-43-generic", "7", depends: "zfs"), package("zfs"),
      // Headers and firmware need not even be resolvable to select an image.
      package("ibus-mozc"),
    ]
    let image = try UbuntuPackages.kernelImage(
      meta: "linux-generic-hwe-24.04", available: available)
    XCTAssertEqual(image, "linux-image-7.0.0-43-generic")
    XCTAssertEqual(
      try UbuntuPackages.resolve(roots: [image, "ibus-mozc"], installed: [:], available: available)
        .map(\.name),
      ["ibus-mozc", "linux-image-7.0.0-43-generic", "linux-modules-7.0.0-43-generic", "zfs"])
  }

  func testKernelAlreadyInstalledNeedsNoArchiveKernel() throws {
    let chosen = try UbuntuPackages.resolve(
      roots: ["linux-image-7.0.0-30-generic", "ibus-mozc"],
      installed: ["linux-image-7.0.0-30-generic": "7"],
      available: [
        package("ibus-mozc", depends: "mozc-server, mozc-data"),
        package("mozc-server"), package("mozc-data"),
      ])
    XCTAssertEqual(chosen.map(\.name), ["ibus-mozc", "mozc-data", "mozc-server"])
  }

  func testCacheOnlyPreparationNeverDownloads() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let suite = source.appendingPathComponent("dists/noble")
    try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("casper"), withIntermediateDirectories: true)
    try "Codename: noble\nVersion: 24.04\n".write(
      to: suite.appendingPathComponent("Release"), atomically: true, encoding: .utf8)
    try "libc6 2\n".write(
      to: source.appendingPathComponent("casper/minimal.manifest"), atomically: true,
      encoding: .utf8)
    let iso = root.appendingPathComponent("fixture.iso")
    _ = try LinuxTemplateBuilder.tool(
      "/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-o", iso.path, source.path])
    XCTAssertThrowsError(
      try UbuntuPackages.prepare(
        iso: iso,
        download: { _ in
          XCTFail("Template preparation must never contact the archive")
          return Data()
        }, cachedOnly: true))
    XCTAssertThrowsError(try UbuntuPackages.cached(iso: iso)) { error in
      XCTAssertTrue(error.localizedDescription.contains(UbuntuPackages.missingPackagesMessage))
    }
  }

  func testAnISOsPackagesAreFoundByTheChecksumKeptOnIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    MachineStore.rootOverride = root.appendingPathComponent("Machines")
    defer { MachineStore.rootOverride = nil }
    MachineStore.prepare()
    // Not an ISO at all: nothing here may read it.
    let iso = root.appendingPathComponent("ubuntu-24.04.5-live-server-arm64.iso")
    try Data("not an iso".utf8).write(to: iso)
    // An ISO this hukan neither downloaded nor added is not ready, and is not hashed to find out.
    XCTAssertNil(UbuntuPackages.snapshot(for: iso))
    XCTAssertFalse(UbuntuPackages.isReady(iso: iso))
    XCTAssertThrowsError(try UbuntuPackages.cached(iso: iso)) { error in
      XCTAssertTrue(error.localizedDescription.contains(UbuntuPackages.missingPackagesMessage))
    }
    let identity = String(repeating: "ab", count: 32)
    _ = try LinuxTemplateBuilder.tool(
      "/usr/bin/xattr", ["-w", "dev.tnayuki.hukan.sha256", identity, iso.path])
    XCTAssertEqual(UbuntuPackages.identity(of: iso), identity)
    XCTAssertEqual(UbuntuPackages.snapshot(for: iso), UbuntuPackages.snapshot(identity: identity))
    // The checksum alone is not enough: the packages it names have to be there.
    XCTAssertFalse(UbuntuPackages.isReady(iso: iso))
    try FileManager.default.createDirectory(
      at: UbuntuPackages.snapshot(identity: identity), withIntermediateDirectories: true)
    XCTAssertTrue(UbuntuPackages.isReady(iso: iso))
  }

  func testUnresolvableVersionFailsInsteadOfKeepingPartialClosure() {
    XCTAssertThrowsError(try UbuntuPackages.Requirement(":"))
    XCTAssertThrowsError(try UbuntuPackages.Requirement("libc6 (~ 2)"))
    XCTAssertThrowsError(
      try UbuntuPackages.resolve(
        roots: ["root"], installed: [:],
        available: [package("root", depends: "image (= 7), image (>= 8)"), package("image", "7")]))
  }

  func testInstalledVirtualProviderAndPreDepends() throws {
    var root = package("root", depends: "virtual-api (>= 2)").fields
    root["Pre-Depends"] = "bootstrap"
    let chosen = try UbuntuPackages.resolve(
      roots: ["root"], installed: ["provider": "1"],
      available: [
        .init(fields: root), package("provider", provides: "virtual-api (= 2)"),
        package("bootstrap"),
      ])
    XCTAssertEqual(chosen.map(\.name), ["bootstrap", "root"])
  }

  func testHashAndReleaseIndexVerificationRejectTampering() throws {
    let data = Data("abc".utf8)
    let hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    try UbuntuPackages.verify(data, sha256: hash, size: 3)
    XCTAssertThrowsError(try UbuntuPackages.verify(data, sha256: hash, size: 4))
    XCTAssertThrowsError(try UbuntuPackages.verify(Data("abd".utf8), sha256: hash, size: 3))
    let release = ["SHA256": "\n \(hash) 3 main/binary-arm64/Packages.gz"]
    try UbuntuPackages.verifyIndex(data, path: "main/binary-arm64/Packages.gz", release: release)
    XCTAssertThrowsError(
      try UbuntuPackages.verifyIndex(
        data, path: "universe/binary-arm64/Packages.gz", release: release))
  }

  func testRealUbuntuSignatureAndTamperedRelease() throws {
    // Official noble Release/Release.gpg from ports.ubuntu.com, retrieved 2026-11-16.
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/UbuntuArchive")
    let release = try LinuxTemplateBuilder.tool(
      "/usr/bin/gzip", ["-dc", fixture.appendingPathComponent("Release.gz").path])
    let signature = try Data(contentsOf: fixture.appendingPathComponent("Release.gpg"))
    try UbuntuArchiveSignature.verify(release: release, signature: signature)
    XCTAssertThrowsError(
      try UbuntuArchiveSignature.verify(
        release: release + Data("tamper".utf8), signature: signature))
    XCTAssertThrowsError(
      try UbuntuArchiveSignature.verify(release: release, signature: signature.prefix(20)))
    XCTAssertThrowsError(
      try UbuntuArchiveSignature.verify(release: release, signature: Data([0xff, 0xff])))
  }

  func testRepositoryIndexRoundTripsMultilineAndRejectsUnsafePaths() throws {
    let p = UbuntuPackages.Package(fields: [
      "Package": "mozc", "Version": "1", "Filename": "pool/mozc.deb",
      "Description": "input\n Japanese",
    ])
    XCTAssertEqual(
      UbuntuPackages.stanzas(UbuntuPackages.indexText([p])).map(UbuntuPackages.Package.init), [p])
    for path in ["/tmp/x", "../x", "pool/../../x", "pool//x", ""] {
      XCTAssertFalse(UbuntuPackages.safePath(path))
    }
    XCTAssertTrue(UbuntuPackages.safePath("pool/main/m/mozc.deb"))
  }
}
