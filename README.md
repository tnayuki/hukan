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
here instead is an editable source viewer: fixing the file an agent just wrote should not mean
leaving the window.

Swift 5, AppKit; macOS 15 and up, built against the current SDK. SwiftTerm is the only package dependency.

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

**Change review.** Branch and a diffstat, from git, measured against `HEAD` — uncommitted work
only, every worktree the same. The size is in the toolbar for the selected worktree; the files
themselves are the panel's changed scope (below). Reading the diff belongs to the PR.

**The desk.** The desk is the selected worktree's open tabs — files, and terminals (a shell in
the worktree, also from the strip's `+`) — with the **files panel** as the window's trailing
column, which the toggle at the toolbar's far end hides. The panel navigates and nothing
else — a pick opens a tab, which is where everything is read and edited.
One field over the tree, in the toolbar's own row over the panel, with the two file-finding jobs
kept apart by the gesture that runs them: **typing** narrows the tree by path, live, and it stays
a tree; **Return** searches the files' contents and the panel becomes a list of files and matching
lines, until Escape brings the tree back. Either can be walked away from: the scan says it is
searching, and a query typed over it drops the one still reading rather than queueing behind it.
Picking a matching line opens its file there, so walking the list
walks the occurrences, and a save re-runs the search so the line just fixed drops out. The ±
beside the field scopes both to the worktree's changed files. Each row carries its own diffstat, a
directory the sum of what changed beneath it, so a folded tree still says where the work is — the
total for the worktree stays in the toolbar.

A single click from the panel previews, a double-click or Return pins. Opening a file shows its
source, always editable; find works within the active tab, a file's bar or the
terminal's. A terminal's tab is named as Terminal.app names one: the command running
in it, or its working directory when nothing is running. Nothing above the text names the file —
the tab does that, with the full path in its tooltip — and a file's tab wears a dot in front of
the name while the buffer holds an unsaved edit. The strip is walked, numbered, closed and reordered the way a browser's is — a new tab opens at
the end, a drag puts one wherever it is dropped, and closing the active one lands on its
right-hand neighbour; past the point where the tabs stop fitting it scrolls sideways instead of
squeezing every label at once, and whichever tab is picked is scrolled back into sight.

A double-click on the tab itself promotes it as far as it will go: a preview becomes a lasting
tab, and a tab that is already lasting takes the whole window — the rail, the transcript and the
files panel fold away (the tab's menu does the same, and either puts them back). Being sent to a
session — by key, or by a tapped notification — restores them, since that is where what is
waiting on you lives. Right-clicking a tab offers the four ways to close from there (this one, the
others, the ones to its right, all of them, each stopping at a Cancel on an unsaved file), Keep
Open while it is still a preview, and that same maximize.

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
