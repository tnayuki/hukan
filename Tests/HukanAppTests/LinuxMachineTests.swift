import XCTest

@testable import Hukan

final class LinuxMachineTests: XCTestCase {
  func testUbuntusISOIsLinuxAndEveryOtherISOWindows() {
    let ubuntu = URL(fileURLWithPath: "/x/ubuntu-24.04.5-desktop-arm64.iso")
    XCTAssertEqual(MachineKind(image: ubuntu), .linux)
    XCTAssertEqual(MachineKind(image: URL(fileURLWithPath: "/x/Win11_24H2.iso")), .windows)
    XCTAssertEqual(MachineKind(image: URL(fileURLWithPath: "/x/a.ipsw")), .macOS)
    XCTAssertNil(MachineKind(image: URL(fileURLWithPath: "/x/a.img")))
    XCTAssertEqual(VirtualMachinesWindowController.imageTitle(ubuntu), "Ubuntu 24.04.5")
  }

  func testSupportedSeriesAreReadFromMetaRelease() {
    let text = """
      Dist: jammy
      Name: Jammy Jellyfish
      Version: 22.04.5 LTS
      Supported: 1

      Dist: mantic
      Version: 23.10
      Supported: 0

      Dist: noble
      Version: 24.04.5 LTS
      Supported: 1
      """
    XCTAssertEqual(UbuntuRelease.supportedSeries(inMetaRelease: text), ["22.04", "24.04"])
  }

  func testNewestPointReleaseIsChosenByItsNumbers() throws {
    let text = """
      aa *ubuntu-24.04.4-desktop-arm64.iso
      bb *ubuntu-24.04.10-desktop-arm64.iso
      cc *ubuntu-24.04.9-desktop-arm64.iso
      dd *ubuntu-24.04.10-live-server-arm64.iso
      ee *ubuntu-24.04.11-desktop-amd64.iso
      """
    let release = try XCTUnwrap(UbuntuRelease.newest(inChecksums: text))
    XCTAssertEqual(release.version, "24.04.10")
    XCTAssertEqual(release.sha256, "bb")
    XCTAssertEqual(
      release.url.absoluteString,
      "https://cdimage.ubuntu.com/ubuntu/releases/24.04/release/ubuntu-24.04.10-desktop-arm64.iso")
    // A release with no desktop for arm64 offers nothing.
    XCTAssertNil(UbuntuRelease.newest(inChecksums: "ff *ubuntu-22.04.5-live-server-arm64.iso"))
    // Its server is read off the same list, and the large-memory build is not it.
    let server = try XCTUnwrap(
      UbuntuRelease.newest(
        inChecksums: text + "\ngg *ubuntu-24.04.10-live-server-arm64+largemem.iso",
        edition: .server))
    XCTAssertEqual(server.version, "24.04.10")
    XCTAssertEqual(server.sha256, "dd")
    XCTAssertEqual(server.title, "Ubuntu 24.04.10 LTS Server")
    XCTAssertEqual(release.title, "Ubuntu 24.04.10 LTS Desktop")
  }

  func testAServerISOIsLinuxAndSaysSo() {
    let server = URL(fileURLWithPath: "/x/ubuntu-24.04.5-live-server-arm64.iso")
    XCTAssertEqual(MachineKind(image: server), .linux)
    XCTAssertTrue(UbuntuRelease.isServer(server))
    XCTAssertFalse(
      UbuntuRelease.isServer(URL(fileURLWithPath: "/x/ubuntu-24.04.5-desktop-arm64.iso")))
    XCTAssertEqual(VirtualMachinesWindowController.imageTitle(server), "Ubuntu 24.04.5 Server")
  }

