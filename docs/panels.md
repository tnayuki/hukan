# Panels

Settled decisions, moved out of CLAUDE.md so it stays loadable. Each bullet is a decision
and the reasoning behind it; read the file before changing the area it covers.

- **A panel is a session's, installed by that session's agent, and shows that session only.** The
  agent calls `panel_install` on its own stream, so which session it lands on is a fact rather
  than an argument, and no tool puts a panel on another session. What it shows is what its render
  command reads in this session's worktree; side sessions are rows on the rail, not a panel's
  business. The work's rules — what a step is, when it is done — stay in the skill that installs
  the panel and in the panel's own scripts: hukan holds no workflow.
- **The definition arrives over MCP, and the scripts stay wherever they are.** A definition names
  its scripts by absolute path — in a skill's folder, a plugin's, the worktree, `/tmp` — because
  where a panel comes from is not hukan's to decide; hukan does not look anything up in a skills
  folder. The install card says nothing about where the definition came from: the agent's word for
  it would vouch for nothing, and the card shows the content itself.
- **The person approves the definition and every file it names, in full, on a card — in every
  permission mode.** That approval is what allows the panel's commands, so no mode can stand in
  for it. It is pinned by SHA-256 to the definition and to each file the definition names: an argv
  entry that is an absolute path to a file, and the `files` list for what a script imports. Not the
  folder holding a script, which was the first idea: a script may live in the worktree, whose
  churn would stop the panel on every edit. A file that changes stops the panel — its drawing
  stays, its buttons do not — until the agent installs it again and the person approves the new
  version; a running panel never moves to a newer definition on its own. A file changed while the
  card was up refuses the install, since it is not what the person read.
- **What is kept is the definition, its seal and the decisions made on it**, with the window like
  the tags, archived sessions included — a session taken back out of the archive has the panel it
  had. It is the one thing hukan keeps that is neither view state nor something Claude Code or git
  already holds; nothing else of a panel is stored.
- **It sits above the conversation, not on the desk.** It is the conversation's own view of its
  work, the scope rule's (`docs/model.md`) "a conversation's facts in its header" grown larger. It
  opens at the height it wants up to two fifths of the column, the rule under it drags it taller
  or shorter, and its title row folds it.
- **The render is an external command, never a runtime inside hukan and never markup.** Its argv
  runs in the worktree, without a shell, with JSON on stdin — the session's id, tags, state
  (working, waiting, ended), worktree and the panel's approvals — and prints the panel as JSON:
  a closed set of parts (badge, text, fields, list with groups, limit and empty text, button,
  approval, notice, divider), rows, fields and buttons taking an SF Symbol. Free HTML in a web view was ruled out with the design: a panel can
  only offer what those parts can say. `watch` globs are a trigger, not what the script reads.
  It redraws when a watched file changes, when a turn ends and when the tags or approvals move,
  a burst being one render. **A render that fails, times out (10s) or prints something that is not
  a panel leaves the last drawing standing** and says why in the notice band.
- **Short and wide, because height is what it is short of.** It stands over the conversation, so
  every line it takes is a line of transcript gone, while the column is wide. A first version
  stacked one part a line in System Settings' inset groups and took twice the height for the same
  content; it is laid out across instead. Badges and the panel-wide buttons ride the title row,
  which a folded panel keeps. Fields flow side by side and wrap. A list's groups stand as columns,
  and a list of one group is dealt into as many columns of 260pt as the width holds, down each and
  then across, so it still reads in order. A row is 24pt; its status is a dot in its tone, the word
  in the tooltip. A document to decide on is one chip, and a band one line, its whole text in the
  tooltip. Columns are laid out by hand, since how many there are is a question of the width,
  which constraints cannot ask.
- **Text is a string or a list of spans**, so what a value names can be what it is: a link, a tag
  chip, monospaced, a time, a symbol. A pull request is a `{tag}` span, `PR: #42 <address>`, and
  draws as the rail draws that tag — the same thing in the same face in both places, coloured by
  its kind, opening on the desk. A time is sent as a time and shown as the rail spells an age,
  `3m ago`, kept current every half minute while the panel is up, so a render need not run just to
  move a clock.
- **The PATH is the person's shell's, asked once.** A GUI launch inherits launchd's bare PATH, and
  the engine's fix — starting through `$SHELL -l -i` at 1.4s a launch (`ClaudeSession`) — is too
  slow for something run every turn, so the shell is asked for its PATH once and every run after is
  a plain `Process`.
- **A button sends to its own session or runs a declared command, and nothing else.** A send
  waits for a free turn rather than cutting one, and is off while the session waits on a decision,
  since a send then would drop it. It opens the turn as `TurnInput.panel`, not the person's: the
  person pressed it, but its words are what a render, reading files the agent wrote, put there —
  so such a turn cannot start a side session without asking. A command is one the definition
  declares, its `{holes}` typed by patterns matched against the whole value, run as an argv. One
  marked `outward` shows the argv it is about to run and waits for Run on each press, inline in
  the panel rather than in a sheet, since nothing modal goes over the window. What a command
  printed and how it ended go to the session as a message.
- **An approval is pinned to the document as it stood at the press.** Approve records the file's
  hash; Send Back records it with the reason, typed in a popover. Both go to the session, with the
  hash, and to every render after; the part shows when the document changed since it was approved.
- **The commands a panel runs are the person's, not hukan's own outbound requests**
  (`docs/updates.md`): each was declared in a definition the person approved, the way the browser's
  traffic is the user's.
- **Not built yet, and refused rather than half-installed:** a definition with `schedules` or `mcp`
  is turned away with the reason, since a schedule silently not running is worse than an install
  that says why it did not happen. The rest of the design waiting with them — the evidence log,
  approving in a document's tab, the flow and table parts — is in CLAUDE.md's TODO.
