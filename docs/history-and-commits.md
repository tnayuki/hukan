# History and the commit tab

Settled decisions, moved out of CLAUDE.md so it stays loadable. Each bullet is a decision
and the reasoning behind it; read the file before changing the area it covers.

- **The history a worktree shows is its branch's log, read a page at a time.** The History section
  at the foot of the files panel walks first-parent from HEAD, newest first, one page of 50; going
  past the last row read asks for the next page, and the limit lives on the worktree so every
  other reason to re-read git — a commit landing, a branch moving — hands back what has been paged
  in rather than the first page again. It listed `<base>..HEAD` once, and that bound made the
  section *disappear* the moment the branch was pushed: on a checkout in sync with its remote
  there is nothing past the base, so the one thing the list is asked for most — what landed
  recently — was the one thing it would not show. The base is still read, and it is still the
  remote's default branch (a local `main`/`master` with no remote), but it now marks rather than
  bounds: **the fork-point rule sits between the commits this branch put down and the ones it was
  cut from**, and a checkout with nothing of its own draws no rule at all. A page that stopped
  before reaching the fork draws none either — the count is capped at what was read, and a rule on
  the last row would be claiming to know where a branch began when the walk never got there. No
  lane graph still: a task branch is nearly always linear, and the one structural fact worth
  having is that rule. The upstream is consulted only for the unpushed dot, never as the base: a
  pushed task is exactly the one being reviewed, so pushing must not empty the list. **A tag is a
  rule too, above the commit it names** — the same idiom and the same reading as the fork point,
  which is that the ref below the line is what everything above it is not in yet. It is the one
  structural fact the *main* checkout has, where the fork rule never draws (a branch in sync with
  its base has nothing of its own to divide), and it says what the release commit's summary does
  not: that the tag exists at all. It carries a tag glyph, or two rules in a row would be two
  facts drawn identically. What it cannot say is whether the tag was pushed: a tag lives in
  `refs/tags` whichever side it came from, so unlike a commit's dot there is no local answer, and
  libgit2 is built here without the network to ask for one — whether a release actually went out
  stays the GitHub question the TODO covers. Several tags on one commit are one rule naming the
  first and counting the rest, with the whole list in the tooltip: running the names out to an
  ellipsis instead squeezed the rules and then the glyph out of the row, leaving a line of grey
  text that read as no kind of row at all. Ordered numerically rather than lexically, the
  Finder's rule, since the dictionary's puts `v0.10.0` above `v0.9.0`. **A commit
  opens as a read-only tab**, which is where the diff hukan removed from the file pane is allowed
  back: that pane's Diff/Source switch failed because a coloured diff cannot be edited and the
  files carrying one are the ones you want to correct — but a commit is finished, so the coloured
  diff is not a mode standing in front of the text, it is the text. The list is per-worktree
  (it is HEAD's) while the commit is per-repository (git's object database is shared), which is
  why the tab's identity is the oid and not `(Worktree, oid)`. The section is folded from the
  toolbar's row over this column — beside the ± and the panel's own toggle, where the panel's
  filter and scope already went for the same reason: the panel is full-height, so its first row
  belongs to the bar. It carried a `History · <base>` header of its own first, and both halves of
  that were wrong: a chevron there is one operation with two controls, and a title over one half
  of a panel whose other half has none reads as decoration. What the title was actually carrying —
  the base — is now **the rule closing the list**, which says it where it means something (this is
  where the task began, the one structural fact a lane graph would have carried) and, by being
  absent on a capped list, says the cap too. Folded, the section is not a stub but gone.
  **The line above the section is the panel's own divider**, not a hairline: the tree gave the
  section a fixed seven rows at first, and seven rows is not a reading of a log — the one thing
  the section is asked for is "what did this task put down", which is as long as it is. Making it
  a split is also what makes folding it the same act as folding the panel one level up (the item
  collapses; the section stops measuring itself), and the height rides in the window's restorable
  state beside the column widths, for the same reason they do. Dragging it shut is remembered as
  folding it, or the next worktree with commits would push open a section that was deliberately
  closed.
- **What git has underway is part of the history, not a separate readout.** A rebase stopped on a
  conflict, a merge waiting to be committed, a bisect — `git_repository_state` answers which in
  one read of the gitdir, and the step count is read from the files git already wrote there
  (`rebase-merge/msgnum` of `end`, or `rebase-apply/next` of `last`) rather than through
  `git_rebase_open`, which opens a rebase in order to *drive* it and hukan does not act on
  worktrees. It belongs to the history because it is the history that stops making sense without
  it: a rebase replays onto a detached HEAD, so `<base>..HEAD` loses the branch's own commits
  until they are re-applied one at a time — on a checkout in sync with its remote the list empties
  outright — and that happens on a worktree whose files are full of conflict markers. A section
  that quietly empties is the worst available answer, so the operation is also what keeps it on
  screen when there is nothing to list. The enum is not the label: git has run every rebase
  through the merge backend since 2.26, leaving an `interactive` marker even for a plain
  `git rebase main`, so libgit2 says `REBASE_INTERACTIVE` for both — saying "interactive rebase"
  because the enum did would be reporting git's plumbing rather than what is happening. The same
  read gives the worktree its name back: a detached HEAD's shorthand is the literal `HEAD`, so a
  rebase used to cost the rail and the top bar the branch they name it by.
