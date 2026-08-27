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
