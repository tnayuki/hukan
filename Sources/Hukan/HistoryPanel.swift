import AppKit

/// The History section, at the foot of the files panel: what this worktree has committed past its
/// base branch, newest first.
///
/// The panel is the worktree's index and this is its second half — the tree says which files the
/// task touches, this says what the task has already put down. Both are navigation only: a pick
/// opens a tab on the desk, which is where a commit is actually read, the same rule that keeps a
/// file editable in exactly one place.
///
/// It carries no field and no dates, but it does page: the first read is one page of commits from
/// the tip, and scrolling to the end of the rows asks for the next. It was bounded at the base
/// branch once — `<base>..HEAD` — and that made the section vanish the moment the branch was
/// pushed, which is exactly when what landed is worth looking at. The base is still read, but as a
/// rule *within* the list marking where this branch's own work began; below it the log carries on
/// into what the branch was cut from.
final class HistoryPanelViewController: NSViewController {
  /// A single click / arrow-key move: preview the commit on the desk.
  var onSelect: ((String) -> Void)?
  /// A double-click or Return: open it as a lasting tab.
  var onActivate: ((String) -> Void)?
  /// Scrolled to the end of what has been read: walk further back.
  var onLoadMore: (() -> Void)?

  private let table = HistoryTableView()
  private let scroll = NSScrollView()
  private var commits: [Git.Commit] = []
  private var base: String?
  private var forkIndex = 0
  private var truncated = false
  private var tags: [String: [String]] = [:]
  /// What the table draws, commits and the rules between them, in the order they are drawn. Built
  /// once per list rather than worked out per row: with two kinds of rule in it the arithmetic
  /// that mapped a row to a commit stops being an offset and starts being a map.
  private var rows: [Row] = []

  /// A row of the section: a commit, or one of the two rules drawn between commits — the fork
  /// point, and a tag naming the commit directly below it.
  private enum Row: Equatable {
    case commit(Int)
    case fork
    case tags([String])
  }
  /// How many commits were on the list when a page was asked for, or nil when none is
  /// outstanding. A page is *outstanding* until one that answers it arrives, which is what the
  /// count is for: the section is redrawn constantly — every FSEvents batch, and once more from
  /// inside the very call that asks for the page — so "a refresh happened" is not the same
  /// question as "the page arrived", and answering the first is how one flick came to launch
  /// dozens of reads.
  private var pagingFrom: Int?
  /// True while the panel moves its own selection, so the delegate does not open the commit —
  /// the files tree's guard, for the same reason. Restoring the row after a refresh posts the
  /// very notification a person's click does, and without this a commit landing on the list threw
  /// a diff onto the desk on its own.
  private var isSelectingQuietly = false
  private var operation: Git.Operation?
  private let operationLabel = NSTextField(labelWithString: "")
  private lazy var operationHeight = operationLabel.heightAnchor.constraint(equalToConstant: 0)

  private static let rowHeight: CGFloat = 20
  /// The hairline, one row, and room for the banner: what the section may be dragged down to
  /// before it is worth folding instead. It no longer sets its own height — the panel's divider
  /// does, which is what lets a log be read at more than a keyhole's worth of rows.
  static let minimumHeight: CGFloat = 21

  /// The rule naming what this branch was cut from, drawn between the commits it has of its own
  /// and the ones it inherited — the one structural fact a lane graph would have carried, said in
  /// a row rather than in a column of ancestry. A checkout with nothing of its own (in sync with
  /// its remote) has nothing to divide, so it draws no rule at all.
  /// …and a list cut off before the fork was reached draws none either: the count is capped at
  /// what was read, so a rule on the last row would be claiming to know where a branch began when
  /// the walk never got there.
  private var showsForkPoint: Bool {
    base != nil && forkIndex > 0 && (forkIndex < commits.count || !truncated)
  }
  private var rowCount: Int { rows.count }

  /// The rows, laid out once: each commit, preceded by a tag rule when the repository names it
  /// and by the fork-point rule where the branch's own work stops. A tag sits *above* the commit
  /// it names, which is where the fork rule already sits relative to the base tip — the line
  /// reads "the ref below this is what everything above is not in yet".
  private func layOutRows() {
    var laid: [Row] = []
    for index in commits.indices {
      if showsForkPoint && index == forkIndex { laid.append(.fork) }
      if let names = tags[commits[index].oid] { laid.append(.tags(names)) }
      laid.append(.commit(index))
    }
    // A fork point at the very end of what was read has no commit under it, and still marks
    // where the branch's work stopped.
    if showsForkPoint && forkIndex == commits.count { laid.append(.fork) }
    rows = laid
  }

  /// The commit a row shows, or nil for a rule sitting between two of them.
  private func commitIndex(forRow row: Int) -> Int? {
    // Not a guard against paranoia: `selectedRow` is -1 when nothing is selected, and that is
    // what this is asked about after every refresh.
    guard rows.indices.contains(row), case .commit(let index) = rows[row] else { return nil }
    return index
  }

