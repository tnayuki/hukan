import AppKit

/// The repositories that have been open and are not open in this window now — what File ▸ Open
/// Recent and the rail's own submenu offer.
///
/// It is the one thing about hukan's use that nothing else records. git owns worktrees and Claude
/// Code owns sessions, and which repositories are *open* rides the window's restorable state, which
/// is where it belongs: a window is what a set of repositories is open in. But "this was open last
/// week" belongs to no window — the window that held it is exactly what is gone — so this is
/// hukan's one app-global store, a list of paths in the defaults. Not a preference (there is no
/// settings window, and nothing here is a choice), and not master data either: every entry is a
/// path git answers for, and a list that is lost costs one trip through the open panel.
///
/// An entry is a *repository* id — the path git's common dir sits under, the same string the model
/// interns repositories by — so opening a linked worktree records the repository it belongs to and
/// reopening lands on the open/close unit rather than on whichever checkout was pointed at.
final class RecentRepositories {
  /// Ten, the length every Open Recent on this machine is.
  static let limit = 10

  /// Under XCTest the backing is memory rather than the defaults: a test opening a /tmp fixture
  /// must not turn up in the dev build's real menu at the next launch.
  static let shared = RecentRepositories(
    defaults: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
      ? .standard : nil)

  /// What a menu row says, and what it opens.
  struct Entry {
    let path: String
    /// The repository's name — its last path component, the same one the rail's heading uses —
    /// with the directory it sits in appended when the offered list holds two of that name, since
    /// two rows both reading `hukan` name nothing.
    let title: String
  }

  private static let key = "recentRepositories"
  private let defaults: UserDefaults?
  private var memory: [String] = []

  init(defaults: UserDefaults?) { self.defaults = defaults }

  private var stored: [String] {
    get { defaults.map { $0.stringArray(forKey: Self.key) ?? [] } ?? memory }
    set {
      if let defaults {
        defaults.set(newValue, forKey: Self.key)
      } else {
        memory = newValue
      }
    }
  }

  /// The list as it stands, newest first, with whatever is no longer a directory dropped — from
  /// the store as well as from the answer. A repository that has been deleted or moved is not
  /// recent, it is gone, and leaving it would hold one of the ten places for good. Ten stats, so
  /// the pruning can ride every read rather than being something to schedule.
  var paths: [String] {
    let live = stored.filter { path in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    }
    if live != stored { stored = live }
    return live
  }

  /// Record a repository, at the head. Noted when one is opened *and* when it is closed: closing
  /// is what usually puts a repository in this menu, but one that was opened and then carried
  /// across restarts until a quit would otherwise never have been noted at all.
  func note(_ path: String) {
    var list = paths
    list.removeAll { $0 == path }
    list.insert(path, at: 0)
    stored = Array(list.prefix(Self.limit))
  }

  func forget(_ path: String) {
    stored = paths.filter { $0 != path }
  }

  func clear() {
    stored = []
  }

  /// What a menu offers: the list less whatever the window it would add to already holds, since
  /// the act is "open this here" and a repository already here has nothing to open.
  func entries(excluding open: Set<String>) -> [Entry] {
    let offered = paths.filter { !open.contains($0) }
    var byName: [String: Int] = [:]
    for path in offered { byName[(path as NSString).lastPathComponent, default: 0] += 1 }
    return offered.map { path in
      let name = (path as NSString).lastPathComponent
      guard byName[name, default: 0] > 1 else { return Entry(path: path, title: name) }
      let parent = ((path as NSString).deletingLastPathComponent as NSString)
        .abbreviatingWithTildeInPath
      return Entry(path: path, title: "\(name) — \(parent)")
    }
  }
}

/// The Open Recent submenu, wherever it hangs — the File menu, the rail's right-click, the empty
/// state's pull-down. Built when it is opened rather than kept in step: the list moves whenever any
/// window opens or closes a repository, and what it excludes is what the window it would add to
/// holds, so the only moment the answer is certainly right is the moment it is asked for.
final class RecentRepositoriesMenu: NSMenu, NSMenuDelegate {
  /// Set when the menu backs a pull-down button, whose first item is its title and is never
  /// chosen. Held here because rebuilding empties the menu, and the title has to survive that.
  var pullDownTitle: String?

  override init(title: String) {
    super.init(title: title)
    delegate = self
  }

  required init(coder: NSCoder) { fatalError() }

  func menuNeedsUpdate(_ menu: NSMenu) {
    removeAllItems()
    if let pullDownTitle {
      addItem(withTitle: pullDownTitle, action: nil, keyEquivalent: "")
    }
    let open = Set(WorkspaceWindowController.front?.workspace.repositories.map(\.id) ?? [])
    let entries = RecentRepositories.shared.entries(excluding: open)
    guard !entries.isEmpty else {
      // A nil action disables it: nothing to open, and nothing to clear either — a store that is
      // not empty but wholly open here is a menu with nothing to say, not one with a Clear.
      addItem(withTitle: "No Recent Repositories", action: nil, keyEquivalent: "")
      return
    }
    for entry in entries {
      let item = addItem(
        withTitle: entry.title,
        action: #selector(WorkspaceWindowController.openRecentRepository(_:)), keyEquivalent: "")
      item.representedObject = entry.path
      item.toolTip = (entry.path as NSString).abbreviatingWithTildeInPath
    }
    addItem(.separator())
    addItem(
      withTitle: "Clear Menu", action: #selector(AppDelegate.clearRecentRepositories(_:)),
      keyEquivalent: "")
  }
}
