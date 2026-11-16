# Remote Control

Settled decisions, moved out of CLAUDE.md so it stays loadable. Each bullet is a decision
and the reasoning behind it; read the file before changing the area it covers.

- **Remote Control is a control request on the open stream, and the engine does the bridging.**
  It puts one session on claude.ai/code and the Claude app while the process goes on running here,
  and hukan reaches it exactly as the VS Code extension does — `{subtype: "remote_control",
  enabled}`, the same door `set_model` goes through. That it is a request and not a slash command
  is what makes it available at all: `/remote-control` is a `local-jsx` command, drawn by the REPL
  it runs in, and it is not even in the command list a stream-json engine reports, so a composer
  that offered it would be offering a dead word. **The line this does not cross is the outbound
  one.** hukan opens no socket and sends no credential — the engine bridges, hukan only says
  when — which is what leaves the cask check and the images a template is made from the only
  requests hukan makes for itself. What it does
  mean is that the conversation travels via Anthropic's servers, and that is why nothing about it
  is implicit.
  **Three facts arrive in the initialize reply and they are kept apart, because the engine keeps
  them apart.** Whether the deployment offers the bridge at all; whether the standing
  `remoteControlAtStartup` answer is on; and whether that answer is an org or rollout default
  rather than the person's own. Only the first two would be needed to decide — the third exists to
  be *shown*, and the keys say so themselves ("so IDE hosts can render the same disclosure
  notice"). So hukan turns the bridge on unasked only when the standing answer is theirs, and
  otherwise says in the tooltip where the default came from. That is not hypothetical: on this
  machine's own account the reply is available, auto-enable and by-default all true, so obeying
  `auto_enable` alone would have bridged every conversation in the window because a rollout said
  so. The setting itself stays where it is — user scope in Claude Code (repo-scoped settings are
  refused outright for this one, so it is the person's answer and not the repository's) — and
  hukan gains no preference for it, having no settings window and no business keeping a second
  copy of one.
  **It is not remembered per session either**, unlike the model and the mode beside it: those are
  a way of working, where this is a decision about this conversation now, and a remembered "on"
  would be hukan making it again tomorrow on nobody's behalf. The bridge dies with the engine for
  the same reason the state is not carried across a restart — a bridge belongs to a live process,
  and a state that outlived one would claim a phone can reach a conversation nothing is holding.
  Two parameters are deliberately never sent: `keep_session_on_exit`, which would leave an engine
  up on the bridge after hukan quit — a process this window can no longer show, the same refusal
  that keeps a closed repository off the rail — and `work_secret`, which is for a host that runs
  its own bridge environment, and whose absence is also what means the engine will never ask for a
  fresh one (`remote_control_work_secret`) and leave hukan a request it has no answer for.
  **It sits in the session's header** by the scope rule the context dial beside it already
  follows: it is one conversation's fact, so it would be a lie anywhere the selection can change
  under it. **Whether to show it and whether it can be pressed are two questions**, and collapsing
  them is what hid the feature. Showing is whether the *install* offers the bridge, which is not a
  fact about this conversation — every session in a window talks to the same `claude` — so the
  window carries the answer across from the first engine that gave one, exactly as it does the
  slash command list, and for the same payoff: the control is on the header of a session that has
  never started. Tied to this session's engine instead, the antenna appeared on running rows only,
  so the one place you would look for it — a conversation you are about to resume — was the one
  place it was invisible. Pressing is whether an engine of this session's own is up, since the
  bridge is the engine's to hold and there is nothing to queue an intent against; that is a
  *disabled* control with a tooltip saying so, which is what the model and mode pickers beside it
  already do for a held session. Hidden, still, where the deployment refuses the bridge outright:
  an offer that can never be taken is worse than no offer.
  **It is a toggle and not a picker**, unlike the three beside it: those answer "which of
  several?", where this answers "yes or no?", and a two-item menu serves that badly — it pops a
  list to choose between two things, it makes the states the engine reports on its own
  (connecting, failed) read as a third choice, and its two items have to be named as siblings,
  which "Off" and "Remote" are not. Clicking to flip is what every other binary in hukan already
  does (the panel's ± scope, the History fold); only the display contract is the picker's, kept
  exactly, so a header of defaults stays a row of quiet glyphs.
  **Where the bridge leads is a second thing, and it hangs off the antenna's hover as a QR code.**
  The reply carries `session_url`, the claude.ai/code address for this session, and it is the one
  part of that reply worth keeping: the *state* arrives continuously as `bridge_state`, so an id
  held beside it would be a second account of one thing, but the address is not a state — it is
  the answer to "so how do I reach this from my phone", and nothing else on the stream ever says
  it. **And the address is on the wrong screen**, which is the whole problem: it is on this Mac,
  and the device that wants it is in your hand. Every way across — mailing yourself the link,
  hunting the session down in the app — is longer than pointing a camera at the window. So the
  click stays the switch and the hover carries the code, which is a gesture nothing else on the
  header was using; a pill above the composer was built for this first and taken out, because it
  put Remote Control in two places when the header could hold both halves. The two never compete:
  the hover has something to show only while the bridge is up, which is exactly when the click
  means "turn it off". A bridge that came up without an address has nothing behind the hover (the
  engine treats that as a failed enable anyway).
  **A code is the one surface here drawn for a machine rather than for a person**, and that
  changes what care means. It is scaled by a *whole* number of device pixels with interpolation
  off — the same argument the image pane makes for a screenshot of text, one step further, since
  there a soft pixel is ugly and here it is unreadable — and its quiet zone is part of the bitmap
  rather than a margin the layout supplies, because a reader finds the code by its border of
  light. The white is painted in, not left to the appearance: the generator hands back modules on
  transparency, and a code composited onto a dark window is inverted, which most readers refuse.
  Two modules of zone rather than the specified four, that being sized for print at a distance
  where this is read off a bright screen at arm's length. And the bitmap is drawn in *pixels*
  before its point size is set, which is the trap that made this worth testing at all: setting the
  size first makes the context map points to pixels, so on a 2× display the code was drawn at
  twice its size with the quarter that fitted kept. What the tests assert is therefore not how it
  looks but that it *decodes* — the system's own detector reading it back, which is the job a
  phone camera does.
  **The panel names the login, because a code cannot check one.** A bridged conversation opens
  only for the account that bridged it, so a code scanned on a phone signed in as somebody else
  fails — several steps after the decision that doomed it, and on the phone rather than here.
  hukan cannot fix that, the bridge being account-scoped by construction, but it can say it:
  `account.email` rides in the same initialize reply as everything else read here, travels the
  window the way the command list does (one window, one login) and stands under the code, so a
  mismatch is visible before the camera comes up rather than after.
  **The transcript gets the same three sentences**, because they
  are facts about the conversation and not about the window: it left this machine here, came back
  there, and the address is what someone reading it back would need. Written once per address, so
  the engine's own reconnects do not repeat it, and not written at all when the engine merely
  exits — a stop and a restart would otherwise narrate the process's life in a conversation that
  is about something else.
  **What was typed on the phone is shown here, and that took reading the replay properly.** The
  engine replays every message it accepts (`--replay-user-messages`), and hukan took those for
  acknowledgements of its own sends — worth a uuid, since the replay is the only place the engine
  says which record a message became, and nothing more. Once a session is bridged that stops being
  true: some of those messages were typed somewhere else, hukan never wrote them, and nothing else
  will ever show them — so the agent's answer arrived under no question. The engine tags each
  message with where it came from, and **the test is that a tag is there at all, not what it
  says**: a message hukan hands the engine over stdin is recorded with no `origin` whatever, so
  absence is the reliable half and it is the half hukan needs — the only messages it has already
  drawn are the ones it sent, and those are exactly the untagged ones. A tag it has never met
  therefore shows, a line drawn twice being the smaller wrong. Matching a *value* was the first
  rule and it was wrong twice over: `bridge` is a kind the engine uses for something else, and a
  person typing on the far end produces `{"kind":"human"}` — which no amount of reading the binary
  settled and one look at a real transcript did. Only the text: an image typed on a phone lives on
  Anthropic's side, not in this worktree, so there is no path here to draw it from.
  A failure is narrated there too, and for a reason the other two do not have: the antenna shows
  only the two states you can choose between, so a bridge that drops or is refused would otherwise
  report itself by quietly going back to Off, which reads as the toggle not having taken. **All
  three notes are written in one place**, because the two things that move the bridge disagree
  about which of them speaks — a state pushed by the engine reports the drops, the reconnects and
  the retries, while a *disable* hukan asks for is answered by the reply and not always followed
  by a state at all, so narrating at either site alone missed half the transitions. Where the
  bridge stands arrives as `bridge_state` on the stream, pushed rather than polled. **An unknown
  state word reads as off, and off is not failed** — two different claims, and only one of them is
  safe to make from a protocol read off a shipped binary. Not knowing a state means not knowing
  the conversation is on the wire, which is what off says; failed says the bridge was refused,
  which hukan cannot know. Reading unknown as failed put a failure in the transcript of every
  connection that *worked*: `ready` is an ordinary attached state — the engine's own check is
  `connected || ready` — and it is the first thing a successful enable sends, before the reply
  carrying the address. A drop the engine reports on its own is not narrated either, only a
  disable someone asked for: the engine reattaches by itself, a line each way would bury the
  conversation the bridge exists to carry, and the antenna and the pill going quiet already report
  it on screen.
