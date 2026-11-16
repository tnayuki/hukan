# The transcript

Settled decisions, moved out of CLAUDE.md so it stays loadable. Each bullet is a decision
and the reasoning behind it; read the file before changing the area it covers.

- **The conversation is drawn by a view that owns its height; the text is still TextKit 2's, in
  slices.** It was one `NSTextView` over the whole conversation, and everything it fought was
  the view's rather than the engine's: it sized itself to TextKit's estimate of the text outside
  the viewport and wrote that estimate over a height that had just been laid out exactly, so the
  reader's line moved under them and every placement had to be re-derived from an anchor; a
  history slice landing above the reader cost a layout of everything already loaded, which over a
  climb is quadratic; and a stray call touching a `layoutManager` converted it to TextKit 1
  without a word, taking the washes, the marks and every table with it. Measured against the
  snapshot references, the engine matched them paragraph for paragraph, so the engine stays and
  the view goes. The transcript is written at its two ends and nowhere else — a reply appends, a
  slice is put in front, and the one edit inside is a tool call folding — so each slice is a
  segment with a TextKit 2 stack of its own, whose geometry is the truth inside it; the document
  adds only where each segment starts, its height is a sum of a few dozen exact numbers, a slice
  landing above the reader shifts the scroll origin by exactly what it added, and a fold re-lays
  out the segment it is in. What the view carries itself is what a text view owned: the
  selection and its copy, the cells of a table, the find bar's client, the cursor. What it gives
  up is what a text view gave for nothing — VoiceOver reading the conversation, Look Up and the
  services on a selection — which is the bill, and it was paid knowingly. **It scrolls on the
  main thread, the way an `NSTextView` does**: a plain view is scrolled concurrently by AppKit,
  and a session switch landing while a fling was still running left the overlay scroller
  refusing to show for the gestures that followed, until a click or a focus change reset it —
  found by logging the private knob alpha in the running app, since a synthetic gesture never
  reaches a scroll view without an accessibility grant. **Coming back to a session lands where
  you left it**, unless you left it at the end: the end is where a reader following the
  conversation wants to be whatever has arrived since, and anywhere else is a place they were
  reading, which a session switch is no reason to lose. A search jump and a highlight match
  still come first. The place is this window's fact and is never saved — a restored window has
  no reader to have left one.
- **A link in the transcript opens on the desk, not in the default browser.** The address an agent
  writes is the task's — the PR it just opened, the issue it is working from — which is what a web
  tab is for; ⌘ sends it out instead. Never automatic: hukan following an address out of the
  transcript on its own would be the agent driving the browser, which is the line `approve` draws
  too. Only `http(s)`, which is the narrow half of the scheme table the web view's own navigation
  policy uses — a page already showing may carry on into `blob:`, but a click in another column
  must not conjure a tab out of one. **A bare URL is a link at all only since then**: markdown
  syntax is what an agent writes least, so `gh pr create`'s answer — the most useful address in
  the transcript — was plain black text. The rule is an explicit `http(s)://` up to the first
  space, with trailing sentence punctuation handed back, and no guessing at `www.` or at a bare
  dot, which is what would start colouring `Model.swift` mid-sentence. Code spans and fenced
  blocks are never touched, because code is quoted, not followed. A web tab has no preview slot,
  unlike a file or a commit — the pages an agent hands you are context you want side by side — so
  what keeps them from piling up is that an address already open is switched to rather than opened
  twice.
  **A table's cell is not an exception, and it was one for as long as the table has been drawn.**
  A cell is built by the same pass the prose is, so a URL in one has always been coloured as a
  link — but a table is a single drawn attachment, and a click on it belongs to the drag that
  selects its cells, so the colour was the whole of what arrived: it read as a link and did
  nothing. The link is decided after that drag rather than in front of it, which is what keeps a
  drag that starts on one a selection; a click is the drag that never left the character it began
  on. The pointer turns to a hand over it for the same reason the code mark's turns to an arrow —
  the column's I-beam is the one thing that would say this text is there only to be selected.
- **A table in the transcript is selected in, and what it copies is tab-separated.** It is drawn
  rather than laid out — the cells are fitted to the pane, and the pane's width is known to
  nothing but the layout — so no range in the storage can name a cell, and the selection is the
  table's own. A drag takes characters while it stays in the cell it started in and snaps to whole
  cells the moment it leaves: a run that ends halfway through a cell two rows down is a shape no
  table can be copied as, so the switch is what keeps the highlight and the copy the same thing,
  and it makes taking a column, or a row, the same gesture rather than a mode. **Tabs rather than
  the markdown the agent wrote**, because a table lifted out on its own is going to a spreadsheet
  or to Slack, and Slack builds a real table out of tab-separated text and out of nothing else —
  which was measured rather than reasoned: a `<table>` on the pasteboard beside it is read first
  and the table dropped, and the dedicated tabular type is not read at all. The markdown is still
  what a selection *through* the transcript yields, where the table is one attachment inside prose
  and pipes are what reads there. A block of cells carries the header whether the drag touched it
  or not, since that is what says what the rows are.
