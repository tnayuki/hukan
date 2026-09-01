import XCTest

@testable import Hukan

/// What the composer's slash-command list offers, and when it offers anything at all.
final class CommandCompletionTests: XCTestCase {
  /// A slice of a real engine's list, in the order it sends: skills first, then built-ins.
  private let roster = [
    ClaudeCommand(name: "hyperframes", description: "Video.", argumentHint: "", aliases: []),
    ClaudeCommand(
      name: "code-review", description: "Review the current diff.",
      argumentHint: "[low|medium|high]", aliases: ["review"]),
    ClaudeCommand(name: "clear", description: "Clear.", argumentHint: "[name]", aliases: ["reset"]),
    ClaudeCommand(name: "compact", description: "Compact.", argumentHint: "", aliases: []),
    ClaudeCommand(
      name: "model", description: "Switch model.", argumentHint: "<model>", aliases: []),
    ClaudeCommand(
      name: "__remote-workflow", description: "Internal.", argumentHint: "", aliases: []),
  ]

  // MARK: when a list opens at all

  /// The whole message or nothing: `/` opens it, and a space means the name is settled and what
  /// is being typed now is the argument.
  func testOnlyALeadingSlashWithNoSpaceOpensAList() {
    XCTAssertEqual(CommandCompletion.query(in: "/"), "")
    XCTAssertEqual(CommandCompletion.query(in: "/comp"), "comp")
    XCTAssertNil(CommandCompletion.query(in: "/model sonnet"), "the name is settled")
    XCTAssertNil(CommandCompletion.query(in: "look at Model.swift"), "a slash mid-line is a path")
    XCTAssertNil(CommandCompletion.query(in: " /clear"), "not the first character")
    XCTAssertNil(CommandCompletion.query(in: ""))
  }

  /// A bare `/` offers everything, which is how the list doubles as "what can I even type here".
  func testABareSlashOffersTheWholeList() {
    let all = CommandCompletion.matches("", in: roster)
    XCTAssertEqual(all.count, roster.count - 1, "all but the internal one")
  }

  // MARK: matching

  /// Substring, so what matched is always explicable — but a prefix is what someone typing at a
  /// completion list nearly always means, so those sort first.
  func testPrefixMatchesSortAboveMatchesFoundInside() {
    let names = CommandCompletion.matches("co", in: roster).map(\.name)
    XCTAssertEqual(names, ["code-review", "compact"])

    // "ode" starts `code-review` and sits inside `model`, so both are found and the prefix leads.
    let inside = CommandCompletion.matches("ode", in: roster).map(\.name)
    XCTAssertEqual(inside, ["code-review", "model"])
  }

  /// An alias matches but never gets a row of its own: `/rev` finds `code-review`, and the list
  /// says `code-review`, which is the thing that will actually be sent.
  func testAliasesMatchWithoutBecomingRows() {
    let names = CommandCompletion.matches("rev", in: roster).map(\.name)
    XCTAssertEqual(names, ["code-review"])
    XCTAssertEqual(CommandCompletion.matches("reset", in: roster).map(\.name), ["clear"])
  }

  func testMatchingIgnoresCase() {
    XCTAssertEqual(CommandCompletion.matches("CoMp", in: roster).map(\.name), ["compact"])
  }

  /// The engine's list carries entries meant for a host embedding it rather than for a person to
  /// type. They are never offered.
  func testInternalCommandsAreNeverOffered() {
    XCTAssertTrue(CommandCompletion.matches("remote", in: roster).isEmpty)
    XCTAssertTrue(CommandCompletion.matches("__", in: roster).isEmpty)
  }

  // MARK: what a pick puts in the field

  /// A command that takes an argument leaves the caret past a space, ready for it; one that takes
  /// none is finished as it stands, and a trailing space would only have to be deleted.
  func testTheTrailingSpaceFollowsTheArgumentHint() {
    let review = try! XCTUnwrap(roster.first { $0.name == "code-review" })
    let compact = try! XCTUnwrap(roster.first { $0.name == "compact" })
    XCTAssertEqual(CommandCompletion.completion(for: review), "/code-review ")
    XCTAssertEqual(CommandCompletion.completion(for: compact), "/compact")
  }

  /// hukan runs these two itself, so the engine never lists them — and without them the one
  /// command a signed-out session needs would be the one the list could not offer.
  func testLoginAndLogoutAreAddedByHukan() {
    let names = CommandCompletion.intercepted.map(\.name)
    XCTAssertEqual(names, ["login", "logout"])
    XCTAssertEqual(
      CommandCompletion.matches("log", in: roster + CommandCompletion.intercepted).map(\.name),
      ["login", "logout"])
  }
}

