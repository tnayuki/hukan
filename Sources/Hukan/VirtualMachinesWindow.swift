import AppKit
import UniformTypeIdentifiers
import Virtualization

/// Window ▸ Virtual Machines: what the store holds — templates, the sessions' copies, the
/// installers — and the acts on it that are not a tab's: making a template, and deleting what is
/// no longer wanted. A window of things, not of settings: nothing here is a choice about how hukan
/// behaves, which is why it is not a preferences window.
///
/// Laid out the way the system lays out a list of things with details — a sidebar and a detail
/// pane, `+` and `−` under the list — and a template being made is a row of that list like any
/// other, with its progress on the row and its first boot in the detail pane, rather than a bar
/// floating apart from what it is about.
final class VirtualMachinesWindowController: NSWindowController, NSWindowDelegate,
  NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate
{
  static let shared = VirtualMachinesWindowController()

  fileprivate enum Row: Equatable {
    case header(String)
    case empty(String)
    case building
    case template(Machine)
    case session(Machine)
    case image(URL)
    case downloading
  }

  private var rows: [Row] = []
  private let table = MachineTableView()
  /// The template whose name is being typed on its row.
  private var renaming: Machine?
  private let addRemove = NSSegmentedControl()
  private let detail = MachineDetailView()

  private var builder: MacTemplateBuilder?
  /// The latest IPSW being fetched into Images, while it is.
  private var download: RestoreImageDownload?
  private var buildPhase: MacTemplateBuilder.Phase?
  /// The sheet asking for a new template, held while it is up: its buttons' target is the sheet's
  /// controller, and a sheet does not keep that alive by itself.
  private var newTemplateSheet: NewMacTemplateSheet?
  private var templateTitles: [UUID: String] = [:]
  /// Every template and session machine, for working out what came from what.
  private var machines: [Machine] = []
  private var indentation: [UUID: Int] = [:]

  /// The template a machine was copied from, if that template is still here. One whose template
  /// was deleted is an origin of its own now — the blocks it shared are its alone.
  private func originParent(of machine: Machine) -> UUID? {
    guard let parent = machine.manifest.parent, templateTitles[parent] != nil else { return nil }
    return parent
  }

  /// The machines copied from `machine` that are still here.
  private func copies(of machine: Machine) -> [Machine] {
    machines.filter { $0.manifest.parent == machine.id }
  }

  /// What a machine costs this Mac, counted so the list adds up: an origin — a template made from
  /// an installer, or one whose template is gone — counts everything it holds, shared blocks
  /// included; a copy counts only what it has written since, as `+`. A template is never written
  /// to once made, so what a copy shares is exactly what its origin already counted.
  private func onThisMac(_ machine: Machine) -> String {
    if originParent(of: machine) != nil {
      return "+" + Self.size(machine.privateSize ?? machine.allocatedSize)
    }
    return Self.size(machine.allocatedSize)
  }

  private init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
      styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
      backing: .buffered, defer: true)
    window.title = "Virtual Machines"
    window.minSize = NSSize(width: 640, height: 400)
    window.setFrameAutosaveName("VirtualMachines")
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    build()
    NotificationCenter.default.addObserver(
      forName: MachineStore.didChange, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard self?.window?.isVisible == true else { return }
        self?.reload()
      }
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  /// ⌘W: File ▸ Close Tab's action, which reaches whatever is frontmost. This window has no tabs,
  /// so closing what is in front of you is closing it.
  @objc func closeTab(_ sender: Any?) {
    window?.performClose(sender)
  }

  func show() {
    MachineStore.prepare()
    reload()
    if window?.isVisible != true { window?.center() }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }

  // MARK: Layout

  private func build() {
    guard let content = window?.contentView else { return }
    table.addTableColumn(NSTableColumn(identifier: .init("item")))
    table.headerView = nil
    table.style = .sourceList
    table.dataSource = self
    table.delegate = self
    // ⏎ names the selected row — the files panel's key and the Finder's.
    table.onReturn = { [weak self] in self?.beginRename(row: self?.table.selectedRow ?? -1) }
    let menu = NSMenu()
    menu.delegate = self
    table.menu = menu
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false

    addRemove.segmentStyle = .smallSquare
    addRemove.trackingMode = .momentary
    addRemove.segmentCount = 2
    addRemove.setImage(
      NSImage(systemSymbolName: "plus", accessibilityDescription: "Add"), forSegment: 0)
    addRemove.setImage(
      NSImage(systemSymbolName: "minus", accessibilityDescription: "Delete"), forSegment: 1)
    addRemove.setToolTip("New Template or Image", forSegment: 0)
    addRemove.setToolTip("Delete…", forSegment: 1)
    addRemove.target = self
    addRemove.action = #selector(addRemovePressed)

    let sidebar = NSVisualEffectView()
    sidebar.material = .sidebar
    sidebar.blendingMode = .behindWindow
    let bar = NSStackView(views: [addRemove, NSView()])
    bar.orientation = .horizontal
    bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)
    let sidebarStack = NSStackView(views: [scroll, bar])
    sidebarStack.orientation = .vertical
    sidebarStack.spacing = 0
    sidebar.addSubview(sidebarStack)
    sidebarStack.pin(to: sidebar, insets: NSEdgeInsets(top: 28, left: 0, bottom: 0, right: 0))
    scroll.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
    bar.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true

    let split = NSSplitView()
    split.isVertical = true
    split.dividerStyle = .thin
    split.addArrangedSubview(sidebar)
    split.addArrangedSubview(detail)
    sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
    sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
    content.addSubview(split)
    split.pin(to: content)
    split.setPosition(280, ofDividerAt: 0)

    detail.onShutDown = { [weak self] in self?.shutDownBuild() }
    update()
  }

  // MARK: Rows

  func reload() {
    let selected = selectedRow
    let templates = MachineStore.templates()
    templateTitles = Dictionary(uniqueKeysWithValues: templates.map { ($0.id, $0.manifest.title) })
    let sessions = MachineStore.sessions()
    machines = templates + sessions
    var rows: [Row] = [.header("Templates")]
    if builder != nil { rows.append(.building) }
    // Each template under the one it was made from, so a derived template reads as what it adds.
    func appendTemplates(under parent: UUID?, depth: Int) {
      for template in templates where originParent(of: template) == parent {
        rows.append(.template(template))
        indentation[template.id] = depth
        appendTemplates(under: template.id, depth: depth + 1)
      }
    }
    indentation = [:]
    appendTemplates(under: nil, depth: 0)
    if rows.count == 1 { rows.append(.empty("No templates — press + to make one")) }
    rows.append(.header("Sessions"))
    rows += sessions.isEmpty ? [.empty("No session machines")] : sessions.map { .session($0) }
    rows.append(.header("Images"))
    let images = MachineStore.images()
    if download != nil { rows.append(.downloading) }
    rows += images.map { .image($0) }
    if images.isEmpty, download == nil { rows.append(.empty("No installers")) }
    self.rows = rows
    table.reloadData()
    if let selected, let index = rows.firstIndex(where: { Self.same($0, selected) }) {
      table.selectRowIndexes([index], byExtendingSelection: false)
    }
    update()
  }

  private static func same(_ a: Row, _ b: Row) -> Bool {
    switch (a, b) {
    case (.template(let x), .template(let y)), (.session(let x), .session(let y)):
      return x.id == y.id
    case (.image(let x), .image(let y)): return x == y
    case (.building, .building), (.downloading, .downloading): return true
    default: return false
    }
  }

  private var selectedRow: Row? {
    rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
  }

  private var clickedRow: Row? {
    rows.indices.contains(table.clickedRow) ? rows[table.clickedRow] : nil
  }

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
    if case .header = rows[row] { return true }
    return false
  }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    switch rows[row] {
    case .header, .empty: return false
    default: return true
    }
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    switch rows[row] {
    case .header, .empty: return 24
    default: return 38
    }
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    switch rows[row] {
    case .header(let title):
      let label = NSTextField(labelWithString: title)
      label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
      label.textColor = .secondaryLabelColor
      return label
    case .empty(let text):
      let label = NSTextField(labelWithString: text)
      label.textColor = .tertiaryLabelColor
      label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      return label
    case .building:
      return MachineRowView(
        symbol: "apple.logo", title: builder?.request.title ?? "",
        subtitle: Self.describe(buildPhase), progress: Self.fraction(buildPhase))
    case .template(let machine):
      return MachineRowView(
        symbol: Self.symbol(machine.manifest.kind), title: machine.manifest.title,
        subtitle: "\(onThisMac(machine)) on this Mac", indent: indentation[machine.id] ?? 0)
    case .session(let machine):
      let title = machine.manifest.parent.flatMap { templateTitles[$0] } ?? machine.manifest.title
      let running = Self.runningMachineIDs.contains(machine.id.uuidString)
      return MachineRowView(
        symbol: Self.symbol(machine.manifest.kind), title: title,
        subtitle: (running ? "Running · " : "") + "\(onThisMac(machine)) on this Mac")
    case .downloading:
      return MachineRowView(
        symbol: "arrow.down.circle", title: Self.imageTitle(name: download?.name),
        subtitle: Self.describe(download?.state), progress: Self.fraction(download?.state))
    case .image(let url):
      return MachineRowView(
        symbol: "opticaldiscdrive", title: Self.imageTitle(url),
        subtitle: Self.size(Self.fileSize(url)))
    }
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    update()
  }

  // MARK: Detail

  private func update() {
    let selected = selectedRow
    let canDelete: Bool
    switch selected {
    case .template, .image, .downloading: canDelete = true
    case .session(let machine):
      canDelete = !Self.runningMachineIDs.contains(machine.id.uuidString)
    default: canDelete = false
    }
    addRemove.setEnabled(builder == nil, forSegment: 0)
    addRemove.setEnabled(canDelete, forSegment: 1)

    if case .building = selected {
    } else {
      builder?.parkScreen()
    }
    switch selected {
    case .building:
      detail.show(
        symbol: "apple.logo", title: builder?.request.title ?? "",
        status: Self.describe(buildPhase), progress: Self.fraction(buildPhase), controls: [],
        facts: [],
        screen: builder?.screenMachine == nil ? nil : builder?.screenView,
        canShutDown: Self.isSetupFailed(buildPhase), password: nil)
    case .template(let machine), .session(let machine):
      var facts = facts(machine)
      if case .session = selected, let parent = machine.manifest.parent {
        facts.insert(("Template", templateTitles[parent] ?? "Deleted"), at: 0)
      }
      // A running machine was sized when it started; the popups wait for it to stop.
      let running = Self.runningMachineIDs.contains(machine.id.uuidString)
      detail.show(
        symbol: Self.symbol(machine.manifest.kind), title: machine.manifest.title,
        status: nil, progress: nil, controls: resourceControls(machine, enabled: !running),
        facts: facts, screen: nil, canShutDown: false,
        password: machine.manifest.password)
    case .image(let url):
      detail.show(
        symbol: "opticaldiscdrive", title: Self.imageTitle(url), status: nil, progress: nil,
        controls: [],
        facts: [("File", url.lastPathComponent), ("Size", Self.size(Self.fileSize(url)))],
        screen: nil, canShutDown: false, password: nil)
    default:
      detail.showEmpty()
    }
  }

  private func facts(_ machine: Machine) -> [(String, String)] {
    let manifest = machine.manifest
    var facts: [(String, String)] = [
      // In the unit it was asked for in: 80 GB typed is 80 × 2³⁰ bytes, which decimal units call
      // 85.9 GB.
      (
        "Disk",
        ByteCountFormatter.string(fromByteCount: machine.diskSize, countStyle: .memory)
          + " as the guest sees it"
      ),
      ("On this Mac", onThisMac(machine)),
      ("Created", manifest.created.formatted(date: .abbreviated, time: .shortened)),
    ]
    if let user = manifest.username { facts.append(("Account", user)) }
    return facts
  }

  // MARK: Processors and memory

  /// The two things about a machine that can change after it is made: they are read from the
  /// manifest at every boot, and nothing on its disk depends on them. A template's apply to the
  /// copies made from it from now on; a copy's, to its next start.
  private func resourceControls(_ machine: Machine, enabled: Bool) -> [(String, NSView)] {
    let cpus = NSPopUpButton()
    for count in Self.processorChoices {
      cpus.addItem(withTitle: "\(count)")
      cpus.lastItem?.tag = count
    }
    if cpus.itemTitles.contains("\(machine.manifest.cpuCount)") {
      cpus.selectItem(withTag: machine.manifest.cpuCount)
    } else {
      cpus.addItem(withTitle: "\(machine.manifest.cpuCount)")
      cpus.lastItem?.tag = machine.manifest.cpuCount
      cpus.selectItem(withTag: machine.manifest.cpuCount)
    }
    let memory = NSPopUpButton()
    let currentGB = Int(machine.manifest.memorySize >> 30)
    for gb in Self.memoryChoices {
      memory.addItem(withTitle: "\(gb) GB")
      memory.lastItem?.tag = gb
    }
    if memory.indexOfItem(withTag: currentGB) < 0 {
      memory.addItem(withTitle: "\(currentGB) GB")
      memory.lastItem?.tag = currentGB
    }
    memory.selectItem(withTag: currentGB)
    for popUp in [cpus, memory] {
      popUp.isEnabled = enabled
      popUp.target = self
      popUp.action = #selector(resourcesChanged(_:))
      popUp.identifier = .init(machine.url.path)
      popUp.toolTip = enabled ? nil : "Shut the machine down to change this."
    }
    cpus.tag = 1
    memory.tag = 2
    return [("Processors", cpus), ("Memory", memory)]
  }

  @objc private func resourcesChanged(_ sender: NSPopUpButton) {
    guard let path = sender.identifier?.rawValue,
      var machine = Machine(url: URL(fileURLWithPath: path)),
      let value = sender.selectedItem?.tag
    else { return }
    if sender.tag == 1 {
      machine.manifest.cpuCount = value
    } else {
      machine.manifest.memorySize = UInt64(value) << 30
    }
    do {
      try machine.save()
      // A state saved under the old size cannot be restored into the new one; the next start is
      // a cold boot either way, and this keeps it from trying first.
      try? FileManager.default.removeItem(at: machine.stateURL)
    } catch {
      NSAlert(error: error).runModal()
    }
    reload()
  }

  /// From what macOS asks of a guest to what the framework and this Mac allow.
  static var processorChoices: [Int] {
    let most = min(
      VZVirtualMachineConfiguration.maximumAllowedCPUCount,
      ProcessInfo.processInfo.processorCount)
    return Array(2...max(2, most))
  }

  static var memoryChoices: [Int] {
    let ceiling =
      min(
        VZVirtualMachineConfiguration.maximumAllowedMemorySize,
        ProcessInfo.processInfo.physicalMemory) >> 30
    return [4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128].filter { UInt64($0) <= ceiling }
  }

  // MARK: Acts

  @objc private func addRemovePressed() {
    if addRemove.selectedSegment == 0 { showAddMenu() } else { deleteSelected() }
  }

  /// Making a template and bringing in an image are two acts, so `+` offers both rather than one
  /// standing inside the other: an image is tens of gigabytes and minutes away, and a sheet held
  /// open over that wait, or closed by it, is the wrong shape for either.
  private func showAddMenu() {
    let menu = NSMenu()
    let template = menu.addItem(
      withTitle: "New Template…", action: #selector(newTemplate), keyEquivalent: "")
    template.isEnabled = builder == nil
    menu.addItem(.separator())
    let latest = menu.addItem(
      withTitle: "Download the Latest macOS", action: #selector(downloadLatest), keyEquivalent: "")
    let file = menu.addItem(
      withTitle: "Add Image from File…", action: #selector(addImageFromFile), keyEquivalent: "")
    let address = menu.addItem(
      withTitle: "Add Image from Address…", action: #selector(addImageFromAddress),
      keyEquivalent: "")
    for item in [template, latest, file, address] { item.target = self }
    for item in [latest, file, address] { item.isEnabled = download == nil }
    menu.autoenablesItems = false
    let frame = addRemove.frame
    menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: frame.minY), in: addRemove.superview)
  }

  @objc private func downloadLatest() { startDownload(.latest) }

  @objc private func addImageFromFile() {
    guard let window else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.startDownload(.file(url))
    }
  }

  /// An older macOS: Apple keeps each IPSW at an address on its CDN, and one of those is what is
  /// asked for. Only https, and only an IPSW — anything else is not an image a template is made
  /// from.
  @objc private func addImageFromAddress() {
    guard let window else { return }
    let alert = NSAlert()
    alert.messageText = "Add an image from an address"
    alert.informativeText = "The address of a macOS restore image (.ipsw) on Apple's servers."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    field.placeholderString = "https://updates.cdn-apple.com/…/UniversalMac_….ipsw"
    alert.accessoryView = field
    alert.addButton(withTitle: "Download")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let url = URL(string: text), url.scheme == "https",
        url.pathExtension.lowercased() == "ipsw"
      else {
        let refusal = NSAlert()
        refusal.messageText = "That is not the address of a restore image."
        refusal.informativeText = "It has to be an https address ending in .ipsw."
        refusal.beginSheetModal(for: window)
        return
      }
      self?.startDownload(.address(url))
    }
  }

  @objc private func newTemplate() {
    guard let window, builder == nil else { return }
    let sheet = NewMacTemplateSheet()
    sheet.onCreate = { [weak self] request in self?.startBuilding(request) }
    newTemplateSheet = sheet
    window.beginSheet(sheet.window!) { [weak self] _ in self?.newTemplateSheet = nil }
  }

  private func deleteSelected() {
    guard let window, let selected = selectedRow else { return }
    if case .downloading = selected {
      download?.cancel()
      return
    }
    let alert = NSAlert()
    let url: URL
    switch selected {
    case .template(let machine):
      url = machine.url
      alert.messageText = "Delete the template “\(machine.manifest.title)”?"
      let copies = copies(of: machine)
      let freed = machine.privateSize ?? machine.allocatedSize
      if copies.isEmpty {
        alert.informativeText = "This gives back \(Self.size(freed))."
      } else {
        // What it shares stays: the copies made from it hold the same blocks.
        let kept = max(0, machine.allocatedSize - freed)
        let count = copies.count == 1 ? "the machine" : "the \(copies.count) machines"
        alert.informativeText =
          "This gives back about \(Self.size(freed)). The other \(Self.size(kept)) stays in use by"
          + " \(count) copied from it, which keep working."
      }
    case .session(let machine):
      url = machine.url
      alert.messageText = "Delete this session's machine?"
      alert.informativeText = "Everything done inside it is lost."
    case .image(let image):
      url = image
      alert.messageText = "Delete \(Self.imageTitle(image))?"
      alert.informativeText = "It is only needed to make another template from it."
    default:
      return
    }
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      do {
        try FileManager.default.removeItem(at: url)
        if case .session(let machine) = selected {
          for controller in WorkspaceWindowController.all {
            controller.deskForScripting.closeTab(ofMachine: machine.id.uuidString)
          }
        }
      } catch {
        NSAlert(error: error).runModal()
      }
      self?.reload()
    }
  }

  @objc private func revealClicked() {
    switch clickedRow {
    case .template(let machine), .session(let machine):
      NSWorkspace.shared.activateFileViewerSelecting([machine.url])
    case .image(let url):
      NSWorkspace.shared.activateFileViewerSelecting([url])
    default:
      break
    }
  }

  @objc private func deleteClicked() {
    guard table.clickedRow >= 0 else { return }
    table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
    deleteSelected()
  }

  @objc private func copyPasswordClicked() {
    guard table.clickedRow >= 0 else { return }
    table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
    copyPassword()
  }

  private func copyPassword() {
    switch selectedRow {
    case .template(let machine), .session(let machine):
      guard let password = machine.manifest.password else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(password, forType: .string)
    default:
      break
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    switch clickedRow {
    case .template(let machine), .session(let machine):
      if case .template = clickedRow {
        menu.addItem(withTitle: "Rename", action: #selector(renameClicked), keyEquivalent: "")
          .target = self
      }
      menu.addItem(withTitle: "Show in Finder", action: #selector(revealClicked), keyEquivalent: "")
        .target = self
      if machine.manifest.password != nil {
        menu.addItem(
          withTitle: "Copy Password", action: #selector(copyPasswordClicked), keyEquivalent: ""
        ).target = self
      }
      menu.addItem(.separator())
      menu.addItem(withTitle: "Delete…", action: #selector(deleteClicked), keyEquivalent: "")
        .target = self
    case .image:
      menu.addItem(withTitle: "Show in Finder", action: #selector(revealClicked), keyEquivalent: "")
        .target = self
      menu.addItem(.separator())
      menu.addItem(withTitle: "Delete…", action: #selector(deleteClicked), keyEquivalent: "")
        .target = self
    default:
      break
    }
  }

  // MARK: Renaming

  @objc private func renameClicked() {
    beginRename(row: table.clickedRow)
  }

  /// A template's name is typed on its row rather than in a dialog: the row already says what is
  /// being renamed. Only the title changes — the directory is named by id, and every copy and
  /// derived template points at the id — so nothing on disk moves but one line of the manifest.
  private func beginRename(row: Int) {
    guard rows.indices.contains(row), case .template(let machine) = rows[row],
      let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MachineRowView
    else { return }
    renaming = machine
    let field = cell.nameField
    field.isEditable = true
    field.isBordered = false
    field.drawsBackground = false
    field.delegate = self
    window?.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    guard let field = notification.object as? NSTextField, var machine = renaming else { return }
    renaming = nil
    field.isEditable = false
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    // Escape, or nothing typed, keeps the name it had.
    let cancelled =
      (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue
    if !cancelled, !name.isEmpty, name != machine.manifest.title {
      machine.manifest.title = name
      do {
        try machine.save()
      } catch {
        NSAlert(error: error).runModal()
      }
    }
    reload()
    window?.makeFirstResponder(table)
  }

  // MARK: Scripting

  /// One line per thing the window lists, then the build, if there is one.
  var scriptingReport: String {
    var lines = MachineStore.templates().map {
      "template  \($0.manifest.title)  \($0.id.uuidString)"
    }
    lines += MachineStore.sessions().map {
      "session   \($0.manifest.title)  \($0.id.uuidString)"
    }
    lines += MachineStore.images().map { "image     \($0.lastPathComponent)" }
    if builder != nil {
      lines.append("building  \(builder?.request.title ?? "")  \(Self.describe(buildPhase))")
    } else if let buildPhase {
      lines.append("last build  \(Self.describe(buildPhase))")
    }
    return lines.isEmpty ? "(empty)" : lines.joined(separator: "\n")
  }

  /// Start a build from the newest IPSW in Images, with the sheet's defaults. Answers why not,
  /// when it cannot.
  func buildForScripting(title: String) -> String? {
    guard builder == nil else { return "a template is already being made" }
    guard let ipsw = MachineStore.images().first(where: { $0.pathExtension.lowercased() == "ipsw" })
    else { return "no IPSW in Images" }
    startBuilding(
      MacTemplateBuilder.Request(
        title: title, ipsw: ipsw, diskSize: 80 << 30, cpuCount: nil, memorySize: nil,
        username: NSUserName()))
    return nil
  }

  // MARK: Downloading

  private func startDownload(_ source: RestoreImageDownload.Source) {
    guard download == nil else { return }
    let download = RestoreImageDownload(source)
    self.download = download
    download.onChange = { [weak self] in self?.downloadChanged() }
    reload()
    download.start()
  }

  private func downloadChanged() {
    guard let download else { return }
    switch download.state {
    case .done:
      self.download = nil
      reload()
    case .failed(let message):
      self.download = nil
      reload()
      guard message != "Cancelled" else { return }
      let alert = NSAlert()
      alert.messageText = "The image could not be added."
      alert.informativeText = message
      if let window { alert.beginSheetModal(for: window) }
    default:
      if let index = rows.firstIndex(of: .downloading) {
        table.reloadData(forRowIndexes: [index], columnIndexes: [0])
      }
    }
  }

  private static func describe(_ state: RestoreImageDownload.State?) -> String {
    switch state {
    case .locating, nil: return "Finding the latest macOS…"
    case .copying: return "Copying…"
    case .downloading(let fraction): return "Downloading… \(Int(fraction * 100))%"
    case .done: return "Downloaded"
    case .failed(let message): return message
    }
  }

  private static func fraction(_ state: RestoreImageDownload.State?) -> Double? {
    switch state {
    case .downloading(let fraction): return fraction
    case .locating, .copying, nil: return -1
    default: return nil
    }
  }

  static func imageTitle(name: String?) -> String {
    guard let name else { return "macOS" }
    return imageTitle(URL(fileURLWithPath: name))
  }

  // MARK: Building

  private func startBuilding(_ request: MacTemplateBuilder.Request) {
    let builder = MacTemplateBuilder(request: request)
    self.builder = builder
    buildPhase = .preparing
    builder.onPhase = { [weak self] phase in self?.advance(phase) }
    reload()
    if let index = rows.firstIndex(of: .building) {
      table.selectRowIndexes([index], byExtendingSelection: false)
    }
    builder.run()
  }

  private func advance(_ phase: MacTemplateBuilder.Phase) {
    buildPhase = phase
    switch phase {
    case .done:
      builder = nil
      reload()
    case .failed(let message):
      builder = nil
      reload()
      let alert = NSAlert()
      alert.messageText = "The template could not be made."
      alert.informativeText = message
      if let window { alert.beginSheetModal(for: window) }
    default:
      // The one row and the detail, not the whole list: rebuilding it on every percent would
      // take the selection each time.
      if let index = rows.firstIndex(of: .building) {
        table.reloadData(forRowIndexes: [index], columnIndexes: [0])
      }
      update()
    }
  }

  private func shutDownBuild() {
    try? builder?.running?.requestShutdown()
  }

  /// A build goes on without the window, which is only where it is watched from: its machine
  /// belongs to the builder, and its screen goes back to the window nobody sees, so the keystrokes
  /// typed into Recovery still have a view to go to.
  func windowWillClose(_ notification: Notification) {
    builder?.parkScreen()
  }

  // MARK: Words

  private static func describe(_ phase: MacTemplateBuilder.Phase?) -> String {
    switch phase {
    case .preparing, nil: return "Preparing…"
    case .installing(let fraction): return "Installing macOS… \(Int(fraction * 100))%"
    case .firstBoot: return "Setting up the account and the agent…"
    case .disablingSIP: return "Turning SIP off in Recovery…"
    case .granting: return "Giving the agent its permissions…"
    case .setupFailed(let message):
      return "Could not finish by itself (\(message)). Shut it down once it reaches the desktop."
    case .done: return "Ready"
    case .failed(let message): return message
    }
  }

  /// A fraction for a bar, -1 for an indeterminate one, nil for none.
  private static func fraction(_ phase: MacTemplateBuilder.Phase?) -> Double? {
    switch phase {
    case .installing(let fraction): return fraction
    case .preparing, .firstBoot, .disablingSIP, .granting, nil: return -1
    default: return nil
    }
  }

  private static func isSetupFailed(_ phase: MacTemplateBuilder.Phase?) -> Bool {
    if case .setupFailed = phase { return true }
    return false
  }

  private static func symbol(_ kind: MachineKind) -> String {
    kind == .macOS ? "apple.logo" : "pc"
  }

  /// `UniversalMac_27.2_26B123_Restore.ipsw` reads as `macOS 27.2 (26B123)`.
  static func imageTitle(_ url: URL) -> String {
    let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_")
    if url.pathExtension.lowercased() == "ipsw", parts.count >= 3, parts[0] == "UniversalMac" {
      return "macOS \(parts[1]) (\(parts[2]))"
    }
    return url.lastPathComponent
  }

  /// A clone counts in full — APFS says nothing of which blocks are shared — so the size is what
  /// a machine would cost alone, and deleting it may give back less.
  private static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  private static func fileSize(_ url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
    return Int64(values?.totalFileAllocatedSize ?? 0)
  }

  /// The session machines a tab somewhere is running, which are not this window's to delete.
  private static var runningMachineIDs: Set<String> {
    Set(
      WorkspaceWindowController.all.flatMap(\.deskForScripting.machinePanes)
        .filter(\.isRunning).compactMap(\.machineID))
  }
}

/// The rows of a machine's detail, the way System Settings groups them: a rounded panel the width
/// of the pane, a name at each row's leading edge and its value or control at the trailing one.
private final class MachineFormView: NSBox {
  init(rows: [(String, NSView)]) {
    super.init(frame: .zero)
    boxType = .custom
    borderWidth = 0
    cornerRadius = 8
    fillColor = .quaternarySystemFill
    titlePosition = .noTitle
    contentViewMargins = .zero
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 0
    for (index, (name, value)) in rows.enumerated() {
      let label = NSTextField(labelWithString: name)
      label.setContentHuggingPriority(.required, for: .horizontal)
      label.setContentCompressionResistancePriority(.required, for: .horizontal)
      value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      let spacer = NSView()
      spacer.setContentHuggingPriority(.init(1), for: .horizontal)
      let row = NSStackView(views: [label, spacer, value])
      row.orientation = .horizontal
      row.alignment = .centerY
      row.spacing = 12
      row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
      row.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
      stack.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      if index < rows.count - 1 {
        let line = NSBox()
        line.boxType = .separator
        stack.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        stack.setCustomSpacing(0, after: row)
      }
    }
    stack.alignment = .centerX
    contentView = stack
  }

  required init?(coder: NSCoder) { fatalError() }
}

/// The guest account's password on a row of its own: hidden until asked for, since this window is
/// open beside whatever else is on the screen, and put on the pasteboard without being shown.
private final class PasswordRow: NSStackView {
  private let password: String
  private let value = NSTextField(labelWithString: "")
  private let reveal = NSButton()
  private var isShown = false

  init(password: String) {
    self.password = password
    super.init(frame: .zero)
    orientation = .horizontal
    spacing = 6
    value.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    value.isSelectable = true
    reveal.bezelStyle = .accessoryBarAction
    reveal.isBordered = false
    reveal.target = self
    reveal.action = #selector(toggle)
    let copy = NSButton(
      image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Password")!,
      target: self, action: #selector(copyPassword))
    copy.bezelStyle = .accessoryBarAction
    copy.isBordered = false
    copy.toolTip = "Copy Password"
    for view in [value, reveal, copy] { addArrangedSubview(view) }
    update()
  }

  required init?(coder: NSCoder) { fatalError() }

  private func update() {
    // A fixed run of dots: the password's length is no business of someone looking over a shoulder.
    value.stringValue = isShown ? password : String(repeating: "•", count: 12)
    let title = isShown ? "Hide Password" : "Show Password"
    reveal.image = NSImage(
      systemSymbolName: isShown ? "eye.slash" : "eye", accessibilityDescription: title)
    reveal.toolTip = title
  }

  @objc private func toggle() {
    isShown.toggle()
    update()
  }

  @objc private func copyPassword() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(password, forType: .string)
  }
}

/// A row of the list: an icon, a name, a line under it, and — for a template being made — its
/// progress at the trailing edge.
private final class MachineRowView: NSTableCellView {
  /// The name, which a rename edits in place.
  private(set) var nameField = NSTextField(labelWithString: "")

  init(symbol: String, title: String, subtitle: String, progress: Double? = nil, indent: Int = 0) {
    super.init(frame: .zero)
    let icon = NSImageView(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    icon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
    icon.contentTintColor = .secondaryLabelColor
    icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
    let name = nameField
    name.stringValue = title
    name.lineBreakMode = .byTruncatingTail
    let line = NSTextField(labelWithString: subtitle)
    line.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    line.textColor = .secondaryLabelColor
    line.lineBreakMode = .byTruncatingTail
    let text = NSStackView(views: [name, line])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 1
    // Long names give way to the column rather than widening the row past it, where they were
    // clipped with no ellipsis to say so.
    for view in [name, line, text] as [NSView] {
      view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }
    var views: [NSView] = [icon, text]
    if let progress {
      let indicator = NSProgressIndicator()
      indicator.style = .spinning
      indicator.controlSize = .small
      if progress >= 0 {
        indicator.isIndeterminate = false
        indicator.doubleValue = progress * 100
      } else {
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
      }
      views += [NSView(), indicator]
    }
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.spacing = 8
    addSubview(stack)
    stack.pin(
      to: self, insets: NSEdgeInsets(top: 2, left: 4 + CGFloat(indent) * 16, bottom: 2, right: 16))
  }

  required init?(coder: NSCoder) { fatalError() }
}

/// The right side: what the selected row is, in a few facts, and while a template is being made,
/// its progress and its first boot's screen.
private final class MachineDetailView: NSView {
  var onShutDown: (() -> Void)?

  private let icon = NSImageView()
  private let title = NSTextField(labelWithString: "")
  private let status = NSTextField(wrappingLabelWithString: "")
  private let progress = NSProgressIndicator()
  private var factsGrid = NSView()
  /// Where a screen lent by the template build sits.
  private let screen = NSView()
  private let shutDown = NSButton(title: "Shut Down and Finish", target: nil, action: nil)
  private let buttons = NSStackView()
  private let placeholder = NSTextField(labelWithString: "Select a template, session or image.")
  private let content = NSStackView()
  /// Takes the room the screen would have when there is no screen, so the facts stay at the top
  /// rather than being stretched apart to reach the bottom.
  private let filler = NSView()

  init() {
    super.init(frame: .zero)
    icon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
    icon.contentTintColor = .secondaryLabelColor
    title.font = .systemFont(ofSize: 20, weight: .semibold)
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    status.textColor = .secondaryLabelColor
    status.isSelectable = false
    progress.style = .bar
    progress.minValue = 0
    progress.maxValue = 1
    // Scaled to fit rather than asking the guest to match: this is a view of an install and a
    // first boot, and neither can change its resolution — asked to, the view stopped scaling and
    // the guest's 1920×1200 ran off the pane. A session's tab, where the guest is a desktop that
    // can, keeps following its size.
    // The view's intrinsic size is the guest's display, 1920×1200; left to that, it pushed the pane
    // past the window. It takes whatever room is left instead.
    for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
      screen.setContentCompressionResistancePriority(.defaultLow, for: orientation)
      screen.setContentHuggingPriority(.defaultLow, for: orientation)
    }
    shutDown.bezelStyle = .rounded
    shutDown.target = self
    shutDown.action = #selector(shutDownPressed)
    placeholder.textColor = .tertiaryLabelColor

    let header = NSStackView(views: [icon, title])
    header.orientation = .horizontal
    header.spacing = 10
    for view in [shutDown, NSView()] { buttons.addArrangedSubview(view) }
    buttons.orientation = .horizontal
    content.orientation = .vertical
    content.distribution = .fill
    content.alignment = .leading
    content.spacing = 12
    filler.setContentHuggingPriority(.init(1), for: .vertical)
    filler.setContentCompressionResistancePriority(.init(1), for: .vertical)
    for view in [header, status, progress, factsGrid, buttons, screen, filler] as [NSView] {
      content.addArrangedSubview(view)
    }
    content.setCustomSpacing(16, after: header)
    for view in [header, progress, status, screen, buttons] as [NSView] {
      view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48).isActive = true
    }
    screen.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
    content.edgeInsets = NSEdgeInsets(top: 44, left: 24, bottom: 24, right: 24)
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: topAnchor),
      content.leadingAnchor.constraint(equalTo: leadingAnchor),
      content.trailingAnchor.constraint(equalTo: trailingAnchor),
      // To the bottom, so the screen — the one view that gives — fills what the rest leave.
      content.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    placeholder.translatesAutoresizingMaskIntoConstraints = false
    addSubview(placeholder)
    NSLayoutConstraint.activate([
      placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
      placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    showEmpty()
  }

  required init?(coder: NSCoder) { fatalError() }

  func showEmpty() {
    content.isHidden = true
    placeholder.isHidden = false
    for view in screen.subviews { view.removeFromSuperview() }
  }

  func show(
    symbol: String, title: String, status: String?, progress fraction: Double?,
    controls: [(String, NSView)], facts: [(String, String)], screen machineView: NSView?,
    canShutDown: Bool,
    password: String?
  ) {
    content.isHidden = false
    placeholder.isHidden = true
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    self.title.stringValue = title
    self.status.stringValue = status ?? ""
    self.status.isHidden = status == nil
    if let fraction {
      progress.isHidden = false
      if fraction >= 0 {
        progress.isIndeterminate = false
        progress.doubleValue = fraction
      } else {
        progress.isIndeterminate = true
        progress.startAnimation(nil)
      }
    } else {
      progress.isHidden = true
    }
    let rows: [(String, NSView)] =
      controls
      + facts.map { name, value in
        let text = NSTextField(labelWithString: value)
        text.isSelectable = true
        text.lineBreakMode = .byTruncatingMiddle
        text.alignment = .right
        text.textColor = .secondaryLabelColor
        return (name, text)
      }
      + (password.map { [("Password", PasswordRow(password: $0) as NSView)] } ?? [])
    // A new form each time: what a selection shows is different rows, not different values.
    let grid = MachineFormView(rows: rows)
    if let index = content.arrangedSubviews.firstIndex(of: factsGrid) {
      content.removeArrangedSubview(factsGrid)
      factsGrid.removeFromSuperview()
      content.insertArrangedSubview(grid, at: index)
      grid.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48).isActive = true
    }
    factsGrid = grid
    factsGrid.isHidden = rows.isEmpty
    if let machineView {
      if machineView.superview !== screen {
        for view in screen.subviews { view.removeFromSuperview() }
        machineView.removeFromSuperview()
        screen.addSubview(machineView)
        machineView.pin(to: screen)
      }
    } else {
      for view in screen.subviews { view.removeFromSuperview() }
    }
    screen.isHidden = machineView == nil
    filler.isHidden = machineView != nil
    shutDown.isHidden = !canShutDown
    buttons.isHidden = !canShutDown
  }

  @objc private func shutDownPressed() { onShutDown?() }
}

/// What a macOS template needs from a person: what to call it, which macOS, and how big a disk.
/// The account is the Mac's own short name with a password hukan makes up and keeps in the
/// template's manifest.
private final class NewMacTemplateSheet: NSWindowController {
  var onCreate: ((MacTemplateBuilder.Request) -> Void)?
  /// Ask the window to fetch the latest IPSW; the sheet closes, since a download of tens of
  /// gigabytes is minutes away from being something to make a template from.

  private let titleField = NSTextField(string: "")
  private let imagePopUp = NSPopUpButton()
  private let diskField = NSTextField(string: "80")
  private let processorsPopUp = NSPopUpButton()
  private let memoryPopUp = NSPopUpButton()
  private let diskNote = NSTextField(labelWithString: "")
  /// The name the sheet filled in itself, so choosing another image can replace it — and a name
  /// the person typed is left alone.
  private var suggestedTitle = ""

  /// macOS 27.2 alone writes about 22 GB to the disk, and an update unpacks itself beside it
  /// before it installs; below this there is no room left to put anything in. The disk is sparse,
  /// so a larger number costs nothing until the guest writes to it.
  static let minimumDiskGigabytes = 50

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 200), styleMask: [.titled],
      backing: .buffered, defer: true)
    super.init(window: window)
    build()
  }

  required init?(coder: NSCoder) { fatalError() }

  private func build() {
    guard let content = window?.contentView else { return }
    titleField.placeholderString = "macOS"
    // Half the Mac's cores up to eight, and 8 GB: enough for a desktop and a build, and leaves
    // the host room for a second guest. Changeable later from the template's detail.
    for count in VirtualMachinesWindowController.processorChoices {
      processorsPopUp.addItem(withTitle: "\(count)")
      processorsPopUp.lastItem?.tag = count
    }
    processorsPopUp.selectItem(
      withTag: max(2, min(ProcessInfo.processInfo.processorCount / 2, 8)))
    for gb in VirtualMachinesWindowController.memoryChoices {
      memoryPopUp.addItem(withTitle: "\(gb) GB")
      memoryPopUp.lastItem?.tag = gb
    }
    memoryPopUp.selectItem(withTag: 8)
    reloadImages()
    suggestTitle()
    imagePopUp.target = self
    imagePopUp.action = #selector(imageChosen)
    diskField.widthAnchor.constraint(equalToConstant: 60).isActive = true
    diskNote.stringValue = "at least \(Self.minimumDiskGigabytes) GB"
    diskNote.textColor = .secondaryLabelColor
    diskNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    let disk = NSStackView(views: [diskField, NSTextField(labelWithString: "GB"), diskNote])
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Name:"), titleField],
      [NSTextField(labelWithString: "macOS:"), imagePopUp],
      [NSTextField(labelWithString: "Disk:"), disk],
      [NSTextField(labelWithString: "Processors:"), processorsPopUp],
      [NSTextField(labelWithString: "Memory:"), memoryPopUp],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.column(at: 1).width = 280
    let note = NSTextField(
      wrappingLabelWithString:
        "The account “\(NSUserName())” is created on the first boot, logs in by itself and is"
        + " reached over SSH with hukan's key. Its password is made up for you; copy it from the"
        + " template when a prompt in the guest asks for it.")
    note.textColor = .secondaryLabelColor
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
    cancel.keyEquivalent = "\u{1b}"
    let create = NSButton(title: "Create", target: self, action: #selector(create))
    create.keyEquivalent = "\r"
    let buttons = NSStackView(views: [NSView(), cancel, create])
    let stack = NSStackView(views: [grid, note, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    note.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    content.addSubview(stack)
    stack.pin(to: content)
  }

  private func reloadImages() {
    imagePopUp.removeAllItems()
    let urls = MachineStore.images().filter { $0.pathExtension.lowercased() == "ipsw" }
    for url in urls {
      imagePopUp.addItem(withTitle: Self.versionTitle(url))
      imagePopUp.lastItem?.representedObject = url
    }
    // Bringing an image in is the window's `+`, not this sheet's: with none here it says so.
    if urls.isEmpty {
      imagePopUp.addItem(withTitle: "No images — add one with + first")
      imagePopUp.isEnabled = false
    }
  }

  @objc private func imageChosen() {
    suggestTitle()
  }

  /// The image's own name — `macOS 27.2` — as the template's, until someone types one.
  private func suggestTitle() {
    guard let url = imagePopUp.selectedItem?.representedObject as? URL else { return }
    let suggestion = Self.versionTitle(url)
    if titleField.stringValue.isEmpty || titleField.stringValue == suggestedTitle {
      titleField.stringValue = suggestion
    }
    suggestedTitle = suggestion
  }

  /// `macOS 27.2`, without the build the list shows beside it.
  private static func versionTitle(_ url: URL) -> String {
    let title = VirtualMachinesWindowController.imageTitle(url)
    guard let paren = title.range(of: " (") else { return title }
    return String(title[..<paren.lowerBound])
  }

  @objc private func cancel() {
    guard let window else { return }
    window.sheetParent?.endSheet(window)
  }

  @objc private func create() {
    guard let window, let ipsw = imagePopUp.selectedItem?.representedObject as? URL else {
      NSSound.beep()
      return
    }
    guard diskField.integerValue >= Self.minimumDiskGigabytes else {
      diskNote.textColor = .systemRed
      NSSound.beep()
      return
    }
    let title = titleField.stringValue.isEmpty ? Self.versionTitle(ipsw) : titleField.stringValue
    let gigabytes = UInt64(diskField.integerValue)
    let request = MacTemplateBuilder.Request(
      title: title, ipsw: ipsw, diskSize: gigabytes << 30,
      cpuCount: processorsPopUp.selectedItem?.tag,
      memorySize: memoryPopUp.selectedItem.map { UInt64($0.tag) << 30 },
      username: NSUserName())
    window.sheetParent?.endSheet(window)
    onCreate?(request)
  }
}

/// The list, with ⏎ handed to the window: on a row it means rename, as it does in the files panel.
private final class MachineTableView: NSTableView {
  var onReturn: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76 {  // Return, Enter
      onReturn?()
    } else {
      super.keyDown(with: event)
    }
  }
}
