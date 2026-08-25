# hukan

**hukan (俯瞰) is not an editor.** 俯瞰 is the bird's-eye view, and that is what the app is: one
window over a room full of coding agents, each in its own git worktree. The rail down the left
says which one is working, which one is stuck on a question and which one is waiting on your
approval. You stand in the middle of them and see them all from above, and decide which to
advance and which to drop.

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
the empty composer sends the last one queued now. A session's rail row starts, stops, restarts
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
under a *Worktrees* heading beneath it, each folding away with its sessions. An agent moving worktree (`EnterWorktree`)
takes its session with it, and leaving it (`ExitWorktree`) brings the session back to the worktree
it was started from. Dragging a repository's heading puts it somewhere else in the rail, worktrees
and all — the insertion line falls only between repositories, never inside one.

**Change review.** Branch and diffstat against `HEAD` in the toolbar, the changed files in the
panel's ± scope, the changed lines in the open file's gutter. Reading the diff belongs to the PR.

**History.** The branch's log at the foot of the files panel, newest first, folded away from the
toolbar's glyph beside the ±. It is read a page at a time: scrolling past the last row walks
further back. Each row is a short hash and summary, with a dot where the upstream has not caught
up, and a rule across the list names what the branch was cut from — `origin`'s default branch, or
a local `main`/`master` — with this worktree's own commits above it and the history it inherited
below. The line above it is a divider, so the section can be dragged as tall as the log you are
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
by the toggle at the toolbar's far end. One field over the tree runs two jobs, told apart by
gesture: typing filters by path, Return searches contents and the panel becomes a result list
until Escape. Either can be walked away from: the scan says it is searching, and a query typed
over it drops the one still reading rather than queueing behind it. The ± scopes both to the
changed files, and every row carries its own diffstat.

Tabs are files (always editable source), commits (read-only), web tabs (one shared cookie store,
passing as this machine's Safari) and terminals (named as Terminal.app names one). The plain
new-tab key opens a browser rather than a terminal — the shell work here is the agent's — and
the strip walks, numbers, closes and reorders the way a browser's does: a new tab opens at the
end, a drag puts one wherever it is dropped, and closing the active one lands on its right-hand
neighbour. Past the point where the tabs stop fitting, it scrolls sideways instead of squeezing
every label at once, and whichever tab is picked is scrolled back into sight; `+` keeps the
trailing edge, outside the scroll. A click previews and a double-click promotes: a preview
becomes lasting, and a lasting tab takes the whole window.

A web tab's field is an address bar and a search box at once, and the text decides which: a
scheme, a slash or a dot makes it an address, anything else is a search. A load that fails says
so on the page — with what went wrong, the address it was, and the offer to search for what you
typed instead, or to open it in Safari. A link in the transcript opens here rather than in the
default browser, ⌘-click sends it out, and a bare URL is a link (code, quoted or fenced, is not).
The tab does what a page expects of its browser: popups open as tabs and close themselves when
done, a file picker, dialogs, downloads (into Downloads, the Dock stack bouncing) and a name-and-
password or client-certificate challenge all get the system's panels, a swipe goes back, and ⌘F
finds in the page. Web tabs come back after a relaunch, on their worktrees, with their history —
in the order they and the terminals stood on the strip —
each loading only once it is looked at.

A file tab is syntax-highlighted — Swift, TypeScript, TSX, JavaScript, Python, Ruby, Rust, Go,
C, C++, C#, shell, JSON, YAML and Markdown, a fenced block in the language its info string names and
its emphasis drawn bold and italic — with a gutter carrying its changes against
`HEAD`: green added, blue rewritten, a red wedge where lines were deleted, hollow once staged and
solid while not. The bars measure the buffer, so an edit is marked as it is typed; hover one for
the lines it replaced. Lines never wrap.

**Cost & usage.** A per-session cost estimate in the conversation header (the "if it were
API-metered" figure), the account-wide plan usage in the toolbar, and beside it the CPU and
memory of hukan and every process it spawned, split in the tooltip between hukan itself, the
Claude Code engines and what those spawned, with a process count for each.

**Sessions.** A restored session reads its conversation back rather than opening empty. Names are
Claude Code's own titles. A session not yet reattached is marked `detached` and resumes on
selection; one another process already holds shows greyed and cannot be started, but still reads
and searches, and returns the moment that process exits.

**Markdown.** Rendered on both sides of the conversation, with what you typed tinted and indented.

**Search.** One field for the rail, with the same two gestures as the panel's: typing filters the
sessions by title, `⏎` searches the transcripts themselves, off the main thread. Opening a
session under transcript results lands on its first match, highlighted.

**Notifications.** A banner the moment a session becomes your turn, and only while hukan is not
frontmost. Tapping it jumps to that session, and one key does the same from anywhere. A turn
merely finishing is silent.

**Scripting.** The whole surface is reachable from AppleScript.

### Session lifetime

Nothing leaves the rail by age, and nothing is deleted from disk except by asking — Delete
Session removes the transcript that *is* the session, permanently. Sessions are discovered from
Claude Code's transcripts and ordered by when you last instructed them, each row saying how long
ago that was. *Archive* puts the ones
you are done with into a folded section at the foot of the main checkout's rows — only main's,
since a linked worktree leaves the rail with its sessions when git stops listing it. It stops the
agent, the way *Stop Session* does, and destroys nothing: the transcript stays exactly where it
was, *Unarchive* brings the row back, and the next message resumes it. A session
that starts working or asks for you comes back out on its own, so nothing waiting on you is ever
hidden. Several rows can be selected at once, so a batch of finished attempts is one gesture. A
worktree's rows leave when git stops listing it, or when its repository is closed.

---

## Install

Build it — one `xcodebuild`, see [CLAUDE.md](CLAUDE.md). hukan spawns the Claude Code CLI
(`claude`) per session, so [install that separately](https://docs.anthropic.com/en/docs/claude-code).

---

## License

hukan is released under the [MIT License](LICENSE).
