import AppKit

/// The Finder's Open With submenu for one file: the default application first, then every other
/// application Launch Services says can open it. The list is the system's, not a table here, so
/// what it offers is what the Finder would offer for the same file.
///
/// It lives beside `WordSelection` for the same reason that does: the transcript and the files
/// panel both reach for it, and it knows nothing about either.
public enum OpenWithMenu {
  /// The `Open With` item, or nil when no application claims the file — an offer that can never
  /// be taken is worse than no offer. hukan itself is left out: the item beside this one already
  /// opens the file here, so listing hukan again would be the same act under a second name.
  public static func item(for file: URL) -> NSMenuItem? {
    let workspace = NSWorkspace.shared
    let own = Bundle.main.bundleURL.standardizedFileURL
    let preferred = workspace.urlForApplication(toOpen: file)?.standardizedFileURL
    var seen = Set<URL>()
    let others = workspace.urlsForApplications(toOpen: file)
      .map(\.standardizedFileURL)
      .filter { $0 != own && $0 != preferred && seen.insert($0).inserted }
    let preferredShown = preferred.flatMap { $0 == own ? nil : $0 }
    guard preferredShown != nil || !others.isEmpty else { return nil }

    let names = Dictionary(grouping: ([preferredShown].compactMap { $0 } + others), by: name)
    func title(_ app: URL) -> String {
      // Two copies of one application — a beta beside a release, the Dev build beside the
      // cask's — would read as the same row twice, so a name that repeats carries its version.
      guard (names[name(app)]?.count ?? 0) > 1,
        let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
      else { return name(app) }
      return "\(name(app)) (\(version))"
    }

    let submenu = NSMenu(title: "Open With")
    func add(_ app: URL, _ title: String) {
      let item = NSMenuItem(
        title: title, action: #selector(Target.open(_:)), keyEquivalent: "")
      item.target = Target.shared
      item.representedObject = Choice(file: file, application: app)
      let icon = workspace.icon(forFile: app.path)
      icon.size = NSSize(width: 16, height: 16)
      item.image = icon
      submenu.addItem(item)
    }
    if let preferredShown {
      add(preferredShown, "\(title(preferredShown)) (default)")
      if !others.isEmpty { submenu.addItem(.separator()) }
    }
    for app in others.sorted(by: {
      title($0).localizedStandardCompare(title($1)) == .orderedAscending
    }) {
      add(app, title(app))
    }
    let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
    item.submenu = submenu
    return item
  }

  private static func name(_ app: URL) -> String {
    FileManager.default.displayName(atPath: app.path)
      .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
  }

  final class Choice {
    let file: URL
    let application: URL
    init(file: URL, application: URL) {
      self.file = file
      self.application = application
    }
  }

  /// A menu item holds its target weakly, so the target is one object that outlives every menu.
  final class Target: NSObject {
    static let shared = Target()

    @objc func open(_ sender: NSMenuItem) {
      guard let choice = sender.representedObject as? Choice else { return }
      NSWorkspace.shared.open(
        [choice.file], withApplicationAt: choice.application,
        configuration: NSWorkspace.OpenConfiguration())
    }
  }
}
