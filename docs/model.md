# The model

Settled decisions, moved out of CLAUDE.md so it stays loadable. Each bullet is a decision
and the reasoning behind it; read the file before changing the area it covers.

- **Buffer identity is `(Worktree, relative path)` — never the absolute path.** Keying on the
  path splits the same file in two worktrees into two unrelated buffers, and "put main and
  feature side by side" stops working. Practically impossible to retrofit.
- **It is a Worktree, not a Root, and a Repository, not a Project** — git's vocabulary, because
  hukan is git-only and "the folder you opened" is the notion this design argues against. A
  non-git directory still opens as its own repository, but it is the degenerate case, not the
  model.
- **Repository identity is `git rev-parse --git-common-dir`'s parent** — something git
  computes, not a folder someone nominated. Worktrees are enumerated from git, never opened or
  closed individually; they arrive with the repository and leave when git stops listing one —
  the `git worktree remove` a session runs once its task has landed, noticed as it is run. **A
  worktree leaving does not take its sessions with it**: the checkout is over, not the
  conversation, so each session that stood there is put on the main checkout — where a resumed
  engine carries on, having said the worktree is gone and cleared its binding (measured) — and
  its row keeps the branch, struck through. Its transcript stays where `EnterWorktree` filed it,
  under the gone checkout, so that is where every read of it looks, and the mark rides the
  window's restorable state, since no listing of the worktrees there are will reach it again.
  Closing the repository takes the rest, the main checkout included: git will not remove that
  one, so nothing but a decision can.
- **What was open and is not is a list, not a row.** Open Recent — in the File menu, on the rail's
  right-click and beside the empty window's button, the three places Open Repository… is already
  reached from — offers the repositories this app has had open that the window it would add to has
  not. The alternative was leaving a closed repository on the rail as a dimmed row, which is where
  you closed it and so where you would look; refused because such a row has nothing to say and
  never will. A closed repository has no worktrees, no sessions and nothing measured — git is not
  being enumerated for it — so it would sit permanently mute on the one column whose job is to show
  what is waiting on you. The archived session it would be modelled on is not the same case: an
  archived session still has a transcript, a history and a resume, and it comes back out of the
  fold the moment it is working. A closed repository can never come back out, because closing it
  stopped everything in it. The rail is also per-window, and the window that held a repository is
  exactly what is gone by the time you want it back.
  **So it is hukan's one app-global store**, a list of paths in the defaults — not a preference
  (there is no settings window, and nothing in it is a choice) and not master data (every entry is
  a path git answers for, and losing the list costs one trip through the open panel). An entry is a
  *repository* id, the path git's common dir sits under, so opening a linked worktree records the
  repository and reopening lands on the open/close unit. It is noted when a repository is opened
  *and* when it is closed — closing is what usually fills the menu, but a repository carried across
  restarts until a quit would otherwise never be noted at all — and noted in the model rather than
  at the menu items, so every route in lands in it. Restoration is pointedly not one of those
  routes: a repository coming back is the same one carrying on. Ten places, the length every Open
  Recent on this machine is; an entry that is no longer a directory is dropped from the store on
  the next read, since a repository that has been deleted or moved is gone rather than recent and
  must not hold a place for good; and a name that repeats in the offered list carries the directory
  it sits in, since two rows both reading `hukan` name nothing. **The open panel takes several at
  once** for the same reason the menu exists: it is one trip, and a morning that starts with three
  repositories open was three trips through it.
- **Where a session is, is read off `EnterWorktree` and `ExitWorktree` — and the engine is asked
  to use them.** The engine's process is what moves: `EnterWorktree` switches its working
  directory and relocates its transcript, `ExitWorktree` puts both back. Their results are the one
  record of that, and hukan reads both — in, to a worktree it registers on arrival; out, only onto
  a worktree already open. The original directory is where the session was started, a worktree
  root the window holds, so nothing else is ever registered: a Worktree git does not list is what
  the next reconcile drops, and a session still standing in it is stranded onto main with its
  engine stopped (see the repository bullet). That is why the exit had to be followed at all — an
  `ExitWorktree` with `remove` is git ceasing to list a worktree while the session in it lives on,
  and until the session had gone home first, the reconcile stopped the one process that had just
  finished its task. Nothing steers the model toward those tools by
  itself: a `git worktree add` in Bash reaches the rail, since git lists it, but the engine's
  directory never moves and the desk goes on measuring the checkout the session left. So hukan
  appends one line to the system prompt saying to use them. One line, a fact about the tools and
  not a way of working, and **nothing about what hukan is**: identity is not an instruction, and the
  only behaviour it could add is the agent driving the app — what the guarded scripting verbs exist
  to stop. If hukan is ever explained to an agent, it is in the description of a tool the agent
  calls on it, read when it is used rather than on every turn. **The rule is a line per tool the
  window depends on the agent calling**, not one line in total: the session's tags (`docs/rail.md`) are the
  second, for the same reason — a tool nothing mentions is a tool the model never calls unasked.