- **A code block is taken from its corner, and the mark is drawn rather than typed.** The command
  an agent hands you is what is lifted out of a transcript most, and by hand that is a triple-click
  — a selection gesture that has to be aimed, and that stops being one act the moment the block is
  more than one line. Every fenced block and every opened tool call's body are one builder, so one
  mark serves both; the folded line is not one of them, having no block and a clipped summary. It
  sits at the **top-right** rather than at the vertical centre a message's `…` takes, because a
  slab can be twenty lines tall and the mark has to be findable without reading down it first —
  which is also what makes it cheap, since only the first line has to keep its trailing edge clear
  where the centred mark costs every line one. **Drawn, never text**, the same call the `…` makes
  and for the same reason: a transcript is selected and copied from constantly, and furniture
  nobody said must not come out with the selection — which is also why it is not a right-click
  item, that menu being spoken for. **What it copies carries no trailing newline**, since what is
  copied here is usually a shell command and a newline pasted into a terminal is the command run
  rather than offered. The glyph turns to a tick for a beat, which is the whole of the report
  available: nothing else moves, and the pasteboard is somewhere else. **The pointer over it is an
  arrow**, since the I-beam the rest of the column shows is the one thing that would say the mark
  is text to be selected. The view decides its cursor in one place, asked both when the pointer
  enters the column and on every move within it — the step from the code onto the mark is never
  an entry — and it is a decision rather than a cursor rect, since a rect is in document
  coordinates and covering the marks would mean asking every code slab in the transcript for a
  corner known only once it is laid out. **A fence inside a message
  you typed is not one of these** — a message's own block styling writes over the code block within
  it, so there is no slab there to have a corner, and that corner is where its `…` already is.
- **A double-click selects the whole token, and a token is what an agent hands you.** A commit
  hash, a session id, a branch name, a path, a URL, an option, a file and its line: the things
  this window is read for, each one unit. macOS breaks all of them, and only on a Japanese line —
  it words a paragraph in the language it detects for it, so one kana anywhere puts the rest of
  the line on a tokenizer that splits a Latin run at every class boundary, while the identical
  English line was already right. So no word rule is invented here: **an ASCII run is worded as if
  it stood alone**, and Japanese keeps the morpheme split it already had. **Honouring whichever
  answer was wider was the first rule, and it is the wrong shape** — the Japanese tokenizer calls
  `kebab-case-name` one word where the English one calls it five, so a rule that took the wider
  answer left the same token reading differently on the two lines, which is the bug and not a
  safety net. It belongs to the transcript, the editor and the commit tab at once, all three being
  the same kind of text — and a table's cells, which are not a text view at all and are read the
  same way regardless. It is a gesture: the double-click's meaning wherever text is read, never a
  mode and never a preference.
- **A find is aimed by the focus.** ⌘F finds inside whatever is being read — the conversation,
  or the desk's active tab — because "which column does this mean" is the question ⌃⌘M already
  answers that way, and answering it any other way is what left the transcript with no find at
  all: it was the desk's key whatever had the focus, so the one column with no tab strip to hang
  a field off was also the one column nothing could search.
  **The conversation's find opens what is folded and pulls in what is above, first.** A find bar
  can only see the storage, and the transcript keeps two things out of it: the history above,
  which arrives a slice at a time as the reader climbs, and the tail of every tool call, whose
  folded line is a clipped summary and whose argument in full rides in an attribute. Both are
  reading conveniences, and a reading convenience must never act as a filter on the search — the
  rule the commit tab's find already follows when it opens its cards before searching them.
  **The two index fields are aimed by keys of their own, and ⏎ is still the escalation.** The
  rail's field and the files panel's are not that first key's business — they are indexes, not
  something being read — so each gets one key that lands *in* it and does nothing else. A menu
  item for the escalation was the same offer twice, since the field itself says what ⏎ adds for
  as long as it has the focus; what the second item was actually costing was a key that ran the
  expensive gesture over whatever happened to be left in the field. Each field now names the verb
  and its subject, since a key aims at one of the two and the toolbar item's label is not drawn
  in icon mode.
  **The rail's scan reads the tool calls too, and reads them in full.** It read only what the
  person and the agent had *said*, which sounds like the right narrowing and is not: a
  `▸ Bash  git worktree add …` line is on screen, so a scan that cannot find it is a search
  disagreeing with the window it is in — and once the transcript had a find of its own, that
  disagreement was two fields in one window answering one string two ways. Both readings now come
  off one parse of one file, which is the only arrangement in which they cannot drift; the second
  walk of the transcript that used to produce the narrow one is gone with it.
