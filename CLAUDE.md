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
  the `git worktree remove` a session runs once its task has landed, noticed on the next return
  to the window. Closing the repository takes the rest, the main checkout included: git will not
  remove that one, so nothing but a decision can.
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
  back. The strip's right-click menu is the same set of acts spelled out — the four ways to close
  from a tab, `Keep Open` while it is still a preview, and that maximize.
- **The desk's plain `⌘T` is the browser's; the terminal takes `⌃⌘T`.** Creation is two families,
  `⌘N` for the rail and `⌘T` for the desk, and within the desk the plain key goes to what is
  actually opened most: the shell work here is the agent's, so a terminal a person opens by hand
  is the occasional act, while a task's issue, PR and docs breed tabs by being followed. It also
  makes `⌘T` mean what it means everywhere else, which is what leaves the rest of the desk's
  vocabulary — walking the strip, jumping into it, closing — reading as a browser's. `⇧⌘T` is
  left free for the same reason: beside a browser tab it means reopen the closed one, and a
  terminal on it would take that key from the desk for good. So the terminal sits on the control
  key, beside the window's own `⌃⌘S` and `⌃⌘M`. Zoom keeps `⌘0`/`⌘+`/`⌘-`, so nothing else may
  take them.
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
  **Reload is the browser's own key, and it never becomes Stop.** A web tab is the one surface on
  the desk with a manual re-read to give — a file, the tree and the history all come back on the
  batch FSEvents hands them — and the button holds both meanings only because it can show which
  one it is holding, where a key that reloads or stops depending on how far the page has got is
  one you cannot press without looking first. Stopping is Escape's instead, and it reaches the tab
  only if the page did not want it: that ordering is the whole reason it is not a menu key
  equivalent, since one of those is matched before the page ever sees the event and would take
  Escape from every menu and dialog a page has.
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
  spent at the first reload available is spent against half a strip. Only the one worktree's — the
  desk does not remember a tab per worktree, so there is nothing else to save. A restored tab is
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
- **A file row drags out as a file URL, and that is the whole of "add this to the context".**
  The composer already takes a file dropped from the Finder and turns it into an attachment chip
  — the agent reads it from the path the chip carries — so the panel had only to write the same
  thing a Finder drag writes, and dragging a row onto the field attaches it. The path is absolute
  for that reason: it is what goes to the engine, and it must not depend on where the engine is
  standing. Files only, the rule that already decides which rows have a tab to open. It is the
  opposite call from the rail's rows, which stand for a checkout and so refuse `.fileURL`
  outright — a repository row offered to the Finder would be a folder anyone could take, where
  these rows *are* files, and being good in the Finder and in any editor is a side effect worth
  having. Copy only, in and out of the window: an index must never be able to move the file it
  points at.
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
  against 280, 288 for the rail against 280, each measured the way the originals were. The desk
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
- **One field over the tree, two operations, told apart by gesture.** Typing filters the tree by
  path — live, in memory, and the tree stays a tree. Return searches contents — off the main
  thread, over every file, and the panel becomes a result list until Escape. Running both off the
  same keystroke was built and removed: it greps the worktree on every character, and it has to
  flatten the tree to show what it found, so the filter stops being a filter. Both are plain
  case-insensitive substring, so what matched is always explicable, and there is still one field
  and no prefix syntax. **Case-insensitive means ASCII case folding** — one rule, shared by the
  two gestures, and the reason is that the general one was unaffordable: Foundation's
  `.caseInsensitive` is most of what made a whole-worktree scan take ten seconds. What it gives
  up is accented Latin (`CAFÉ` no longer answers to `café`); a query with no case of its own,
  Japanese included, is matched exactly as before.
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
- **The panel's right-click menu is the one place hukan writes to a worktree, and it writes files,
  never the repository.** Open in a tab, Reveal in Finder, a terminal in the row's directory, Copy
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
  when its batch lands, without waiting on git and whether git will ever see it or not. **The one
  refusal is that ignored directories are not walked into.** They are rows, and they open, but a
  dependency directory is a hundred thousand files nobody wants filtered or searched, and walking
  it with git's ignore rules applied from outside libgit2 was measured at 566ms against the 107ms
  the working-tree diff spends applying them inside. So **the filter and the content search cover
  what the walk covers**, which is the tree less those directories; an ignored file in an ordinary
  directory is covered like any other. The ± scope is git's changed set, as before, and everything
  under `.git` is left out of all of it, being the repository and not the worktree.
