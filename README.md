# hukan

**hukan (俯瞰) is not an editor.** 俯瞰 is the bird's-eye view, and that is what the app is: one
window over a room full of coding agents, each in its own git worktree. The rail down the left
says which one is working, which one is stuck on a question and which one is waiting on your
approval. You stand in the middle of them and see them all from above, and decide which to
advance and which to drop.

![The rail down the left listing every session in every worktree, one of them holding a question
above the composer; the desk on the right showing a commit's diff, with the worktree's files
beside it](docs/hukan.png)

## No multi SCM. No multi coding agent. No multi platform.

git, Claude Code, macOS — because that is what I use. Each of those is what buys the next line:

- **No multi SCM** — a worktree *is* the model. One worktree, one task, one agent; a repository
  is whatever `git rev-parse --git-common-dir` answers, and hukan stores no list of either.
- **No multi coding agent** — hukan reads Claude Code's own transcripts and task store, so a
  session outlives the app that showed it.
- **No multi platform** — AppKit, and nothing under it.

No LSP, no debugger, no multiple cursors, no plugin API. External tools do those better, and
leaving them out is what keeps hukan small enough for one person to hold in their head. What is
here instead is an editable, syntax-highlighted source viewer: fixing the file an agent just
wrote should not mean leaving the window.

Swift 5, AppKit; macOS 15 and up, built against the current SDK. git and tree-sitter are
vendored static libraries; SwiftTerm and SwiftTreeSitter are the only package dependencies.

---

## What works

**Layout.** Four columns in one window — the session rail, the running agent, the desk, the files
panel — restored on relaunch with their Space and geometry. The edge columns run the window's
full height, Mail-fashion, and the toolbar is cut into sections that follow them. Either middle
column can have the window to itself: double-click a lasting tab, or the conversation's own
header, and everything else folds away until the same gesture puts it back.

**Agents.** `claude -p` kept resident per session, talking both ways: text token by token, tool
calls as they are made, several sessions at once with the rail showing each one's state. Escape
or the composer's stop button interrupts a turn. A line sent while the agent is working waits
above the composer for the turn to end, each with its own send-now, edit and delete; Return on
the empty composer sends the last one queued now. Interrupting the turn keeps them: they go on
waiting for you rather than opening the next turn. A session's rail row starts, stops, restarts
and deletes it, or archives it out of the way; a stopped session resumes on the next send. The
rail takes several rows at once, and one act reaches all of them.

**Approvals.** A tool call the agent is not already allowed to make becomes a card above the
composer. Allow, Deny, or Escape answers it. Never modal.

**Questions.** The agent's own question is the same kind of card, carrying its options — a click
answers, checkboxes and a Done when it takes more than one, and an option's sketch of its own
outcome folds under it. Typing in the composer answers in your own words, ticks included.

**Tasks.** The agent's task list as a card, read from Claude Code's store rather than from the
calls that write it. Folded it is the count and the task in flight; opened it is what is left,
with anything waiting on an unlanded task marked as held up. The card leaves when the list
finishes, so one still standing after the turn says the work stopped half-done.

**Going back.** Every message you sent carries a quiet `…` once there is a conversation above it.
*Fork Before This Message* opens a sibling session in the same worktree holding everything above
it; *Roll Back to Before This Message* cuts this conversation to the same point instead, asking
first. Neither deletes anything, and neither touches the worktree's files. A session another
process holds can be forked, but not rolled back.

**Worktrees.** Repositories are opened and closed; their worktrees are enumerated from git, never
stored. The main checkout is the repository's own rail row, naming its branch; the linked ones sit
under a *Worktrees* heading beneath it, each folding away with its sessions, in order of the
directory name their row carries. An agent moving worktree (`EnterWorktree`)
takes its session with it, and leaving it (`ExitWorktree`) brings the session back to the worktree
it was started from. Dragging a repository's heading puts it somewhere else in the rail, worktrees
and all — the insertion line falls only between repositories, never inside one, the worktrees'
own order being the name's rather than anyone's. The open panel
takes several at once, and *Open Recent* offers the ones this app has had open and this window has
not — in the File menu, on the rail's right-click, and beside the empty window's button. An entry
that is no longer a directory drops itself.

**Change review.** Branch and diffstat against `HEAD` in the toolbar, the changed files in the
panel's ± scope, the changed lines in the open file's gutter. A file git has never seen counts as
added throughout — a brand-new file is what an agent writes most, and waiting for `git add` would
keep it out of every one of those readings. Ignored files stay out. Reading the diff belongs to
the PR.

