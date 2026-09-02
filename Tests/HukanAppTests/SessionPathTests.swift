import XCTest

@testable import Hukan

/// The two charter "traps" that are pure string logic: the transcript directory slug (which is
/// Claude Code's rule and not an approximation of it) and pulling a worktree path out of a tool
/// result.
///
/// The slug cases are the CLI's own answers, measured against 2.1.258 by running `claude -p` in
/// each directory and reading back what appeared under `~/.claude/projects`.
final class SessionPathTests: XCTestCase {
  // MARK: transcript directory slug

  func testDirectoryFlattensSlashesAndDots() {
    // github.com must become github-com — dots are encoded too, not just slashes.
    let dir = ClaudeSessionStore.directory(
      for: URL(fileURLWithPath: "/Users/x/src/github.com/y/main"))
    XCTAssertEqual(dir.lastPathComponent, "-Users-x-src-github-com-y-main")
    XCTAssertTrue(
      dir.deletingLastPathComponent().path.hasSuffix(".claude/projects"),
      "the slug sits under ~/.claude/projects")
  }

  func testDirectoryEncodesEveryDot() {
    let dir = ClaudeSessionStore.directory(for: URL(fileURLWithPath: "/nowhere/a.b.c/d"))
    XCTAssertEqual(dir.lastPathComponent, "-nowhere-a-b-c-d")
  }

  /// Everything that is not a letter or a digit, which is the half the old reading missed: a
  /// space, an underscore, a `+`, a kanji. `/Volumes/Macintosh HD/…` is the case that made it
  /// matter.
  func testDirectoryEncodesEveryNonAlphanumeric() {
    XCTAssertEqual(
      ClaudeSessionStore.encodedPath("/Volumes/Macintosh HD/Users/x/w"),
      "-Volumes-Macintosh-HD-Users-x-w")
    XCTAssertEqual(ClaudeSessionStore.encodedPath("/nowhere/my_repo/v1+2"), "-nowhere-my-repo-v1-2")
    XCTAssertEqual(ClaudeSessionStore.encodedPath("/nowhere/作業"), "-nowhere---")
  }

  /// A character outside the BMP is two UTF-16 units, and the CLI walks units — so it is two
  /// dashes there, and must be two here.
  func testDirectoryCountsANonBMPCharacterTwice() {
    XCTAssertEqual(ClaudeSessionStore.encodedPath("/a/\u{1F600}b"), "-a---b")
  }

  /// The engine names its cwd with whatever `getcwd(3)` gives it, which is always resolved — so
  /// a path reached through a symlink has to be resolved here too, or hukan reads a directory
  /// the engine never writes into.
  func testDirectoryCanonicalizesThePath() {
    // /tmp is a symlink to /private/tmp, and the CLI's own answer there is -private-tmp-….
    XCTAssertEqual(
      ClaudeSessionStore.directory(for: URL(fileURLWithPath: "/tmp")).lastPathComponent,
      "-private-tmp")
  }

  /// A path with nothing at the end of it has no canonical form; what was asked for stands.
  func testDirectoryKeepsAPathThatIsNotThere() {
    XCTAssertEqual(
      ClaudeSessionStore.directory(for: URL(fileURLWithPath: "/nowhere/at/all")).lastPathComponent,
      "-nowhere-at-all")
  }

  /// Past 200 characters the CLI cuts the name and hangs a hash of the whole path off the end.
  /// This is its answer for this path, read off disk.
  func testDirectoryTruncatesALongPathAndHashesIt() {
    var path = "/private/tmp/hukanlong"
    for i in 1...8 { path += "/segment_\(i)_aaaaaaaaaaaaaaaaaaaaaa" }
    let slug = ClaudeSessionStore.encodedPath(path)
    XCTAssertEqual(
      slug,
      "-private-tmp-hukanlong-segment-1-aaaaaaaaaaaaaaaaaaaaaa"
        + "-segment-2-aaaaaaaaaaaaaaaaaaaaaa-segment-3-aaaaaaaaaaaaaaaaaaaaaa"
        + "-segment-4-aaaaaaaaaaaaaaaaaaaaaa-segment-5-aaaaaaaaaaaaaaaaaaaaaa"
        + "-segment-6-aa-39955c")
    XCTAssertEqual(slug.prefix(200).count, 200, "the cut is at 200, the hash rides after it")
  }

