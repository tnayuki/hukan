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
  implementations of one thing, a process running in this worktree, sharing the middle column
  via tabs.
- **A double-click promotes what it lands on as far as it will go.** A preview becomes a lasting
  tab — the files panel's gesture and the rail's, unchanged — and a tab that is already lasting
  takes the whole window, folding every other column away. One rule covers both halves, which is
  what let the maximize share the gesture that pins instead of buying a modifier of its own.
  **The conversation maximizes the same way, from its header.** The gesture belongs to the strip
  that names what a column is showing — the desk's tab strip, and beside it the session's header
  — because that strip is also what stays when everything else folds, so the thing pressed and
  the way back are one view. A conversation has no preview state to leave, so there the first
  double-click is already the maximize; and the rail's rows are pointedly not the place for it,
  since a double-click there already means dive into this session. One key serves both, and which
  column it means is where the focus is: an edge column maximizes the column it feeds — the
  rail's detail is the conversation, the files panel's is a tab — so nothing is ambiguous and the
  second maximize costs no second shortcut. Maximizing is a mode you are in, not a state the
  workspace has: it is never saved with the window (a restored window with no rail and no
  transcript reads as a broken one), toggling any column by hand ends it, and being sent to a
  session — by key, by a tapped notification — ends it too, because what is waiting on you is on
  the rail and in the transcript and the mode must not outlive its own reason. **Ending it that
  way puts back what nothing else can unfold**: the rail and the files panel have toggles of
  their own and keep whatever the act that ended the mode makes of them, but the transcript and
  the desk have none, so a mode dropped where it stood would leave whichever of them it had
  folded with no way to it. Everything that can fold does; the strip stays, because it is the way
  back. The strip's right-click menu is the same set of acts spelled out — the four ways to close
  from a tab, `Keep Open` while it is still a preview, and that maximize.
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
  the rule overrides — because a pulsing row must never be behind a fold. **Archiving stops the
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
- **The rail navigates between tasks; the files panel navigates within one.** The rail lists
  worktrees, sessions and what is waiting (approvals) — bounded state, which is why one field
  searches it, under the same typing-filters / Return-searches rule as the panel's (titles are in
  memory; transcripts are files, so reading them waits to be asked for). Finding a *file* is the
  files panel's, docked on the desk's trailing edge, with its
  own field. The tree once sat on the rail and made the rail's search have to span files and
  transcripts at once; moving it out is what lets the two searches stay two fields with two
  scopes. It was briefly a tab on the desk instead, which was worse: a tab needs an editor inside
  it to show what it found, so the same file became editable in two places and wanted a
  shared-buffer machine underneath. As a panel it is an index and nothing else — every pick opens
  a tab, so a file is read and edited in exactly one place, and the preview tab is the detail view
  the results list would otherwise have had to grow.
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
- **The panel's own costs were measured, against a 25,000-file checkout.** git was never the slow
  half there — the working-tree diff and the index read are tens of milliseconds — so all three
  of the numbers that mattered were hukan's own. A content search took 10.5s, nearly all of it
  Foundation's case-insensitive matching, and the read is now split over the cores a round at a
  time: 1.4–1.8s, abandonable, and in path order regardless of which read finishes first, because
  the cap has to cut the same hits a serial scan would have cut. A keystroke in the filter cost
  272ms of the main thread — 33ms matching every path, 239ms opening every row of what survived —
  and is now ~34ms: the paths are folded once when git's answer moves rather than per keystroke,
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
  message.** The model roster and the account's plan usage are the engine's own facts, so neither
  is a table here or a file to scan: the roster rides in on its startup reply, and the usage is
  asked for on the open stream, the same channel a model switch goes down. **A probe must not be
  a turn.** The plan usage was
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
  What cannot be placed is not narrowed: a commit or a staging moves what every open file is
  measured against while touching none of them, so it refreshes them all.

- **hukan observes worktrees, it does not act on them.** Work reaches main through a PR the
  agent opens itself; cleaning up a merged worktree is a plain `git worktree remove` any
  session can run. No local-merge path, no forced delete — an irreversible decision does not go
  inside hukan without review — and whatever hukan eventually does to a worktree must never be
  modal over the rail.

---

## TODO