**History.** The branch's log at the foot of the files panel, newest first, folded away from the
toolbar's glyph beside the ±. It is read a page at a time: scrolling past the last row walks
further back. Each row is a short hash and summary, with a dot where the upstream has not caught
up, and a rule across the list names what the branch was cut from — `origin`'s default branch, or
a local `main`/`master` — with this worktree's own commits above it and the history it inherited
below. A tag draws a rule of its own, carrying a tag glyph so the two cannot be read for each
other, above the commit it names: on the main checkout that is where a release sits, and
everything above the line is what has not gone out under it. Several tags on one commit are one
rule, which names the first and counts the rest; hovering it lists them all. The line above the
section is a divider, so it can be dragged as tall as the log you are
reading — or shut, which is the same act as the toolbar's glyph, and is remembered either way.

While git has something underway in the worktree — a rebase stopped on a conflict, a merge waiting
to be committed, a bisect — a line above the rows says so, naming the branch and, where git counts
them, which step of how many. It has to: a rebase replays onto a detached HEAD, so the branch's own
commits leave the list until they are re-applied one at a time, and on a checkout in sync with its
remote the list empties outright — with the files full of conflict markers and nothing else on
screen saying why. The branch keeps its name on the rail and in the top bar for the same reason.

A pick opens the commit on the desk as a read-only tab: the message, then a foldable card per
file — status, path, diffstat, and that file's diff, read only once the card opens. The diff
reads as source rather than patch text: no plumbing lines and no `+`/`-` column (a full-width
band and a two-column gutter say it instead), with the editor's own tree-sitter colors. The
tab's own search field marks every occurrence in every open card at once, and Return steps
through them.

**The desk.** The selected worktree's tabs, with the files panel as the trailing column, hidden
by the toggle at the toolbar's far end. The tree is the worktree as it is on disk — every file and
directory, including the ones git ignores, which are drawn dimmed — walked once in the background
when the worktree is first selected and kept in step with what moves, so a file a build or an
agent just wrote is there as it lands. git's diffstats are laid over it. One field over the tree runs two jobs, told apart by
gesture: typing filters by path, Return searches contents and the panel becomes a result list
until Escape. Both work over what the tree shows, with one exception: a directory git ignores is
on the tree, dimmed, but neither filtered into nor searched — a dependency directory is a hundred
thousand files nobody wants either done to. An ignored file in an ordinary directory is. Either can be walked away from: the scan says it is searching, and a query typed
over it drops the one still reading rather than queueing behind it. The ± scopes both to the
changed files, and every row carries its own diffstat.

Space previews the selected row — the Finder's key and the Finder's own Quick Look panel, so a
PDF, a video, a font or an archive is looked at without leaving the window and without becoming a
tab. It closes on the same key, it follows the arrows while it is up, and a directory row gets one
too.

A right-click on a row is where hukan writes to a worktree itself. It opens the row in a lasting
tab, previews it in Quick Look, reveals it in the Finder, opens a terminal in its directory, and
copies its path — twice over, relative to the worktree and absolute. Below that it makes a new file, renames the row and
deletes it. A name is typed on the row itself: renaming edits it in place, and a new file is made
under an untitled name and handed straight to the same edit. ⏎ on a row starts it, the way the
Finder does, and ⌘↓ is what opens a row from the keyboard. The name is read against the directory
the row is in and may carry directories, which are made on the way, so renaming is also how a file
moves. It cannot climb out of the worktree. New Folder sits beside New File.
While a name is being typed the tree holds still, so an agent writing in the worktree cannot take
the field away mid-word. A delete is confirmed and then really deleted
rather than moved to the Trash. A tab already showing
a renamed file follows the new name, and one showing a deleted file closes. On the panel's own
background the same menu makes a file at the worktree root.

Dragging a file out of the panel onto the composer attaches it, the same way dropping one from
the Finder does — the agent reads it from there, and the chip above the field carries its name. The
same drag is good out to the Finder or another editor, and a folder drags as well, though a folder
never becomes a chip. Dropping files back onto the panel is the other direction: onto a folder row,
or between rows, which means the folder those rows are in. Anything from outside is copied in; a
row of the panel's own moves, which is the rename that carries directories done as a gesture, and
⌥ copies it instead. An open tab follows the file wherever it lands, everything under a folder
included. A name the destination already has gets the Finder's answer — Keep Both, Replace or Stop,
with Apply to All when several collide — except for a folder, which is refused rather than
replaced.

