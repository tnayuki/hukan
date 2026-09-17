# hukan

Built for one user, on macOS, for git and Claude Code only. No LSP, debugger, cross-platform,
multiple cursors, or elaborate multi-root features — external tools do those better, and
dropping them is what keeps this small.

This file holds the settled decisions, what is TODO, and how development runs. The README
describes only what currently works; the reasoning behind each decision lives in git history
if it is ever needed again.

---

## Model

```
Workspace (one window)
└─ Repository        ← the open/close unit; identity is git's common dir's parent
   └─ Worktree
      ├─ Session (agent)   ← claude -p over pipes
      ├─ Terminal          ← a shell over a PTY
      └─ File
```

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
  the `git worktree remove` a session runs once its task has landed, noticed as it is run.
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
  the next reconcile drops, and it takes the worktree's sessions with it. That is why the exit had
  to be followed at all — an `ExitWorktree` with `remove` is git ceasing to list a worktree while
  the session in it lives on, and until the session had gone home first, the reconcile stopped the
  one process that had just finished its task. Nothing steers the model toward those tools by
  itself: a `git worktree add` in Bash reaches the rail, since git lists it, but the engine's
  directory never moves and the desk goes on measuring the checkout the session left. So hukan
  appends one line to the system prompt saying to use them. One line, a fact about the tools and
  not a way of working, and **nothing about what hukan is**: identity is not an instruction, and the
  only behaviour it could add is the agent driving the app — what the guarded scripting verbs exist
  to stop. If hukan is ever explained to an agent, it is in the description of a tool the agent
  calls on it, read when it is used rather than on every turn.
- **Session and Terminal are children of a Worktree, not peers of each other** — two
  implementations of one thing, a process running in this worktree. The session's conversation
  has the column beside the desk; the terminal is a tab on the desk, beside the files, commits
  and web tabs of the same worktree.
- **A double-click promotes what it lands on as far as it will go.** A preview becomes a lasting
  tab — the files panel's gesture and the rail's, unchanged — and a tab that is already lasting
  takes the whole window, folding every other column away. One rule covers both halves, which is
  what let the maximize share the gesture that pins instead of buying a modifier of its own; on a
  browser or a terminal, which have no preview state to leave, the first double-click is already
  the maximize. **The conversation maximizes the same way, from its header.** The gesture belongs
  to the strip that names what a column is showing — the desk's tab strip, and beside it the
  session's header — because that strip is also what stays when everything else folds, so the
  thing pressed and the way back are one view. A conversation has no preview state either, so
  there too the first double-click is the maximize; and the rail's rows are pointedly not the
  place for it, since a double-click there already means dive into this session. One key serves
  both, and which column it means is where the focus is: an edge column maximizes the column it
  feeds — the rail's detail is the conversation, the files panel's is a tab — so nothing is
  ambiguous and the second maximize costs no second shortcut. Maximizing is a mode you are in,
  not a state the workspace has: it is never saved with the window (a restored window with no
  rail and no transcript reads as a broken one), toggling any column by hand ends it, and being
  sent to a session — by key, by a tapped notification — ends it too, because what is waiting on
  you is on the rail and in the transcript and the mode must not outlive its own reason. **Ending
  it that way puts back what nothing else can unfold**: the rail and the files panel have toggles
  of their own and keep whatever the act that ended the mode makes of them, but the transcript
  and the desk have none, so a mode dropped where it stood would leave whichever of them it had
  folded with no way to it. Everything that can fold does; the strip stays, because it is the way
  back. **Which is also why neither middle column can be dragged shut**: they were collapsible so
  that the maximize could fold them, and the divider inherited that as a second way in — one with
  no way out, since the only key that unfolds them reads the layout it is entered from and puts
  the same fold straight back. The desk's version of it even outlived a relaunch: what is saved
  is the transcript's width, and a transcript grown over a folded desk is a number nothing can
  tell from one somebody dragged, so the arrangement was replayed and the desk collapsed again.
  Now the drag stops at the column's minimum and the fold belongs to the maximize alone, which is
  what it was added for. The strip's right-click menu is the same set of acts spelled out — the
  four ways to close from a tab, `Keep Open` while it is still a preview, and that maximize.
- **The desk's plain `⌘T` is the browser's; the terminal takes `⌃⌘T`.** Creation is two families,
  `⌘N` for the rail and `⌘T` for the desk, and within the desk the plain key goes to what is
  actually opened most: the shell work here is the agent's, so a terminal a person opens by hand
  is the occasional act, while a task's issue, PR and docs breed tabs by being followed. It also
  makes `⌘T` mean what it means everywhere else, which is what leaves the rest of the desk's
  vocabulary — walking the strip, jumping into it, closing — reading as a browser's. `⇧⌘T` is
  left free for the same reason: beside a browser tab it means reopen the closed one, and a
  terminal on it would take that key from the desk for good. So the terminal sits on the control
  key, beside the window's own `⌃⌘S` and `⌃⌘M`. Zoom keeps `⌘0`/`⌘+`/`⌘-`, so nothing else may
  take them — and which surface they mean is where the focus is, the rule ⌘F and ⌃⌘M already
  read: a web tab's page, or an image's magnification. They are the only two things on the desk
  with a size to change; source is the size it is set at, and a terminal's is the terminal's.
- **The web tab's one field is an address bar and a search box, and the text decides which** — a
  scheme, a slash or a dot makes it an address; anything else is a search. The files panel's field
  splits its two jobs by *gesture* because one of them costs far more than the other and a person
  has to choose; here both are one Return and one request and being wrong costs a back click, so
  nothing is bought by making anyone choose. No public suffix list stands behind the rule — knowing
  that `.swift` is not a real TLD is far more than this is worth — so `Model.swift` is tried as an
  address, fails to resolve, and **the error page offers the search instead**. The engine is one
  constant, not a preference: hukan has no settings window, and nothing separates the engines for
  "the search you would otherwise have run in Safari".
- **A failed load says so, and it says so as a page.** It used to show nothing at all: WKWebView
  keeps the previous content — on a new tab, a white rectangle — and `didCommit` never fires, so
  even the chrome stayed as it was and every wrong address read as "Return did nothing". Drawn as
  a simulated response rather than as a banner over the page, which keeps the failed address as
  the web view's own URL: the address bar stays right and the reload button goes on meaning "try
  again" without hukan having to remember what it means. Its three offers are the whole of what
  can be done next — retry, search for what was typed, open in Safari (the way out for a page
  hukan cannot sign into, since passkeys and iCloud Keychain autofill need entitlements it has
  not got). A cancelled navigation is not a failure and never reaches it: cancelling in
  `decidePolicyFor` is *how* a `kolide://` handoff is handed over, so reporting one would put an
  error page in the middle of the device-trust flow this browser exists to get through.
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
- **The web tab's chrome reads the view, and the tab does the host's half of WKWebView.** The
  address, title and history buttons are KVO on the web view, not the navigation delegate:
  `didCommit` fires for a document load and nothing else, and GitHub — the page this browser
  exists for — moves between an issue and its PR without one, so a chrome synced there stayed on
  the first page all day. The field is never written while it is being edited (the sync catches
  up when editing ends), because now that it is a search box the half-written line is its usual
  state. The rest is what a page assumes its browser provides and a bare WKWebView does not, each
  of which failed silently: a popup that closes itself (`webViewDidClose`, how an SSO popup ends)
  took its tab with it or left an empty one; `<input type=file>`, `alert`/`confirm`/`prompt`, a
  download (into Downloads, the Dock stack bouncing — Safari's own signal and the whole of the UI
  a download gets), a name-and-password challenge, a client certificate (looked up by the
  issuers the server names, no chooser — this machine has one device certificate). Reload is Stop
  while loading, with a progress line under the bar. ⌘F is the commit tab's field, in the pane's
  own row: WebKit's find is a step, not a list, so the label says only that there was nothing to
  find. **A popup lands on the worktree of the page that opened it**, which is not necessarily the
  one on screen: a sign-in finishing in a background worktree's tab must not swap the desk out
  from under the rail's selection, so it joins that worktree's tabs and waits there — and a page
  whose worktree is gone is declined, so WebKit drops the popup rather than loading it into a
  view no one will see. A page retitles itself several times while loading; that relabels one
  tab in place rather than rebuilding the strip. No process pool: it was set on the belief that it
  shared the sign-in, and it never did — the persistent data store does, and WebKit has managed
  its own processes since macOS 12.
  **A ⌘-click opens the link as a tab of its own, and the tab is what has to read the click.**
  WebKit asks for a new view only when the *page* asks for one — `target=_blank`, `window.open` —
  and hands a modified click over as an ordinary link activation carrying the flags it was made
  with, so a ⌘-click followed the link in place until that was measured. ⌘ opens the tab behind
  the page being read and ⌘⇧ opens it in front, which is Safari's allocation and the whole
  difference between the two: the reason the gesture exists at all is not leaving the page you are
  on, and a tab in front is what every other way of opening one already gives. It goes through the
  same open as those, so the reuse rule holds — an address already open is not opened twice, and
  behind, it is not switched to either, since the strip is carrying it already and not moving is
  what was asked for. A link marked `download` is still a download, whatever was held down. That ⌘
  means something else over the transcript — send it out to the default browser — is the same rule
  read per column rather than a collision: in a page the useful answer is the tab beside this one,
  out of a transcript it is Safari.
  **Reload is the browser's own key, and it never becomes Stop.** A web tab is the one surface on
  the desk with a manual re-read to give — a file, the tree and the history all come back on the
  batch FSEvents hands them — and the button holds both meanings only because it can show which
  one it is holding, where a key that reloads or stops depending on how far the page has got is
  one you cannot press without looking first. Stopping is Escape's instead, and it reaches the tab
  only if the page did not want it: that ordering is the whole reason it is not a menu key
  equivalent, since one of those is matched before the page ever sees the event and would take
  Escape from every menu and dialog a page has.
- **A web tab is shared with the agent per tab, on a card the agent's own call raises.** The
  tools are hukan's — list the desk's tabs, open one, read one, load an address in it, screenshot
  it, run JavaScript in it — hosted in-process on the session's own stream: a name in the engine's
  `initialize` and its JSON-RPC arrives as control requests, the same door `set_model` and Remote
  Control go through. No second process, no config file, no socket, and the call arrives on the
  stream of the session making it, so whose tabs it means is a fact rather than an argument
  anything on the machine could forge. It is read off the shipped binary, like the permission
  prompt tool, and re-verified on upgrades. **The tab is the unit of consent**, where every other
  browser agent scopes it to a site: a site is what nobody is looking at, and a hukan tab belongs
  to a worktree and was opened for its task. **The call is the request**: a tab it has not been
  given stops the session on a card naming the page and the address, with three answers — read,
  read and drive, or not at all — and the answer stays with the tab rather than the call, which is
  what lets the standing yes be narrow instead of the whole permission mode. **Opening a tab is
  the same card asked before the tab exists**, and the tab is made only on a yes, already shared
  and showing — the yes is the click, and opened behind it sat on the strip reading as an open
  that had not happened. It shows only on the worktree the desk is on: which worktree that is
  belongs to the rail's selection, not to the agent. That is also why
  hukan's own tools never reach the generic approval card, and why the grant is asked for whatever
  the mode says: a `can_use_tool` is not sent under `bypassPermissions` at all, so a gate hung off
  it would be gone exactly where it mattered, and a mode loosened for a checkout was never a
  decision about the person's logins. **Driving lapses when the tab leaves the site it was granted
  on; reading does not.** A read that lapsed on every link would make following a PR a card per
  click, and a drive that survived a navigation would be consent to act on a page nobody saw —
  the shape of the hole that has been found in browser agents' origin checks. The person never
  meets the word origin: the glyph goes hollow, and the next drive asks again. The glyph is the model picker's sparkles —
  the agent's mark in this window already; the symbol set has no robot, and the chip is the
  toolbar's load gauge — and a wand once the tab may be driven, two glyphs rather than a fill. One grant serves
  every session of the worktree, since the tabs are the worktree's and so is the task. **Never
  saved**: a grant back after a relaunch would be hukan making it again tomorrow on nobody's
  behalf, and a grant that lives nowhere on disk is one nothing can forge — the other attack on
  browser agents' permission stores. What the grant is not is a boundary on identity: every tab
  shares one cookie store, so inside a shared tab the agent is the person, on whatever the page
  reaches. That is the whole reason it is asked for, and the reason the hidden `browser` verb's
  loading half is guarded now — a session's agent reaches `osascript` with no prompt in the way,
  and that verb steered a logged-in tab with no card in front of it.
