# The rail

Settled decisions, moved out of CLAUDE.md so it stays loadable. Each bullet is a decision
and the reasoning behind it; read the file before changing the area it covers.

- **The rail has a history, and Back and Forward walk it.** A step is wherever the selection
  lands, by any route — a click, a key, a tapped notification, a search hit — because the rail is
  the window's navigation and the question "where was I a moment ago" does not care how you got
  there. A place is the session, not the worktree it stood in: an agent's `EnterWorktree` moves a
  session without anyone choosing anything, so it is no step, and going back reaches the
  conversation wherever it now lives. What has gone since — a deleted session, a worktree git
  stopped listing — is stepped over rather than removed, so the order around it holds. Per window
  and never saved, the reader's place in the transcript's rule: a restored window has no reader to
  have been anywhere. **The chevrons open the content section, not the rail's**: the rail's row is
  spent to the point on its filter and its sort, each of which cost the rail's floor its width,
  and over the
  conversation is where Finder and Xcode put theirs — first in the column whose contents they
  change. **The keys are ⌃⌘←/→, Xcode's, and not the browser's ⌘[ / ⌘]**, which the web tab holds:
  a focused web view answers yes to every ⌘-key put to it, so one pair could not be split between
  the two by where the focus is, and ⌃⌘ is already the family of what the window is showing.