- **A desk is a session's, not a worktree's, and a terminal is a tab on it.** The session's
  conversation has the column beside the desk; the desk is that session's files, commits, web
  tabs and terminals. It was the worktree's, and the agent is what made that wrong: an
  `EnterWorktree` moves the session and not the selection, so a desk keyed by worktree left the
  task's tabs behind in the checkout it had left and swapped the desk out from under a row nobody
  had clicked. So **a file tab remembers its path and follows its session** into the next
  checkout, the task carrying on in another place — a file the new checkout does not have closes,
  and a tab holding an unsaved edit stays on the buffer it was typed into, since the edit is that
  worktree's, and the strip names the worktree beside it. The buffer is still
  `(Worktree, relative path)`; what moved is only who holds the tab. Two conversations in one
  checkout are two desks, and a fork is a desk of its own. **No session, no desk**: with none
  selected the desk is empty, ⌘T and ⌃⌘T are off and a pick in the files panel has nowhere to
  go, since there is nobody whose tab it would be — no repository-level desk stands in, that
  being the worktree desk again under another name. A window saved while desks were worktrees'
  hands each worktree's tabs, once, to the session instructed there last; a worktree no session
  stood in keeps only its web tabs, given to the repository's latest session, since a page is the
  one tab that costs something to find again.
- **Master data lives where it already is.** git owns worktrees, Claude Code owns sessions and
  transcripts; hukan stores only open repositories plus UI state — plus the one session-side
  exception, the composer choices the engine forgets across `--resume`. The rail's order is UI
  state and is stored as such, keyed by session id: it is when *you* last instructed a session,
  which nothing on disk records. It was re-derived from the transcript's mtime instead, and that
  answers a different question — mtime moves for the agent's own output, and again for the
  `last-prompt` line a quitting engine appends, which re-stamps every attached session within the
  same second and so reshuffled the day's rows on every restart. Stored stamp wins; mtime is only
  the seed for a session this window has never seen.
- **What the engine knows, the engine is asked — over the stream, and never by sending it a
  message.** The model roster, the slash commands, the account's plan usage and how full the
  context window is are all the engine's own facts, so none of them is a table here or a file to
  scan. Two of them ride in on its startup reply; the other two are asked for on the open stream,
  the same channel a model switch goes down. **A probe must not be a turn.** The plan usage was
  read by spawning `claude -p "/usage"` in a scratch directory, and because a slash command is a
  user message, every poll left a session transcript behind — 2400 files over six days, from a
  poll that only runs while the window is up — while the figures themselves had to be recovered
  from an English sentence the CLI happened to print. The line is exactly there: ask a question
  and nothing is written; send a message and a conversation exists.
  **What the engine spells, the engine spells** — a roster entry's label is shown exactly as it
  arrives. It was recomposed for a while, the version dug out of the resolved id and spliced onto
  a numberless name so the picker read "Opus 4.8" rather than "Opus"; that is hukan keeping a copy
  of the engine's naming rule, and the copy went wrong the moment the rule moved. Fable 5.1 shipped
  beside Fable 5, the engine started numbering the label itself to tell the two apart, and the
  picker read "Fable 5 5" — while the name it was actually being asked for, "Fable 5", was sitting
  in the reply. Which of the two Fables an account needs spelled out is the engine's to know, not
  something to be re-derived from a model id here.