- **The panel's own costs were measured, against a 25,000-file checkout.** git was never the slow
  half there — the working-tree diff and the index read are tens of milliseconds — so all three
  of the numbers that mattered were hukan's own. A content search took 10.5s, nearly all of it
  Foundation's case-insensitive matching, and the read is now split over the cores a round at a
  time: 1.4–1.8s, abandonable, and in path order regardless of which read finishes first, because
  the cap has to cut the same hits a serial scan would have cut. A keystroke in the filter cost
  272ms of the main thread — 33ms matching every path, 239ms opening every row of what survived —
  and is now ~34ms: the paths are folded once when the file list moves rather than per keystroke,
  the opening is budgeted, and the rows are inserted in one batch, since `expandItem` reloads the
  view around every row it inserts and that alone was 58ms of the 239. And the held-elsewhere
  rescan re-listed Claude Code's process registry once *per session on the rail* — 42ms of the
  main thread for 121 of them, on every FSEvents batch under that directory — where one read of
  it answers for every session at once.
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
  completing it is making. Sharing Return is not free, and the cost was measured before it was
  taken: the ASCII messages sent as they stand are acknowledgements — `yes` 248 sends, `ok` 111,
  `dou` 33 — and each now opens a list Return answers rather than sends, so those go Esc then
  Return. A digit or a single letter is the one thing kept out, by the two-character floor and by
  there having to be a letter at all.
  **The list reads bottom-up, best nearest the field.** The panel stands over the transcript
  because the composer is at the foot of the column, so a ranking that starts at the top puts the
  best answer as far from the caret as the list is long. The slash list turned round with it: one
  panel, one order, and the arrows then read as they look.
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
  differs from HEAD, which is how a file edited back to what HEAD holds leaves the set. The index
  is not read again at all then: it lives inside git's own directory, so a batch that named
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
  command it ran. The heaviest of those never leave the stream either. Anything not recognised
  as churn counts, since what is being decided is whether to read, and a read nobody needed is
  cheaper than a reading left stale.

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
`Vendor/Clibgit2.xcframework`, `Vendor/CtreesitterParsers.xcframework` and the query files
under `Resources/TreeSitter/` are committed static assets; regenerating any of them is a manual
step, not part of the build.

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

Sixteen parsers for fifteen languages — Swift, TypeScript, TSX, JavaScript, Python, Ruby, Rust,
Go, C, C++, C#, shell, JSON, YAML and Markdown, the last of which is two grammars. **There is no
one place that has them all**, which is the fact that shapes the script: most come from the
tree-sitter organization, YAML and Markdown from the community `tree-sitter-grammars` one that
has what the first never had, and Swift from alex-pinkus — the official Swift grammar was
archived in 2022 and stopped at roughly Swift 5.5, so the live grammar is a community one and
every editor that highlights Swift uses it. Swift is also the only one whose generated parser
ships in a *release* rather than in the repository. Nobody's set is all from one place — Zed
pulls eight of its twenty-two from outside the official one, two of them its own forks — so
the script takes a source per grammar rather than a rule.

**The committed archive is 43 MB.** C# and C++ are the two largest grammars, bigger even than
Swift, and those three are half of it; JSON is 8 KB. That is the price of the decision, paid
once: a grammar is a table, so it never changes between version bumps.

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
/tmp/hukan-preview-editor.png instead). The files panel's History section is pinned by
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

**CI runs everything but these.** The runner draws on a 1× 1024×768 virtual display where this
machine is 2×, and its twelve modes are all non-HiDPI — a resolution can be raised, a backing
scale factor cannot — so a reference recorded here comes back half size. Scale is not the whole
of it: the suites that already build their own 2× bitmap come back the right size and still
differ, an eighth of the commit tab's pixels and nearly all of the command list's, because the
runner's text rendering is not this machine's. A tolerance is the one answer this comparison
refuses, so the workflow skips the pixel-pinned tests by name — the snapshot suites, the two
emphasis tests that measure the same drawing, and the reader test that wants a window taller than
the runner's screen. CI is the gate on the logic; the look stays the gate this machine keeps.

### Verifying the GUI: AppleScript, not coordinates

System Events coordinate clicking breaks when a window moves; the scripting surface exists for
this — extend it rather than reaching for coordinates. The dictionary is an object model
(`application → window → repository → worktree → session`):

```sh
osascript -e 'tell application "Hukan Dev" to get name of every worktree of every repository of window 1'
osascript -e 'tell application "Hukan Dev" to files'   # then: files filtering "…" / files searching "…" / files menu "…"
osascript -e 'tell application "Hukan Dev" to send "..." to (selected session of window 1)'
osascript -e 'tell application "Hukan Dev" to get transcript of (selected session of window 1)'
osascript -e 'tell application "Hukan Dev" to get history of worktree "main" of repository 1 of window 1'
osascript -e 'tell application "Hukan Dev" to commit "<full oid>"'   # then: commit / commit toggling 3 / commit finding "…"'
osascript -e 'tell application "Hukan Dev" to tabs'
osascript -e 'tell application "Hukan Dev" to completions typing "/co"'   # then: completions moving 1 / completions accepting true
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
right-click menu that row would carry, a line each; the writes that menu makes
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
