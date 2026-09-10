import XCTest

@testable import Hukan

/// Remote Control as it arrives from the engine: the three availability facts in the initialize
/// reply, and the `bridge_state` events that follow. Both shapes are read off the shipped CLI and
/// the VS Code extension's own client, so what these pin is hukan's reading of them — in
/// particular that an unfamiliar word is not mistaken for "on".
final class RemoteControlTests: XCTestCase {

  // MARK: - Availability

  /// The only combination that turns the bridge on unasked: the deployment offers it, and the
  /// standing `remoteControlAtStartup` answer is the person's own. That setting is user-scope
  /// (repo-scoped settings are refused outright for it), which is what makes obeying it obeying
  /// them rather than the repository.
  func testStartsOnItsOwnOnlyForAnExplicitUserSetting() {
    XCTAssertTrue(
      ClaudeRemoteControl(isAvailable: true, autoEnable: true, autoOnByDefault: false)
        .startsOnItsOwn)
  }

  /// An org policy or a rollout reaching `autoEnable` is a disclosure to show, not an instruction
  /// to follow: nobody chose, and this is the switch that puts a conversation on Anthropic's
  /// servers. The two flags differ in exactly that case, which is why hukan keeps them apart.
  func testAnOrgDefaultDoesNotStartOnItsOwn() {
    XCTAssertFalse(
      ClaudeRemoteControl(isAvailable: true, autoEnable: true, autoOnByDefault: true)
        .startsOnItsOwn)
  }

  func testUnavailableNeverStartsOnItsOwn() {
    XCTAssertFalse(
      ClaudeRemoteControl(isAvailable: false, autoEnable: true, autoOnByDefault: false)
        .startsOnItsOwn)
  }

  // MARK: - Bridge state

  func testReadsTheStatesTheEngineSends() {
    XCTAssertEqual(ClaudeBridgeState(state: "connected", detail: nil), .connected)
    XCTAssertEqual(ClaudeBridgeState(state: "connecting", detail: nil), .connecting)
    XCTAssertEqual(ClaudeBridgeState(state: "disconnected", detail: nil), .off)
    XCTAssertEqual(ClaudeBridgeState(state: "failed", detail: "auth"), .failed("auth"))
  }

  /// `ready` is an ordinary attached state — the engine's own check is
  /// `be === "connected" || be === "ready"` — and it is the *first* thing a successful enable
  /// sends, before the reply carrying the address. Reading it as anything else put a failure in
  /// the transcript of every connection that worked, which is how this was found.
  func testReadyIsAnAttachedState() {
    XCTAssertEqual(ClaudeBridgeState(state: "ready", detail: nil), .connected)
  }

  /// The vocabulary is the engine's and open-ended, so a word hukan has never seen reads as off —
  /// but off is not the same claim as failed, and only one of them is safe to make. Not knowing a
  /// state means not knowing the conversation is on the wire; saying it failed says the bridge was
  /// refused, which hukan cannot know and which writes a line about something that did not happen.
  func testAnUnknownStateIsOffAndNotAFailure() {
    let unknown = ClaudeBridgeState(state: "reticulating", detail: "hmm")
    XCTAssertFalse(unknown.isOn)
    XCTAssertEqual(unknown, .off, "off, so nothing is claimed about why")
  }

  /// Connecting counts as on for the header, so the antenna does not flick back to Off for the
  /// beat between the request being answered and the bridge coming up.
  func testConnectingCountsAsOn() {
    XCTAssertTrue(ClaudeBridgeState.connecting.isOn)
    XCTAssertTrue(ClaudeBridgeState.connected.isOn)
    XCTAssertFalse(ClaudeBridgeState.off.isOn)
    XCTAssertFalse(ClaudeBridgeState.failed("x").isOn)
  }

  // MARK: - The header's antenna

  private static let bridged = URL(string: "https://claude.ai/code/session-42")!

  private func display(
    available: Bool = true, autoEnable: Bool = false, autoOnByDefault: Bool = false,
    state: ClaudeBridgeState = .off, live: Bool = true, held: Bool = false, asking: Bool = false,
    url: URL? = bridged
  ) -> RemoteControlDisplay {
    RemoteControlDisplay(
      availability: ClaudeRemoteControl(
        isAvailable: available, autoEnable: autoEnable, autoOnByDefault: autoOnByDefault),
      bridge: state, hasLiveEngine: live, isHeld: held, isAsking: asking, url: url)
  }

  // MARK: - What the hover has to show

  /// The hover carries the address, so it has something to show only where there is somewhere to
  /// go. Connecting is not that: the bridge is on its way and has no address yet, and a code for
  /// one would be a picture of nothing.
  func testAnAddressExistsOnlyWhileTheBridgeIsUp() {
    XCTAssertEqual(display(state: .connected).url, Self.bridged)
    XCTAssertNil(display(state: .connecting).url)
    XCTAssertNil(display(state: .off).url)
    XCTAssertNil(display(state: .failed("x")).url)
  }

  /// A bridge that came up without an address is the one case the engine treats as a failed
  /// enable. The antenna still says the bridge is on, which is true — there is simply nothing
  /// behind the hover.
  func testNoAddressMeansNothingToHover() {
    XCTAssertNil(display(state: .connected, url: nil).url)
    XCTAssertTrue(display(state: .connected, url: nil).isOn)
  }

  /// Whether the bridge exists is a fact about the install, so the window carries it across from
  /// the first engine that answered and the antenna shows on a session with no engine of its own.
  /// It was tied to this session's engine at first, which put the control on running rows only —
  /// so the one place you would look for it, a conversation you are about to resume, was the one
  /// place it was invisible.
  func testTheAntennaShowsOnASessionThatHasNotStarted() {
    XCTAssertTrue(display(live: false).isShown)
    XCTAssertFalse(display(live: false).isEnabled, "but there is no engine to ask yet")
    XCTAssertEqual(
      display(live: false).toolTip?.contains("start the session first"), true,
      "and it says what would make it pressable")
  }