- **The whole strip comes back after a relaunch, at the tab that was showing.** Each tab is saved
  as what identifies it and nothing more — a worktree and a relative path, an oid, a directory
  and a scrollback, and for a web tab WebKit's own `interactionState` (the back/forward list and where
  each entry was scrolled) held opaque beside the title and address, so the tab can be named and
  found by address before it loads. It rides the window's restorable state keyed by worktree,
  passed in from the desk because the model has no view to read it off. **Nothing is read until
  its tab is looked at** — a restored window may carry a dozen tabs across its worktrees, and
  reading them all at launch is what a browser's session restore is known for; a saved web title
  holds until the page reports its own, or every restored tab would rename itself to a bare host
  name the moment it loads. What does not come back is what has nothing left to show: a blank web
  tab (one keystroke to make again), a file or a worktree that is gone, a commit a rebase dropped
  — that last one unchecked at launch, since nothing answers it more cheaply than reading the
  commit, so the tab says so when it is opened. **The strip's order is saved apart from the tabs**,
  one row per tab naming only its kind, because a row is then answered by position in that kind's
  list — and a tab that did not come back is a row past the end of its list, which the strip
  closes up over. **The showing tab is a place in that order**, applied once the strip is in it:
  the terminals arrive on a reload of their own, before the rest of the strip is on it, so an index
  spent at the first reload available is spent against half a strip. **A showing tab is a fact about
  a strip, not about the desk**, so there is one per worktree and every one of them is saved. The
  desk holds every worktree's tabs at once and shows one worktree's, and a single showing tab was
  the desk standing in for each strip: switching the rail away left the reconcile nothing to land
  on and it fell to the end of the new strip, which is then what the old worktree came back to as
  well. Saving only the showing worktree's would be that same bug one relaunch later — the desk you
  were looking at right, every other one on its last tab — where coming back to a worktree is the
  same act whether the window was restarted in between or not. A restored tab is
  lasting, never a preview: a preview is what the last click made of a tab, and a relaunch is not
  a click.
- **A window that closes, and a quit, ask about every unsaved edit first.** The same Save / Don't
  Save / Cancel a closing tab gets, since closing the window closes every tab, and a Cancel keeps
  the window. It is the other half of restoring file tabs: hukan holds no copy of an unsaved
  buffer — that would be a second copy of the file outside git, which is the line master data
  draws — so without the prompt a quit dropped the edit silently and put the tab back on the file
  as it stood on disk, which is the worst of the three available answers. The alternative was hot
  exit, VS Code's and Zed's: carry the unsaved text across too. Refused for the copy it costs,
  not for the convenience it buys.
- **A terminal's tab is named the way Terminal.app names one** — the command holding the pty
  while something is running, the working directory's last component when nothing is. The path
  relative to the worktree is the alternative, and the one thing it buys — two tabs in one
  worktree that can never read alike — is a distinction rarely needed, paid for in length: the
  tab worth finding is the busy one, and the busy one says `make` or `claude` itself. The
  directory half arrives free — OSC 7, which the stock `/etc/zshrc` emits at every prompt because
  hukan poses as `Apple_Terminal` — but the command half does not: nothing announces a command
  *starting* (`sleep 60` writes no byte), so the window polls `tcgetpgrp` on the master fd twice a
  second. That is two syscalls per terminal per tick, which is why the poll needs no bookkeeping
  to be affordable and why it stops the moment the last terminal goes. The name only, never the
  arguments: `git` fits a tab where `git log --oneline --graph` does not.
- **The file pane is the source, and only the source.** It had a Diff/Source switch; the diff
  was unreadable-as-work — a coloured diff cannot be edited, and the files carrying a diff are
  exactly the ones an agent just wrote and you want to correct, so the mode you needed was always
  the one you were not in. What survives of the diff is the signal, not the text: the per-file
  diffstat in the toolbar says how much moved, and the files panel's changed scope says which
  files. The reading of the change itself belongs to the PR the agent opens. It does not name the
  file either: a header saying `Model.swift` directly under a tab saying `Model.swift` is the same
  word twice, and it charged the file 36pt to say it. The one thing that header carried alone —
  the dot for an unsaved edit — moved onto the tab, beside the ✕ that would discard it, which is
  where the state and the act that destroys it belong together.
  **A file it cannot read as text says so, and refuses the keyboard.** The read fell back to an
  empty string, which is not the same answer as an empty file: it lands as a buffer that can be
  typed into, and ⌘S writes that buffer back — so a `.zip` opened by a mis-click and one keystroke
  was the archive gone, silently, with the tab still claiming to show it. The note stands where
  the text would be and the pane is left uneditable, the same call the browser's error page makes
  for a load that failed. The ruler goes with it: a gutter row is a file line, and a note has none
  to number.
- **A file whose content is pixels is drawn, and it is drawn at actual pixels.** It is not a
  second kind of tab: a buffer is `(Worktree, relative path)` whatever the bytes are, so an image
  is this pane answering differently — the strip, the order, the restoration and the scripting all
  carry on not knowing. What decides is **a table of extensions**, because both tests that look
  like the right one are wrong in the same place: `NSImage(contentsOfFile:)` and `UTType`'s
  `.image` conformance each say yes to `.svg` (measured), which is source an agent edits and has
  to stay in the editor. `.pdf` is the one image-ish thing left out on purpose: a page is drawn
  from instructions rather than held as pixels, so the promise below has nothing to attach to.
  Anything else falls through to the note above, which is also where an image too large or too
  broken to draw says so: the same answer in the same place, so a `.png` that is refused never
  reads as a `.png` that is empty.
  **Which bitmap is on screen is hukan's own decision, because a file may hold several.** An
  `.icns` here holds ten, 1024 down to 16, and `NSImage.size` answers 512 — neither the largest
  nor the size of any single one of them — so leaving the choice to AppKit means the pixel count
  under the picture is a guess about a file it is not the whole of. Every bitmap is measured
  before any is decoded (ImageIO answers a dimension without decoding a pixel) and **the largest
  is drawn**, named by index rather than by asking for "the image": largest because an icon
  container is opened to be looked at, and by index because the order is the file's — this `.icns`
  happens to put 1024 first and nothing in the format says it must. The caption says so when
  there is more than one, or it is a true number about the wrong thing. That rule is what brought
  `.icns` into the table and what `.ico` needed all along, being the same kind of file: excluding
  one and admitting the other was one decision made twice.
  **Actual pixels means one image pixel to one *device* pixel, which is a fact about the display
  and not about the file.** The alternative reading — one pixel to one point — is a 2× upscale on
  this machine, and the file being looked at most is a screenshot of text, so it would be read
  blurred. `NSImage`'s own `size` cannot answer it: it is the pixel count divided by whatever DPI
  the file claims, and the DPI in real files is noise — hukan's own 2× snapshot references say 72,
  and a `@2x` asset in the wild said 96, which is neither its pixels nor its intended size. So the
  pixels are read from the header (ImageIO answers that without decoding, the same shape as
  `git_patch_size` answering in bytes without building the patch) and the scale from the window.
  A side effect worth having: a `@2x` asset then draws at the size it was cut for, with nobody
  parsing `@2x` out of a filename. It is re-measured when the window changes display, since the
  statement is about the display; **and the centring is landed on the backing grid**, because
  centring is exactly the arithmetic that produces the fractional origin that would resample a
  1:1 blit back into softness.
  **What does not fit scrolls**, which is the rule the editor beside it already follows for a long
  line — this pane never shrinks its content to the column. Getting closer is the trackpad's: one
  property (`allowsMagnification`) brings the pinch and the two-finger double tap, and the zoom
  keys are the way back, where `⌘0` is not a figure of speech but the rung at which the pixels line
  up again. The ceiling is per image, because far enough is a size on screen and not a factor —
  4× of a 16px icon is still 32pt of nothing — and the magnification survives an agent rewriting
  the file under the reader (a refresh should change the picture, not the place they were looking
  at it from) but not a relaunch, for the reason a web tab's zoom does not: what a restored tab
  carries is what identifies it.
  **The checkerboard is under the image and nowhere else.** Drawn rather than an asset, out of two
  semantic fills so it follows the appearance, and clipped to the image's own rect — one running
  out over the pane would say the whole column is transparent. There is no border around the image:
  drawn inside it covers the outermost row of the file's pixels, and drawn outside it grows with
  the magnification into a frame nobody asked for. The caption under it — the pixel count and the
  size — is drawn rather than set in a label, because a label is a control and AppKit rounds a
  control's intrinsic size to the *screen's* backing grid, the one thing a pinned snapshot cannot
  pin. It is the only place the pixel count is stated at all, now that the drawing is half as wide
  as it on a 2× display.
  **What the pane gives up saying so**: an animated GIF stands at its first frame, animating one
  meaning an `NSImageView` laid over the checkerboard rather than drawn into it; ⌘F is aimed away,
  an image being the one surface on the desk with no text for a find bar to reach; and there is no
  gutter, no base and no dirty state, so nothing here can be saved or asked about on the way out.
  **And there is no image diff**: the file pane has no diff at all by the decision above, so a
  changed image is the one on disk and what it replaced is the PR's to show.
- **Space previews the row, and the previewer is the system's.** The Finder's key and the
  Finder's panel, which is the whole of what makes it affordable: a `.pdf`, a `.mov`, a font, an
  archive are all answered without hukan learning a thing about any of them — and those are
  exactly the files the pane next door refuses, that one being the editor, reading text and
  drawing the handful of bitmap formats it has a table for. So this is not a second file viewer
  growing beside the first; it is the one look at a file that hukan does not have to write.
  **It is a look and never a way in**: it closes on the same key, and opening a file to work on it
  stays the double-click's and ⌘↓'s. Which is why a *directory* gets one too — the row with no tab
  to open at all is the row a preview has the most to add to. **It follows the selection while it
  is up**, so ↑/↓ walks the tree with the preview keeping up, a run of files being read one after
  another rather than a row guessed right the first time; the panel holds the keyboard while it
  shows, so those two keys are handed back to the tree and nothing else is — the panel's own keys
  are the system's, and a key nobody claims must go on meaning what the panel says it means.
  What it takes the key from is type-select, which a tree narrowed by a field of its own has no
  use for. **It is in the right-click menu as well**, because every key this panel has is: ⏎ is
  Rename, ⌘↓ is Open in New Tab, and a menu is where a key is found by someone who does not
  already know it is there. Not on the panel's background, which is not a row and names no file;
  and from the menu it opens rather than toggles, a menu item being a thing chosen where Space is
  a key pressed twice.
- **A row drags out as a file URL, and a file dropped on the panel is the same read from the
  other side.** The composer already takes a file dropped from the Finder and turns it into an
  attachment chip — the agent reads it from the path the chip carries — so the panel had only to
  write the same thing a Finder drag writes, and dragging a row onto the field attaches it. The
  path is absolute for that reason: it is what goes to the engine, and it must not depend on where
  the engine is standing. It is the opposite call from the rail's rows, which stand for a checkout
  and so refuse `.fileURL` outright — a repository row offered to the Finder would be a folder
  anyone could take, where these rows *are* files, and being good in the Finder and in any editor
  is a side effect worth having. **Directories drag too, and the rule that used to keep them from
  it has moved to the composer**: a folder must not become an attachment chip, a chip standing for
  a file the agent will read — but saying that at the row was saying it in the one place it could
  not hold, since a folder dragged out of the Finder always walked straight past it, and a folder
  that cannot be picked up is a move that works on half the rows.
  **Out of the window it stays a copy; inside it, a drag is a move.** An index must never be able
  to move the file it points at somewhere hukan cannot see, which is the half of that rule a
  destination cannot enforce — but the tree *is* the worktree, so landing a row in another
  directory is the rename that carries directories, read as a gesture rather than typed, and it
  reports itself as one so an open tab follows the file, everything under a folder included. ⌥
  turns it back into a copy with nothing spent on saying so, AppKit having already folded the
  modifiers into the mask the destination is handed; a drag from another window's panel is another
  checkout, and copies. A drop *between* two rows is retargeted onto the directory those rows are
  in rather than refused — the rail's reorder idiom, and here there is not even an order to take a
  position in, the tree's being the disk's. Never onto a result list, whose rows are hits rather
  than places.
  **A name the destination already has gets the Finder's three answers** — Keep Both, Replace,
  Stop, with its Apply to All, since a drop is the Finder's gesture and this is the one place
  hukan runs it; Keep Both spells `Model 2.swift`, the " 2" the untitled name already uses, with
  the number before the extension. What is not offered is Replace for a *directory*, which is
  deleting everything in it: the one place this panel destroys a directory is behind Delete's own
  alert, so a folder whose name is taken is refused instead. Nor Merge, the one answer that leaves
  no row afterwards saying which side won. **A dropped file opens no tab**, unlike one New File
  makes — that one is a file you are about to write in, where a drop may be twenty at once, so the
  row the panel selects is the whole of the report. What it does owe is a re-read of the
  *contents* and not only of the name, since a file it replaced may be the one a tab is showing.
