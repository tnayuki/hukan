import AppKit

// MARK: - Right: files (diff or source)

final class FileSidebarViewController: NSViewController, NSOutlineViewDataSource,
  NSOutlineViewDelegate
{
  let modeControl = NSSegmentedControl(
    labels: ["Changed", "All"], trackingMode: .selectOne, target: nil, action: nil)
  var onSelectFile: ((String) -> Void)?
  var onChangeMode: ((FileSidebarMode) -> Void)?

  private let outlineView = NSOutlineView()
  private var nodes: [FileNode] = []
  private var isUpdatingSelection = false

  override func loadView() {
    modeControl.selectedSegment = 0
    modeControl.controlSize = .small
    modeControl.target = self
    modeControl.action = #selector(modeChanged)

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("files"))
    column.resizingMask = .autoresizingMask
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column
    outlineView.headerView = nil
    outlineView.style = .inset
    outlineView.rowHeight = 22
    outlineView.indentationPerLevel = 12
    outlineView.dataSource = self
    outlineView.delegate = self

    let scrollView = NSScrollView()
    scrollView.documentView = outlineView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    let header = HeaderBar(views: [modeControl])
    header.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(header)
    container.addSubview(scrollView)
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      header.topAnchor.constraint(equalTo: container.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    view = container
  }

  @objc private func modeChanged() {
    onChangeMode?(modeControl.selectedSegment == 0 ? .changed : .all)
  }

  func show(worktree: Worktree?, mode: FileSidebarMode) {
    loadViewIfNeeded()
    modeControl.selectedSegment = mode == .changed ? 0 : 1

    guard let worktree else {
      nodes = []
      outlineView.reloadData()
      return
    }

    nodes = Self.buildNodes(worktree: worktree, mode: mode)

    isUpdatingSelection = true
    outlineView.reloadData()
    if mode == .all {
      // Expanding everything is expensive; open only the shallow level.
      for node in nodes where node.isDirectory { outlineView.expandItem(node) }
    }
    isUpdatingSelection = false
  }

  /// Rebuild the list after the files changed on disk, keeping the selection, the open
  /// directories and the scroll where they were. `show` rebuilds those from scratch — right
  /// for a worktree switch, wrong for an agent editing several times a minute, which would
  /// yank the selection and scroll away mid-read. Items are matched by relative path, not
  /// object identity, since the rebuild makes fresh `FileNode`s.
  func refresh(worktree: Worktree, mode: FileSidebarMode) {
    loadViewIfNeeded()
    modeControl.selectedSegment = mode == .changed ? 0 : 1

    let selectedPath = (outlineView.item(atRow: outlineView.selectedRow) as? FileNode)?
      .relativePath
    let expanded = expandedRelativePaths()
    let scrollY = outlineView.enclosingScrollView?.contentView.bounds.origin.y ?? 0

    nodes = Self.buildNodes(worktree: worktree, mode: mode)

    isUpdatingSelection = true
    outlineView.reloadData()
    applyExpansion(expanded)
    if let selectedPath, let row = row(forRelativePath: selectedPath) {
      outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    outlineView.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: scrollY))
    isUpdatingSelection = false
  }

  private static func buildNodes(worktree: Worktree, mode: FileSidebarMode) -> [FileNode] {
    switch mode {
    case .changed:
      // Changes are the review path, so list them flat rather than buried in a tree.
      return worktree.changedFiles.map {
        FileNode(
          name: $0.path, relativePath: $0.path, isDirectory: false,
          added: $0.added, removed: $0.removed)
      }
    case .all:
      var changed: [String: ChangedFile] = [:]
      for file in worktree.changedFiles { changed[file.path] = file }
      return FileNode.tree(paths: worktree.trackedFiles, changed: changed)
    }
  }

  /// The relative paths of the directories currently open, read off the live tree before it is
  /// rebuilt.
  private func expandedRelativePaths() -> Set<String> {
    var result: Set<String> = []
    func walk(_ list: [FileNode]) {
      for node in list where node.isDirectory {
        if outlineView.isItemExpanded(node) { result.insert(node.relativePath) }
        walk(node.children)
      }
    }
    walk(nodes)
    return result
  }

  /// Re-open the directories that were open before the rebuild. A parent is expanded before its
  /// children are reached, so a nested directory can be restored too.
  private func applyExpansion(_ expanded: Set<String>) {
    func walk(_ list: [FileNode]) {
      for node in list where node.isDirectory && expanded.contains(node.relativePath) {
        outlineView.expandItem(node)
        walk(node.children)
      }
    }
    walk(nodes)
  }

  private func row(forRelativePath path: String) -> Int? {
    (0..<outlineView.numberOfRows).first {
      (outlineView.item(atRow: $0) as? FileNode)?.relativePath == path
    }
  }

  /// Move the highlight to `path` without treating it as a user pick (no `onSelectFile`), so a
  /// cancelled switch can put the selection back on the file that is still open.
  func select(path: String) {
    loadViewIfNeeded()
    guard let row = row(forRelativePath: path) else { return }
    isUpdatingSelection = true
    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    isUpdatingSelection = false
  }

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    (item as? FileNode)?.children.count ?? nodes.count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    (item as? FileNode)?.children[index] ?? nodes[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    !((item as? FileNode)?.children.isEmpty ?? true)
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
    -> NSView?
  {
    guard let node = item as? FileNode else { return nil }
    let cell = NSTableCellView()

    let icon = NSImageView()
    icon.image = NSImage(
      systemSymbolName: node.isDirectory ? "folder" : "doc", accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 10, weight: .regular)
    icon.contentTintColor = .tertiaryLabelColor

    // In flat mode the relative path is the name. Without dimming the directory and
    // leading with the file name, the rows are unreadable.
    let label = NSTextField(labelWithAttributedString: Self.pathText(node.name))
    label.lineBreakMode = .byTruncatingTail
    label.cell?.truncatesLastVisibleLine = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    var views: [NSView] = [icon, label]
    if let added = node.added, let removed = node.removed, added + removed > 0 {
      let stat = NSTextField(
        labelWithAttributedString: diffstatText(added: added, removed: removed))
      stat.setContentCompressionResistancePriority(.required, for: .horizontal)
      views.append(stat)
    }

    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 5
    cell.addSubview(row)
    row.pin(to: cell)
    return cell
  }

  /// Lead with the file name. Starting from the path means that when width runs out it is
  /// the file name — the part that matters — that gets truncated away.
  private static func pathText(_ path: String) -> NSAttributedString {
    let font = NSFont.systemFont(ofSize: 12)
    let name = (path as NSString).lastPathComponent
    let directory = String(path.dropLast(name.count + 1))
    let text = NSMutableAttributedString(
      string: name, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    if !directory.isEmpty {
      text.append(
        NSAttributedString(
          string: "  " + directory,
          attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor,
          ]))
    }
    return text
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    guard !isUpdatingSelection,
      let node = outlineView.item(atRow: outlineView.selectedRow) as? FileNode,
      !node.isDirectory
    else { return }
    onSelectFile?(node.relativePath)
  }
}