  /// Nothing is known until some engine in the window has answered, and until then there is no
  /// claim to make either way.
  func testNoAntennaUntilTheWindowHasAnAnswer() {
    XCTAssertFalse(RemoteControlDisplay(session: AgentSession(worktreeID: UUID())).isShown)
    XCTAssertFalse(RemoteControlDisplay(session: nil).isShown)
  }

  /// Hidden rather than greyed where the deployment refuses it outright: managed settings can
  /// hard-disable the bridge, and an offer that can never be taken is worse than no offer.
  func testNoAntennaWhereTheDeploymentRefusesIt() {
    XCTAssertFalse(display(available: false).isShown)
  }

  func testTheAntennaFollowsTheBridge() {
    XCTAssertFalse(display(state: .off).isOn)
    XCTAssertTrue(display(state: .connecting).isOn)
    XCTAssertTrue(display(state: .connected).isOn)
    // A failure lands back on Off, which is true — the transcript is what says it failed.
    XCTAssertFalse(display(state: .failed("x")).isOn)
  }

  /// The engine holding this conversation is another process's to speak to, so the bridge is not
  /// hukan's to switch — the same line that keeps a held session from being rolled back.
  func testAHeldSessionCannotSwitchTheBridge() {
    XCTAssertTrue(display(held: true).isShown)
    XCTAssertFalse(display(held: true).isEnabled)
  }

  func testARequestInFlightOwnsTheControl() {
    XCTAssertFalse(display(asking: true).isEnabled)
  }

  /// The disclosure the engine asks a host to render. On this machine's own account the standing
  /// answer is on *and* `autoOnByDefault`, so this is the live case rather than a hypothetical:
  /// hukan leaves the bridge off and says where the default came from, instead of quietly
  /// bridging every conversation because a rollout said so.
  func testAnOrgDefaultIsDisclosedRatherThanActedOn() {
    let shown = display(autoEnable: true, autoOnByDefault: true, state: .off)
    XCTAssertFalse(shown.isOn, "still off — nobody chose this")
    XCTAssertEqual(
      shown.toolTip?.contains("on by default for your organization"), true,
      "and the antenna says why it is being offered")
  }

  /// Without that flag the tooltip is the plain one, which still names the cost of saying yes:
  /// the conversation leaves this machine.
  func testTheOffTooltipSaysWhereTheConversationGoes() {
    XCTAssertEqual(display(state: .off).toolTip?.contains("Anthropic's servers"), true)
  }

  // MARK: - What was typed on the phone

  /// The engine replays every message it accepts, and once a session is bridged some of them were
  /// typed somewhere else. hukan shows only what it wrote itself, so those left the conversation
  /// with the answer arriving under no question. The engine tags where a message came from, so
  /// this is read off its own account rather than guessed at.
  /// What a person typing on claude.ai/code actually produces, read out of a real transcript —
  /// `human`, not the `bridge` that reading the binary suggested and that the engine uses for
  /// something else. Which is why the rule does not name a value.
  func testAMessageTypedOnTheFarEndIsRecognised() {
    XCTAssertTrue(AgentSession.isFromElsewhere(["origin": ["kind": "human"]]))
  }

  /// A message hukan sent over stdin carries no origin at all, and is already on screen — showing
  /// it again on the replay would double every line typed here. Absence is the reliable half, and
  /// the only one hukan needs.
  func testOurOwnMessageCarriesNoOrigin() {
    XCTAssertFalse(AgentSession.isFromElsewhere([:]))
  }

  /// An origin hukan has never met still shows. It cannot be one of ours — ours have none — so
  /// the alternative is dropping a message nothing else will draw.
  func testAnUnfamiliarOriginStillShows() {
    XCTAssertTrue(AgentSession.isFromElsewhere(["origin": ["kind": "reticulating"]]))
  }

  /// A prompt reaches hukan spelled either way — a bare string, or the blocks a message with
  /// attachments arrives as — and both have to read back, since which one it is depends on what
  /// was typed on a device hukan cannot see.
  func testAPromptIsReadWhicheverWayItIsSpelled() {
    XCTAssertEqual(AgentSession.promptText(["message": ["content": "手伝って"]]), "手伝って")
    XCTAssertEqual(
      AgentSession.promptText([
        "message": ["content": [["type": "text", "text": "続けて"]]]
      ]), "続けて")
    XCTAssertNil(AgentSession.promptText(["message": ["content": ""]]))
    XCTAssertNil(
      AgentSession.promptText([
        "message": ["content": [["type": "tool_result", "content": "x"]]]
      ]), "a tool result is not something anyone typed")
  }

  // MARK: - One answer per window

  /// Seeding is how a session with no engine gets the answer at all, and it must never overwrite
  /// one this session's own engine gave: that one is current, and its `autoOnByDefault` was
  /// resolved against this very process.
  func testSeedingFillsAGapAndNeverOverwrites() {
    let session = AgentSession(worktreeID: UUID())
    session.seedRemoteControl(
      ClaudeRemoteControl(isAvailable: true, autoEnable: false, autoOnByDefault: false))
    XCTAssertEqual(session.remoteControl?.isAvailable, true)

    session.seedRemoteControl(
      ClaudeRemoteControl(isAvailable: false, autoEnable: false, autoOnByDefault: false))
    XCTAssertEqual(session.remoteControl?.isAvailable, true, "the first answer stands")
  }
}