- **An outside path opens inside the worktree that contains it.** One resolution for every
  hand-off — a Finder drop, the CLI helper, a terminal's `$EDITOR` file, the `edit` verb behind
  both: the deepest open worktree containing the path claims it, its repository is opened first
  when none does, and a directory git does not know opens as itself, the degenerate case the
  model already has. What is under `.git` is the repository, not the checkout — a COMMIT_EDITMSG
  must not become a phantom row of the checkout it configures, and a linked worktree's lives
  under *main's* gitdir — so those open as outside files, keyed by absolute path (no twin exists
  for the `(Worktree, relative path)` rule to guard against), on the desk of the worktree that
  *asked*: the requesting terminal's, which is why the request carries who asked at all. A path
  that does not exist is refused out loud — a file handed to `open` used to be swallowed with a
  clean exit, the same "Return did nothing" the browser's error page fixed.
- **The terminal's `$EDITOR` is hukan itself, and closing the tab is the editor exiting.** The
  bundled helper by absolute path — nothing installed on PATH, and the Dev build's terminals
  reach the Dev app — riding one public verb, `edit`, whose `waiting` holds the Apple event's
  reply until the tab closes. Injected as a default, not forced: a profile exporting its own
  editor runs later and wins. Inside hukan's terminals the event is self-addressed, so the
  automation prompt never appears; outside them a plain open goes through `open(1)`, and only
  `--wait` costs the one-time prompt.
- **What has changed includes what git has never seen.** The working-tree diff carries untracked
  files, counted as added — `git status`'s reading of the question rather than
  `git diff HEAD`'s — because a file nobody has run `git add` on is the whole of what a brand-new
  file is, and a brand-new file is what an agent produces most. While they were excluded, nothing hukan measures a
  change with counted the file an agent had just written: not the ± scope, not the toolbar's
  diffstat, not the rail, not the row's own numbers — they all read this one diff. Ignored files
  stay out, which is the half of libgit2's default worth keeping.
- **The gutter is where the diff signal reaches line granularity** — change bars beside the
  line numbers, never a second text mode. Stagedness is the bar's fill — solid working-tree,
  hollow staged — because the color already carries the kind: green added, blue rewritten, a
  red wedge for a deletion boundary. **The bars measure the buffer, not the file on disk.**
  They hid while the buffer was dirty at first — the file on disk being what git can answer
  about — and that is backwards: the lines you most want marked are the ones you are typing,
  and the mark going out exactly when you touch it is the moment it was needed. What it costs
  is holding the file's text at HEAD and in the index for as long as it is open, so an edit
  re-diffs two strings rather than asking git per keystroke. **A change stays marked until it
  is committed**, and staging only hollows it — which is a different question from "what is not
  yet staged", and the answer to that one empties as you stage.
  **Hovering a bar opens the block it belongs to** — the lines as they read at the base above
  the lines that replaced them — because a bar says *that* something changed, and the only way
  to see *what* was to leave for the PR. A block with nothing removed opens nothing: its added
  lines are already on screen. The card never takes a click; reading is all it is for, and
  acting on a hunk — stage, revert — is git's, per the worktree rule below.
  The editor never wraps a line: a gutter row is one file line, and wrapping would split that
  line across rows. Long lines scroll sideways, and wrapped reading stays the transcript's,
  for prose.
- **Highlighting is a rendering attribute, not text.** tree-sitter parses (vendored grammars,
  see the Build note) and the colors land as TextKit 2 rendering attributes — so the document,
  its undo stack and the dirty state never learn highlighting exists, and the buffer stays
  exactly what a save writes. The whole file is re-parsed rather than incrementally: a parse
  costs less than a person types, and a whole-file one cannot fall out of step with the buffer,
  which an incremental one drifting by a unit at a time very much can. Past a size no one edits
  by hand the file is left plain.
  **A file is often more than one language**, so a grammar's own account of which of its ranges
  belong to somebody else is followed rather than ignored: a fenced block in Markdown is
  coloured as the language it names, and Markdown's emphasis is a second grammar again. A
  language named but not vendored is left plain.
  **A patch is the case that says what an injection actually is.** A `.diff` opened here reads as
  the file it patches: the grammar names the language by naming the file, so the extension table
  answers it, and the rows of a hunk are cut out, joined and parsed *together* — a grammar handed
  a single line gets its strings and comments wrong at both ends, the same reason a commit's diff
  is coloured from the file's parse and not the hunk's. So an injection is a set of ranges rather
  than one, and a span coming back is placed by which of them it fell in. What the join costs is
  that it is approximate by construction: the hunks skip what lies between them, so the text
  parsed is not any file that ever existed. Every editor that colours a patch takes that trade,
  and there is no other on offer — a patch on disk has no file behind it to read instead.
  **Which side a row is on is a band, not a colour.** They are two facts about one row — this
  line was added, this line says `func` — and only one of them can be the foreground. The commit
  tab settled that already, so a patch opened as a file takes the same reading and the same
  colours, or one window would read a diff two ways. It costs a rendering surface that reaches
  past the row's own text, which is what a fragment subclass would charge every paragraph — the
  transcript draws its washes under the fragments instead — and what this editor was built not
  to; so it is asked for only in a file whose grammar bands rows
  at all, and every other file keeps the stock surface. The band never enters the storage — the
  buffer is exactly what `⌘S` writes, which is the line the colours already hold to — so unlike
  the commit tab's, which reads a fill off an attribute in text hukan itself built, this one is
  looked up in a table beside the document.
  **Only a patch carrying the `diff` line it was produced by** is read this way: without one the
  grammar builds no hunks and the payload is left plain. Every patch git writes carries the line,
  which is what makes this worth having in a git-only app; a bare `diff -u` gets its frame
  coloured and nothing else.
  **Bold and italic are drawn, not set.** A rendering attribute cannot carry a font — the
  advances were measured before it arrived — and putting the font in the storage instead would
  be the end of the document not knowing about highlighting. So emphasis is drawn over the
  glyphs the layout already placed, by thickening and shearing them where they stand. Synthetic
  rather than the font's own bold, but the file is monospace prose being checked, not typeset,
  and it keeps the buffer exactly what `⌘S` writes.
  **Plain is a style, not the absence of one.** A grammar's captures are written to correct
  each other — one paints a range and the next says part of it belongs to nobody — so a theme
  that answers "nothing to say" for the second leaves the first standing. Being deliberately
  plain and never having heard of the name are different answers, and the theme gives different
  ones.
  **The parse is the whole file; the question asked of it is what is on screen.** They are two
  costs and only one of them can be narrowed. A parse picked up in the middle gets the strings
  and comments wrong at both ends — the same reason a commit's diff is coloured from the file's
  parse and not the hunk's — so it reads everything, always. Running the highlights query and
  re-parsing every injected language is a *search of the tree the parse built*, and on a long
  file that is most of the time: measured here, a 1568-line Swift file spends 19ms parsing and
  18ms querying, and this file spends 50ms parsing and 146ms on the languages inside its fenced
  blocks. So the query is aimed at the viewport with a margin either side, and a fence outside
  it is not parsed at all. It is safe because tree-sitter returns every match that *intersects*
  a range, so a node enclosing the whole of it still arrives and the nesting the spans are built
  from is the nesting the whole file would have given — which is a property a runtime bump could
  quietly break, and so is what the tests assert rather than the timings.
  **The parse is then kept, and that is not the incremental parse this file declines.** Nothing
  is edited into a tree here; the text it was built from is held beside it, so it can only be
  reused by proving the buffer has not moved, and a tree that no longer matches its text is not
  a stale answer to be noticed later but one the lookup cannot return. What it buys is that
  asking a second question of the same text — which is what following the viewport is — costs
  the question and not the parse.
  **What is on screen is coloured first, and the rest follows without being asked.** Stopping at
  the viewport would mean every scroll starts a query and waits for it, and there is nothing to
  wait for once the tree is built. So the coloured front grows outward from the viewport a step
  at a time until it reaches both ends, and then stops for good, leaving the file coloured
  exactly as a whole-file read would have left it. Only the first step clears — the later ones
  are adding to a file that is already on screen, and clearing there would take the colour off
  the lines being read for as long as the next slice takes. A scroll faster than the front is
  the one thing this shows: text arrives plain and fills a beat later, which is the trade every
  editor that does this makes.
- **The history a worktree shows is its branch's log, read a page at a time.** The History section
  at the foot of the files panel walks first-parent from HEAD, newest first, one page of 50; going
  past the last row read asks for the next page, and the limit lives on the worktree so every
  other reason to re-read git — a commit landing, a branch moving — hands back what has been paged
  in rather than the first page again. It listed `<base>..HEAD` once, and that bound made the
  section *disappear* the moment the branch was pushed: on a checkout in sync with its remote
  there is nothing past the base, so the one thing the list is asked for most — what landed
  recently — was the one thing it would not show. The base is still read, and it is still the
  remote's default branch (a local `main`/`master` with no remote), but it now marks rather than
  bounds: **the fork-point rule sits between the commits this branch put down and the ones it was
  cut from**, and a checkout with nothing of its own draws no rule at all. A page that stopped
  before reaching the fork draws none either — the count is capped at what was read, and a rule on
  the last row would be claiming to know where a branch began when the walk never got there. No
  lane graph still: a task branch is nearly always linear, and the one structural fact worth
  having is that rule. The upstream is consulted only for the unpushed dot, never as the base: a
  pushed task is exactly the one being reviewed, so pushing must not empty the list. **A tag is a
  rule too, above the commit it names** — the same idiom and the same reading as the fork point,
  which is that the ref below the line is what everything above it is not in yet. It is the one
  structural fact the *main* checkout has, where the fork rule never draws (a branch in sync with
  its base has nothing of its own to divide), and it says what the release commit's summary does
  not: that the tag exists at all. It carries a tag glyph, or two rules in a row would be two
  facts drawn identically. What it cannot say is whether the tag was pushed: a tag lives in
  `refs/tags` whichever side it came from, so unlike a commit's dot there is no local answer, and
  libgit2 is built here without the network to ask for one — whether a release actually went out
  stays the GitHub question the TODO covers. Several tags on one commit are one rule naming the
  first and counting the rest, with the whole list in the tooltip: running the names out to an
  ellipsis instead squeezed the rules and then the glyph out of the row, leaving a line of grey
  text that read as no kind of row at all. Ordered numerically rather than lexically, the
  Finder's rule, since the dictionary's puts `v0.10.0` above `v0.9.0`. **A commit
  opens as a read-only tab**, which is where the diff hukan removed from the file pane is allowed
  back: that pane's Diff/Source switch failed because a coloured diff cannot be edited and the
  files carrying one are the ones you want to correct — but a commit is finished, so the coloured
  diff is not a mode standing in front of the text, it is the text. The list is per-worktree
  (it is HEAD's) while the commit is per-repository (git's object database is shared), which is
  why the tab's identity is the oid and not `(Worktree, oid)`. The section is folded from the
  toolbar's row over this column — beside the ± and the panel's own toggle, where the panel's
  filter and scope already went for the same reason: the panel is full-height, so its first row
  belongs to the bar. It carried a `History · <base>` header of its own first, and both halves of
  that were wrong: a chevron there is one operation with two controls, and a title over one half
  of a panel whose other half has none reads as decoration. What the title was actually carrying —
  the base — is now **the rule closing the list**, which says it where it means something (this is
  where the task began, the one structural fact a lane graph would have carried) and, by being
  absent on a capped list, says the cap too. Folded, the section is not a stub but gone.
  **The line above the section is the panel's own divider**, not a hairline: the tree gave the
  section a fixed seven rows at first, and seven rows is not a reading of a log — the one thing
  the section is asked for is "what did this task put down", which is as long as it is. Making it
  a split is also what makes folding it the same act as folding the panel one level up (the item
  collapses; the section stops measuring itself), and the height rides in the window's restorable
  state beside the column widths, for the same reason they do. Dragging it shut is remembered as
  folding it, or the next worktree with commits would push open a section that was deliberately
  closed.