  func testAServerInstallsTheServerAndLingersForTheAgent() {
    let builder = LinuxTemplateBuilder(
      request: .init(
        title: "Ubuntu", image: URL(fileURLWithPath: "/x.iso"), diskSize: 1, cpuCount: nil,
        memorySize: nil, username: "someone"))
    let server = builder.userData(server: true)
    XCTAssertTrue(server.contains("    id: ubuntu-server\n"))
    XCTAssertFalse(server.contains("codecs:"))
    XCTAssertTrue(server.contains("  drivers:\n"))
    XCTAssertTrue(server.contains("rosetta server && umount"))
    XCTAssertTrue(server.contains("    runcmd:\n      - [loginctl, enable-linger, someone]\n"))
    XCTAssertTrue(server.contains("plain_text_passwd: \(builder.password)\n    runcmd:"))
    XCTAssertFalse(server.contains("\t"))
    let desktop = builder.userData()
    XCTAssertTrue(desktop.contains("  codecs:\n    install: false\n  drivers:\n"))
    XCTAssertTrue(desktop.contains("rosetta desktop && umount"))
    XCTAssertFalse(desktop.contains("runcmd"))
    XCTAssertTrue(desktop.contains("plain_text_passwd: \(builder.password)\n  shutdown: poweroff"))
    // The user half starts with the user manager on a server, with the session on a desktop.
    let script = LinuxTemplateBuilder.setupScript
    XCTAssertTrue(script.contains("WantedBy=default.target"))
    XCTAssertTrue(script.contains("WantedBy=graphical-session.target"))
    XCTAssertTrue(script.contains("if [ \"$4\" = server ]; then R=networkd; fi"))
    XCTAssertTrue(script.contains("renderer: $R"))
  }