  /// A decomposed directory name is one character to the engine, so it must be one dash here.
  /// The CLI's answer for a directory called `\u{304B}\u{3099}` is `…-hukannfd--`: one dash for the
  /// separator and one for the kana, not two.
  func testDirectoryComposesADecomposedName() throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hukan-nfc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    // Made through `mkdir` with the bytes spelt out, so the fixture cannot be composed on the
    // way to disk by whatever Foundation would rather write.
    let name = "\u{304B}\u{3099}"
    let decomposed = parent.appendingPathComponent(name)
    XCTAssertEqual(mkdir(decomposed.path, 0o755), 0, String(cString: strerror(errno)))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: parent.path).first?.unicodeScalars
        .count, 2, "the fixture has to be decomposed on disk or it asserts nothing")

    let slug = ClaudeSessionStore.slug(for: decomposed)
    XCTAssertTrue(slug.hasSuffix("--"), "one dash for the separator, one for the kana: \(slug)")
    XCTAssertFalse(slug.hasSuffix("---"), "the decomposed spelling would give two: \(slug)")
  }

  /// A path exactly at the limit is not cut — the CLI's test is `> 200`, not `>=`.
  func testDirectoryLeavesAPathAtTheLimitAlone() {
    let path = "/" + String(repeating: "a", count: 199)
    XCTAssertEqual(ClaudeSessionStore.encodedPath(path).count, 200)
    XCTAssertFalse(ClaudeSessionStore.encodedPath(path).dropFirst().contains("-"))
  }

  // MARK: how an id is spelt

  /// Claude Code spells the ids it mints in lower case, and `UUID.uuidString` spells them in
  /// upper. hukan used to hand the engine the upper one, so every session started here was named
  /// against the grain of the store it was written into.
  func testAnIDIsSpeltTheWayTheCLISpellsItsOwn() {
    let id = UUID(uuidString: "FFF40972-FBDE-40F0-B6F8-1EA442254E7C")!
    XCTAssertEqual(ClaudeSessionStore.name(id), "fff40972-fbde-40f0-b6f8-1ea442254e7c")
    XCTAssertEqual(
      ClaudeSessionStore.transcriptURL(id: id, worktree: URL(fileURLWithPath: "/tmp/x"))
        .lastPathComponent, "fff40972-fbde-40f0-b6f8-1ea442254e7c.jsonl")
  }

  // MARK: worktree path extraction

  func testWorktreePathBeforeBranchClause() {
    let text = "Created worktree at /Users/x/wt/feature on branch feature-x. Ready."
    XCTAssertEqual(
      AgentSession.worktreePath(fromToolResult: text),
      URL(fileURLWithPath: "/Users/x/wt/feature"))
  }

  func testWorktreePathFallsBackToSentenceEnd() {
    // No " on branch " — the ". " delimiter closes the path instead.
    let text = "Created worktree at /Users/x/wt/plain. Next step follows."
    XCTAssertEqual(
      AgentSession.worktreePath(fromToolResult: text),
      URL(fileURLWithPath: "/Users/x/wt/plain"))
  }

  func testWorktreePathRejectsRelativePath() {
    // The wording matched, but a non-absolute path is not trustworthy — give up.
    XCTAssertNil(
      AgentSession.worktreePath(fromToolResult: "worktree at relative/dir on branch x. "))
  }

  func testWorktreePathNilWhenWordingAbsent() {
    XCTAssertNil(
      AgentSession.worktreePath(fromToolResult: "Entered the existing worktree /Users/x/wt."))
    XCTAssertNil(AgentSession.worktreePath(fromToolResult: ""))
  }

  // MARK: the way back out — ExitWorktree's result, as the engine words it (2.1.246)

  func testExitedCwdAfterAKeep() {
    let text =
      "Exited worktree. Your work is preserved at /Users/x/wt/feature on branch feature-x. "
      + "Session is now back in /Users/x/main."
    XCTAssertEqual(
      AgentSession.exitedCwd(fromToolResult: text), URL(fileURLWithPath: "/Users/x/main"))
  }

  /// A remove's result also says `worktree at <path>` — the Enter parser would read that and
  /// move the session *into* the worktree it just left. The exit parser must read the other end.
  func testExitedCwdAfterARemoveIsNotTheRemovedWorktree() {
    let text =
      "Exited and removed worktree at /Users/x/wt/feature. Discarded 2 commits and 1 "
      + "uncommitted file. Session is now back in /Users/x/main."
    XCTAssertEqual(
      AgentSession.exitedCwd(fromToolResult: text), URL(fileURLWithPath: "/Users/x/main"))
    XCTAssertEqual(
      AgentSession.worktreePath(fromToolResult: text),
      URL(fileURLWithPath: "/Users/x/wt/feature"),
      "which is exactly why the two results are read by two parsers")
  }

  /// The original directory was gone, so the engine went somewhere else and says so — and that
  /// is where the session is, so that is what is read.
  func testExitedCwdWhenTheOriginalDirectoryWasGone() {
    let text =
      "Exited worktree. Your work is preserved at /Users/x/wt/feature. The original directory "
      + "/Users/x/gone no longer exists, so the session is now in /Users/x/wt/feature. "
      + "Consider restarting Claude from an existing directory."
    XCTAssertEqual(
      AgentSession.exitedCwd(fromToolResult: text), URL(fileURLWithPath: "/Users/x/wt/feature"))
  }

  func testExitedCwdRejectsWhatIsNotAPath() {
    XCTAssertNil(AgentSession.exitedCwd(fromToolResult: "Session is now back in main."))
    XCTAssertNil(
      AgentSession.exitedCwd(
        fromToolResult: "No-op: there is no active EnterWorktree session to exit."))
    XCTAssertNil(AgentSession.exitedCwd(fromToolResult: ""))
  }
}