  private func row(forCommit index: Int) -> Int {
    rows.firstIndex(of: .commit(index)) ?? index
  }

  private var selectedCommit: Git.Commit? {
    commitIndex(forRow: table.selectedRow).map { commits[$0] }
  }

  /// Nothing to show means nothing drawn at all — the panel folds the section away.
  var isEmpty: Bool { commits.isEmpty }

  /// Whether there is a reason to draw the section: commits, or something git has underway. A
  /// worktree mid-rebase has *no* commits to list — that is the whole trouble — and is exactly
  /// when the section must be on screen.
  var hasAnythingToShow: Bool { !commits.isEmpty || operation != nil }

  override func loadView() {
    let column = NSTableColumn(identifier: .init("commit"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = Self.rowHeight
    table.intercellSpacing = NSSize(width: 0, height: 0)
    table.style = .plain
    table.selectionHighlightStyle = .regular
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(activateSelected)
    table.onActivate = { [weak self] in self?.activateSelected() }
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
      object: scroll.contentView)

    // A hairline over the header, so the section reads as its own thing under the tree rather
    // than as more tree.
    let hairline = NSView()
    hairline.wantsLayer = true
    hairline.layer?.backgroundColor = NSColor.separatorColor.cgColor
    hairline.translatesAutoresizingMaskIntoConstraints = false

    // What git has underway, pinned above the rows rather than scrolling with them: it is the
    // reason the rows read the way they do, so it must not be the first thing dragged out of
    // sight when the section is made short.
    operationLabel.font = .systemFont(ofSize: 11, weight: .medium)
    operationLabel.textColor = .systemOrange
    operationLabel.lineBreakMode = .byTruncatingTail
    operationLabel.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(hairline)
    container.addSubview(operationLabel)
    container.addSubview(scroll)
    NSLayoutConstraint.activate([
      hairline.topAnchor.constraint(equalTo: container.topAnchor),
      hairline.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      hairline.heightAnchor.constraint(equalToConstant: 1),
      operationLabel.topAnchor.constraint(equalTo: hairline.bottomAnchor),
      operationLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
      operationLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
      operationHeight,
      scroll.topAnchor.constraint(equalTo: operationLabel.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    view = container
  }

  /// Point the section at a worktree's history. A different list redraws; the same one is left
  /// alone, so a routine refresh does not drop the selection.
  func show(history: Git.History) {
    loadViewIfNeeded()
    let changed =
      history.commits != commits || history.base != base || history.forkIndex != forkIndex
      || history.operation != operation || history.tags != tags
    // Which commit is under the selection — read against the list the selection was made in, and
    // so before that list is replaced. Reading it afterwards is reading a new list at an old
    // index, which is the same mistake as restoring by index, one step earlier.
    let selected = selectedCommit?.oid
    commits = history.commits
    base = history.base
    forkIndex = history.forkIndex
    truncated = history.truncated
    operation = history.operation
    tags = history.tags
    layOutRows()
    updateOperationBanner()
    // Only a list that actually grew — or one that has reached the end — answers the page. The
    // request stands until then, whatever else redraws the section in the meantime.
    if let asked = pagingFrom, commits.count > asked || !truncated { pagingFrom = nil }
    guard changed else { return }
    table.reloadData()
    // By oid, never by index: a commit landing on top shifts every row down, and the table keeps
    // the *index* it had — which now names a different commit. Restoring by index is how a
    // refresh came to open a diff nobody asked for.
    isSelectingQuietly = true
    if let selected, let index = commits.firstIndex(where: { $0.oid == selected }) {
      table.selectRowIndexes([row(forCommit: index)], byExtendingSelection: false)
    } else {
      // The commit is gone — amended, or rebased away, which this repository's own history does
      // constantly. Leaving the index selected would leave it pointing at whatever moved into
      // that row.
      // `deselectAll` answers to `allowsEmptySelection`; selecting nothing does not, and this
      // has to hold whatever the table's mood.
      table.selectRowIndexes([], byExtendingSelection: false)
    }
    isSelectingQuietly = false
  }

  /// `Rebasing task — 3 of 7`. The branch is named because a rebase detaches HEAD, so this line
  /// is where the worktree's own name is while it runs; the step is named when git counts one.
  private func updateOperationBanner() {
    guard let operation else {
      operationLabel.stringValue = ""
      operationHeight.constant = 0
      return
    }
    let verb: String
    switch operation.kind {
    case .rebase: verb = "Rebasing"
    case .merge: verb = "Merging"
    case .cherryPick: verb = "Cherry-picking"
    case .revert: verb = "Reverting"
    case .bisect: verb = "Bisecting"
    case .applyMailbox: verb = "Applying patches"
    }
    var text = verb
    if let branch = operation.branch { text += " \(branch)" }
    if let step = operation.step, let total = operation.total { text += " — \(step) of \(total)" }
    operationLabel.stringValue = text
    operationLabel.toolTip = text
    operationHeight.constant = 18
  }

  @objc private func activateSelected() {
    guard let commit = selectedCommit else { return }
    onActivate?(commit.oid)
  }

  /// Scrolled to the last rows read: ask for the next page. The section is a keyhole onto a log
  /// that has no end, so the rows arrive as they are reached rather than all at once — and the
  /// request is made a little before the end, so the list does not stop dead while it waits.
  @objc private func scrolled() {
    guard truncated, pagingFrom == nil else { return }
    let visible = scroll.contentView.bounds
    guard visible.maxY >= table.bounds.height - Self.rowHeight * 2 else { return }
    pagingFrom = commits.count
    onLoadMore?()
  }
}

extension HistoryPanelViewController: NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

  /// The fork-point rule is a caption, not a commit — arrowing through the list steps over it.
  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    commitIndex(forRow: row) != nil
  }

  func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
    guard rows.indices.contains(row) else { return nil }
    let index: Int
    switch rows[row] {
    case .fork: return ruleRow(label: base ?? "", tooltip: "Branched from \(base ?? "")")
    case .tags(let names):
      // Two names fit the panel at its narrowest; past that the row counts the rest rather than
      // running the list out to an ellipsis, which took the rules and the glyph with it and left
      // a line of grey text reading as no kind of row at all. The whole list is in the tooltip.
      let text =
        names.count <= 2
        ? names.joined(separator: ", ") : "\(names[0]) +\(names.count - 1)"
      return ruleRow(
        label: text, tooltip: "Tagged \(names.joined(separator: ", "))", symbol: "tag")
    case .commit(let commitIndex): index = commitIndex
    }
    let commit = commits[index]

    // The marker column stays there whether or not it draws anything, so the hashes line up
    // under each other rather than stepping in and out with the dots.
    let marker = NSTextField(labelWithString: commit.isPushed == false ? "●" : " ")
    marker.font = .systemFont(ofSize: 7)
    marker.textColor = .tertiaryLabelColor
    marker.toolTip = commit.isPushed == false ? "Not pushed" : nil
    marker.setContentHuggingPriority(.required, for: .horizontal)

    let hash = NSTextField(labelWithString: commit.shortOID)
    hash.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
    hash.textColor = .tertiaryLabelColor
    hash.setContentHuggingPriority(.required, for: .horizontal)

    let summary = NSTextField(labelWithString: commit.summary)
    summary.font = .systemFont(ofSize: 11)
    summary.textColor = .labelColor
    summary.lineBreakMode = .byTruncatingTail
    summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let stack = NSStackView(views: [marker, hash, summary])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 5
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
    stack.toolTip = commit.summary
    return stack
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !isSelectingQuietly, let commit = selectedCommit else { return }
    onSelect?(commit.oid)
  }

  /// `──── origin/main ────`, and `──── ⌸ v0.2.2 ────`: a ref naming the commit below it. The
  /// fork point says where this worktree's work parts from what it was branched off; a tag says
  /// what the commit under it was released as, and carries a glyph so the two rules cannot be
  /// read for each other.
  private func ruleRow(label text: String, tooltip: String, symbol: String? = nil) -> NSView {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 10)
    label.textColor = .tertiaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.setContentHuggingPriority(.required, for: .horizontal)

    var middle: [NSView] = [label]
    if let symbol,
      let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    {
      let glyph = NSImageView(image: image)
      glyph.symbolConfiguration = .init(pointSize: 9, weight: .regular)
      glyph.contentTintColor = .tertiaryLabelColor
      glyph.setContentHuggingPriority(.required, for: .horizontal)
      // It is what says the row is a tag rather than the fork point, so it is the last thing the
      // row may give up — a squeezed stack dropped it before the name it belongs to.
      glyph.setContentCompressionResistancePriority(.required, for: .horizontal)
      middle.insert(glyph, at: 0)
    }

    let leading = rule()
    let trailing = rule()
    let row = NSStackView(views: [leading] + middle + [trailing])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 4
    row.distribution = .fill
    row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
    row.setCustomSpacing(6, after: leading)
    row.setCustomSpacing(6, after: label)
    row.toolTip = tooltip
    // Both halves take the slack, or the stack hands it all to one and the name slides to an edge.
    leading.widthAnchor.constraint(equalTo: trailing.widthAnchor).isActive = true
    return row
  }

  private func rule() -> NSView {
    let line = NSView()
    line.wantsLayer = true
    line.layer?.backgroundColor = NSColor.separatorColor.cgColor
    line.translatesAutoresizingMaskIntoConstraints = false
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    line.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    line.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    return line
  }
}

/// Return opens the selected commit as a lasting tab — the same dive the files tree makes.
private final class HistoryTableView: NSTableView {
  var onActivate: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76 {
      onActivate?()
      return
    }
    super.keyDown(with: event)
  }
}