  func testChecksumIsTheFilesSHA256() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("abc".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    XCTAssertEqual(
      RestoreImageDownload.sha256(of: file),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  func testLinuxCommandsRunInALoginBash() {
    XCTAssertEqual(
      WorktreeDeskViewController.guestCommand("make test", kind: .linux),
      ["/bin/bash", "-lc", "make test"])
  }

  func testAutoinstallRunsUnattendedAndHandsOnTheAccount() {
    let builder = LinuxTemplateBuilder(
      request: .init(
        title: "Ubuntu", image: URL(fileURLWithPath: "/x.iso"), diskSize: 1, cpuCount: nil,
        memorySize: nil, username: "someone"))
    let data = builder.userData()
    XCTAssertTrue(data.hasPrefix("#cloud-config\nautoinstall:\n"))
    XCTAssertTrue(data.contains("  interactive-sections: []\n"))
    XCTAssertTrue(data.contains("    id: ubuntu-desktop-minimal\n"))
    XCTAssertTrue(data.contains("  shutdown: poweroff\n"))
    XCTAssertTrue(data.contains("      - name: someone\n"))
    XCTAssertTrue(data.contains("        uid: \(getuid())\n"))
    XCTAssertTrue(data.contains("plain_text_passwd: \(builder.password)\n"))
    XCTAssertTrue(data.contains("hukan-setup /target someone"))
    // No tab in YAML, which would end a block.
    XCTAssertFalse(data.contains("\t"))
  }

  func testBootMenuStartsTheISOsKernelUnattended() {
    let menu = LinuxTemplateBuilder.bootMenu
    XCTAssertTrue(menu.contains("search --no-floppy --file --set=iso /casper/vmlinuz"))
    XCTAssertTrue(menu.contains("linux ($iso)/casper/vmlinuz autoinstall "))
    XCTAssertTrue(menu.contains("initrd ($iso)/casper/initrd"))
  }

  func testSetupPutsTheAgentRosettaAndTheSharesIn() {
    let script = LinuxTemplateBuilder.setupScript
    XCTAssertTrue(script.contains(#":rosetta:M::\x7fELF\x02\x01\x01"#))
    XCTAssertTrue(script.contains(":/media/rosetta/rosetta:CF"))
    XCTAssertTrue(script.contains("rosetta /media/rosetta virtiofs ro,nofail 0 0"))
    XCTAssertTrue(script.contains("worktree /worktree virtiofs rw,nofail 0 0"))
    XCTAssertTrue(script.contains("ExecStart=/usr/local/libexec/hukan-guest-agent --root"))
    XCTAssertTrue(script.contains("ExecStart=/usr/local/libexec/hukan-guest-agent --user"))
    // The heredocs end where the shell looks for them, at the start of a line.
    XCTAssertTrue(script.contains("\nEOF\n"))
  }

  private func primaryISOFilenames(_ iso: URL) throws -> [String] {
    let data = try Data(contentsOf: iso)
    func number(_ offset: Int) -> Int {
      (0..<4).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
    }
    func directory(_ record: Int, prefix: String) -> [String] {
      var names: [String] = []
      var offset = number(record + 2) * 2048
      let end = offset + number(record + 10)
      while offset < end {
        let length = Int(data[offset])
        if length == 0 {
          offset = (offset / 2048 + 1) * 2048
          continue
        }
        let nameLength = Int(data[offset + 32])
        let bytes = data[(offset + 33)..<(offset + 33 + nameLength)]
        if bytes.first != 0 && bytes.first != 1 {
          let name = prefix + String(decoding: bytes, as: UTF8.self)
          names.append(name)
          if data[offset + 25] & 2 != 0 {
            names += directory(offset, prefix: name + "/")
          }
        }
        offset += length
      }
      return names
    }
    return directory(16 * 2048 + 156, prefix: "")
  }

  func testOfflineAnswersDiscCarriesPackagesAndBothSetupStages() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = directory.appendingPathComponent("cache")
    try FileManager.default.createDirectory(
      at: repository.appendingPathComponent("pool"), withIntermediateDirectories: true)
    let deb = Data("verified package fixture".utf8)
    try deb.write(to: repository.appendingPathComponent("pool/linux-image-7.0.0-43-generic_24.deb"))
    for name in ["Packages", "InstallPackages"] {
      let prefix = name == "InstallPackages" ? "repository/" : ""
      try "Package: ibus-mozc\nFilename: \(prefix)pool/linux-image-7.0.0-43-generic_24.deb\n\n"
        .write(
          to: repository.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let builder = LinuxTemplateBuilder(
      request: .init(
        title: "fixture", image: directory.appendingPathComponent("unused.iso"), diskSize: 1,
        username: "guest"))
    let machine = Machine(
      url: directory,
      manifest: .init(
        id: UUID(), kind: .linux, title: "fixture", cpuCount: 2, memorySize: 1 << 30,
        display: .init(width: 1280, height: 800), macAddress: "02:00:00:00:00:01",
        username: "guest", password: "fixture", created: Date()))
    try builder.makeAnswers(
      for: machine,
      packages: .init(
        directory: repository, codename: "resolute", kernel: "linux-image-7.0.0-30-generic"))
    let iso = directory.appendingPathComponent("answers.iso")
    XCTAssertEqual(try UbuntuPackages.isoFile(iso, "repository/pool/p0.deb"), deb)
    // Check the primary ISO9660 directory, not tar's preferred Joliet namespace.
    let primary = try primaryISOFilenames(iso)
    XCTAssertTrue(primary.contains("REPOSITORY/POOL/P0.DEB"), "\(primary)")
    XCTAssertTrue(
      String(decoding: try UbuntuPackages.isoFile(iso, "repository/installpackages"), as: UTF8.self)
        .contains("Filename: repository/pool/p0.deb\n"))
    for name in ["packages", "installpackages"] {
      XCTAssertFalse(try UbuntuPackages.isoFile(iso, "repository/" + name).isEmpty)
    }
    let answers = String(decoding: try UbuntuPackages.isoFile(iso, "user-data"), as: UTF8.self)
    XCTAssertTrue(answers.contains("package: linux-image-7.0.0-30-generic"))
    XCTAssertTrue(answers.contains("update: false"))
    XCTAssertTrue(answers.contains("geoip: false"))
    XCTAssertTrue(answers.contains("dhcp4: false"))
    XCTAssertTrue(answers.contains("Acquire::Retries"))
    XCTAssertEqual(
      String(decoding: try UbuntuPackages.isoFile(iso, "hukan-offline"), as: UTF8.self),
      LinuxTemplateBuilder.offlineScript)
    XCTAssertEqual(
      String(decoding: try UbuntuPackages.isoFile(iso, "hukan-setup"), as: UTF8.self),
      LinuxTemplateBuilder.setupScript)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("answers").path))
  }

  func testEarlyFailureReachesSerialLogWithExitStatus() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let builder = LinuxTemplateBuilder(
      request: .init(
        title: "fixture", image: directory.appendingPathComponent("unused.iso"), diskSize: 1,
        username: "guest"))
    let line = try XCTUnwrap(
      builder.userData().split(separator: "\n").first {
        $0.contains("hukan-early exit=")
      })
    let command = try XCTUnwrap(line.components(separatedBy: "sh -exc '").last).dropLast()
    let log = directory.appendingPathComponent("serial.log")
    let script = String(command)
      .replacingOccurrences(of: "/dev/hvc0", with: log.path)
      .replacingOccurrences(of: "blkid;", with: "echo simulated-blkid-failure; exit 23;")
    let shell = directory.appendingPathComponent("early.sh")
    try script.write(to: shell, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try LinuxTemplateBuilder.tool("/bin/sh", ["-ex", shell.path]))
    let output = try String(contentsOf: log, encoding: .utf8)
    XCTAssertTrue(output.contains("simulated-blkid-failure"))
    XCTAssertTrue(output.contains("hukan-early exit=23"), output)
  }

  func testOfflineScriptBuildsAnIndexAPTCanVerify() throws {
    for codename in ["noble", "resolute"] {
      try verifyOfflineIndex(codename: codename)
    }
  }

  private func verifyOfflineIndex(codename: String) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = directory.appendingPathComponent("cdrom/dists/\(codename)")
    let repository = directory.appendingPathComponent("cdrom/repository")
    let answers = directory.appendingPathComponent("run/hukan/repository")
    for url in [suite, repository, answers] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    for name in ["InRelease", "Release.gpg"] {
      try Data("old signature".utf8).write(to: suite.appendingPathComponent(name))
    }
    try codename.write(
      to: answers.appendingPathComponent("codename"), atomically: true, encoding: .utf8)
    let pool = UbuntuPackages.Package(fields: [
      "Package": "iso", "Version": "1", "Filename": "pool/iso.deb",
    ])
    let local = UbuntuPackages.Package(fields: [
      "Package": "mozc", "Version": "1", "Filename": "pool/mozc.deb", "Size": "3",
      "SHA256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    ])
    try FileManager.default.createDirectory(
      at: repository.appendingPathComponent("pool"), withIntermediateDirectories: true)
    try Data("abc".utf8).write(to: repository.appendingPathComponent("pool/mozc.deb"))
    try UbuntuPackages.indexText([local]).write(
      to: repository.appendingPathComponent("Packages"), atomically: true, encoding: .utf8)
    let index = UbuntuPackages.installIndex(pool: [pool], local: [local])
    try index.write(
      to: repository.appendingPathComponent("installpackages"), atomically: true, encoding: .utf8)
    let script = try XCTUnwrap(
      LinuxTemplateBuilder.offlineScript.components(separatedBy: "python3 - <<'PY'\n").last
    )
    .components(separatedBy: "\nPY")[0]
    .replacingOccurrences(of: "'/cdrom", with: "'" + directory.path + "/cdrom")
    .replacingOccurrences(of: "'/run/hukan", with: "'" + directory.path + "/run/hukan")
    let python = directory.appendingPathComponent("prepare.py")
    try script.write(to: python, atomically: true, encoding: .utf8)
    try LinuxTemplateBuilder.tool("/usr/bin/python3", [python.path])
    let release = try XCTUnwrap(
      UbuntuPackages.stanzas(
        String(contentsOf: suite.appendingPathComponent("Release"), encoding: .utf8)
      ).first)
    for component in ["main", "restricted"] {
      for name in ["Packages", "Packages.gz"] {
        let path = "\(component)/binary-arm64/\(name)"
        try UbuntuPackages.verifyIndex(
          Data(contentsOf: suite.appendingPathComponent(path)), path: path, release: release)
      }
    }
    XCTAssertEqual(
      try String(
        contentsOf: suite.appendingPathComponent("main/binary-arm64/Packages"), encoding: .utf8),
      index)
    XCTAssertTrue(index.contains("Filename: pool/iso.deb"))
    XCTAssertTrue(index.contains("Filename: repository/pool/mozc.deb"))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: suite.appendingPathComponent("Release.gpg").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: suite.appendingPathComponent("InRelease").path))
    // A missing or damaged package must fail early, before curtin starts installing.
    try Data("abd".utf8).write(to: repository.appendingPathComponent("pool/mozc.deb"))
    XCTAssertThrowsError(try LinuxTemplateBuilder.tool("/usr/bin/python3", [python.path]))
    try FileManager.default.removeItem(at: repository.appendingPathComponent("pool/mozc.deb"))
    XCTAssertThrowsError(try LinuxTemplateBuilder.tool("/usr/bin/python3", [python.path]))
    XCTAssertTrue(LinuxTemplateBuilder.offlineScript.contains("index=off,xino=off"))
    XCTAssertTrue(
      LinuxTemplateBuilder.offlineScript.contains("mount --bind /run/hukan-cdrom/view /cdrom"))
    for (name, contents) in [
      ("offline", LinuxTemplateBuilder.offlineScript), ("setup", LinuxTemplateBuilder.setupScript),
    ] {
      let shell = directory.appendingPathComponent(name)
      try contents.write(to: shell, atomically: true, encoding: .utf8)
      try LinuxTemplateBuilder.tool("/bin/sh", ["-n", shell.path])
    }
  }

}
