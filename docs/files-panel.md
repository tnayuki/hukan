# The files panel

Settled decisions, moved out of CLAUDE.md so it stays loadable. Each bullet is a decision
and the reasoning behind it; read the file before changing the area it covers.

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
- **A change lights the row on screen that stands for it, and what lights it is git's answer, not
  FSEvents'.** The deepest visible row — the file's own, or the folded directory it is hidden in
  — washes in the accent colour and fades. An ignored path lights nothing: it is dimmed so as not
  to read as the work, and a folder pulsing for every object a build or `npm install` writes into
  it would undo that — including a folder whose ignored depths are not listed yet, which only git
  can answer for. So the signal is the report that re-reads a tab, filtered to what git knows:
  one reading of "this file changed" for the tab and the tree, an edit that leaves the same
  `+1 −1` still lights, and a commit or a checkout — the wholesale report — lights nothing,
  since no file was written. An open directory lights only for a row that has gone, never for
  one merely scrolled away. The tree as browsed only; a filter or the ± scope is left still.
