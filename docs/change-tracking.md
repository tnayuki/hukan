# How a change on disk reaches the window

Settled decisions, moved out of CLAUDE.md so it stays loadable. Each bullet is a decision
and the reasoning behind it; read the file before changing the area it covers.

- **What has changed includes what git has never seen.** The working-tree diff carries untracked
  files, counted as added — `git status`'s reading of the question rather than
  `git diff HEAD`'s — because a file nobody has run `git add` on is the whole of what a brand-new
  file is, and a brand-new file is what an agent produces most. While they were excluded, nothing hukan measures a
  change with counted the file an agent had just written: not the ± scope, not the toolbar's
  diffstat, not the row's own numbers — they all read this one diff. Ignored files
  stay out, which is the half of libgit2's default worth keeping.
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
  **A tab that cannot take the change notes it, and a note is spent, never dropped.** Two panes
  refuse a re-read for good reasons — one on a desk nobody is looking at, which must not pay that
  parse off screen, and one holding an unsaved edit, which must not lose it — and both used to
  refuse in silence, which is how a refusal becomes a tab quietly showing a file as it stood an
  hour ago. Now each marks itself instead, and the mark is spent at the one moment it can be: the
  desk coming up, or an undo taking the edit back off, which is the one moment a pane stops having
  anything to protect. A clean buffer re-reads where it was scrolled; a dirty one keeps the edit
  and keeps the mark, beside the dot on its tab, since those are two facts about one tab and the
  dot cannot carry both. **The write is where it is asked about**, because that is the act with
  something to lose: ⌘S over a marked buffer offers Overwrite, Reload and Cancel — the closing
  tab's three answers read from the other side — where before it replaced the agent's file with
  the buffer and said nothing. No Compare, the answer VS Code puts beside those: the file pane has
  no diff at all, and what the other side wrote is git's to show. **Every tab on the worktree
  hears, wherever it stands**: a write lands in a checkout and a desk belongs to a session, so two
  sessions in one checkout hold a tab each on the file an agent just wrote, and telling only the
  desk on screen left the other one behind for as long as the window lived.
  **The same batch narrows what git is asked, and that is where the size of a checkout is paid.**
  The working-tree diff stats every file there is, which on a very large one is seconds, and it
  ran per batch — so an agent's write cost a walk of the whole checkout. It is now
  `git diff HEAD -- <the paths that moved>`, which libgit2 answers by walking only where they
  point rather than by filtering a diff it has already taken in full: 97ms whole against 12ms for
  one path on a synthesized 50,000-file repository, nearly all of the 12 being the index both of
  them load. What comes back answers for those paths and no others, so it is folded into the
  changed set rather than replacing it — a path asked about that the diff did not name no longer
  differs from HEAD, which is how a file edited back to what HEAD holds leaves the set. **A path
  asked about may be a directory, and the fold reads it as one**: libgit2 answers a pathspec with
  everything under it, so what leaves the set is what is under the path as well as the path
  itself. The two disagreed for a while, and the case that says so is an *untracked* file moved
  out of a folder — a tracked one comes back as a deletion at its old path, where an untracked one
  is not mentioned at all, so its entry survived every later read as a file that no longer existed
  and the ± went on counting it until something moved HEAD or the index and forced a whole read.
  Directories reach the fold from every side: a folder renamed, deleted or dropped on, and an
  agent's `mv`, which FSEvents names as the directory itself. The index is not read again at all
  then: it lives inside git's own directory, so a batch that named
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
  command it ran. The heaviest of those never leave the stream either — bar the one that turned
  out to carry a second question, below. Anything not recognised as churn counts, since what is
  being decided is whether to read, and a read nobody needed is cheaper than a reading left
  stale.
  **What the repository moving also moves is the branch's name and the set of worktrees, and
  both used to wait for the window to be focused.** That is the one moment they cannot be
  needed: the window is the one being worked in, so it never lost the focus to come back to,
  and the read the repository's own stream already wakes had by then swapped the history and
  the ± over to the new branch while the rail and the top bar went on naming the old one. So
  the branch is read on the wholesale question and on no other — a batch that named files in
  the checkout is by construction one that did not move HEAD — which costs one more repository
  open on a read that already makes several, and is reported apart from the files, a branch
  move being what they are measured against rather than one of them.
  **The set of worktrees is the other half, and nothing on disk reported it at all.**
  `git worktree remove` writes nowhere outside `.git/worktrees/<name>`: no ref moves, no file
  in any checkout moves, and that directory was excluded from the stream outright — for the
  reason above, a task worktree's own HEAD and index being in there. So the end of a task was
  invisible, which is the one thing about a worktree this window most has to notice. It is let
  through now and asked a second, narrow question: the registry directory, a worktree's own
  directory, and its `gitdir` file, which is what `git worktree add` and `git worktree remove`
  were measured writing and what decides whether git lists a worktree at all. Letting it
  through cannot widen the first question, which read everything under there as churn and still
  does; what it costs is a callback per git command an agent runs in a task worktree, answered
  by a string comparison, against the whole-worktree read the exclusion was there to prevent.
  **The focus-in read stays**, as the backstop for what a stream did not carry — a window
  launched after the fact, a batch dropped — rather than as the way either is normally noticed.
