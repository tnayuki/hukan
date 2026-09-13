import Foundation

/// What a web tab's owner has let the agent do with it.
///
/// The tab is the unit, because the tab is what a person sees: a row on the strip, a page on the
/// desk, an address in the bar. Every other browser agent scopes its consent to a *site*, and a
/// site is a thing nobody is looking at — hukan's tabs belong to a worktree and were opened for
/// its task, which is what makes the tab a boundary worth granting on. What the grant is *not* is
/// a boundary on identity: every tab shares one cookie store, so inside a shared tab the agent is
/// the person, on whatever the page reaches.
///
/// Two levels, chosen on the card that asks — reading is not a decision a person would have made,
/// driving is — and one rule between them: **driving lapses when the tab leaves the site it was
/// granted on, reading does not.** A read that lapsed on every link would make following a PR's
/// links a card per click; a drive that survived a navigation would be consent to act on a page
/// nobody saw, which is exactly the shape of the hole that has been found in browser agents'
/// origin checks. The person never meets the word "origin": what they see is the glyph going
/// hollow and, on the next drive, the card again.
///
/// Never saved: a grant that came back after a relaunch would be hukan making it again tomorrow
/// on nobody's behalf — and a grant that lives nowhere on disk is one nothing on the machine can
/// forge.
struct BrowserGrant: Equatable {
  enum Level: Comparable {
    case read
    case drive

    var label: String {
      switch self {
      case .read: return "read"
      case .drive: return "drive"
      }
    }
  }

  var level: Level
  /// The site the grant was made on — scheme, host and port — which is what a drive is held to.
  let origin: String

  init(level: Level, origin: String) {
    self.level = level
    self.origin = origin
  }

  /// A grant on the site of `url`. A blank tab has no site, and is granted on none: a read there
  /// is the way to hand the agent a tab to navigate, and a drive there lapses on the first page.
  init(level: Level, at url: URL?) {
    self.init(level: level, origin: Self.origin(of: url) ?? "")
  }

  func allows(_ level: Level) -> Bool { self.level >= level }

  /// The grant after the tab moves to `url`. A drive is held to the site it was granted on and
  /// falls back to a read anywhere else — including an address with no site at all, since that is
  /// not the page the drive was granted for either. A read is the same grant wherever the tab
  /// goes.
  func afterNavigating(to url: URL?) -> BrowserGrant {
    guard level == .drive, Self.origin(of: url) != origin else { return self }
    return BrowserGrant(level: .read, origin: origin)
  }

  /// Scheme, host and port, lower-cased — the browser's own notion of a site, and the unit a
  /// drive is held to. Nil for anything without a host.
  static func origin(of url: URL?) -> String? {
    guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased()
    else { return nil }
    let port = url.port.map { ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)"
  }
}