- **The rail lists a repository's sessions; a worktree is where a session stands, not a row.**
  Under the heading come the repository's sessions, whichever worktree each is in, in the order
  you last instructed them, then the Archived section. It was arranged by worktree — main's
  sessions under the heading, each linked worktree a heading over its own — and that arrangement
  was the desk's: while a desk belonged to a worktree, the worktree was what a row was chosen
  under. A desk is a session's now (`docs/model.md`), and an agent's `EnterWorktree` moved a row from one
  heading to another under a reader who had chosen nothing. Tags settled the rest, the ticket
  being what a row is looked for by where the worktree's name only stood in for it. **The line
  under the title names the branch, then the tags** — the branch rather than the worktree's
  directory, since git never checks one branch out twice, so the branch names the worktree, and
  it is what the pull request and the agent call it too; the path is the branch's tooltip. Every session row has that line, so the
  rows are one height again apart from tags that wrap. The heading drops the branch it carried,
  the rows below saying it already. **What has moved in the worktree is not on the row, and a tool
  call says what it changed instead.** The row carried the worktree's diffstat at its trailing
  edge, and that number is the worktree's, not the session's: with no worktrees in use every row
  stands on main and the same `+120 −30` ran down the column, saying nothing about any one row
  and reading as though each session had written it. The selected session's worktree is the
  toolbar's to measure, as it already was. What a session did is said where it did it — an
  `Edit` or `Write` line in the transcript ends in the lines that call changed, the engine's own
  patch out of the result (`toolUseResult.structuredPatch`, `tool_use_result` on the stream),
  so nothing is diffed and a checkout shared by several sessions cannot mix them up. The result
  arrives after the line is drawn, so it is put on the line in place, the one edit inside the
  transcript besides a fold. **Never summed**: a total needs a start, and every start on offer
  is a number that wants explaining — counting committed work for ever, or emptying on each
  send — where one call's count can only mean what it says. A file changed by a shell command has
  no patch and is not counted; measuring git around each call would catch it, at the price of
  counting whatever the session next door wrote in the meantime.
  **A worktree no session stands in is not on the rail** — a
  terminal's `git worktree add`, what a Remote Control worker leaves — and is reached by starting
  a session there, from the heading's right-click: the heading's `+` is main's. The worktrees
  under a repository are still kept in order by name, compared the Finder's way, for the readers
  that list them (`hukan status`, the outside client's session list).
  **A subagent is not a row; the row of the session that sent it says what it is doing and where
  its work went.** The desktop app nests the subagents a session sends off under it as sessions of
  their own, and the question was whether this rail should too. It should not, because of what a
  row is here: a session you can speak to, whose approvals land on it. Over `-p` a subagent is
  neither — the engine refuses `send_task_message` there (measured, 2.1.300), and its approvals
  arrive as the parent's `can_use_tool`, so its waiting is already the parent's row's. What is left
  to say is two facts, and both are on the parent's row: a line for each one at work — what it was
  sent to do and the last tool it used, three at most and the rest counted, since a row that grew
  without end would push the other sessions off the column — from the stream's own task events,
  and the worktrees they made, from the engine's
  record beside the transcript (`subagents/*.meta.json`) — the record and not the worktree's
  `agent-<id>` name, which is a convention. Read when one starts or reports and when the session
  is opened, so a session never opened in this window says nothing of what its subagents left.
  **What a subagent did is read inside the call that sent it.** Opening an `Agent` line in the
  transcript puts the subagent's own conversation under its prompt — the engine's file for it,
  `subagents/agent-<id>.jsonl`, found by the call's id in the record, and read when the line is
  opened, the one moment it is wanted. That file is all sidechain, the mark a session's own file is
  read past, so it is read with the mark rather than without. Inside, nothing answers a click: a
  click in an opened call already means fold the call, and a nested call that also took one would
  leave which was meant to chance; and its messages carry no fork or rollback mark, that
  conversation not being the session's to cut.
  **The order is the window's choice of three, and only an order.** When you last instructed a
  session is the default and the one the ages down the trailing edge read in; by branch, and by
  the value of one *kind* of tag, are the other two — the kind because a session carries several
  and a ticket and a pull request are not one sequence, and each falls back to the instruction
  order where it has nothing to say. No headings come with them: grouping by branch would be the
  worktree headings back under another name, and an order costs nothing to undo. An instruction
  is any message the session is given, not only one typed into this window's composer: one sent
  from Remote Control or by another session stamps the order too (and, like a send, takes the row
  out of the Archived fold) — a session driven from a phone otherwise kept the age of its last
  local send and sank while it worked. The agent's own turns — a task notification, a tool's
  result — are not instructions and move nothing. No pinning
  either, there being nothing a pinned row would say that the choice of order does not. The
  choice is a glyph pulling down a menu at the rail's toolbar row — a pop-up naming the order
  would spend the width that row's floor is measured from — and the same items under View and on
  the rail's own right-click, a menu being where an option is looked for. Saved with the window.
  **Above the repositories, a group is a name someone gave, and it is the window's.** One window
  per customer is the arrangement the rail exists to make unnecessary — what is waiting on you is
  the question, and it was split across as many rails as there were customers. So repositories
  gather under named groups, and the membership is made by hand rather than read off the remote's
  owner: that was the obvious derivation and the one the checkouts here refute, one customer
  spanning two GitHub organizations and another a GitHub one and an SVN host, so the rule would
  have needed a table of exceptions written by hand anyway. **It is view state, not a second
  app-global store** — saved with the window beside the folds and the order, keyed by repository
  path, and kept for a repository that has closed, so opening it again in the same window puts it
  back where it was. Nothing of a closed member is drawn: the membership waits in the state, which
  is not the dimmed row Open Recent was chosen over. Opened in another window it arrives loose,
  the one place this can disagree, and the one consolidating into a single window removes. **A
  folded group's heading carries the loudest state inside it** — needing you over working, and
  idle saying nothing — because a fold that hides a pulsing row is the one thing the rail must not
  do, and pulling the row out of the fold, which is what the Archived section does, would undo the
  fold that a customer's whole block was folded to get. The group's heading takes the uppercase
  label the repository had, and the repository its name, so the two levels never read alike.
  **Moving between windows is a transfer, not a close and an open.** Gathering windows into one
  is the reason groups exist, and the cheap version of the move — close it there, open it here —
  stops every engine and shell in the repository and drops every unsaved buffer, so consolidating
  would cost the agents that are working right now. So the objects themselves change hands: the
  sessions keep their engines, the terminals their shells, the tabs their pages, grants and undo
  stacks, and only the closures that name a window are rewired. The tabs leave the source desk
  before the source redraws, since that redraw closes whatever no longer has a worktree. Only a
  repository crosses — a group is a window's own arrangement, and one already open on the other
  side is refused rather than merged, there being no rule for two sets of live objects standing
  for one checkout. It is not a close, so Open Recent does not hear of it, and the source forgets
  its membership there, the move having been the decision.
- **A session leaves the rail by being archived, not by getting old.** The rail carried time
  buckets — Today, Yesterday, Last 7 days, Older, the last folded — and the proxy was wrong in
  both directions: a one-shot finished twenty minutes ago sat in Today all day, while a session
  still working or waiting on you sank into a collapsed Older, which is the opposite of the rail's
  one job. The boundaries also crossed at midnight, so the row you left in place was somewhere
  else in the morning. Archiving is your decision instead: one `Archived` section at the foot of
  the repository's rows, folded until asked. What the buckets
  did carry — when — every row now says for itself, at its trailing edge: how long since you
  last instructed it, which is the sort key, so the numbers read in order down the column where
  "last activity" would not. **Any session can be archived.** It was main's alone while a
  `git worktree remove` took a task's sessions off the rail with its worktree; now that they stay
  (see the repository bullet in `docs/model.md`), the long tail grows wherever the work was. **A
  session that is working or waiting on you comes back out** — the flag stays, the showing is what
  the rule overrides — because a pulsing row must never be behind a fold. **A message you send it
  takes the flag off outright**, which is the difference between coming out and staying out: a
  send is what resumes an archived session, so it is the archiving decided the other way, and the
  only way to decide it that is not the menu item. Under the showing rule alone, a message sent
  to an archived session lent its row the length of the turn and the fold took it back the moment
  the agent answered — the conversation you are in being put away while you watch it, and the flag
  still set to do the same thing on the next send. **Archiving stops the
  engine**: archived means done with, and a process kept alive for a row below the fold is one
  nobody is watching — while without the stop a working session took the flag and stayed on the
  rail until its turn ended, so archiving it looked like nothing had happened. It is the same act
  as Stop Session, confirmed the same way when a turn is under way, and the two differ only in
  where the row goes. Nothing is destroyed: the transcript stays where Claude Code wrote it, and
  the next send resumes it — which is the whole distance between this and Delete Session, and the
  two sit together on the menu for that reason. A fold may hide the
  selected row; the transcript column goes on showing what it was showing, the way a sidebar fold
  behaves everywhere — the buckets needed the opposite rule only because their fold was automatic,
  and every fold left is an explicit one. A count-based backstop (the ninth session archives
  itself) was built and taken out: it is the clock's mistake one variable along. What keeps the
  manual act from rotting is instead that **the rail selects several sessions at once**, so a
  morning's abandoned attempts go in one gesture. Selection stays navigation — the transcript
  column follows the row you touched last, never a "3 selected" placeholder — so what widens is
  only what the context menu acts on; the batch is sessions only, and `approve`/`deny` are
  pointedly not in it, since making a decision cheaper by the dozen is the opposite of why they
  are guarded.
- **A session started outside the window gets its row from the registry, not from a transcript.**
  The rail is built by listing Claude Code's transcripts, and that list cannot answer for a
  `claude` someone starts in a terminal: the transcript is not written until the first message —
  measured at eleven seconds on a session started here, which is simply how long it took to type —
  so the session is working with no row until the next time a repository is opened or the app is
  relaunched, which is the one thing the rail exists to prevent. What is on time is the
  per-process registry hukan already watches for the held-elsewhere state: a record appears the
  moment the engine is up, and it carries the directory as well as the id, which is the whole of
  what a row needs. So the acquire edge that greys a row also *makes* one, held, when the id is
  unknown and the directory is a worktree this window holds. Only the worktree root, never a
  directory inside it: Claude Code keys its transcript directory off the process's directory, so a
  session started one level down is one the transcript listing will never see, and a row for it is
  a row the next discovery drops. The record is written once and never rewritten, which is what
  rules out waiting for the transcript and re-reading on a second event — there is no second
  event. **The two things it then owes are what nothing else will do for it.** Its name arrives
  when its transcript does, so the transcript store is watched — but only while such a row is
  still nameless, since every `claude` on the machine writes into that directory. And a row whose
  process goes without leaving a transcript behind was never a conversation, so it leaves with the
  process: without that, a `claude` started and quit before a word was typed would leave a
  permanent "New session" on the rail, which is exactly the pile of rows standing for nothing that
  this window is supposed to be the opposite of. A New Session opened here by hand is someone's
  intent and stays.
  **Not every record is a conversation, and the registry says which.** `claude remote-control` is
  a persistent server that spawns sessions for a phone, and it and they register here like
  anything else — as `daemon` and `daemon-worker`, against the `interactive` and `bg` that are
  people's. Neither is a row: the server is a server, and a worker's engine is not hukan's to
  speak to — it cannot be resumed (Claude Code filters both out of `/resume` itself), its
  approvals are waiting on the phone, and a row that can only be looked at is the dimmed
  repository row the rail already refuses. What that work leaves behind instead is a *worktree*,
  which git lists and a session started there shows with its ± and its history — the work is
  reachable without hukan pretending the conversation is yours. **The hold is the opposite reading of the same
  record and counts every kind**: what it prevents is two engines writing one transcript, which
  is true whoever the other one is, so the kind is read where the row is made and nowhere else.
  An absent kind is an older CLI's and reads as a session, since the kinds worth excluding are
  ones the engine names.
- **A session's name is the engine's to keep, and hukan only asks.** The engine draws one up from
  the opening message when hukan asks it to (`generate_session_title`, since a `-p` engine names
  nothing unasked), and *Rename…* on the row asks it to take one given by hand (`rename_session`
  as the host, which the engine records as the person's own: `custom-title` and `agent-name`).
  Either way the name lands in the transcript, so `claude --resume` and every other list of the
  session show the same one, and hukan never holds a name the transcript does not — the same
  stance as tags not being written into it, from the other side. **Which name wins is the kind,
  not the place**: the engine re-appends a chosen name and then its drawn-up one every time it
  starts, so a reader taking the last record would undo every rename at the next restart; the
  order is the engine's own list's — agent name, then the chosen title, then the drawn-up one.
  The sheet's *Suggest* is the drawn-up kind on demand (`persist: false`, from the opening and
  the latest few messages, a subject drifting as the work does), offered to edit and kept only
  by Rename. **A session with no engine running cannot be renamed** — the item is off — rather
  than one being started for the length of a rename: renaming is not starting, and an engine
  brought up and torn down for one string is more machinery than the act is worth.
- **A session carries tags, and the agent is the one who writes them.** What a row says it is
  working on — the ticket, the issue, the pull request — is what a person scans the rail for, and
  a title is the wrong place for it: the engine draws a name up once, early, from the opening
  exchange, and a name is one string where the ticket is often known only later and changes as
  the work does. **Several, not one**, since a task's work is a ticket and its PR at
  the least. Each is `kind: value`; **the row draws only the value and the kind picks its
  colour** — a row of `JIRA:` prefixes would be the same word down the column, and the colour
  still says which tracker each identifier is from. The colour is a hash of the kind over a
  handful of system colours rather than a table, so a kind nobody planned for is coloured the
  moment it is written, and it is a hash that does not reseed per process, since the colour is the
  only place the kind is shown and it has to be the same one tomorrow. Two kinds can land on one
  colour; the full tag is the chip's tooltip. **Every row draws its chips in one order**, by kind
  and then by value, so a kind stands in the same place down the column whatever order each list
  was written in — the drawing only, the list being kept as the agent or the editor wrote it, or a
  rewrite and the editor's text would disagree with what is stored. **The chips go on lines of their own under the
  title, wrapping onto as many as they need.** On the title's line one of the two had to give
  way: the chips taking precedence left a session with a ticket and a PR showing two letters of
  its title, and a floor under the title squeezed the status dot and cut the ticket to its first
  letter instead. Under it, neither does. What it costs is that a tagged row is taller than the
  rest and the rail is no longer one height — so a row's height is worked out before the row
  exists, from the rail's width and the insets the source-list style puts around a cell, which are
  measured rather than documented and held by a test against the outline's own frames.
  **A tag can name its page, and the click opens it where a link in the transcript would** — on
  the session's desk, the session selected first since the desk on screen is the selected
  session's, ⌘ sending it out to the default browser instead. The PR an agent tags
  is the PR it just opened, which is what a web tab is for, and one rule for every address in the
  window is what keeps the ⌘ meaning one thing. The address rides in the tag's own string, `PR:
  #42 <https://…>`, rather than beside it: the tool, the editor, the saved state and the scripting
  property then stay one string per tag, and a field for addresses would be a second list to keep
  in step with the first. Only `http(s)`, the transcript's narrow half of the scheme table, and
  the label is cut to what a row holds while the address never is — a shortened address is a
  different page. A chip with no address leaves the click to the row, so labelling a session
  costs nothing in how its row is chosen.
  **They are view state, not master data.** Claude Code has a `tag` record of its own — one
  string, last one wins, carried across a resume — but nothing in the engine writes it, so using it
  would mean hukan appending to a transcript, which it never does; and a tag exists to find a row
  on this rail, which nothing outside hukan draws. So they ride the window's restorable state keyed
  by session id beside the rail's order, and they live on the session object, so a repository
  moved to another window takes them with it. The engine's `pr-link` record is pointedly not read
  into them either: a pull request is tagged by the agent like every other tag, so there is one
  rule for where a tag comes from rather than two.
  **The agent sets them through a hosted tool, `set_tags`, which replaces the whole list** — the
  agent restates the tags it keeps, rather than sending additions and removals that could drift
  from what the row shows; the answer is the list as it now stands. It is answered by the session
  rather than the desk, since it touches no tab, and it asks nobody: it is hukan's own state about
  the session, reaching nothing outside it. The system prompt names the tool (the bullet in `docs/model.md` on
  `EnterWorktree`): left to the tool's description alone, a deferred tool is seen by name
  only, and the agent would tag a session only when told to — which would make the feature depend
  on the person writing the instruction into their own settings. *Edit Tags…* on the row's
  right-click is the same list by hand, one line with commas between, in a sheet: a tag is decided
  against the ticket rather than against the rows around it, which is what keeps a group's name on
  its row instead. One session at a time — replacing five lists with one is a different act from
  labelling a row. The rail's filter matches the tags as it matches the title, since a ticket id is
  exactly what gets typed into it.
- **A session is named out of the window three ways, and all are reads.** The rail's right-click
  copies the transcript's path, the session's id and its agent name — the file to read the
  conversation out of, the id to resume it by, and the name another Claude session messages it by
  — because what is done with any of them is done somewhere else: handed to an agent, grepped
  for, passed to `claude`, put in `SendMessage`'s `to`. **The name is the one that does not last**:
  it is the running process's, in Claude Code's registry, drawn from the directory afresh at every
  start unless the session was renamed, and gone when the process is. So it is read at the click
  and never kept, a session with no engine up has none — the item is off rather than starting one
  to read a name off it — and a batch counts the names it will copy, not its rows. The id cannot
  stand in for it: `SendMessage` reads a bare id as a name and matches nothing, and its explicit
  addresses are sockets, which die with the process too. The path is one item rather than the
  files panel's relative/absolute pair, since a transcript lives in Claude Code's store and has
  nothing in the worktree to be relative to. They sit between the lifecycle items and the Archive/Delete pair,
  which is where the panel puts Copy Path, and nothing may fall between Archive and Delete, whose
  order is what says which of them is the reversible one. **The rest of that menu narrows a batch
  to the sessions hukan owns; these do not** — the narrowing is about acting on another
  process's engine, and naming a session is only reading it. A session that has never run is given
  its path and id as well: its file not existing yet is a fact about the conversation, not about
  the path, which the id and the worktree already decide.
- **A session id is spelt the way Claude Code spells its own.** The CLI names the ids it mints in
  lower case; Swift's `UUID` renders in upper, and hukan supplies the id for every session started
  here, so the store held two spellings of the same kind of thing. Nothing ever opened the wrong
  file — the volume is case-insensitive — so what it cost was invisible and landed entirely on the
  places that compare the two as *strings*: the watch above matched no file it was put there for,
  since every row it watches for is one another `claude` made and therefore one spelt in lower
  case. Reading stays tolerant of either, because the transcripts hukan wrote before this keep
  their names for good.