- **What git has underway is part of the history, not a separate readout.** A rebase stopped on a
  conflict, a merge waiting to be committed, a bisect — `git_repository_state` answers which in
  one read of the gitdir, and the step count is read from the files git already wrote there
  (`rebase-merge/msgnum` of `end`, or `rebase-apply/next` of `last`) rather than through
  `git_rebase_open`, which opens a rebase in order to *drive* it and hukan does not act on
  worktrees. It belongs to the history because it is the history that stops making sense without
  it: a rebase replays onto a detached HEAD, so `<base>..HEAD` loses the branch's own commits
  until they are re-applied one at a time — on a checkout in sync with its remote the list empties
  outright — and that happens on a worktree whose files are full of conflict markers. A section
  that quietly empties is the worst available answer, so the operation is also what keeps it on
  screen when there is nothing to list. The enum is not the label: git has run every rebase
  through the merge backend since 2.26, leaving an `interactive` marker even for a plain
  `git rebase main`, so libgit2 says `REBASE_INTERACTIVE` for both — saying "interactive rebase"
  because the enum did would be reporting git's plumbing rather than what is happening. The same
  read gives the worktree its name back: a detached HEAD's shorthand is the literal `HEAD`, so a
  rebase used to cost the rail and the top bar the branch they name it by.
- **In that tab the file is the unit, not the commit — and the tab is a stack of cards, not a
  document.** It was one text view holding the whole commit first, headers and message and all,
  and that is what a patch file looks like rather than what a change looks like. One document has
  one layout, and the two halves of a commit disagree about it: a message is prose and wants the
  column's width, while a diff line is code and must never be split across two gutter rows. So the
  message is a wrapping label and each file is a card — a header of real views (git's status
  letter as a pill, the path with its directory held back, the diffstat) over its own diff. The
  header is the fold, and the whole strip takes the click, because what is being aimed at is the
  file and not a chevron the size of a full stop.
  A card's diff is read, coloured and laid out only once it is open, so the tab costs what is on
  screen and a 5000-file vendor drop opens at once — its delta list is free, and nothing under it
  is built until it is asked for. What opens on arrival is a line budget spent in file order,
  passing over what does not fit rather than stopping there — stopping hands you a wall of folded
  cards whenever the expensive file sorts first, and a card that is shut still carries its own
  diffstat, so it says why. Past 300 files the cards stop being built at all, since a card is real
  views and ten thousand of those is a freeze of a different kind; what is left out says so at the
  foot of the list rather than being quietly dropped.
  Inside a card there is no `diff --git`, `index`, `---` or `+++` — the header said the path
  already, so four lines per file would say it again — and no `+`/`-` column: which side a line is
  on is a full-width band behind it and the blank half of a two-column gutter, old number then
  new. Taking the sign out of the text is what makes a line copy as code. The colours are the
  editor's tree-sitter, mapped per line from *the file's* parse rather than the hunk's, since a
  hunk starts mid-scope and a grammar reading one alone gets its strings and comments wrong at
  both ends. The caps are per file — 20,000 lines, or a megabyte — so a wall is one file wide and
  the rest of the commit still reads; the byte half is what catches the minified file, which is
  two changed lines and three megabytes and which no count-based cap sees coming. Renames are
  folded back into one card (`git_diff_find_similar`), or a directory move reads as twice the work
  it was and spends twice the budget saying so.
  The search is the tab's own field rather than a text view's find bar, because what it has to
  cross here is more than one text: it marks every occurrence in every open card at once — in a
  diff the useful question is usually "where else", not "next" — and Return steps through them. It
  opens what it can afford before it searches, since a fold is a reading convenience and must
  never act as a filter on the search.
- **The reads are bounded by what they cost, and it was measured.** Against synthesized
  repositories: the list costs its page and not its history — 0.41ms for 50 rows on a
  5000-commit repository, 1.83ms for 500. That is only true because the walk is *unsorted*
  (`GIT_SORT_NONE`): first-parent simplification off one tip leaves a single chain, so it comes
  out newest-first by construction, while asking for a topological sort makes libgit2 preload the
  whole history before yielding a row — the same 50-row page measured 13.7ms sorted, a number set
  by the history's depth rather than the page's size, and a refresh runs per FSEvents batch for
  every open worktree. Two other things were not free. Asking
  `git_graph_descendant_of` per row for the pushed marker cost *rows × history depth* (8.2ms for a
  full list), against the 1.3ms of everything else a refresh does — and a refresh runs per
  FSEvents batch for every open worktree, which is the shape that buried the machine when these
  reads were subprocesses; one walk of `upstream..HEAD` answers the same question exactly, in
  1.2ms. The tags are the same shape of question and were bounded the same way: the scan grows
  with the *repository*, not the page, so it runs only on a wholesale refresh — a ref lives in
  git's own directory, so a batch narrowed to paths in the working tree cannot have moved one,
  which is the reasoning that already keeps the index out of a narrowed read — and it is read
  through a glob-restricted ref iterator, which is not a detail: on a checkout with 1462 tags and
  4871 refs the same answer costs 28ms through `git_tag_foreach` and 25ms through
  `git_reference_foreach`, both of which walk every ref and look each one up again, against 8.4ms
  for the one that walks the packed table's `refs/tags/` run once. The map is repository-wide
  rather than page-wide, which is what makes paging free: a page reaching further back is already
  answered. And a commit tab built its text whatever the commit's size: a 5000-file vendor drop took
  363ms to read and 812ms to lay out, the second of those on the main thread. Capping the *commit*
  was the first answer and it was not an honest one — the cap counted changed lines, while what
  gets laid out is the patch, which carries every hunk's context too (measured at 4.5× the
  changed-line count where the edits are scattered), and no count sees a minified file's megabyte
  on one line at all. Making the file the unit is what fixed it: the delta list is free, a section
  is read only when it opens, and the one commit-wide gate left is the 500 files past which
  per-file line counts are dropped rather than counted — counting means building every delta's
  patch, which is 363ms, where the list without them is nothing. That also took the commit's read
  from three passes over its content to one: `git_diff_get_stats` and `git_diff_to_buf` both went,
  and the per-delta patch that was already being built answers what they were asked for. All of it
  now costs about what the reads it rides along with cost, which is why none of it needed a cache:
  the cheapest version of this is no bookkeeping at all.
- **Linked worktrees are children of the repository heading, not top-level rows beside it.** The
  heading is still the main worktree (the common dir's parent), naming its branch after the
  project name, with main's sessions straight under it; the linked worktrees sit beneath as rows
  of their own, each folding with its sessions. They stood beside the heading once, and that made
  a repository a run of rows rather than one thing: the fold, the indent and the drag all had to
  be done by hand, and a hairline down the gutter stood in for the level the tree did not have.
  As children the outline does all of it and the hairline has nothing left to say. They sit
  under a `Worktrees` heading of their own, beneath main's rows: a repository's children are two
  kinds, and the label is what tells the block of worktree rows from the session rows above it
  — which a `Sessions` label over the sessions would not do, since a worktree's rows *are* its
  sessions and the label would name the obvious.
  **They are ordered by name, which git only looked like it was answering.** hukan held no
  opinion about the order at first, on the grounds that the worktrees are git's enumeration and
  an opinion would be a second copy of something git already answers — but the enumeration is
  `git_worktree_list`, which reads `.git/worktrees/` in the directory's own order where the CLI's
  `git worktree list` sorts, so what the rail read down was neither the order they were made in
  nor any order visible on screen; and a `git worktree add` noticed mid-session was appended
  after all of them, so it drifted further the longer a window stayed up. The name is the
  directory's, which is what the row's title says (the branch is its subtitle) and what the CLI
  sorts on — compared the Finder's way, the same rule the History section's tags take, so
  `task-9` comes before `task-10`. It is a rule the list is kept in rather than an arrangement
  anyone makes, so nothing new is saved for it: the repositories' order is still yours to drag
  and still rides the saved paths, while the worktrees under one come back sorted from the paths
  themselves.
- **A session leaves the rail by being archived, not by getting old.** The rail carried time
  buckets — Today, Yesterday, Last 7 days, Older, the last folded — and the proxy was wrong in
  both directions: a one-shot finished twenty minutes ago sat in Today all day, while a session
  still working or waiting on you sank into a collapsed Older, which is the opposite of the rail's
  one job. The boundaries also crossed at midnight, so the row you left in place was somewhere
  else in the morning. Archiving is your decision instead: one `Archived` section at the foot of
  main's rows, folded until asked. What the buckets
  did carry — when — every row now says for itself, at its trailing edge: how long since you
  last instructed it, which is the sort key, so the numbers read in order down the column where
  "last activity" would not. **Only main's
  sessions can be archived** — a linked worktree *is* the task, and the `git worktree remove` that
  ends it takes the worktree off the rail with its sessions, so nothing accumulates there; the long
  tail is main's alone, the one-shot questions asked where you happened to be standing. **A
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
  which git lists and the rail shows with its ± and its history — the work is visible without
  hukan pretending the conversation is yours. **The hold is the opposite reading of the same
  record and counts every kind**: what it prevents is two engines writing one transcript, which
  is true whoever the other one is, so the kind is read where the row is made and nowhere else.
  An absent kind is an older CLI's and reads as a session, since the kinds worth excluding are
  ones the engine names.
- **A session is named out of the window two ways, and both are reads.** The rail's right-click
  copies the transcript's path and the session's id — the file to read the conversation out of,
  and the id to resume it by — because what is done with either is done somewhere else: handed to
  an agent, grepped for, passed to `claude`. One item each rather than the files panel's
  relative/absolute pair, since a transcript lives in Claude Code's store and has nothing in the
  worktree to be relative to. They sit between the lifecycle items and the Archive/Delete pair,
  which is where the panel puts Copy Path, and nothing may fall between Archive and Delete, whose
  order is what says which of them is the reversible one. **The rest of that menu narrows a batch
  to the sessions hukan owns; these two do not** — the narrowing is about acting on another
  process's engine, and naming a session is only reading it. A session that has never run is named
  as well: its file not existing yet is a fact about the conversation, not about the path, which
  the id and the worktree already decide.
- **A session id is spelt the way Claude Code spells its own.** The CLI names the ids it mints in
  lower case; Swift's `UUID` renders in upper, and hukan supplies the id for every session started
  here, so the store held two spellings of the same kind of thing. Nothing ever opened the wrong
  file — the volume is case-insensitive — so what it cost was invisible and landed entirely on the
  places that compare the two as *strings*: the watch above matched no file it was put there for,
  since every row it watches for is one another `claude` made and therefore one spelt in lower
  case. Reading stays tolerant of either, because the transcripts hukan wrote before this keep
  their names for good.
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
- **The rail navigates between tasks; the files panel navigates within one.** The rail lists
  worktrees, sessions and what is waiting (approvals) — bounded state, which is why one field
  searches it, under the same typing-filters / Return-searches rule as the panel's (titles are in
  memory; transcripts are files, so reading them waits to be asked for). It listed the changed
  files too, briefly, and that was redundant: the panel's changed scope already answers "which
  files", next to the tabs where they open. Finding a *file* is the files panel's, docked on the
  desk's trailing edge, with its own field. The tree once sat on the rail and made the rail's
  search have to span files and transcripts at once; moving it out is what lets the two searches
  stay two fields with two scopes. It was briefly a tab on the desk instead, which was worse: a
  tab needs an editor inside it to show what it found, so the same file became editable in two
  places and wanted a
  shared-buffer machine underneath. As a panel it is an index and nothing else — every pick opens
  a tab, so a file is read and edited in exactly one place, and the preview tab is the detail view
  the results list would otherwise have had to grow.