- **A conversation forks or goes back; it is not edited.** Every message you sent carries a quiet
  `…` once there is something above it, and the two things behind it are the two ways to undo an
  exchange. **Fork** opens a sibling session in the same worktree holding everything above that
  message; **roll back** cuts this conversation back to the same point instead. Which one is right
  is whether the attempt being undone is worth anything: fork keeps the road not taken — an
  agent's long context is expensive enough that throwing one away to try a variation is the
  decision the fork exists to avoid — and rolling back is for the exchange that was simply noise,
  where a branch would only leave a row on the rail to ignore. Both are the engine's own work,
  the same git-owns-the-truth stance as the rest: hukan never writes a transcript, it says where
  to cut and the engine writes what follows. **Where they stop agreeing is how the cut is
  delivered.** A fork is a launch — a second session out of one conversation is what
  `--fork-session` is for, and there is no other way to get one — while a rollback is a message
  to the engine already holding the conversation, which cuts it in place. It used to be a launch
  too, and that meant throwing away a warm process and everything it had loaded in order to undo
  one exchange; the relaunch is now only what a session that is *not* running takes, since there
  is nobody to ask. The engine refuses a cut that would drop a turn hukan never displayed, which
  is why hukan has to keep track of what it has shown — a guard worth having, since the whole
  point is undoing what you saw. Neither deletes anything — a rollback re-parents onto an earlier record and leaves the
  abandoned messages in the jsonl — which is why **a transcript is read as a tree, not a list**:
  the conversation is the chain from the last record back through `parentUuid`, and reading the
  file line by line would show messages the agent itself has forgotten. Files are pointedly not
  part of either: the engine can restore those too, and that would be hukan acting on a worktree
  (`docs/model.md`). The mark is on the message rather than in a right-click menu, because a transcript is
  selected and copied from constantly and the context menu is already spoken for. A held session
  — one another live process has open — can be forked but not rolled back: a fork only reads the
  source, while a rollback is only real once the engine holding the conversation applies it, and
  the engine holding a held session is not hukan's to speak to. A fork is a peer
  on the rail rather than a child of what it came from, because the model has Sessions belonging
  to a Worktree and nothing else; that the two share a past is hukan's own fact, not Claude
  Code's, which is why nothing on disk records it.
- **The agent's task list is a card, not a transcript line, and it is read from the store rather
  than off the wire.** Claude Code keeps one JSON file per task under `~/.claude/tasks/<session
  id>/`, written by `TaskCreate` and amended in place by `TaskUpdate` — so the directory already
  *is* the list, where the calls are only the story of how it got that way, and following them
  would mean replaying a create-then-update stream to work out what it says now. Master data where
  it already is, the same stance as git and the transcripts: hukan re-reads the directory on every
  open and after every task tool's result, which costs a directory listing and a handful of
  few-hundred-byte files (21 in the longest list on this machine), and so needs no cache and no
  watcher. **Restoring after a restart is that same read** — nothing is stored, and no scan of the
  transcript is needed to find what the list ended as. The two calls therefore have no transcript
  line: `TaskUpdate` is a status and an id, which says nothing without the list beside it, and
  `TaskCreate`'s subject is a row of the card already (`TaskStop` and `TaskOutput` only share the
  prefix — they drive background tasks, and keep their lines). It rides in the stack above the
  composer under the same never-modal rule as an approval, but wearing the queued card's quiet grey
  rather than an orange: the cards below it are stopped on *you*, and this one is only the agent
  saying what it is doing. Folded to a row — the count, and the running task in the present-tense
  phrasing the agent writes for exactly that — unless you open it, since a list is context and not
  what you came to read. Opened, it lists **what is left**, not the whole store: the store is
  cumulative over the session, a wall of finished work is not what the card is for, and the count
  carries the finished ones. A task waiting on one that has not landed is drawn as held up rather
  than pending, resolved against the list rather than read off `blockedBy`, since a blocker that
  has since completed blocks nothing. The card leaves when every task is completed, so **a card
  outliving its turn is the signal that the work stopped half-done** — and that signal is free,
  where a rail badge for it would not be: the rail's one signal is the dot, and an agent with
  unfinished tasks is already the pulsing row.
- **A conversation another process is writing is followed by reading its file, not by asking more
  often.** Opened here, such a session's pane is fixed at whatever it said when it was opened:
  there is no stream to hear it on, the engine being someone else's. The file is the one thing it
  says anything through, and the file moving is an event — so the same watch that waits for a name
  carries this too, and nothing is on a clock. **What the follow costs is why it is a tail read
  and not a re-read.** A conversation is the chain walked back from the last line, so reading one
  means parsing every line in the file, and the transcripts here run to tens of megabytes;
  affordable once, when a session is opened, and not at the rate an agent writes lines. So the
  read carries on from where the last one stopped — the bytes taken, and the uuid of the last line
  on the branch. The uuid is what makes the offset safe: a rollback re-parents the tail onto an
  earlier record rather than appending, and bytes alone cannot tell the two apart, so a tail that
  does not hang off the last line taken is refused and the file is walked again. It stops at the
  last newline, never at the file's end, since a line being written is not a record yet. The two
  reads share one reading of what a record means, or a conversation followed and one loaded whole
  would come out different — and the name rides along on the same read, which matters because the
  rows being followed are exactly the ones that went up without one.