- **Syntax highlighting** — the source pane renders as plain monospace. It is editable
  (Cmd+S writes back atomically, leaving a file with an unsaved edit asks first — Save / Don't
  Save / Cancel — and a dirty buffer is never clobbered by an agent's on-disk refresh), but the
  text is flat.
  Highlighting is the missing half — still not an editor (see the README): you correct what an
  agent wrote, you do not live in it; no LSP or multiple cursors (see the intro).
- **GitHub / GitHub Enterprise integration** — in the UI, not a `gh` shell-out: hukan talks
  to the GitHub API itself (Enterprise is the same API under a different base URL). A
  worktree's PR belongs next to the work it holds: its state on the rail extends "find what
  is waiting on you" past local approvals — a failed check or a review request is also
  waiting on you, and a merged PR is what lets a worktree leave the rail — and review comments
  read next to the diff lines they discuss. Reading comes first;
  whether hukan ever writes back (a reply, a re-request) is open. A `gh`-based PR-state link
  was prototyped and pulled back out; evaluating the real thing needs a repository with a
  real remote, Enterprise included.
- **Browser: task-context tabs** — worktree = task = one issue, so the tab set belongs to a
  Worktree: switch worktrees and the whole desk switches. Tabs sit in the right column over one
  shared cookie store. Measured with a WKWebView harness (2026-08): SSO redirect chains and Kolide
  device trust **work**; passkeys and iCloud Keychain autofill **do not** (browser-vendor
  entitlements); sharing Safari's login state is officially impossible (plan B: inject
  `Cookies.binarycookies`, needs Full Disk Access). The two pieces still needed were proven at
  ~30 lines: `createWebViewWith` to open popups as real windows, `decidePolicyFor` to forward
  custom schemes (`kolide://`) to `NSWorkspace.open`.

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
and so cannot be committed. SwiftTerm is the one exception to the vendoring rule: it is pulled as
an Xcode-managed package dependency (pinned to an exact version in `project.pbxproj`, its graph
locked in the tracked `Package.resolved`), *not* a committed binary like `Clibgit2.xcframework`.
That does not resurrect the rejected "SwiftPM as the build system" — the build is still
`xcodebuild`, hukan still has no `Package.swift`; it is a pure-Swift library with a build plugin,
which a hand-built static `xcframework` fights (the plugin breaks a universal `swift build`), so
letting Xcode resolve it is the path of least resistance where libgit2's network-less custom C
build was not.

The project is hand-authored and tracked — edit `project.pbxproj` directly. Folder groups are
file-system-synchronized, so a new file under `Sources/` just appears. `Resources/hukan.icns`
and `Vendor/Clibgit2.xcframework` are committed static assets; regenerating either is a manual
step, not part of the build.

`Clibgit2.xcframework` is the git engine: libgit2, linked in-process so hukan spawns no `git`
at all — the point being that a large repository under a storm of FSEvents used to fork two
`git` processes per batch per worktree and bury the machine. It is built network-less
(`USE_HTTPS=OFF`, `USE_SSH=OFF` — hukan only reads local worktrees, never clones or fetches),
which also drops the OpenSSL and libssh2 dependencies, leaving one self-contained static
archive linked with `-liconv`. Rebuild it — to bump the libgit2 version — with
`Vendor/build-libgit2.sh`; it is not SPM, just an `xcframework` in "Link Binary With Libraries".


**The Debug build is a separate app from the Release one.** Debug carries its own bundle id,
name and icon (`Hukan Dev.app`, amber DEV ribbon); Release keeps the identity that ships.
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

### Formatting: swift-format, blocked at commit

Standard swift-format, no house style — Xcode's own binary (`xcrun swift-format`, nothing to
install), and `.swift-format` is `{ "version": 1 }`: the plain defaults, pinned to a config
version so an Xcode update cannot silently move them (the same reason the snapshot references
are pinned). Fix a whole tree with:

```sh
xcrun swift-format format -i -p -r Sources Tests
```

Enforcement is a tracked hook, `.githooks/pre-commit` — there is no CI, so the commit is the only
format gate, the way the snapshot tests gate the look. It lints the *staged* blob of
each `.swift` with `--strict` and blocks on any finding, so what is judged is exactly what the
commit records. Activate it once per clone (`core.hooksPath` is not itself tracked):

```sh
git config core.hooksPath .githooks
```

A handful of rules are lint-only —
`format` will not rewrite them: `.forEach { … }` over a for-in loop, an end-of-line comment past
the column, a non-`lowerCamelCase` name. The tree is clean of them today; fix any new one by hand.

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
transcript's harness cannot reach — are pinned the same way by `CardSnapshotTests`.

### Verifying the GUI: AppleScript, not coordinates

System Events coordinate clicking breaks when a window moves; the scripting surface exists for
this — extend it rather than reaching for coordinates. The dictionary is an object model
(`application → window → repository → worktree → session`):

```sh
osascript -e 'tell application "Hukan Dev" to get name of every worktree of every repository of window 1'
osascript -e 'tell application "Hukan Dev" to files'   # then: files filtering "…" / files searching "…"
osascript -e 'tell application "Hukan Dev" to send "..." to (selected session of window 1)'
osascript -e 'tell application "Hukan Dev" to get transcript of (selected session of window 1)'
```

The session verbs address the session as the receiver — `stop session X`, or `tell session X to
stop` / `start` / `interrupt` / `restart` / `fork` / `roll back` — the way `close repository X`
does; `send` is the
exception, naming its target with `to` (`send "…" to session X`) because its direct parameter is the
message. The standalone utility verbs (`hukan status`, a bare `restart` to relaunch the app) stay
app- or window-scoped; `hukan status` returns one line per worktree with its sessions. The verbs
that stand in
for a human decision — `approve`/`deny` a pending tool call (`approve session X`) — are honoured
only under `HUKAN_SCRIPTING_GUARDED=1`, since a session's own agent can reach `osascript` and would
otherwise approve its own calls. The files panel has a hidden verb for the same reason the tabs
do — it is rows and not text, so `files` reports what the panel is showing and which of the two
gestures put it there, and `filtering`/`searching` run them. `selected sessions` is another
of that kind, and it reads *and writes*: a multi-selection is rows on a list with nothing to read
back, and a property that could only be read would leave the half worth checking — that a batch
survives the reload every FSEvents batch triggers — reachable only by ⌘-clicking at coordinates.