- **A column's minimum width is the toolbar row over it, so it is the display mode's too.** The
  edge columns carry their own chrome in the bar — the panel's filter, ± and History over the
  panel, the rail's filter beside the sidebar toggle — which is what fixes their floors: squeeze
  a column past its row and the filter runs out into the section next door, reading as a field
  belonging to nothing. `Icon and Text` writes a caption under every glyph and so widens every
  section: the ± alone goes from 44pt to the width of "Changed Files Only", and the row stops
  fitting a panel measured for icons. The bar's own right-click menu offers that mode and
  **nothing supported declines it** — `allowsDisplayModeCustomization` is the flag for it and it
  works, but refusing the mode is refusing to lay out, which is the wrong half of the problem to
  solve. So the floors are read off the mode instead (KVO; the property is documented
  observable) and the columns are pushed as wide as the captions need — 372 for the panel
  against 280, 296 for the rail against 280, each measured the way the originals were. The desk
  pays the difference, which is the right pocket: it is the cost of a choice its owner made, and
  it is refunded the moment the bar is icons again. The window's own minimum is the three floors
  added up, so it moves with them — leave it behind and the split view is asked to honour floors
  that do not fit inside it, which produces the same spill by another route. What the widening
  must not do is outlive the mode: the mode is not saved (a restored window's toolbar starts at
  icons), so **nothing measured while the captions are up is recorded** — not the panel, which
  the floor pushed out, and not the transcript beside it, which paid for the push. It is one
  arrangement belonging to a mode that will not be there next time, and the widths from before
  it are the ones that still mean something. `ToolbarRowFitsTests` measures both modes, and that
  the columns widen and hand the width back while the window stays open.
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
- **One field over the tree, two operations, told apart by gesture — and both of them are one
  `rg`.** Typing filters the tree by path; Return searches contents, and the panel becomes a
  result list until Escape. Running both off the same keystroke was built and removed: it greps
  the worktree on every character, and it has to flatten the tree to show what it found, so the
  filter stops being a filter. There is still one field and no prefix syntax, and what matched is
  always explicable: a filter matches a path component that contains what was typed, and
  everything under a directory whose name does, so `Tests` narrows to that directory's contents
  and `Hukan/Files` narrows by two components at once; a search matches a literal line,
  case-insensitively. Neither is a regular expression — someone filtering for `*.swift` means
  those characters, and the query's own glob characters are escaped on the way to rg.
  **Both readings used to be hukan's own**, matching a list it had walked and held: a plain
  case-insensitive substring, ASCII-folded because Foundation's `.caseInsensitive` was most of
  what made a whole-worktree scan take ten seconds. rg answers the same questions without the
  list — which is the point, since the list was the memory — and its case folding is Unicode's,
  so `CAFÉ` answers to `café` again. The one thing the old rule did that this one does not is
  straddle a separator inside a component: a `/` in the query now has to line up with one in the
  path, which is what a raw substring over the whole path never required.
- **The expensive gesture has to visibly take.** ⏎ empties the list it is asked from — the files
  panel's, and now the rail's — before anything is read. Leaving the rows up through the scan is
  showing the answer to the *other* question while this one is being read, and on the rail it also
  suppressed the note that would have said so: that note draws over an empty list, so a title
  filter with one hit was enough to hide it for the whole scan. An emptied list says nothing at all
  until the note is due, since calling it "no matches" for that beat would be answering a question
  still being read.
- **Neither gesture may be a wait you cannot leave.** The scan reads every file in the worktree,
  so it says that it is searching, and a query typed over it *drops* the one still out rather
  than letting it run to the end while the next waits behind it — an agent writing files re-runs
  the search on every FSEvents batch, which without that is a queue of ten-second reads. The tree
  half has the same duty in the other direction: an empty panel is ambiguous — git has not
  answered yet, or it has and the worktree is empty — so until git *has* answered the panel says
  it is reading. Saying "No files" there is a claim about the worktree that nothing has
  established. Both notes wait a beat before appearing, since an answer that lands in
  milliseconds would only flash a word and take it away. And the wait itself is cut where it can
  be: a worktree's first read arrives in two hops rather than one — which files there are, then
  what has moved in them — because the tree needs only the index, and bundling that with the
  measuring made it wait on a diff that stats every file in the checkout.
- **A filtered tree opens itself as far as a budget, not all the way.** It opens at all because a
  narrowed tree's point is to be read at a glance — but one character typed against a large
  worktree narrows almost nothing, and opening every row of that was most of what a keystroke
  cost. So the opening is a budget spent in tree order, and what does not fit stays folded —
  which is the state a tree row is readable in anyway.
- **The panel's right-click menu is where hukan writes to a worktree — with the drop above the
  other way in — and both write files, never the repository.** Open in a tab, Reveal in Finder, a terminal in the row's directory, Copy
  Path, then New File, New Folder, Rename and Delete. The path copies **two ways, as two items**:
  the relative one is what is wanted nearly every time — it is the unit a buffer is keyed by and
  the form a path is written in to an agent — and the absolute one was briefly its ⌥ alternate,
  which is the wrong saving, since an alternate is reachable only by someone who already knows it
  is there and a menu is where you look precisely when you do not. **⏎ names the selected row** —
  the Finder's key, and Xcode's navigator's. It was the open, matching the rail's dive into a
  session, and naming took it because naming is the one act on a row with no other way to it from
  the keyboard, while opening keeps the double-click it always had and gains ⌘↓. Only in the tree:
  a result list is hits rather than rows of it, and there ⏎ keeps the meaning it always had.
  **A name is typed on the row, not in a dialog** — the row already says what is being renamed, so
  a sheet would say it a second time and take the window to do it, and a new file's name is decided
  against the rows around it, which is what a sheet stands in front of. That decides New File too:
  the file is **made first under an untitled name and then handed to the same edit**, the Finder's
  order, so there is one naming mechanism instead of two; what it costs is that Escape leaves an
  `untitled` behind, which is the Finder's bargain as well. **While a name is being typed the tree
  holds still**, since in a worktree an agent is working in a redraw arrives every second and takes
  the field with it; it catches up the moment the name is finished, a read held back and never run
  being worse than the flicker holding it back avoids. A name may carry directories, read against
  the directory the row is in and made on the way — which turns a rename into a move as the same
  rule read from the other side, a name box that quietly cannot reach a new directory being the
  worse surprise. It cannot leave the worktree: `..` is refused rather than resolved, since the one
  thing a name typed on a row must not be able to mean is a file somewhere else. **Delete is
  confirmed and then deleted, not moved to the Trash.** None of this moves the line `hukan observes
  worktrees, it does not act on them` draws: that one is about the repository — the merge, the
  `worktree remove`, the decision nobody reviewed — where a file in a checkout is something any
  session already writes with a shell, and having to leave the window to rename one bought nothing.
  What the acts do owe is a report of themselves, since nothing else will notice them: a tab
  showing a renamed file follows the name, one showing a deleted file closes, and git is re-read.
- **The files panel's tree is the worktree as it is on disk, and git is laid over it.** It was
  git's path list at first, and every hole that list had was patched one at a time — untracked
  files, then empty directories, and the next was the ignored files, which were to be shown too.
  At that point the list was the filesystem with extra steps. So the disk is what is listed, and
  what git answers is laid over it: the diffstats, and the dimming. **An ignored file is a row,
  dimmed** — it is in the worktree whether git wants it or not, and the dimming is what keeps a
  build directory from reading as the work. **The listing is lazy and off the main thread**, so a
  checkout of any size costs what is on screen and a file a build or an agent just wrote appears
  when its batch lands, without waiting on git and whether git will ever see it or not. **Nothing is walked because a
  worktree was opened.** The tree lists the directory it is showing and hands that listing to
  `WorktreeIndex`, which keeps it only so that a later FSEvents batch can be answered by
  comparison — so what is held is what someone opened, a bound nobody had to choose. It used to be
  the whole worktree, walked once when a repository opened and kept: every directory's entries
  plus a flattened list of every path, which is what the filter and the search matched against.
  The walk's only bound was git's ignore rules, and **git answers nothing at all outside a
  repository**, so a plain directory was walked to the bottom however large it was — and the plain
  directory people actually open is the home directory. 4.56M entries here, about 174 bytes each
  held: three quarters of a gigabyte spent because a window was opened. A budget was the obvious
  answer and the wrong one: it is a number nobody can defend, and it makes the filter quietly
  partial in a way the person then has to be told about. What replaced it is not a smaller walk
  but no walk — the two gestures produce their own answers and drop them (see the bullet above),
  and the ± scope is git's changed set, as before. Everything under `.git` stays out of all of it,
  being the repository and not the worktree.
- **The panel's own costs were measured, and what was left after rg is the drawing.** git was
  never the slow half — the working-tree diff and the index read are tens of milliseconds — and
  the reading half is not hukan's any more: a content search it used to do itself took 10.5s over
  a 25,000-file checkout, nearly all of it Foundation's case-insensitive matching, where rg
  answers the same query over a 60,000-file one in 0.03s. What stayed hukan's is what happens to
  the rows. A keystroke in the filter cost 272ms of the main thread — 33ms matching every path,
  239ms opening every row of what survived — and the second of those is still paid: the opening
  is budgeted, and the rows are inserted in one batch, since `expandItem` reloads the view around
  every row it inserts and that alone was 58ms of the 239. The matching is gone from that number
  because it happens in the other process. And the held-elsewhere rescan re-listed Claude Code's
  process registry once *per session on the rail* — 42ms of the main thread for 121 of them, on
  every FSEvents batch under that directory — where one read of it answers for every session at
  once.
- **What a gesture costs, it costs again — nothing is kept between two of them.** A filter is one
  rg per keystroke, the one before it killed as the next starts: 0.03s on this checkout, and on a
  home directory 10s, which is what a question about 1.56M files costs anywhere. Holding the walk
  instead was built and measured — the second keystroke free, the first one 170MB of resident
  memory for as long as the field had text in it — and dropped, because a bound that only exists
  while nobody looks at a large directory is not a bound. The rows stream in as rg finds them, in
  path order, so a filter fills rather than waiting; a search does the same, with no cap on the
  hits and no size at which a file stops being read. The old scan had both, a 2000-hit limit and a
  2MB file, because it was reading every file on this machine's own cores and a query like `e`
  would otherwise have cost ten thousand rows of work nobody asked for. What still does not get
  read is a binary file, which is rg's default and was the old rule too.
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
- **Remote Control is a control request on the open stream, and the engine does the bridging.**
  It puts one session on claude.ai/code and the Claude app while the process goes on running here,
  and hukan reaches it exactly as the VS Code extension does — `{subtype: "remote_control",
  enabled}`, the same door `set_model` goes through. That it is a request and not a slash command
  is what makes it available at all: `/remote-control` is a `local-jsx` command, drawn by the REPL
  it runs in, and it is not even in the command list a stream-json engine reports, so a composer
  that offered it would be offering a dead word. **The line this does not cross is the outbound
  one.** hukan opens no socket and sends no credential — the engine bridges, hukan only says
  when — which is what leaves the cask check the one request hukan makes for itself. What it does
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
- **hukan says when a newer hukan has been released, and Claude Code is not watched at all.** The
  engine updates itself — the native installer writes `autoUpdates: false` to disable the *legacy*
  npm updater and sets `autoUpdatesProtectedForNative`, which exempts its own — so there is nothing
  to tell you that will not have happened by morning anyway. The cask does not follow anything, so
  hukan is the one of the two that can go quietly stale.
  **This is hukan's one outbound request, and the line around it is the whole of why it is
  allowed**: one fixed URL, GET, nothing sent, no credentials, nothing about the work. libgit2 is
  built network-less on purpose and the browser's traffic is the user's own; this is neither, so it
  is stated as a constraint rather than as a beginning.
  **It reads the cask, not the tag's GitHub Release.** The two disagree for a minute at a time —
  `release.yml` publishes the Release and pushes the cask that points at it afterwards — so a check
  against the Release API lights up in a window where `brew` still has nothing to give, which is
  hukan and Homebrew answering one question two ways in one glance. Reading what actually installs
  makes them one file. Hourly, `If-None-Match` so a 304 costs no body, and a failed read leaves the
  last answer standing: a machine with no network has not learned there is no new version. Release
  builds only, since a Dev build's version is whatever the working tree says and would announce
  every release from the moment it shipped.
  **The arrow sits at the toolbar's trailing edge** by the scope rule above — true of the whole
  window, as its two neighbours are — and only while a release is ahead, the way the plan usage
  shows only once there is a plan. Accented rather than secondary-tinted, because it is the one
  item in that cluster that acts instead of reads; both version numbers are in the tooltip, the bar
  having no room for them and the glyph having only to carry that there is something to do.
  **Asking early is a menu item, and it is pointedly not a second answer.** `Check for Updates`
  sits under About, the block that names the app itself, since what it asks about is which hukan
  this is. The check is hourly and a 304 costs no body, so the command is not what keeps the answer
  current — it is only the way to make it current at the moment you thought to wonder. So its title
  never moves and it opens nothing: a row reading `0.5.1 available` under a bar already carrying
  that would be the same fact twice, and one reading `up to date` would be a second place to look
  for one answer. It carries no ellipsis for the same reason. The About panel held the reading
  first and that is the wrong room — About is where you go once you already suspect, where a menu
  is already open in front of you. Disabled while a check is in flight, so a second press does not
  read as the first having missed — and on a Debug build, which is never what Homebrew installed:
  without that, a Dev window offers to upgrade the Release app beside it, a button whose action is
  about a different program than the one it is sitting in.
  **Pressing it hands one command line to Terminal.app, the road `/login` already takes** — one
  handoff (`ExternalTerminal`) rather than two, for opposite reasons: the login needs a TTY the
  stream-json engine has not got, and the upgrade needs a process that is not hukan's child, since
  what it replaces is the bundle hukan is running out of. **Nothing quits**, which is what keeps
  what is handed over to a single literal instead of a script with quoting inside it: Homebrew
  unlinks the old bundle rather than writing over it, so the running process keeps the inode it
  started from and is untouched until it exits. A quit-first version had to wait for the app to go,
  abort if a Cancel on an unsaved edit refused it, and carry all of that through three levels of
  escaping — for nothing, since the last word is a relaunch either way, said in that terminal.
  **The cask is named in full** (`tnayuki/hukan/hukan`), which is not decoration: Homebrew
  auto-updates before `upgrade` once every 24 hours by default, so a release published today is
  invisible to a plain `brew upgrade --cask hukan` for the rest of the day — hukan pointing at a
  version Homebrew then reports it already has. An argument naming a third-party tap in full drops
  that interval to five minutes, which the shell does for exactly this reason. `brew update` in
  front would close the remaining minutes and pay for every tap on the machine to do it.
