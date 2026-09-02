import AppKit

/// Whether the hukan being distributed is newer than the one running.
///
/// This is hukan's one outbound request, and the line it draws around itself is the whole of why
/// it is allowed: **one fixed URL, GET, nothing sent, no credentials, no account and nothing about
/// the work**. libgit2 is built here without the network on purpose, and the browser's traffic is
/// the user's own; this is neither, so it says exactly what it is and does no more.
///
/// **It reads the cask, not the tag's GitHub Release.** They answer differently for a minute at a
/// time: `release.yml` publishes the Release first and pushes the cask that points at it after, so
/// a check against the Release API lights the toolbar up during a window in which `brew` still has
/// nothing to give — hukan saying one thing and Homebrew saying another in the same glance, which
/// is the worst available answer. The cask is also what actually installs, so reading it makes the
/// two answers one file. The `version "X.Y.Z"` line is written by that tag's own workflow, so its
/// shape is fixed rather than guessed at.
///
/// **Only the Release build asks.** A Dev build's version is whatever the working tree says, so it
/// sits at the last release for the whole of the work after it and would announce every version as
/// available from the moment it shipped. `HUKAN_UPDATE_CHECK=1` turns it on anyway, which is how
/// the item is looked at without cutting a release to do it.
final class AppUpdate {
  static let shared = AppUpdate()

  /// Where the tap keeps the cask that installs hukan. Deliberately the raw file rather than the
  /// GitHub API: no rate limit to spend, no JSON, and no token has ever been in the question.
  static let caskURL = URL(
    string: "https://raw.githubusercontent.com/tnayuki/homebrew-hukan/main/Casks/hukan.rb")!

  /// What upgrading is, spelled the way it has to be spelled.
  ///
  /// The cask is **fully qualified** (`tnayuki/hukan/hukan`) and that is not decoration: Homebrew
  /// auto-updates before `upgrade` only once every 24 hours by default, so a release published
  /// today is invisible to a plain `brew upgrade --cask hukan` for the rest of the day — hukan
  /// would be pointing at a version Homebrew then reports it already has. An argument naming a
  /// third-party tap in full drops that interval to 5 minutes (`utils/auto-update.sh`, which does
  /// this for exactly this reason: a tap's casks do not come from the API). That is cheaper than
  /// putting `brew update` in front of it, which pays for every tap on the machine every time.
  ///
  /// Nothing quits first. Homebrew unlinks the old bundle rather than writing over it
  /// (`cask/artifact/moved.rb`), so the running process keeps the inode it started from and is
  /// untouched until it exits — which is why the last word is a relaunch and not a warning.
  static let upgradeCommand =
    "brew upgrade --cask tnayuki/hukan/hukan"
    + " && echo 'Restart hukan to pick up the new version.'"

  /// The released version, and only while it is ahead of this build. `nil` covers every other
  /// case at once — not asked yet, no network, up to date — because they all mean the same thing
  /// to the one thing that reads it: there is nothing to say.
  private(set) var available: String?

  /// Windows register to hear that the answer moved; there is more than one bar to update and a
  /// single closure would hold whichever window registered last.
  private var observers: [(key: ObjectIdentifier, notify: () -> Void)] = []

  private var task: URLSessionDataTask?
  /// `If-None-Match` on the next ask. A 304 costs the round trip and no body, and it is what makes
  /// re-asking cheap enough not to think about.
  private var etag: String?
  private var timer: Timer?

  /// Hourly. The thing being watched moves a few times a month, so this is already far more often
  /// than it needs to be; anything faster would be asking a question whose answer cannot have
  /// changed.
  private static let interval: TimeInterval = 3600

  private init() {}

  var runningVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
  }

  func observe(_ owner: AnyObject, _ notify: @escaping () -> Void) {
    observers.removeAll { $0.key == ObjectIdentifier(owner) }
    observers.append((ObjectIdentifier(owner), notify))
  }

  func stopObserving(_ owner: AnyObject) {
    observers.removeAll { $0.key == ObjectIdentifier(owner) }
  }

  /// Ask once now and then hourly. Silent about everything: a machine with no network has not
  /// learned that there is no new version, so a failed read leaves the last answer standing, the
  /// same way a failed usage read does.
  func start() {
    #if DEBUG
      guard ProcessInfo.processInfo.environment["HUKAN_UPDATE_CHECK"] != nil else { return }
    #endif
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    check()
    let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.check() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func check() {
    guard task == nil else { return }
    var request = URLRequest(url: Self.caskURL)
    request.httpMethod = "GET"
    if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        self.task = nil
        guard let http = response as? HTTPURLResponse else { return }
        if let tag = http.value(forHTTPHeaderField: "Etag") { self.etag = tag }
        // 304: the file has not moved, so neither has the answer.
        guard http.statusCode == 200, let data, let body = String(data: data, encoding: .utf8)
        else { return }
        guard let released = Self.version(inCask: body) else { return }
        self.apply(released)
      }
    }
    self.task = task
    task.resume()
  }

  /// Take the answer, and tell the bars only if it actually moved — a check runs hourly for as
  /// long as the app is up, and relaying an unchanged answer would redraw every toolbar for it.
  ///
  /// Not private so the tests can put a version in without a network: what is worth pinning is
  /// what the bar does with an answer, and that is the half a fixed URL cannot exercise.
  func apply(_ released: String) {
    let ahead = Self.compare(released, runningVersion) == .orderedDescending
    let next = ahead ? released : nil
    guard next != available else { return }
    available = next
    for observer in observers { observer.notify() }
  }

  /// The `version "0.4.4"` line, which is the one thing wanted out of a Ruby file. Matched rather
  /// than parsed: the workflow writes this line, so its shape is fixed, and a cask that has been
  /// reformatted past recognition should answer nothing rather than a guess.
  static func version(inCask body: String) -> String? {
    for line in body.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("version ") else { continue }
      let rest = trimmed.dropFirst("version ".count).trimmingCharacters(in: .whitespaces)
      guard rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") else { continue }
      let value = String(rest[rest.index(after: rest.startIndex)..<end])
      return value.isEmpty ? nil : value
    }
    return nil
  }

  /// Numerically, the Finder's rule — the same comparison the History section's tags are ordered
  /// by, and for the same reason: the dictionary's rule puts `0.10.0` below `0.9.0`.
  static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
    lhs.compare(rhs, options: .numeric)
  }

  /// True while the tap is being asked. The menu's Check for Updates is disabled for as long as
  /// it is, which is the whole of the feedback that command gets: the answer itself lands in the
  /// toolbar, where an arrow appears if there is one to show and nothing appears if there is not.
  var isChecking: Bool { task != nil }

  /// Hand the upgrade to Terminal.app. hukan neither waits for it nor learns how it went — the
  /// terminal window is the report, and the next launch's check is the verdict.
  func upgrade() {
    do {
      try ExternalTerminal.run(Self.upgradeCommand)
    } catch {
      NSLog("hukan: could not open a terminal to upgrade: \(error.localizedDescription)")
    }
  }
}
