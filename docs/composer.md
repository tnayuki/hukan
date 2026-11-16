# The composer

Settled decisions, moved out of CLAUDE.md so it stays loadable. Each bullet is a decision
and the reasoning behind it; read the file before changing the area it covers.

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