final class FileContentViewController: NSViewController {
  private let modeToggle = NSSegmentedControl(
    labels: ["Diff", "Source"], trackingMode: .selectOne, target: nil, action: nil)
  private let fileLabel = NSTextField(labelWithString: "editor.rs")
  private let scrollView: NSScrollView
  private let textView: NSTextView
  private(set) var showsDiff = true
  private var hasChanges = false
  private var worktree: Worktree?
  private var path: String?
  /// The open file's bare name, kept apart from the label so the unsaved-edit marker can ride
  /// in front of it without being baked into the name.
  private var baseFileName = ""
  /// True once the reader has typed into the source without it being written back yet. Guards
  /// the on-disk refresh (an agent editing the same worktree must not clobber an unsaved edit)
  /// and gates the save.
  private var isDirty = false
  /// Fired after a save lands, so the column can re-ask git and the file's changed state catches
  /// up (an FSEvents IgnoreSelf drops our own write, so nothing else would notice it).
  var onSaved: (() -> Void)?

  init() {
    (scrollView, textView) = makeTranscriptTextView()
    super.init(nibName: nil, bundle: nil)
    textView.allowsUndo = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func loadView() {
    modeToggle.selectedSegment = 0
    modeToggle.controlSize = .small
    modeToggle.target = self
    modeToggle.action = #selector(modeChanged)
    fileLabel.font = .systemFont(ofSize: 12, weight: .medium)

    let header = HeaderBar(views: [modeToggle, fileLabel])
    header.translatesAutoresizingMaskIntoConstraints = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(header)
    container.addSubview(scrollView)
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      header.topAnchor.constraint(equalTo: container.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    view = container
    render()
  }

  @objc private func modeChanged() {
    // Leaving an edited Source for the Diff would drop the edit; ask, and put the control back
    // on Cancel.
    guard confirmLeavingCurrentFile() else {
      modeToggle.selectedSegment = showsDiff ? 0 : 1
      return
    }
    showsDiff = modeToggle.selectedSegment == 0
    render()
  }

  func toggleDiffMode() {
    loadViewIfNeeded()
    guard confirmLeavingCurrentFile() else { return }
    showsDiff.toggle()
    modeToggle.selectedSegment = showsDiff ? 0 : 1
    render()
  }

  /// The open file, so the column can fall back to it when a switch is cancelled.
  var currentPath: String? { path }

  /// Before an unsaved edit is lost, ask. Save writes it, Don't Save drops it, Cancel keeps it
  /// and returns false so the caller aborts the move; a no-op returning true when nothing is
  /// dirty. The one modal in the file pane, and only over an otherwise unrecoverable loss.
  func confirmLeavingCurrentFile() -> Bool {
    guard isDirty else { return true }
    let alert = NSAlert()
    alert.messageText = "Save the changes to “\(baseFileName)”?"
    alert.informativeText = "Your edits will be lost if you don’t save them."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
    alert.addButton(withTitle: "Don’t Save")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      save()
      return true
    case .alertThirdButtonReturn:
      isDirty = false
      updateFileLabel()
      return true
    default:
      return false
    }
  }

  @objc private func textChanged() {
    guard textView.isEditable else { return }
    isDirty = true
    updateFileLabel()
  }

  /// Whether the open file has an unsaved edit, so the Save menu item can enable itself.
  var hasUnsavedEdit: Bool { isDirty }

  /// Write the edited source back to disk, atomically, and let the column re-ask git so the
  /// file's changed state updates. Driven by Cmd+S, or by leaving the file. A no-op unless there
  /// is an unsaved edit to a real file, and the view is only editable in Source mode — so this
  /// never writes a colored diff back.
  func save() {
    guard isDirty, textView.isEditable, let worktree, let path else { return }
    let url = worktree.url.appendingPathComponent(path)
    do {
      try textView.string.write(to: url, atomically: true, encoding: .utf8)
      isDirty = false
      updateFileLabel()
      onSaved?()
    } catch {
      NSSound.beep()
    }
  }

  private func updateFileLabel() {
    fileLabel.stringValue = (isDirty ? "• " : "") + baseFileName
  }

  /// Changed files default to the diff, unchanged files to the source.
  func show(worktree: Worktree?, path: String?) {
    loadViewIfNeeded()
    // The caller confirms any unsaved edit before switching (see the column); the new file
    // starts clean.
    isDirty = false
    self.worktree = worktree
    self.path = path
    baseFileName = path.map { ($0 as NSString).lastPathComponent } ?? ""
    updateFileLabel()
    if let worktree, let path {
      hasChanges = worktree.changedFiles.contains { $0.path == path }
      showsDiff = hasChanges
    } else {
      hasChanges = false
    }
    modeToggle.selectedSegment = showsDiff ? 0 : 1
    modeToggle.isEnabled = path != nil
    render()
  }

  /// Re-read the open file after it changed on disk, keeping the reader where they were
  /// scrolled and honouring their Diff/Source choice. Unlike `show` it does not force the mode
  /// or jump to the top — an agent saving mid-read should refresh the text under the eye, not
  /// yank the view around. A file that lost its changes falls back to source on its own, since
  /// `render` only diffs when there is something to diff.
  func refreshCurrent() {
    loadViewIfNeeded()
    // An unsaved edit outweighs the on-disk copy — never overwrite it from a refresh.
    guard !isDirty else { return }
    guard let worktree, path != nil else { return }
    hasChanges = worktree.changedFiles.contains { $0.path == path }
    modeToggle.selectedSegment = (showsDiff && hasChanges) ? 0 : 1
    render(preservingScroll: true)
  }

  func render(preservingScroll: Bool = false) {
    loadViewIfNeeded()
    guard let worktree, let path else {
      textView.isEditable = false
      textView.textStorage?.setAttributedString(
        NSAttributedString(
          string: "",
          attributes: [.font: monospace]))
      return
    }
    let url = worktree.url
    // Uncommitted work only — the diff is measured against HEAD, not a merge base, so it
    // shows what has not yet been committed rather than the whole branch's history.
    let base = "HEAD"
    let wantsDiff = showsDiff && hasChanges
    let restoreY = preservingScroll ? scrollView.contentView.bounds.origin.y : nil
    DispatchQueue.global(qos: .userInitiated).async {
      let text =
        wantsDiff
        ? Git.diff(at: url, path: path, since: base)
        : Git.fileContents(at: url, path: path)
      let rendered = wantsDiff ? Self.renderDiff(text ?? "") : Self.renderSource(text ?? "")
      DispatchQueue.main.async { [weak self] in
        guard let self, self.path == path else { return }
        self.textView.textStorage?.setAttributedString(rendered)
        // Source is editable; a colored diff is not. Typed text inherits the source's monospace.
        self.textView.isEditable = !wantsDiff
        self.textView.typingAttributes = [.font: monospace, .foregroundColor: NSColor.labelColor]
        self.isDirty = false
        self.updateFileLabel()
        self.textView.scroll(restoreY.map { NSPoint(x: 0, y: $0) } ?? .zero)
      }
    }
  }

  /// Color a unified diff by its line prefixes.
  private static func renderDiff(_ raw: String) -> NSAttributedString {
    let output = NSMutableAttributedString()
    for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
      var attributes: [NSAttributedString.Key: Any] = [.font: monospace]
      if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ")
        || line.hasPrefix("index ")
      {
        attributes[.foregroundColor] = NSColor.quaternaryLabelColor
      } else if line.hasPrefix("@@") {
        attributes[.foregroundColor] = NSColor.tertiaryLabelColor
      } else if line.hasPrefix("+") {
        attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.16)
        attributes[.foregroundColor] = NSColor.labelColor
      } else if line.hasPrefix("-") {
        attributes[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.14)
        attributes[.foregroundColor] = NSColor.labelColor
      } else {
        attributes[.foregroundColor] = NSColor.secondaryLabelColor
      }
      output.append(NSAttributedString(string: String(line) + "\n", attributes: attributes))
    }
    return output
  }

  private static func renderSource(_ raw: String) -> NSAttributedString {
    NSAttributedString(
      string: raw, attributes: [.font: monospace, .foregroundColor: NSColor.labelColor])
  }
}