- **In that tab the file is the unit, not the commit — and the tab is a stack of cards, not a
  document.** It was one text view holding the whole commit first, headers and message and all,
  and that is what a patch file looks like rather than what a change looks like. One document has
  one layout, and the two halves of a commit disagree about it: a message is prose and wants the
  column's width, while a diff line is code and must never be split across two gutter rows. So the
  message is a wrapping label and each file is a card — a header of real views (git's status
  letter as a pill, the path with its directory held back, the diffstat) over its own diff. The
  header is the fold, and the whole strip takes the click, because what is being aimed at is the
  file and not a chevron the size of a full stop.
  A card's diff is read, coloured and laid out only once it is open, so the tab costs what is on
  screen and a 5000-file vendor drop opens at once — its delta list is free, and nothing under it
  is built until it is asked for. What opens on arrival is a line budget spent in file order,
  passing over what does not fit rather than stopping there — stopping hands you a wall of folded
  cards whenever the expensive file sorts first, and a card that is shut still carries its own
  diffstat, so it says why. Past 300 files the cards stop being built at all, since a card is real
  views and ten thousand of those is a freeze of a different kind; what is left out says so at the
  foot of the list rather than being quietly dropped.
  Inside a card there is no `diff --git`, `index`, `---` or `+++` — the header said the path
  already, so four lines per file would say it again — and no `+`/`-` column: which side a line is
  on is a full-width band behind it and the blank half of a two-column gutter, old number then
  new. Taking the sign out of the text is what makes a line copy as code. The colours are the
  editor's tree-sitter, mapped per line from *the file's* parse rather than the hunk's, since a
  hunk starts mid-scope and a grammar reading one alone gets its strings and comments wrong at
  both ends. The caps are per file — 20,000 lines, or a megabyte — so a wall is one file wide and
  the rest of the commit still reads; the byte half is what catches the minified file, which is
  two changed lines and three megabytes and which no count-based cap sees coming. Renames are
  folded back into one card (`git_diff_find_similar`), or a directory move reads as twice the work
  it was and spends twice the budget saying so.
  The search is the tab's own field rather than a text view's find bar, because what it has to
  cross here is more than one text: it marks every occurrence in every open card at once — in a
  diff the useful question is usually "where else", not "next" — and Return steps through them. It
  opens what it can afford before it searches, since a fold is a reading convenience and must
  never act as a filter on the search.
- **The reads are bounded by what they cost, and it was measured.** Against synthesized
  repositories: the list costs its page and not its history — 0.41ms for 50 rows on a
  5000-commit repository, 1.83ms for 500. That is only true because the walk is *unsorted*
  (`GIT_SORT_NONE`): first-parent simplification off one tip leaves a single chain, so it comes
  out newest-first by construction, while asking for a topological sort makes libgit2 preload the
  whole history before yielding a row — the same 50-row page measured 13.7ms sorted, a number set
  by the history's depth rather than the page's size, and a refresh runs per FSEvents batch for
  every open worktree. Two other things were not free. Asking
  `git_graph_descendant_of` per row for the pushed marker cost *rows × history depth* (8.2ms for a
  full list), against the 1.3ms of everything else a refresh does — and a refresh runs per
  FSEvents batch for every open worktree, which is the shape that buried the machine when these
  reads were subprocesses; one walk of `upstream..HEAD` answers the same question exactly, in
  1.2ms. The tags are the same shape of question and were bounded the same way: the scan grows
  with the *repository*, not the page, so it runs only on a wholesale refresh — a ref lives in
  git's own directory, so a batch narrowed to paths in the working tree cannot have moved one,
  which is the reasoning that already keeps the index out of a narrowed read — and it is read
  through a glob-restricted ref iterator, which is not a detail: on a checkout with 1462 tags and
  4871 refs the same answer costs 28ms through `git_tag_foreach` and 25ms through
  `git_reference_foreach`, both of which walk every ref and look each one up again, against 8.4ms
  for the one that walks the packed table's `refs/tags/` run once. The map is repository-wide
  rather than page-wide, which is what makes paging free: a page reaching further back is already
  answered. And a commit tab built its text whatever the commit's size: a 5000-file vendor drop took
  363ms to read and 812ms to lay out, the second of those on the main thread. Capping the *commit*
  was the first answer and it was not an honest one — the cap counted changed lines, while what
  gets laid out is the patch, which carries every hunk's context too (measured at 4.5× the
  changed-line count where the edits are scattered), and no count sees a minified file's megabyte
  on one line at all. Making the file the unit is what fixed it: the delta list is free, a section
  is read only when it opens, and the one commit-wide gate left is the 500 files past which
  per-file line counts are dropped rather than counted — counting means building every delta's
  patch, which is 363ms, where the list without them is nothing. That also took the commit's read
  from three passes over its content to one: `git_diff_get_stats` and `git_diff_to_buf` both went,
  and the per-delta patch that was already being built answers what they were asked for. All of it
  now costs about what the reads it rides along with cost, which is why none of it needed a cache:
  the cheapest version of this is no bookkeeping at all.