- **A `/` at the head of the composer completes, and the list is the engine's.** Its built-ins
  and every skill and user command it found arrive together in the startup reply, undistinguished
  — which is exactly what a completion list wants, since the person typing `/` is not asking
  where a command came from. So there is no table of commands here and no directory to scan, and
  a skill added on disk is offered the moment an engine has restarted. Typing filters, Return or
  Tab takes the row, Escape puts it away — each of those already means something in the composer,
  so the list only borrows them while it is open, and Escape reaches it before it reaches the
  turn it would otherwise interrupt. A slash command is the whole message or it is nothing: the
  name runs to the first space, after which what is being typed is the argument and the list has
  nothing left to say, and a `/` anywhere but the first character is a path. **One list per
  window, never saved.** Every session in a window talks to the same install, so the first engine
  up answers for the rest — which is what makes a `/` typed into a session that has never started
  complete anything at all — while a list read at launch would be a stale answer for as long as
  the window lived, and offering a skill that has since been removed is worse than offering
  nothing. `/login` and `/logout` are the exception hukan supplies itself: the engine lists only
  commands it would run, and those two it hands back to be run in a terminal, so the one command
  a signed-out session needs is the one its engine could never have named.
- **What has already been asked completes too, and the bridge is the reading.** The composer is
  ASCII when the input method is off and the prompts typed here are Japanese — 97% of 13,000
  sends — so the two are joined by how a prompt *reads* rather than by its characters: `kentou`
  finds 検討して. That is macOS's own Japanese tokenizer answering, a morphological reading and
  not a transliteration, which is why this is possible at all — no character rule can choose 検討's
  reading. One spelling is settled on for both sides, so which of the several ways a reading and a
  keyboard each write it hardly matters: a long vowel spelt out or written with a macron, the small
  tsu against a doubled consonant, Hepburn against the kunrei-style an IME takes just as happily.
  What the reading cannot do is disambiguate — 日本語 comes back `nippongo` — and it reads an
  initialism aloud, so `PRを作って` is `pīāru…` and the `PR` a person would type survives only in
  the text. **So the text is matched beside the reading**, which is also what leaves an ASCII word
  in a Japanese sentence findable as itself.
  **It shares the slash list's panel and its keys**, because it is one act: the field is completing
  what the whole message will be, and where the candidate came from is not a distinction the person
  completing it is making. **What it does not share is the selection, and that is the difference
  between a list asked for and a list offered.** A slash list is reached for — `/` is typed, and
  while it stands there Return can mean nothing but "take a row" — so it opens on its best match
  and Return is a keystroke saved. A reading's list opens by itself over ordinary text, where
  Return already means send, so it opens on no row at all: the ASCII messages sent as they stand
  are acknowledgements — `yes` 248 sends, `ok` 111, `dou` 33 — and every one of them is also a
  query that opens this list, so a row selected before anything was aimed at it turns the sends
  this composer makes most into a prompt nobody chose. Sharing Return was tried and that is the
  cost it carried: those sends went Esc then Return, which is a list standing in front of the
  message rather than beside it. What enters it is an arrow — up, since the list reads bottom-up,
  so the best match is one key away — or Tab, which takes the best row outright and is where the
  keystroke Return gave back is kept: Tab has no other meaning while a list is open, and Return
  now has one. A digit or a single letter is still kept out, by the two-character floor and by
  there having to be a letter at all, since a query that matches most of the history answers
  nothing whether it is selected or not.
  **The list reads bottom-up, best nearest the field.** The panel stands over the transcript
  because the composer is at the foot of the column, so a ranking that starts at the top puts the
  best answer as far from the caret as the list is long. The slash list turned round with it: one
  panel, one order, and the arrows then read as they look. With nothing selected the walk starts
  from the field itself, which sits below the bottom row — up enters at the best match, down wraps
  round to the far end.
  **The store is the transcripts**, the same stance as git and the session list — nothing is
  written and there is no cache, a cache being a second copy of another tool's master data.
  `~/.claude/history.jsonl` looks like the source and is not: the CLI writes it from its
  interactive REPL only, so it holds 131 lines against those 13,000 sends. The scope is the
  repository's worktrees, git's set: a worktree git stops listing takes its sessions off the rail,
  so its prompts leave with them. Read once per repository per window on a background queue, with
  what is sent afterwards appended, since the one prompt a snapshot could never offer is the one
  typed a minute ago. **The scan is Foundation's rather than a byte loop**, which is not a style
  choice: the same loop written in Swift costs 236ms optimised and 36.6 *seconds* unoptimised over
  one repository's 268MB, so the Debug build spent a minute on what a release spent a quarter
  second on. Handing the newline and the key to Foundation costs 430ms in either build.
  **What it does not buy is keystrokes**, and that was measured too: only 7% of the prompts here
  were ever typed twice, and the ones that repeat — `どう`, `続けて`, `yes` — are far too short to
  be worth completing. What is long enough to complete was typed once. So it is for recalling how
  something was asked, not for typing it again faster, and it is scoped and shaped accordingly.
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
  (below). The mark is on the message rather than in a right-click menu, because a transcript is
  selected and copied from constantly and the context menu is already spoken for. A held session
  — one another live process has open — can be forked but not rolled back: a fork only reads the
  source, while a rollback is only real once the engine holding the conversation applies it, and
  the engine holding a held session is not hukan's to speak to. A fork is a peer
  on the rail rather than a child of what it came from, because the model has Sessions belonging
  to a Worktree and nothing else; that the two share a past is hukan's own fact, not Claude
  Code's, which is why nothing on disk records it.
- **A change on disk reaches the file it changed, and no other.** FSEvents is asked for the
  paths that moved rather than only that something did, and a refresh re-reads the open files
  named in them. Re-reading is not free — it is a whole-file parse and a highlight, and it takes
  the reader's selection with it — so one agent write must not cost every tab on the desk one.
  What cannot be placed is not narrowed — a commit or a staging moves what every open file is
  measured against while touching none of them — but a wholesale *question* is no longer a
  wholesale *report*: a refresh answers with what it observed, the entries that actually differ,
  and claims "everything" only when HEAD or the index moved between this read and the last
  (the index by the checksum git writes at its tail, so a rewrite with identical content is not
  a move). Echoing the question was a race: a read asked for wholesale observes whatever lands
  while it runs, so an edit made during one was reported as everything having moved and cost
  every open tab a re-read.
  **The same batch narrows what git is asked, and that is where the size of a checkout is paid.**
  The working-tree diff stats every file there is, which on a very large one is seconds, and it
  ran per batch — so an agent's write cost a walk of the whole checkout. It is now
  `git diff HEAD -- <the paths that moved>`, which libgit2 answers by walking only where they
  point rather than by filtering a diff it has already taken in full: 97ms whole against 12ms for
  one path on a synthesized 50,000-file repository, nearly all of the 12 being the index both of
  them load. What comes back answers for those paths and no others, so it is folded into the
  changed set rather than replacing it — a path asked about that the diff did not name no longer
  differs from HEAD, which is how a file edited back to what HEAD holds leaves the set. **A path
  asked about may be a directory, and the fold reads it as one**: libgit2 answers a pathspec with
  everything under it, so what leaves the set is what is under the path as well as the path
  itself. The two disagreed for a while, and the case that says so is an *untracked* file moved
  out of a folder — a tracked one comes back as a deletion at its old path, where an untracked one
  is not mentioned at all, so its entry survived every later read as a file that no longer existed
  and the ± went on counting it until something moved HEAD or the index and forced a whole read.
  Directories reach the fold from every side: a folder renamed, deleted or dropped on, and an
  agent's `mv`, which FSEvents names as the directory itself. The index is not read again at all
  then: it lives inside git's own directory, so a batch that named
  nothing there cannot have moved it. **hukan's own writes ask the same question and answer the
  other one differently**: a save and the files panel's edits raise no event at all (every watcher
  carries `IgnoreSelf`), so they say what they wrote and git is asked about exactly that — but
  nothing is re-read, the buffer already holding what went to disk.
  **A wholesale question collapses the same way.** When the repository moves — a commit, a
  staging — nothing in the working tree was written, so the answer can only have moved where
  HEAD went since the last read, where the index stands off HEAD, or where it already differed:
  two metadata diffs name the candidates, the changed set is unioned in, and the same pathspec
  read answers (6ms against 103 on the 50,000-file repository, growing with the change rather
  than the checkout). The whole diff remains only where it is honest — a first read, or nothing
  left to measure from.
  **A worktree's files and its repository are watched apart, on a stream each.** They are
  different questions — one narrows to what moved, the other cannot be narrowed at all — and
  FSEvents coalesces per *stream*, so a batch is answered by the worst thing in it. While the
  main checkout carried both on one, its `.git` being inside the subtree, a `git status` an
  agent ran arrived in the same batch as the file it had just written and the file's name was
  dropped with it. A linked worktree always had the two, its repository living outside it; the
  file stream is now told to leave `.git` out, so every worktree is watched the same way and the
  mixing cannot happen rather than being sorted out afterwards. **Most of what is written in a
  repository moves nothing**, and an answer of yes costs a read of the whole worktree, so the
  batch is asked path by path: the object database, the reflog, the lock file every operation
  takes and drops, the message an editor is handed, the hooks — and another worktree's
  directory, which holds that worktree's own HEAD and index and is watched on its own, so while
  it counted an agent working on a task re-read the main checkout from top to bottom on every
  command it ran. The heaviest of those never leave the stream either — bar the one that turned
  out to carry a second question, below. Anything not recognised as churn counts, since what is
  being decided is whether to read, and a read nobody needed is cheaper than a reading left
  stale.
  **What the repository moving also moves is the branch's name and the set of worktrees, and
  both used to wait for the window to be focused.** That is the one moment they cannot be
  needed: the window is the one being worked in, so it never lost the focus to come back to,
  and the read the repository's own stream already wakes had by then swapped the history and
  the ± over to the new branch while the rail and the top bar went on naming the old one. So
  the branch is read on the wholesale question and on no other — a batch that named files in
  the checkout is by construction one that did not move HEAD — which costs one more repository
  open on a read that already makes several, and is reported apart from the files, a branch
  move being what they are measured against rather than one of them.
  **The set of worktrees is the other half, and nothing on disk reported it at all.**
  `git worktree remove` writes nowhere outside `.git/worktrees/<name>`: no ref moves, no file
  in any checkout moves, and that directory was excluded from the stream outright — for the
  reason above, a task worktree's own HEAD and index being in there. So the end of a task was
  invisible, which is the one thing about a worktree this window most has to notice. It is let
  through now and asked a second, narrow question: the registry directory, a worktree's own
  directory, and its `gitdir` file, which is what `git worktree add` and `git worktree remove`
  were measured writing and what decides whether git lists a worktree at all. Letting it
  through cannot widen the first question, which read everything under there as churn and still
  does; what it costs is a callback per git command an agent runs in a task worktree, answered
  by a string comparison, against the whole-worktree read the exclusion was there to prevent.
  **The focus-in read stays**, as the backstop for what a stream did not carry — a window
  launched after the fact, a batch dropped — rather than as the way either is normally noticed.

- **hukan observes worktrees, it does not act on them.** Work reaches main through a PR the
  agent opens itself; cleaning up a merged worktree is a plain `git worktree remove` any
  session can run. No local-merge path, no forced delete — an irreversible decision does not go
  inside hukan without review — and whatever hukan eventually does to a worktree must never be
  modal over the rail.

---

## TODO