/// Let NSSplitViewController own the sidebar/content split. Adding width constraints to an
/// NSSplitView by hand collides with the autoresizing-derived ones and sends Auto Layout
/// into infinite recursion — which is exactly how this crashed.
final class FileColumnViewController: NSSplitViewController {
  var workspace: Workspace?
  var onNeedsReload: (() -> Void)?

  private let sidebar = FileSidebarViewController()
  private let content = FileContentViewController()

  override func viewDidLoad() {
    super.viewDidLoad()
    splitView.isVertical = true
    splitView.dividerStyle = .thin

    let sidebarItem = NSSplitViewItem(viewController: sidebar)
    sidebarItem.minimumThickness = 240
    sidebarItem.maximumThickness = 380
    sidebarItem.holdingPriority = .init(261)
    let contentItem = NSSplitViewItem(viewController: content)
    contentItem.minimumThickness = 260
    contentItem.holdingPriority = .init(260)

    addSplitViewItem(sidebarItem)
    addSplitViewItem(contentItem)

    sidebar.onSelectFile = { [weak self] path in
      guard let self, let workspace = self.workspace,
        let worktreeID = workspace.selectedWorktreeID
      else { return }
      // A pending edit gets the Save / Don't Save / Cancel decision before the file changes
      // under it; on Cancel, put the highlight back on the file still open.
      guard self.content.confirmLeavingCurrentFile() else {
        if let current = self.content.currentPath { self.sidebar.select(path: current) }
        return
      }
      self.content.show(worktree: workspace.worktree(id: worktreeID), path: path)
    }
    sidebar.onChangeMode = { [weak self] mode in
      self?.workspace?.fileSidebarMode = mode
      self?.reload()
    }
    content.onSaved = { [weak self] in self?.onNeedsReload?() }
  }

