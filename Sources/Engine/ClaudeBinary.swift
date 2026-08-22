import Foundation

/// Where `claude` is, for an app that was not handed a PATH.
///
/// launchd gives a Dock-, Finder- or Spotlight-launched app `/usr/bin:/bin:/usr/sbin:/sbin` and
/// nothing else, so the binary — which its own installer puts in `~/.local/bin`, and Homebrew in
/// the prefix — is not on it. hukan spawned `/usr/bin/env claude` and inherited whatever PATH it
/// was given, which meant the engine started for a build launched from a terminal (`open`
/// forwards the caller's environment, and so does Xcode) and never for the one on the Dock: the
/// same app, two outcomes, decided by something no one looks at, and invisible in development
/// because the documented way to relaunch is `open`.
///
/// So the install locations are simply named. Asking a login shell for its PATH was the
/// alternative, and it buys less than it costs: `-ilc` is itself a guess about which rc file
/// builds PATH, the payload has to be fenced off from whatever the profile prints, a profile is
/// free to be slow or to block, and it ends up replacing the whole environment to answer a
/// question about one file. This is three `stat`s, it runs the user's shell not at all, and when
/// it is wrong it can say exactly where it looked.
///
/// What it cannot find is an install under a version manager — npm under fnm or nvm puts `claude`
/// in a directory named after a shell session, which no fixed list can name. That is what the
/// inherited PATH below is for on a terminal launch; from the Dock such an install is not found,
/// and the error says so.
enum ClaudeBinary {
  /// Where Claude Code installs itself, most official first. `/usr/local/bin` is Homebrew's
  /// prefix on Intel and npm's default global bin, which are the same directory and so one entry.
  static let installLocations = [
    "~/.local/bin/claude",
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
  ]

  /// Resolved once per launch. Not because it is expensive — it is three `stat`s at worst — but
  /// because the answer cannot change under a running app in a way worth noticing: an install
  /// that lands now takes effect in the next launch, the way a PATH edit takes effect in the next
  /// terminal.
  static let url: URL? = resolve()

  /// The inherited PATH first, then the install locations.
  ///
  /// PATH is ahead of the list rather than a fallback for it: a terminal- or Xcode-launched build
  /// already carries the user's own answer, and so does an install this list has never heard of.
  /// The list is only what a GUI launch has instead of a PATH.
  ///
  /// Whatever is found is kept as found, symlink and all: the installer's `~/.local/bin/claude`
  /// points at the version directory it just wrote and repoints on every upgrade, so resolving it
  /// here would pin the app to whichever version was current when it launched.
  static func resolve(
    path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
    home: String = NSHomeDirectory()
  ) -> URL? {
    if let onPath = find("claude", in: path) { return onPath }
    for location in installLocations {
      let expanded = location.hasPrefix("~/") ? home + String(location.dropFirst(1)) : location
      if FileManager.default.isExecutableFile(atPath: expanded) {
        return URL(fileURLWithPath: expanded)
      }
    }
    return nil
  }

  /// First executable named `name` on `path`. Exposed for a test that points it at a directory it
  /// built itself.
  static func find(_ name: String, in path: String) -> URL? {
    for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
      // A PATH may carry an unexpanded `~` (this machine's does, on one entry). A shell would not
      // have expanded it either, so it is skipped along with anything else that is not a real
      // directory.
      let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  /// Every place `resolve` would have looked, for an error that can say where it went. Built the
  /// same way the search is, so the two cannot drift apart.
  static func searchedLocations(
    path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
    home: String = NSHomeDirectory()
  ) -> [String] {
    let onPath = path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    return onPath
      + installLocations.map {
        $0.hasPrefix("~/") ? home + String($0.dropFirst(1)) : $0
      }
  }
}