- **Code folding** — the remaining editor piece, and the heavy one: collapsing a function or
  block means teaching TextKit 2's content storage to skip ranges, which is documented thinly.
  The fold ranges themselves are free — the vendored grammar ships a `folds.scm` the build
  script currently leaves out (see `QUERIES` in `Vendor/build-tree-sitter.sh`), and the same
  parse that colors the file would answer them. Still not an editor (see the README): no LSP
  or multiple cursors (see the intro). A new *language*, by contrast, is cheap: one line in
  the build script's grammar list, one entry in `SyntaxHighlighting.grammars`, rerun the
  script.
- **GitHub / GitHub Enterprise integration** — in the UI, not a `gh` shell-out: hukan talks
  to the GitHub API itself (Enterprise is the same API under a different base URL). A
  worktree's PR belongs next to the work it holds: its state on the rail extends "find what
  is waiting on you" past local approvals — a failed check or a review request is also
  waiting on you, and a merged PR is what lets a worktree leave the rail — and review comments
  read next to the diff lines they discuss. Reading comes first;
  whether hukan ever writes back (a reply, a re-request) is open. A `gh`-based PR-state link
  was prototyped and pulled back out; evaluating the real thing needs a repository with a
  real remote, Enterprise included.
- **Browser** — what is left open is the login state: sharing Safari's is officially impossible
  (plan B: inject `Cookies.binarycookies`, needs Full Disk Access). Measured with a WKWebView
  harness (2026-08): SSO redirect chains and Kolide device trust **work**; passkeys and iCloud
  Keychain autofill **do not** (browser-vendor entitlements) — which is what the error page's
  Open in Safari is for.

---

## Development process

Code, comments, documentation and commit messages are in English.

Documentation moves with the code: a change that adds or alters behavior revisits both files
in the same commit — the README gains or corrects what now works, this file's TODO drops what
is no longer open. Both have drifted before (a 7-day rule the code had outgrown, verbs that no
longer existed), and a stale line is worse than none.

Keyboard shortcuts stay out of both files. The menu carries them at runtime and `main.swift`
defines them, so a table here is a second copy that goes stale in silence. What a document may
hold is the *allocation decision* — which family owns a key, and why; what it may not hold is the
list. Gestures are not shortcuts and stay: typing against Return, a click against a double-click,
a hover.

### Build

`hukan.xcodeproj` is the only build system — no Makefile, no `Package.swift` (SwiftPM as a
separate "fast loop" was measured no faster and dropped). One scheme, two targets (`Hukan`,
`HukanAppTests`):

```sh
xcodebuild build -project hukan.xcodeproj -scheme Hukan -derivedDataPath .build/DerivedData -skipPackagePluginValidation
open ".build/DerivedData/Build/Products/Debug/Hukan Dev.app"   # relaunch; restoration needs open, not the raw binary
xcodebuild test  -project hukan.xcodeproj -scheme Hukan -derivedDataPath .build/DerivedData -skipPackagePluginValidation
```

`-skipPackagePluginValidation` is there for one dependency: SwiftTerm (the terminal emulator, see
the model) ships a build-tool plugin that stamps its version in, and Xcode blocks an unvalidated
plugin — the flag pre-trusts it, since plugin trust is stored per-user (`~/Library/org.swift.swiftpm`)
and so cannot be committed. SwiftTerm and SwiftTreeSitter are the exceptions to the
vendoring rule: pulled as Xcode-managed package dependencies (pinned in `project.pbxproj`, the
whole graph locked in the tracked `Package.resolved`), *not* committed binaries like
`Clibgit2.xcframework`. SwiftTerm pins an exact version; SwiftTreeSitter rides its `main`
branch, because that is how ChimeHQ ships it, so `Package.resolved` is what actually holds it
still.
That does not resurrect the rejected "SwiftPM as the build system" — the build is still
`xcodebuild`, hukan still has no `Package.swift`; they are pure-Swift libraries, which a
hand-built static `xcframework` fights (SwiftTerm's plugin breaks a universal `swift build`), so
letting Xcode resolve them is the path of least resistance where libgit2's network-less custom C
build was not.

The project is hand-authored and tracked — edit `project.pbxproj` directly. Folder groups are
file-system-synchronized, so a new file under `Sources/` just appears. `Resources/hukan.icns`,
`Resources/rg`, `Vendor/Clibgit2.xcframework`, `Vendor/CtreesitterParsers.xcframework` and the
query files under `Resources/TreeSitter/` are committed static assets; regenerating any of them is a manual
step, not part of the build.

`Resources/rg` is ripgrep, and it is the one program hukan runs. The files panel's filter and its
content search are a process each, per gesture, started by someone typing and killed by the next
keystroke — which is a different shape from the thing libgit2 is here to prevent below, a spawn
per FSEvents batch per worktree. What it buys is the walk: rg prunes by every `.gitignore` it
passes, nested repositories included and — with `--no-require-git` — directories that are no
repository at all, which is the only reason a directory with no git above it can be opened at
all. It is bundled rather than depended on, because the cask is one of three ways hukan arrives
and a formula the user could remove, at a prefix that moves with the architecture, is a
dependency that fails silently. Built from a pinned source release by `Vendor/build-ripgrep.sh`
rather than taken from ripgrep's own macOS download, which is the same call the two xcframeworks
make: the bytes hukan ships are bytes built here. 31s, or 1m13s with the whole-program LTO the
script asks for — which buys size and nothing else (4,239,088 bytes against 3,464,480; both jobs
are bound by syscalls and the disk, so the walk and the search are unmoved).

`Clibgit2.xcframework` is the git engine: libgit2, linked in-process so hukan spawns no `git`
at all — the point being that a large repository under a storm of FSEvents used to fork two
`git` processes per batch per worktree and bury the machine. It is built network-less
(`USE_HTTPS=OFF`, `USE_SSH=OFF` — hukan only reads local worktrees, never clones or fetches),
which also drops the OpenSSL and libssh2 dependencies, leaving one self-contained static
archive linked with `-liconv`. Rebuild it — to bump the libgit2 version — with
`Vendor/build-libgit2.sh`; it is not SPM, just an `xcframework` in "Link Binary With Libraries".

`CtreesitterParsers.xcframework` is the same idea for syntax highlighting: the tree-sitter
*grammars*, compiled from pinned tag archives by `Vendor/build-tree-sitter.sh`, which also
refreshes the query files under `Resources/TreeSitter/`.
The tree-sitter *runtime* is deliberately not in there — SwiftTreeSitter brings it, and a
grammar's generated `parser.c` calls nothing in the runtime, so the two link cleanly from their
two directions (the xcframework's headers sit one directory down, `Headers/CtreesitterParsers/`,
so its module map cannot collide with Clibgit2's in the shared products `include/`; the target's
`SWIFT_INCLUDE_PATHS` points into that subdirectory). Adding a language is one line in the
script's grammar list, one entry in `SyntaxHighlighting.grammars`, and a rerun.

Seventeen parsers for sixteen languages — Swift, TypeScript, TSX, JavaScript, Python, Ruby, Rust,
Go, C, C++, C#, shell, JSON, YAML, Markdown and diff, the second-to-last of which is two grammars.
**There is no one place that has them all**, which is the fact that shapes the script: most come
from the tree-sitter organization, YAML, Markdown and diff from the community
`tree-sitter-grammars` one that has what the first never had, and Swift from alex-pinkus — the official Swift grammar was
archived in 2022 and stopped at roughly Swift 5.5, so the live grammar is a community one and
every editor that highlights Swift uses it. Swift is also the only one whose generated parser
ships in a *release* rather than in the repository. Nobody's set is all from one place — Zed
pulls eight of its twenty-two from outside the official one, two of them its own forks — so
the script takes a source per grammar rather than a rule.

**The committed archive is 22 MB.** C# and C++ are the two largest grammars, bigger even than
Swift, and those three are half of it; JSON is 8 KB. That is the price of the decision, paid
once: a grammar is a table, so it never changes between version bumps.

**The build is arm64 only** (`ARCHS` pinned in both configurations), which is a decision about
who can install it rather than a build setting. Homebrew stopped building bottles for Intel
macOS — its own diagnostic says so for every version up to Tahoe, where a formula builds from
source instead — so the machine a universal hukan was for is one that can no longer install the
CLI half of what it needs. Until now it shipped both slices: 62 MB of binary, half of it for
nobody, in an app whose whole argument is being small enough to hold in one head. **The vendored
xcframeworks are arm64 too**, which is the same decision spent in the other pocket: they are
static archives, so the second slice never reached the app and cost repository size instead —
and that was 25 MB of it, the grammar tables going from 44 MB to 22 and libgit2 from 5.2 to 2.6.
Carrying a slice for a machine that cannot install the app is not a cheaper thing to do because
the linker drops it, and the archives are built by hand from pinned sources, so the arch they
are built for is a line in each script rather than a build setting anyone has to remember.

**The Debug build is a separate app from the one CI ships.** Debug carries its own bundle id,
name and icon (`Hukan Dev.app`, amber DEV ribbon); Release keeps the identity the cask installs.
Sharing one identity meant the two builds shared everything macOS keys on it — saved window
state, TCC grants, notification permission, and which one `open` and AppleScript actually reach —
so a copy of the released app could not sit next to the one being built without one of them
answering for the other. The cost is that the dev build answers to a different name: it is
`tell application "Hukan Dev"`, not `"hukan"`. Two settings exist only to keep that split from
leaking: `PRODUCT_MODULE_NAME` is pinned in both configurations, because `PRODUCT_NAME` otherwise
renames the Swift module to `Hukan_Dev` and every `@testable import Hukan` stops compiling, and
the test target's `TEST_HOST` names the Debug bundle. Both icns files ship in both bundles —
`CFBundleIconFile` picks one, and a second 455 KB icon is cheaper than a copy phase that has to
know the configuration.

**Signing is ad-hoc (`-`)** — nothing hukan does needs a stable signature (restoration and
scripting key on the bundle id). The one cost: TCC grants (screen recording, accessibility,
automation) reset every rebuild, so re-approve them in System Settings after rebuilding. Nothing
in hukan depends on those grants: a screen capture of its own window needs one even from inside
the app, which is why looking at the window is `WindowPreviewTests` drawing it by hand instead.

### The tests run in parallel, and the log pays for it

The scheme marks `HukanAppTests` parallelizable, so `xcodebuild test` — and `⌘U` — splits the
test classes across several host processes. The suite went from 51s to 17s wall (measured), and
that is not the core count talking. `BrowserTests` loads WebKit into the test host, and from
that point every `Foundation.Process` spawn in *that* process costs about 7×:
`GitTests` 0.36s → 2.65s, `GitHistoryTests` 2.30s → 16.08s, while pure-CPU work
(`SyntaxHighlightingTests`, 0.26s → 0.25s) and the terminal's `forkpty` (3.17s → 3.19s) are
untouched. The git-backed tests build their fixtures with the CLI — the CLI is the oracle, which
is the point of them — so they are nearly all spawn, and they were paying for a browser test two
suites earlier in the alphabet. Splitting the host confines that to one worker: with parallel on,
skipping `BrowserTests` outright no longer moves the wall clock at all (16.38s against 16.36s).
The mechanism behind the 7× was not identified — it does not reproduce in a plain binary that
loads WebKit, only inside the XCTest host — so this is isolation, not a fix.

What it costs is the log. In parallel mode xcodebuild stops printing the serial format, so
`Test Case '-[Suite test]' passed` and `Executed N tests` are simply absent — grep for those and
you get nothing, which reads as "no tests ran". What is printed is
`Test case 'Suite.test()' passed on 'My Mac - Hukan Dev (pid)'`, interleaved between workers and
occasionally cut mid-line, plus a `Failing tests:` list at the end. **An assertion's file, line
and message are not on stdout any more.** They are in the `.xcresult`, which is where a failure
has to be read from now — cheaper than grepping a 128 KB log, and the whole reason in two lines:

```sh
xcodebuild test -project hukan.xcodeproj -scheme Hukan -derivedDataPath .build/DerivedData \
    -skipPackagePluginValidation > /tmp/xb-test.log 2>&1; echo "exit=$?"
R=$(ls -td .build/DerivedData/Logs/Test/*.xcresult | head -1)
xcrun xcresulttool get test-results summary --path "$R" | jq -r \
    '"\(.result): \(.passedTests) passed, \(.failedTests) failed", (.testFailures[] | "  \(.testIdentifierString)\n    \(.failureText)")'
```

Recording is unaffected: re-recording every snapshot under parallel produced byte-identical PNGs,
and each suite writes its own files. `TEST_RUNNER_HUKAN_RECORD=1` still exits 65 on purpose —
that is the "recorded … run again without HUKAN_RECORD to verify" failure, not a parallel one.

### Formatting: swift-format, blocked at commit

Standard swift-format, no house style — Xcode's own binary (`xcrun swift-format`, nothing to
install), and `.swift-format` is `{ "version": 1 }`: the plain defaults, pinned to a config
version so an Xcode update cannot silently move them (the same reason the snapshot references
are pinned). Fix a whole tree with:

