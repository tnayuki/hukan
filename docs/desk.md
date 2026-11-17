# The desk and the window

Settled decisions, moved out of CLAUDE.md so it stays loadable. Each bullet is a decision
and the reasoning behind it; read the file before changing the area it covers.

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
  you is on the rail and in the transcript and the mode must not outlive its own reason. **A fold
  made by hand is the opposite case, and is saved**: the rail, the files panel and its History
  section come back folded, each having been a decision about how this window is arranged, the
  way its widths are, and each having a toggle in the bar to undo it. What is saved under the
  mode is the arrangement it was entered from, and for History the hand fold alone — a section
  folded because it has nothing to show is not one, or a worktree with commits would open on it
  shut. **Ending
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
  what it was added for. **Bar one: a desk with no tabs folds**, and the conversation takes the
  width — an empty desk is a blank column, and a session just started is exactly the one that has
  nothing on it yet. It is not a fold anyone makes, so it is not
  remembered either: whether the desk is folded is read off the strip and the mode every time,
  which is what keeps it from disagreeing with them. The maximize's memento leaves the desk out
  for that reason — it can only ever have been "the strip was empty", and a tab that arrives while
  the conversation has the window would otherwise come back folded inside the column with no way
  to it — and the widths are not recorded while it holds, since the transcript then stands at the
  width of the pair. What it costs is that switching between a session with tabs and one without
  moves the transcript's width, which was weighed and taken. The strip's right-click menu is the same set of acts spelled out — the
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
- **The whole strip comes back after a relaunch, at the tab that was showing.** Each tab is saved
  as what identifies it and nothing more — a worktree and a relative path, an oid, a directory
  and a scrollback, and for a web tab WebKit's own `interactionState` (the back/forward list and where
  each entry was scrolled) held opaque beside the title and address, so the tab can be named and
  found by address before it loads. It rides the window's restorable state keyed by session,
  passed in from the desk because the model has no view to read it off. **Nothing is read until
  its tab is looked at** — a restored window may carry a dozen tabs across its sessions, and
  reading them all at launch is what a browser's session restore is known for; a saved web title
  holds until the page reports its own, or every restored tab would rename itself to a bare host
  name the moment it loads. What does not come back is what has nothing left to show: a blank web
  tab (one keystroke to make again), a file, worktree or session that is gone, a commit a rebase
  dropped — that last one unchecked at launch, since nothing answers it more cheaply than reading the
  commit, so the tab says so when it is opened. **The strip's order is saved apart from the tabs**,
  one row per tab naming only its kind, because a row is then answered by position in that kind's
  list — and a tab that did not come back is a row past the end of its list, which the strip
  closes up over. **The showing tab is a place in that order**, applied once the strip is in it:
  the terminals arrive on a reload of their own, before the rest of the strip is on it, so an index
  spent at the first reload available is spent against half a strip. **A showing tab is a fact about
  a strip, not about the view**, so there is one per desk and every one of them is saved. The
  view holds every session's tabs at once and shows one desk, and a single showing tab was the
  view standing in for each strip: switching the rail away left the reconcile nothing to land on
  and it fell to the end of the new strip, which is then what the old one came back to as well.
  Saving only the showing desk's would be that same bug one relaunch later — the desk you were
  looking at right, every other one on its last tab — where coming back to a session is the same
  act whether the window was restarted in between or not. A restored tab is
  lasting, never a preview: a preview is what the last click made of a tab, and a relaunch is not
  a click.
- **A window that closes, and a quit, ask about every unsaved edit first.** The same Save / Don't
  Save / Cancel a closing tab gets, since closing the window closes every tab, and a Cancel keeps
  the window. It is the other half of restoring file tabs: hukan holds no copy of an unsaved
  buffer — that would be a second copy of the file outside git, which is the line master data
  draws — so without the prompt a quit dropped the edit silently and put the tab back on the file
  as it stood on disk, which is the worst of the three available answers. The alternative was hot
  exit, VS Code's and Zed's: carry the unsaved text across too. Refused for the copy it costs,
  not for the convenience it buys. **Deleting a session and closing a repository ask the same**,
  for the tabs that go with them — the deleted session's desk; every desk of the repository's
  sessions, and any other desk's tab on one of its worktrees — since both take those tabs without
  closing them one by one, and both dropped the edit unasked. A Cancel keeps the session or the
  repository.
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
- **An outside path opens inside the worktree that contains it.** One resolution for every
  hand-off — a Finder drop, the CLI helper, a terminal's `$EDITOR` file, the `edit` verb behind
  both: the deepest open worktree containing the path claims it, its repository is opened first
  when none does, and a directory git does not know opens as itself, the degenerate case the
  model already has. What is under `.git` is the repository, not the checkout — a COMMIT_EDITMSG
  must not become a phantom row of the checkout it configures, and a linked worktree's lives
  under *main's* gitdir — so those open as outside files, keyed by absolute path (no twin exists
  for the `(Worktree, relative path)` rule to guard against), on the desk of whoever *asked*: the
  requesting terminal's session, which is why the request carries who asked at all. A file of a
  checkout goes to a session standing in that worktree — the selected one if it is there, else
  the one instructed there last — and that session is selected, so the file shows beside the
  conversation it belongs with; with none there it lands on the selected session's desk as a tab
  on the other worktree. A path that does not exist is refused out loud, and so is one with no
  session anywhere to open it on — a file handed to `open` used to be swallowed with a clean exit,
  the same "Return did nothing" the browser's error page fixed.
- **The terminal's `$EDITOR` is hukan itself, and closing the tab is the editor exiting.** The
  bundled helper by absolute path — nothing installed on PATH, and the Dev build's terminals
  reach the Dev app. Inside hukan's terminals it takes **a Unix socket the terminal is spawned
  with**, the way an editor's integrated terminal hands its CLI one: hukan takes no Apple event
  from a process it started (`docs/model.md`), and the socket reaches nothing but opening a path
  and holding the answer until its tab closes, so finding it buys no more than showing a file.
  Outside them a plain open goes through `open(1)`, and only `--wait` rides the `edit` verb,
  whose `waiting` holds the Apple event's reply until the tab closes, at the cost of the one-time
  automation prompt. Injected as a default, not forced: a profile exporting its own editor runs
  later and wins.
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
  observable) and the columns are pushed as wide as the captions need, each floor measured the
  way the originals were and re-measured when the SDK's toolbar changes its spacing. The desk
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