/// Which row a list opens on, and what Return means once it has.
///
/// The mistake this guards is a send that completes instead: the prompt list opens by itself over
/// ordinary text, so a row selected before anything was aimed at it turns the acknowledgements
/// this composer sends most — `yes`, `ok`, `dou`, each of them a query that opens a list — into a
/// prompt nobody chose. The command list is the other case and keeps its selected row: a `/` was
/// typed, so Return can mean nothing else.
final class CompletionSelectionTests: XCTestCase {
  private static let commands = [
    ClaudeCommand(name: "compact", description: "Compact.", argumentHint: "", aliases: []),
    ClaudeCommand(name: "config", description: "Configure.", argumentHint: "", aliases: []),
  ]
  private static let prompts = ["検討して", "これも検討して"]

  /// The host windows the panel and the composer hang off. Held by the case rather than by the
  /// test, since a window that goes away under a child panel takes the view being asked about
  /// with it.
  private var hosts: [NSWindow] = []

  override func tearDown() {
    hosts.removeAll()
    super.tearDown()
  }

  // MARK: - The panel

  @MainActor
  func testACommandListOpensOnItsBestRow() throws {
    let (panel, window) = host()
    defer { panel.dismiss() }
    panel.present(Self.commands.map(CompletionItem.command), below: try anchor(of: window))
    guard case .command(let command)? = panel.selected else {
      return XCTFail("a command list opens with its best row selected")
    }
    XCTAssertEqual(command.name, "compact", "the best match, on the row nearest the field")
    XCTAssertTrue(panel.report.hasSuffix("▸ /compact"), panel.report)
  }

  @MainActor
  func testAPromptListOpensWithNothingSelected() throws {
    let (panel, window) = host()
    defer { panel.dismiss() }
    panel.present(Self.prompts.map(CompletionItem.prompt), below: try anchor(of: window))
    XCTAssertNil(panel.selected, "nothing was aimed at yet")
    XCTAssertFalse(panel.report.contains("▸"), panel.report)
  }

  /// With nothing selected the walk starts from the field, which sits below the bottom row: up
  /// enters at the best match one key away, down wraps round to the far end.
  @MainActor
  func testAnArrowEntersAnUnselectedListAtItsBestRow() throws {
    let (panel, window) = host()
    defer { panel.dismiss() }
    let items = Self.prompts.map(CompletionItem.prompt)
    panel.present(items, below: try anchor(of: window))
    panel.move(-1)
    guard case .prompt(let first)? = panel.selected else { return XCTFail("up selects nothing") }
    XCTAssertEqual(first, "検討して")

    panel.present(items, below: try anchor(of: window))
    panel.move(1)
    guard case .prompt(let last)? = panel.selected else { return XCTFail("down selects nothing") }
    XCTAssertEqual(last, "これも検討して", "the far end of the list")
  }

  // MARK: - What the keys then do

  /// Return is refused while nothing is selected, so it goes on meaning send; Tab takes the best
  /// row, which is the one-key completion Return handed back.
  @MainActor
  func testReturnSendsAndTabCompletesAPromptList() throws {
    let composer = hostedComposer()
    defer { composer.removeFromSuperview() }
    composer.promptSource = { PromptCompletion.index(Self.prompts) }
    composer.typeForScripting("kentou")
    XCTAssertFalse(composer.completionReportForScripting.isEmpty)

    XCTAssertFalse(composer.completionKeyForScripting(.accept), "Return is the composer's")
    XCTAssertEqual(composer.stringValue, "kentou", "and it left the message alone")
    XCTAssertTrue(composer.completionKeyForScripting(.complete))
    XCTAssertEqual(composer.stringValue, "検討して")
  }

  /// The command list is unchanged: Return takes the row it opened on.
  @MainActor
  func testReturnStillTakesACommandRow() throws {
    let composer = hostedComposer()
    defer { composer.removeFromSuperview() }
    composer.commands = Self.commands
    composer.typeForScripting("/comp")
    XCTAssertTrue(composer.completionKeyForScripting(.accept))
    XCTAssertEqual(composer.stringValue, "/compact")
  }

  // MARK: - Fixtures

  @MainActor
  private func host() -> (CommandCompletionPanel, NSWindow) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 200), styleMask: .borderless,
      backing: .buffered, defer: true)
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 200))
    hosts.append(window)
    return (CommandCompletionPanel(), window)
  }

  @MainActor
  private func anchor(of window: NSWindow) throws -> NSView {
    try XCTUnwrap(window.contentView)
  }

  @MainActor
  private func hostedComposer() -> ComposerInput {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 200), styleMask: .borderless,
      backing: .buffered, defer: true)
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 200))
    let composer = ComposerInput(frame: NSRect(x: 0, y: 0, width: 440, height: 40))
    content.addSubview(composer)
    window.contentView = content
    hosts.append(window)
    return composer
  }
}