- **A turn that failed is `is_error`, not the subtype — and the two disagree exactly where it
  matters.** A request that never reached the API ends the turn with `subtype: "success"` and
  `is_error: true`, so a session whose engine could not resolve a hostname wore the green check
  of a turn that went fine, and the `API Error: …` sentence the engine wrote about it was drawn
  as prose the agent had written. Both halves are read now. **What it failed of is
  `terminal_reason`**, which is the only field that tells the ways a loop can stop apart —
  `api_error`, `prompt_too_long`, `blocking_limit`, `max_turns`, `completed` — where one subtype
  covers all of them; absent on an engine that predates it and on a turn the loop never ran, so
  the subtype is what it falls back to.
  **The failure is said once.** The engine reports an API failure twice, as a message it
  synthesized (`is_api_error_message`, `model: "<synthetic>"`) and then as the result, and the
  message is the better sentence of the two, so the result only marks the session. It is a *kind*
  of transcript record rather than a colour applied on the way past, because the same line has to
  read the same way when the jsonl is re-read after a restart — where the flag is spelt
  `isApiErrorMessage` — and because a line that is on screen has to be findable, which a colour is
  not. Flagged rather than worded, so the flag is what is matched: the sentence is the engine's
  phrasing and moves on an upgrade.
  **And it is appended, never laid over the run above it.** The buffered `assistant` message
  normally replaces the streamed span with its formatted self, which is right for every message
  the agent sends and wrong for this one: a request dropped mid-response is reported by a message
  that says the response above may be incomplete, so replacing there deletes exactly the thing
  being reported.
  **The retries are the other half, and they are the part that reads as a hang.** The engine
  retries up to ten times with a delay that grows to half a minute — three minutes in which
  nothing arrives and nothing is said. One note per turn: the nine after the first would only say
  it again, and a retry that succeeds leaves the note standing as the record of why the answer was
  late. Only while nothing is arriving, though — a drop mid-response is retried under an open run,
  where the transcript is not silent and where a note would sit inside the span the buffered
  message replaces, so it would be taken straight back out.
- **A client outside hukan reaches the sessions over stdio, from the executable the bundle
  already ships.** It was built for the Claude desktop app, which is where a person keeps track of
  their work as a whole, and what this window knows — which session is working, which is waiting on
  you, what each was asked — is the part of that work it cannot see. But nothing in it knows which
  client is asking: any MCP client that starts a local server is the same case, and a script
  speaking the Apple event is too. The client starts the app's own executable as its MCP server,
  and that copy hands each call to the one running, which answers from its own model: the turns
  are read the way the transcript pane reads them, so the two cannot disagree. **No port**: a
  listener on localhost is open to every process on the machine and to any page the browser loads,
  so it would need a token kept somewhere anything could read it, and it would stand open whether
  or not anyone was asking — where the Apple event's caller is decided once, by the person, in the
  automation grant. **Registered by hand, in the client's config, not as a `.mcpb`**: the bundle is
  the Claude app's intended road, but an organization's desktop-extension allowlist refuses a
  bundle it has not listed, and the work machine this is for is likely behind one. **It speaks to
  a session, and decides nothing**: a message — to a session, or the first one of a new session —
  is what the person would otherwise have typed, and the session's own permission mode still
  stands between it and the worktree — bypass included, since directing a bypass session from
  there is a use this was wanted for. An approval or a question is a decision already put to the
  person, so it is never answered from there, and a message is refused to a session waiting on
  one, because a send cuts that turn and drops the decision — a deny by another name. **What
  arrives this way says where from**, because the client may be a chat that reads mail and
  documents carrying instructions of their own, and a message nobody typed here should not read as
  one somebody did. Where from is two answers put together: the name the client gives itself in
  the handshake says what is calling but nothing checks it, and the app the sending process runs
  under is the kernel's answer but, for a client in a terminal, only the terminal. A session started
  from there **does not take the selection**: the person may be typing into another one, and the
  composer's focus going with the new row would send what they type next somewhere they never aimed
  it. **Not offered to Claude Code, nor refused to it**: hukan does not put it
  in its sessions' config, but a session the person has set up to drive another — a loop of
  agents — reaches the same tools, and is let through. What stays out of its reach is what stays
  out of every client's: the decisions put to the person. Its note names the sending session, so
  the loop can be followed afterwards.
- **Scope decides where a reading goes.** The toolbar's trailing edge carries the account's plan
  usage and the app's own footprint, because both are true of the whole window; **how full a
  session's context window is goes in that session's header, beside its cost estimate**, because
  both are that one conversation's consumption and would be a lie anywhere the selection can
  change under them. It lands next to the model picker, which is also what you reach for when the
  window is filling up. A dial and a percentage, no words — the same icon-and-digits idiom the
  toolbar uses for the other budget being spent, with the breakdown in the tooltip. **Amber past
  three quarters, red past nine tenths**, because this is not a limit you are warned about and
  then stopped at: the window compacts, and a compaction is the agent forgetting the middle of
  the conversation, so the colour's job is to be noticed while compacting on your own terms, a
  fork, or a fresh session are still choices. It is re-read when a turn ends, when the engine
  starts and when a rollback shortens the conversation — the three things that move it — rather
  than on a timer.
- **hukan observes worktrees, it does not act on them.** Work reaches main through a PR the
  agent opens itself; cleaning up a merged worktree is a plain `git worktree remove` any
  session can run. No local-merge path, no forced delete — an irreversible decision does not go
  inside hukan without review — and whatever hukan eventually does to a worktree must never be
  modal over the rail.