  private var hasPlacedDivider = false

  /// The file list's width, so it can be saved with the window and put back.
  var sidebarWidth: CGFloat {
    get { splitView.subviews.first?.frame.width ?? sidebar.view.frame.width }
    set {
      guard newValue > 0 else { return }
      hasPlacedDivider = true
      splitView.setPosition(newValue, ofDividerAt: 0)
    }
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    // The diff is the main event, so keep the file list at sidebar width.
    guard !hasPlacedDivider, splitView.bounds.width > 420 else { return }
    hasPlacedDivider = true
    splitView.setPosition(250, ofDividerAt: 0)
  }

  func reload() {
    loadViewIfNeeded()
    guard let workspace else { return }
    let worktree = workspace.selectedWorktreeID.flatMap { workspace.worktree(id: $0) }

    // Query git for a worktree that has not been loaded yet, then redraw.
    if let worktree, !worktree.hasLoadedFiles {
      workspace.loadFiles(worktreeID: worktree.id) { [weak self] in
        self?.onNeedsReload?()
      }
    }

    sidebar.show(worktree: worktree, mode: workspace.fileSidebarMode)
    if content.isViewLoaded, worktree == nil {
      content.show(worktree: nil, path: nil)
    }
  }

  /// The selected worktree's files changed on disk. Re-show the list and the open file in
  /// place — keeping selection, disclosure and scroll — where a full `reload` would rebuild
  /// them from scratch and fight an agent editing several times a minute.
  func refreshInPlace() {
    loadViewIfNeeded()
    guard let workspace,
      let worktree = workspace.selectedWorktreeID.flatMap({ workspace.worktree(id: $0) })
    else { return }
    sidebar.refresh(worktree: worktree, mode: workspace.fileSidebarMode)
    content.refreshCurrent()
  }

  func toggleDiffMode() {
    loadViewIfNeeded()
    content.toggleDiffMode()
  }

  /// Cmd+S from the menu: write the open source file back to disk.
  func saveCurrent() {
    loadViewIfNeeded()
    content.save()
  }

  /// The content pane's current mode, read by the View menu's state-reflecting title.
  var isShowingDiff: Bool { content.showsDiff }
  /// Whether the open file has an unsaved edit, so the Save menu item can validate itself.
  var hasUnsavedEdit: Bool { content.hasUnsavedEdit }
}