Tabs are files (editable source; an image is drawn instead, and anything else names its own kind
rather than opening blank), commits (read-only), web tabs (one shared cookie store, passing as
this machine's Safari) and terminals (named as Terminal.app names one). An image opens at actual
pixels — one image pixel to one device pixel, so a screenshot is as sharp and as large as it was
taken — over a checkerboard where it is transparent, with its pixel count and size under it; a
file holding several bitmaps, an icon set, shows the largest and says so. What does not fit
scrolls, and a pinch, a two-finger double tap or the zoom keys get closer. The plain
new-tab key opens a browser rather than a terminal — the shell work here is the agent's — and
the strip walks, numbers, closes and reorders the way a browser's does: a new tab opens at the
end, a drag puts one wherever it is dropped, and closing the active one lands on its right-hand
neighbour. Past the point where the tabs stop fitting, it scrolls sideways instead of squeezing
every label at once, and whichever tab is picked is scrolled back into sight; `+` keeps the
trailing edge, outside the scroll. A click previews and a double-click promotes: a preview
becomes lasting, and a lasting tab takes the whole window.

The strip comes back after a relaunch — every kind of tab, on its worktree, in the order it stood
in, open at the tab that was showing. Nothing is read until its tab is looked at, so a desk of a
dozen tabs costs the one on screen. A tab whose file or worktree is gone by then does not come
back. Unsaved edits are not carried across: closing the window, and quitting, ask about each one
first — Save, Don't Save or Cancel — the way closing a tab does.

A web tab's field is an address bar and a search box at once, and the text decides which: a
scheme, a slash or a dot makes it an address, anything else is a search. A load that fails says
so on the page — with what went wrong, the address it was, and the offer to search for what you
typed instead, or to open it in Safari. A link in the transcript opens here rather than in the
default browser, ⌘-click sends it out, and a bare URL is a link (code, quoted or fenced, is not).
The tab does what a page expects of its browser: popups open as tabs and close themselves when
done, a file picker, dialogs, downloads (into Downloads, the Dock stack bouncing) and a name-and-
password or client-certificate challenge all get the system's panels, a swipe goes back, and ⌘F
finds in the page. A web tab comes back after a relaunch with its history, and its address is
what it is found again by before the page has loaded.

![A web tab open on the desk beside the commit tab it was opened next to, showing a repository
page under the tab strip's own address bar, with the conversation still running in the column to
its left](docs/hukan-browser.png)

A file tab is syntax-highlighted — Swift, TypeScript, TSX, JavaScript, Python, Ruby, Rust, Go,
C, C++, C#, shell, JSON, YAML and Markdown, a fenced block in the language its info string names and
its emphasis drawn bold and italic — with a gutter carrying its changes against
`HEAD`: green added, blue rewritten, a red wedge where lines were deleted, hollow once staged and
solid while not. The bars measure the buffer, so an edit is marked as it is typed; hover one for
the lines it replaced. Lines never wrap.

A patch — `.diff`, `.patch`, `.rej` — reads as the file it patches: the payload of each hunk is
colored as the language the patch names, with the added and removed rows carrying the commit
tab's own bands behind them rather than a color of their own.

A double-click takes the whole token — a hash, a path, a URL, an option — here and in the
transcript alike, on a Japanese line as readily as an English one.

**Opening from outside.** `open -a hukan <path>` — or a Finder drop — opens a directory in the
worktree that contains it, its repository first when none does, and a file as a lasting tab; a
path that does not exist says so instead of exiting clean. The bundled CLI does the same from any
shell (`…/Hukan.app/Contents/Resources/hukan`, one `ln -s` away from a PATH of your choosing),
and `--wait` returns when the tab closes — which is what hukan's own terminals ship as
`$EDITOR`: `git commit` opens its message as a tab, caret on line one, ⌘S ⌘W commits, and closing
without saving aborts. A profile that exports its own `EDITOR` still wins.

**Cost & usage.** A per-session cost estimate in the conversation header (the "if it were
API-metered" figure) and, beside it, how full that session's context window is — amber past three
quarters, red past nine tenths, with the breakdown by category in the tooltip. The account-wide
plan usage sits in the toolbar instead, since it is true of the whole window, and beside it the
CPU and memory of hukan and every process it spawned, split in the tooltip between hukan itself,
the Claude Code engines, what those spawned and the terminals, with a process count for each.

**Sessions.** A restored session reads its conversation back rather than opening empty. Names are
Claude Code's own titles. A session not yet reattached is marked `detached` and resumes on
selection; one another process already holds shows greyed and cannot be started, but still reads
and searches, and returns the moment that process exits. A `claude` started outside the window —
in a terminal, in a worktree open here — joins the rail as it starts, held, and takes its name
when it writes its first message. Opened, its conversation keeps up: what the other process writes
arrives as it is written, a rollback it makes included.

**Slash commands.** A `/` at the head of the composer opens the engine's own command list — its
built-ins beside every skill and user command it found — filtered as you type, taken with `⏎` or
`⇥`. A skill added on disk shows up once an engine has restarted; nothing here keeps a copy.

**Past prompts, by their reading.** With the input method off, two or more letters in the composer
offer what you have already asked this repository, matched by how it reads: `kentou` finds
検討して, `ririsu` finds リリースして. Both spellings of a long vowel work, and so do Hepburn and
kunrei — `syasin` and `shashin` are one query. A word written in ASCII inside a Japanese sentence
is matched as itself, so `pr` finds PRを作って. Unlike the command list this one opens with no row
selected — it comes up over ordinary text, where `⏎` already means send — so an arrow enters it,
or `⇥` takes the best match outright. Nothing is stored: the prompts are read back out of Claude
Code's own transcripts.

**Markdown.** Rendered on both sides of the conversation, with what you typed tinted and indented.
A table's cells are selectable — by character inside a cell, by whole cells once the drag leaves
one — and copy as tab-separated text, which is what a spreadsheet and Slack read as a table.
A code block carries a copy mark at its top-right corner — a fenced block the agent wrote and an
opened tool call's command alike — which takes the block whole, with no trailing newline, and
shows a tick for a beat to say it did.

**Search.** Two questions, two places. *Which conversation* is the rail's field, with the same two
gestures as the panel's: typing filters the sessions by title, `⏎` searches the transcripts
themselves, off the main thread — the tool calls included, each read by the argument it carries in
full rather than by the summary its folded line shows. Opening a session under transcript results
lands on its first match, highlighted. *Where in this conversation* is the find bar over the transcript, which opens
every folded tool call and pulls in the history above before it searches, so what it answers for
is the conversation and not the part of it on screen. Which of the two a find means is where the
focus is.

**Notifications.** A banner the moment a session becomes your turn, and only while the window
carrying that session is not the one in front of you — another window's rail is not showing it.
Tapping it jumps to that session, and one key does the same from anywhere. A turn merely
finishing is silent.

**Scripting.** The whole surface is reachable from AppleScript.

### Session lifetime

Nothing leaves the rail by age, and nothing is deleted from disk except by asking — Delete
Session removes the transcript that *is* the session, permanently. Sessions are discovered from
Claude Code's transcripts, and one that has yet to write a transcript from the live engine that
holds it, ordered by when you last instructed them, each row saying how long ago that was. *Archive* puts the ones
you are done with into a folded section at the foot of the main checkout's rows — only main's,
since a linked worktree leaves the rail with its sessions when git stops listing it. It stops the
agent, the way *Stop Session* does, and destroys nothing: the transcript stays exactly where it
was, *Unarchive* brings the row back, and the next message resumes it. A session
that starts working or asks for you comes back out on its own, so nothing waiting on you is ever
hidden — and one you send a message to leaves the fold for good, since instructing a session is
deciding you are not done with it. Several rows can be selected at once, so a batch of finished attempts is one gesture. A
worktree's rows leave when git stops listing it, or when its repository is closed.

The same right-click also names a session two ways, for handing to something outside the window:
*Copy Transcript Path* gives the jsonl Claude Code is writing, and *Copy Session ID* the id it is
writing under. Both answer for a session another process is holding, and for one that has yet to
write anything — reading a row is not acting on it, and a conversation with no file yet still has
a name waiting for it.

---

## Install

Homebrew:

```sh
brew tap tnayuki/hukan
brew install --cask hukan
```

The cask installs a prebuilt, ad-hoc-signed `Hukan.app` from the tagged GitHub Release and strips
the Gatekeeper quarantine so it launches; `brew upgrade` follows new versions. hukan spawns the
Claude Code CLI (`claude`) per session, so
[install that separately](https://docs.anthropic.com/en/docs/claude-code).

**hukan says when a newer one has been released.** It reads the version out of the cask that
installs it — one HTTPS GET, hourly, sending nothing — and while that is ahead of the running
build the toolbar's trailing edge carries an arrow, with both version numbers in its tooltip.
Pressing it opens Terminal.app and runs the `brew upgrade`; nothing quits, and the terminal says
to restart hukan afterwards. **hukan ▸ Check for Updates** asks now rather than waiting out the
hour; the answer still lands in the toolbar and nowhere else. Claude Code is not watched the same
way, because it updates itself.

Building from source instead is one `xcodebuild` — see [CLAUDE.md](CLAUDE.md).

---

## License

hukan is released under the [MIT License](LICENSE).