```sh
xcrun swift-format format -i -p -r Sources Tests
```

Enforcement is the Release workflow, which lints the whole tree with `--strict` on every push
and every tag — the same gate the tests are, and the snapshot tests are for the look — and a
tracked hook, `.githooks/pre-commit`, which is that gate at the commit: it lints the *staged*
blob of each `.swift` and blocks on any finding, so what is judged is exactly what the commit
records, and a finding is caught before it costs a runner. Activate it once per clone
(`core.hooksPath` is not itself tracked):

```sh
git config core.hooksPath .githooks
```

A handful of rules are lint-only — `format` will not rewrite them: `.forEach { … }` over a for-in
loop, an end-of-line comment past the column, a non-`lowerCamelCase` name. The tree is clean of
them today; fix any new one by hand.

### Release: a tag, and the tap follows it

A release is a tag. Bump `CFBundleShortVersionString` in `Resources/Info.plist`, commit, tag it
`vX.Y.Z` and push the tag: the Release workflow (`.github/workflows/release.yml`) lints, runs the
tests and builds the ad-hoc-signed app on the runner whose SDK the app should be linked against,
publishes the zip as that tag's GitHub Release, and points the cask in `tnayuki/homebrew-hukan` at
it. Every push to main runs the same lint, tests and build without publishing, so a tree that would
not ship is caught before it is tagged.

**The cask was updated by hand at first, and the tag is a better place for it.** What the cask
holds is the version and the zip's sha256 — one of which is the tag, and the other of which the
runner that built the archive is the only party to know without fetching it back, so by hand meant
downloading the Release to re-derive a number the machine that made it had already had. The push
is a **deploy key** (`hukan-release-bot`, registered read-write on the tap and nowhere else)
rather than a personal token, because a token in a runner's environment carries an account's whole
reach — every repository it can touch — where a deploy key reaches exactly the one repository it
was cut for. That is the whole of what a workflow writes to either repository.

**The cask is also what the running app reads to know it is behind** (see the update bullet in the
model), so the order of these two steps is load-bearing: the Release is published first and the
cask pushed after, which is the window in which the Release API would answer ahead of anything
`brew` could install. Swapping them would be fine; leaving a gap between them would not.

### One module, one convention

Everything compiles into the one app module, but three folders carry three conventions:

- **`Sources/Hukan`** — the app: `Workspace`/`AgentSession`, the windows, the columns.
- **`Sources/Transcript`** — the transcript's rendering. Keep it free of
  `Workspace`/`AgentSession`/window — if a render type starts wanting an `AgentSession`, add a
  protocol (`TranscriptStorageMirror` is the pattern), do not reach for it.
- **`Sources/Engine`** — the Claude Code interface: the `claude -p` stdio client and the
  `~/.claude/projects` store. It touches the wire protocol and disk, nothing else — no window,
  no `Workspace`, and no rendering.

The splits are a convention, not a target boundary — the compiler does not enforce them since it
is one module.

### Iterating on the transcript's look

Do not do it through the running app — launching, opening a repository and scrolling to the
right block takes a minute each time, and screenshots fail whenever the display sleeps or the
window is covered. Render a case offscreen and look at the PNG:

```sh
TEST_RUNNER_HUKAN_PREVIEW=transcript xcodebuild test -project hukan.xcodeproj -scheme Hukan \
    -only-testing:HukanAppTests/SnapshotTests/testPreview -derivedDataPath .build/DerivedData
# then look at /tmp/hukan-preview-transcript.png
```

`transcript` is one screen of every block; each focused case isolates a mistake that has
actually happened — the `RenderCase` registry is the list. A new thing to eyeball is a case
there, not a one-off flag.
Anything *assertable* belongs in `HukanAppTests` as a real test instead.

### Snapshot tests pin the look

`xcodebuild test` renders every `RenderCase` through the app's own drawing path and
pixel-compares against the reference PNGs in `Tests/HukanAppTests/Snapshots/`. When a change
is intended, re-record with `TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test …`, then eyeball the
new PNGs before committing. The approval, question and task cards — real AppKit views, which the
transcript's harness cannot reach — are pinned the same way by `CardSnapshotTests`, and the
editor pane — highlighted source, gutter, every change-bar state — by `EditorSnapshotTests`
(`editor.png`; eyeball it with `TEST_RUNNER_HUKAN_PREVIEW=editor`, which writes
/tmp/hukan-preview-editor.png instead). That suite has two more references, because they are the
same pane answering the same question differently and one image cannot hold three: `patch.png`
(`…PREVIEW=patch`), rows banded and the payload coloured by the language being patched, and
`image.png` (`…PREVIEW=image`), a file whose content is pixels — drawn at actual pixels rather
than fitted, centred on the backing grid, over the checkerboard, with the drawn caption under it.
Its picture is built in the test out of greys, not committed beside the reference: every other
fixture in that suite is a string in the source, and a grey is what survives the device-RGB to
sRGB conversion under any display profile. The files panel's History section is pinned by
`HistorySnapshotTests` (`history.png`, `…PREVIEW=history`), drawn at the panel's minimum width
because that is where a summary truncates, and the commit tab by `CommitSnapshotTests`
(`commit.png`, `…PREVIEW=commit`), drawn through `present(_:sections:)` so the cards can be posed
— one open over a real highlighted diff, one too large to show, one binary — without a repository
standing behind them. Both draw through `displayIgnoringOpacity` into their own context rather
than `cacheDisplay`, which fills an opaque background and drops layer-backed subviews (it returned
the History rows under a blank strip where the header's title should have been).
The command list is pinned by `CompletionSnapshotTests` (`completions.png`, `…PREVIEW=completions`),
and the web tab's chrome by `BrowserSnapshotTests` (`browser.png`, `…PREVIEW=browser`) — the bar
and nothing under it, in the three states it is ever in, since a rendered page is WebKit's work
and pinning it would be pinning a browser engine rather than hukan.

**A snapshot must not be a photograph of the machine that took it**, which is what every one of
these was. Three things about the display reached the reference, each measured against a runner
that draws on a 1× 1024×768 virtual screen where this machine is 2×. A window's
`backingScaleFactor` is the grid AppKit aligns layout to — 0.5pt at 2×, 1.0pt at 1× — so the same
view puts its text a device pixel off, per element; `NSImage.lockFocus` and
`bitmapImageRepForCachingDisplay` take their scale from the display, so a reference came back half
size; and a `.deviceRGB` bitmap is *device* RGB, where greys survive the conversion and saturated
colours do not. So they all draw through `SnapshotSurface` now: one window class that reports the
recording scale wherever it runs, and one sRGB bitmap at that scale. The command list adds a
fourth — its panel's root is an `NSVisualEffectView`, whose material *does* render into a bitmap
of our own, as whatever the machine's Reduce Transparency setting makes of it — so an opaque view
goes in under the rows and the snapshot pins the rows, which is what it is for.

**Three of those are the machine's settings rather than its display**, and the workflow writes
them before it runs: Reduce Transparency, which is what an `NSVisualEffectView` and every semantic
system fill read; a preferred language, since CoreText picks the CJK fallback from it and with
none of them Japanese a kanji arrives from PingFang SC in Chinese glyph forms at Chinese advances;
and scroll bars, which when always shown narrow every scroll view until a summary truncates a word
early. Each was measured against a runner, and each moved a reference on its own.

**What CI still skips is what the screen decides.** AppKit rounds a control's intrinsic size to
the *screen's* backing grid and not to the window's, which no amount of pinning reaches: an
`NSButton` holding a symbol measures 13.5pt on a 2× display and 14pt on a 1× one, so the browser's
bar and everything after it sits a device pixel over, and the same rounding catches the commit
tab, the History section's tag rule and the approval card's icon row — and the grant card's,
which is built the same way. The reader tests were skipped too, for a second thing the screen decides — they
open a window wider than it, and AppKit constrains a frame to fit — but that one a resolution
*can* answer, so the workflow asks the display for the widest mode it advertises. They all run
now: the two that used to fail in a parallel whole-suite run and pass alone were waiting a fixed
beat for a resize to land, which is a guess about how busy the machine is, and they wait for the
column to stop moving instead. A tolerance is the one answer this comparison refuses, so those stay
skipped and the rest — the transcript, the editor, the cards, the command list, the emphasis
drawing — are a gate CI keeps now. Closing the last of it needs a real 2× display, which only
`CGVirtualDisplay`'s private hiDPI flag can conjure and which Chromium's own test infrastructure
declines to use on a headless bot; `displayplacer` cannot, its twelve modes all being `scaling:off`.

### Verifying the GUI: AppleScript, not coordinates

System Events coordinate clicking breaks when a window moves; the scripting surface exists for
this — extend it rather than reaching for coordinates. The dictionary is an object model
(`application → window → repository → worktree → session`):

```sh
osascript -e 'tell application "Hukan Dev" to get name of every worktree of every repository of window 1'
osascript -e 'tell application "Hukan Dev" to files'   # then: files filtering "…" / files searching "…" / files menu "…" / files previewing "…"
osascript -e 'tell application "Hukan Dev" to send "..." to (selected session of window 1)'
osascript -e 'tell application "Hukan Dev" to get transcript of (selected session of window 1)'
osascript -e 'tell application "Hukan Dev" to get history of worktree "main" of repository 1 of window 1'
osascript -e 'tell application "Hukan Dev" to commit "<full oid>"'   # then: commit / commit toggling 3 / commit finding "…"'
osascript -e 'tell application "Hukan Dev" to tabs'
osascript -e 'tell application "Hukan Dev" to completions typing "/co"'   # then: completions moving 1 / accepting true / completing true
osascript -e 'tell application "Hukan Dev" to recents'   # then: recents opening "<path>"
```

The session verbs address the session as the receiver — `stop session X`, or `tell session X to
stop` / `start` / `interrupt` / `restart` / `fork` / `roll back` — the way `close repository X`
does; `send` is the
exception, naming its target with `to` (`send "…" to session X`) because its direct parameter is the
message. The standalone utility verbs (`hukan status`, a bare `restart` to relaunch the app) stay
app- or window-scoped; `hukan status` returns one line per worktree with its sessions. The commit tab has a hidden verb of its own — `commit` opens one, reports its cards a line each,
and folds or searches them — because the tab is a stack of cards with no text of its own to read
back, and checking it any other way means clicking at coordinates. It takes the whole oid, the way
libgit2 does. The verbs
that stand in
for a human decision — `approve`/`deny` a pending tool call (`approve session X`) — are honoured
only under `HUKAN_SCRIPTING_GUARDED=1`, since a session's own agent can reach `osascript` and would
otherwise approve its own calls. The files panel has a hidden verb for the same reason the tabs
do — it is rows and not text, so `files` reports what the panel is showing and which of the two
gestures put it there, and `filtering`/`searching` run them. `files menu "<path>"` reads back the
right-click menu that row would carry, a line each, and `files previewing "<path>"` is Space on
that row — the Quick Look panel is the system's own and has nothing to read back, so what it is
showing is reported through `files` itself; the writes that menu makes
(`creating`/`folder`/`renaming … to …`/`deleting`) are guarded, because each of them stands in for
a human's answer — a name typed on the row, or the alert before a delete. `tabs` is the same
answer for the strip as a whole, which is what a relaunch has to be checked against: which tabs
came back, in what order, which one is showing, and which of them have been read yet — all of it
buttons, and otherwise only reachable by clicking at coordinates. `completions` is another of that
kind: the command list is rows on a panel floating over the window, so checking that a `/` opened
it — and that `⏎` took the row the arrows had reached — is otherwise a click at coordinates.
`typing` goes through the text view's own edit path rather than a shortcut only a script can
take, so what it exercises is the list a person would get. `recents` is one of the same kind: Open Recent hangs in three places, two of them
context menus that cannot be opened without a right-click at coordinates, so the verb reports what
a row would say and what it would open, and `opening` takes one the way clicking it would.
`selected sessions` is the last of them, and
it reads *and writes*: a multi-selection is rows on a list with nothing to read back, and a
property that could only be read would leave the half worth checking — that a batch survives the
reload every FSEvents batch triggers — reachable only by ⌘-clicking at coordinates.
