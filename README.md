# hukan

A macOS app for supervising coding agents running in parallel, from a single window. The
name, Hukan (俯瞰), is the bird's-eye view: standing in the middle of the agents while seeing
them all from above, and deciding which to advance and which to drop.

It is not an editor. It is an **agent frontend** that happens to contain an editable diff
viewer. Built for one user.

Swift 5 / macOS 15, AppKit, no package dependencies.

---

## What works

**Layout.** Three columns — the session rail, the running agent, and files — in one window,
restored on relaunch along with its Space and geometry.

**Agents.** `claude -p` kept resident per session, talking both ways. Text arrives token by
token; tool calls are shown as they are made. Several sessions run at once and
the rail shows the state of each.

**Approvals.** A tool call the agent is not already allowed to make becomes a card above the
composer. Allow, Deny, or Escape answers it and the agent unblocks. Never modal.

**Worktrees.** Repositories are opened and closed; their worktrees are enumerated from git,
never stored. When an agent moves into a worktree (`EnterWorktree`), its session moves with
it, and the new worktree groups under the same repository in the rail.

**Diff review.** Branch, changed files, per-file diffstat and colored unified diff, all from
git. Changed is diffed against `HEAD` — uncommitted work only, every worktree the same.

**Cost & usage.** The conversation header carries a per-session cost estimate (a subscription
bills no dollars, so it is the "if it were API-metered" figure; the tooltip breaks the tokens
down). The toolbar carries the account-wide plan usage — the rolling session window and the
weekly limits, one bar per model — which reflects usage spent on other machines too.

**History.** Opening a restored session reads its conversation back, so it shows what was said
rather than an empty pane. Names are Claude Code's own titles, so even a never-opened session
is named in the rail. Sessions not yet reattached are marked `detached` and resume on
selection.

**Markdown.** Rendered on both sides of the conversation. What you typed is tinted and
indented, so scrolling back to "where did I last ask for something" is a glance rather than a
search.

**Search.** One field over the rail filters sessions full-text, over titles and transcripts.
Opening a session under an active filter lands on its first match, highlighted.

**Notifications.** A banner fires the moment a session becomes your turn — an approval or a
question — and only while hukan is not the active app. Tapping it jumps to the session, the
same move as `Cmd+Return`. A turn merely finishing is deliberately silent.

**Scripting.** The whole surface is reachable from AppleScript.

### Session lifetime

Nothing is deleted from disk, and nothing leaves the rail by age. Sessions are discovered from
Claude Code's transcripts and bucketed by when you last instructed them, oldest bucket
collapsed by default, so a worktree that has carried many attempts still reads at a glance —
and `Cmd+Return` reaches the session waiting on you wherever it sits. A worktree's rows leave
when its repository is closed; an out-of-band `git worktree remove` is not noticed on its own.

---

## License

hukan is released under the [MIT License](LICENSE).
