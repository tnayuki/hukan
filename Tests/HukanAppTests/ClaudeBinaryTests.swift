import XCTest

@testable import Hukan

/// Finding `claude` when launchd handed the app no PATH. Every case builds its own directories,
/// so none of this depends on what happens to be installed on the machine running it.
final class ClaudeBinaryTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-claudebinary-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  /// A `claude` at `directory/claude`, executable.
  @discardableResult
  private func install(in directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let binary = directory.appendingPathComponent("claude")
    FileManager.default.createFile(
      atPath: binary.path, contents: Data("#!/bin/sh\n".utf8),
      attributes: [.posixPermissions: 0o755])
    return binary
  }

  func testTheInheritedPathWinsOverTheInstallLocations() throws {
    // A terminal- or Xcode-launched build already carries the user's own answer, and so does a
    // custom install the list has never heard of. The list is what a GUI launch has instead of a
    // PATH, not an override of one.
    let onPath = try install(in: root.appendingPathComponent("somewhere-else"))
    let home = root.appendingPathComponent("home")
    try install(in: home.appendingPathComponent(".local/bin"))

    let found = ClaudeBinary.resolve(path: onPath.deletingLastPathComponent().path, home: home.path)
    XCTAssertEqual(found?.path, onPath.path)
  }

  func testTheInstallLocationIsUsedWhenThePathIsLaunchdBare() throws {
    // The regression this exists for: from the Dock, PATH is /usr/bin:/bin:/usr/sbin:/sbin, which
    // holds no `claude` — and the official installer's directory is where it actually is.
    let home = root.appendingPathComponent("home")
    let installed = try install(in: home.appendingPathComponent(".local/bin"))

    let found = ClaudeBinary.resolve(path: "/usr/bin:/bin:/usr/sbin:/sbin", home: home.path)
    XCTAssertEqual(found?.path, installed.path)
  }

  func testNothingAnywhereResolvesToNil() {
    // Nil is what makes the launch throw with a sentence, rather than exec'ing `env` and coming
    // back later as status 127.
    let home = root.appendingPathComponent("empty-home")
    XCTAssertNil(ClaudeBinary.resolve(path: "/nonexistent-\(UUID().uuidString)", home: home.path))
  }

  func testTheInstallLocationsAreTriedInOrder() throws {
    // `~/.local/bin` is the official installer and comes first; the Homebrew prefixes follow. The
    // order only shows when more than one is populated, which is exactly when it matters.
    let home = root.appendingPathComponent("home")
    let official = try install(in: home.appendingPathComponent(".local/bin"))
    XCTAssertEqual(ClaudeBinary.installLocations.first, "~/.local/bin/claude")
    XCTAssertEqual(ClaudeBinary.resolve(path: "", home: home.path)?.path, official.path)
  }

  func testTheSymlinkTheInstallerLeavesIsNotFollowed() throws {
    // `~/.local/bin/claude` points at the version directory the installer just wrote, and it
    // repoints on every upgrade. Resolving it here would pin the app to whichever version was
    // current when it launched.
    let home = root.appendingPathComponent("home")
    let bin = home.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let real = root.appendingPathComponent("versions-1.2.3")
    FileManager.default.createFile(
      atPath: real.path, contents: Data("#!/bin/sh\n".utf8),
      attributes: [.posixPermissions: 0o755])
    let link = bin.appendingPathComponent("claude")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    XCTAssertEqual(ClaudeBinary.resolve(path: "", home: home.path)?.path, link.path)
  }

  func testFindWalksThePathInOrderAndSkipsWhatItCannotRun() throws {
    let early = root.appendingPathComponent("early")
    let late = root.appendingPathComponent("late")
    try FileManager.default.createDirectory(at: early, withIntermediateDirectories: true)
    let lateBinary = try install(in: late)

    // A file of the right name that cannot be run is not the answer, and neither is an entry
    // that is not a directory at all — an unexpanded `~` sits in this machine's own PATH.
    FileManager.default.createFile(
      atPath: early.appendingPathComponent("claude").path, contents: Data(),
      attributes: [.posixPermissions: 0o644])
    let path = "~/.dotnet/tools::\(early.path):\(late.path)"
    XCTAssertEqual(ClaudeBinary.find("claude", in: path)?.path, lateBinary.path)
  }

  func testTheErrorNamesEveryPlaceTheSearchLooked() {
    // From the Dock there is no PATH to inspect by hand, so naming the directories is the whole
    // of what makes the failure actionable. Built from the same list the search walks.
    let searched = ClaudeBinary.searchedLocations(path: "/usr/bin:/bin", home: "/Users/x")
    XCTAssertEqual(
      searched,
      [
        "/usr/bin", "/bin", "/Users/x/.local/bin/claude", "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
      ])
  }
}
