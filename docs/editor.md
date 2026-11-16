# The file pane

Settled decisions, moved out of CLAUDE.md so it stays loadable. Each bullet is a decision
and the reasoning behind it; read the file before changing the area it covers.

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
  **A file it cannot read as text says so, and refuses the keyboard.** The read fell back to an
  empty string, which is not the same answer as an empty file: it lands as a buffer that can be
  typed into, and ⌘S writes that buffer back — so a `.zip` opened by a mis-click and one keystroke
  was the archive gone, silently, with the tab still claiming to show it. The note stands where
  the text would be and the pane is left uneditable, the same call the browser's error page makes
  for a load that failed. The ruler goes with it: a gutter row is a file line, and a note has none
  to number.
- **A file whose content is pixels is drawn, and it is drawn at actual pixels.** It is not a
  second kind of tab: a buffer is `(Worktree, relative path)` whatever the bytes are, so an image
  is this pane answering differently — the strip, the order, the restoration and the scripting all
  carry on not knowing. What decides is **a table of extensions**, because both tests that look
  like the right one are wrong in the same place: `NSImage(contentsOfFile:)` and `UTType`'s
  `.image` conformance each say yes to `.svg` (measured), which is source an agent edits and has
  to stay in the editor. `.pdf` is the one image-ish thing left out on purpose: a page is drawn
  from instructions rather than held as pixels, so the promise below has nothing to attach to.
  Anything else falls through to the note above, which is also where an image too large or too
  broken to draw says so: the same answer in the same place, so a `.png` that is refused never
  reads as a `.png` that is empty.
  **Which bitmap is on screen is hukan's own decision, because a file may hold several.** An
  `.icns` here holds ten, 1024 down to 16, and `NSImage.size` answers 512 — neither the largest
  nor the size of any single one of them — so leaving the choice to AppKit means the pixel count
  under the picture is a guess about a file it is not the whole of. Every bitmap is measured
  before any is decoded (ImageIO answers a dimension without decoding a pixel) and **the largest
  is drawn**, named by index rather than by asking for "the image": largest because an icon
  container is opened to be looked at, and by index because the order is the file's — this `.icns`
  happens to put 1024 first and nothing in the format says it must. The caption says so when
  there is more than one, or it is a true number about the wrong thing. That rule is what brought
  `.icns` into the table and what `.ico` needed all along, being the same kind of file: excluding
  one and admitting the other was one decision made twice.
  **Actual pixels means one image pixel to one *device* pixel, which is a fact about the display
  and not about the file.** The alternative reading — one pixel to one point — is a 2× upscale on
  this machine, and the file being looked at most is a screenshot of text, so it would be read
  blurred. `NSImage`'s own `size` cannot answer it: it is the pixel count divided by whatever DPI
  the file claims, and the DPI in real files is noise — hukan's own 2× snapshot references say 72,
  and a `@2x` asset in the wild said 96, which is neither its pixels nor its intended size. So the
  pixels are read from the header (ImageIO answers that without decoding, the same shape as
  `git_patch_size` answering in bytes without building the patch) and the scale from the window.
  A side effect worth having: a `@2x` asset then draws at the size it was cut for, with nobody
  parsing `@2x` out of a filename. It is re-measured when the window changes display, since the
  statement is about the display; **and the centring is landed on the backing grid**, because
  centring is exactly the arithmetic that produces the fractional origin that would resample a
  1:1 blit back into softness.
  **What does not fit scrolls**, which is the rule the editor beside it already follows for a long
  line — this pane never shrinks its content to the column. Getting closer is the trackpad's: one
  property (`allowsMagnification`) brings the pinch and the two-finger double tap, and the zoom
  keys are the way back, where `⌘0` is not a figure of speech but the rung at which the pixels line
  up again. The ceiling is per image, because far enough is a size on screen and not a factor —
  4× of a 16px icon is still 32pt of nothing — and the magnification survives an agent rewriting
  the file under the reader (a refresh should change the picture, not the place they were looking
  at it from) but not a relaunch, for the reason a web tab's zoom does not: what a restored tab
  carries is what identifies it.
  **The checkerboard is under the image and nowhere else.** Drawn rather than an asset, out of two
  semantic fills so it follows the appearance, and clipped to the image's own rect — one running
  out over the pane would say the whole column is transparent. There is no border around the image:
  drawn inside it covers the outermost row of the file's pixels, and drawn outside it grows with
  the magnification into a frame nobody asked for. The caption under it — the pixel count and the
  size — is drawn rather than set in a label, because a label is a control and AppKit rounds a
  control's intrinsic size to the *screen's* backing grid, the one thing a pinned snapshot cannot
  pin. It is the only place the pixel count is stated at all, now that the drawing is half as wide
  as it on a 2× display.
  **What the pane gives up saying so**: an animated GIF stands at its first frame, animating one
  meaning an `NSImageView` laid over the checkerboard rather than drawn into it; ⌘F is aimed away,
  an image being the one surface on the desk with no text for a find bar to reach; and there is no
  gutter, no base and no dirty state, so nothing here can be saved or asked about on the way out.
  **And there is no image diff**: the file pane has no diff at all by the decision above, so a
  changed image is the one on disk and what it replaced is the PR's to show.
- **A Markdown file's preview is a second tab on the same buffer, not a mode of the first.** A
  Source/Preview switch in the pane is the Diff/Source switch again, the mode needed always being
  the one you are not in; so the preview is a tab of its own, beside the source, keyed by the same
  `(Worktree, relative path)` with its kind beside it — read-only, never the preview slot (it is
  asked for by name), following the source's buffer as it is typed, and back as a preview after a
  relaunch. The file is still edited in exactly one place. **It is read through the transcript's
  renderer**, for the reason that renderer exists: every CommonMark library drops emphasis that
  touches CJK punctuation, and one window reading Markdown two ways would draw the agent's plan
  and the same plan written to a file differently. What a file adds is that its line breaks are
  the writer's editor rather than the writer, so a document closes a wrapped paragraph up — with
  no space where either side is CJK — where a message keeps every line it was sent with. **HTML,
  Mermaid and maths are not rendered**: each needs a browser engine behind the preview, which
  would trade away the renderer this rests on, and a count of the `.md` files on this machine put
  them at a few dozen against eleven thousand. The editor goes on never wrapping.
- **The gutter is where the diff signal reaches line granularity** — change bars beside the
  line numbers, never a second text mode. Stagedness is the bar's fill — solid working-tree,
  hollow staged — because the color already carries the kind: green added, blue rewritten, a
  red wedge for a deletion boundary. **The bars measure the buffer, not the file on disk.**
  They hid while the buffer was dirty at first — the file on disk being what git can answer
  about — and that is backwards: the lines you most want marked are the ones you are typing,
  and the mark going out exactly when you touch it is the moment it was needed. What it costs
  is holding the file's text at HEAD and in the index for as long as it is open, so an edit
  re-diffs two strings rather than asking git per keystroke. **A change stays marked until it
  is committed**, and staging only hollows it — which is a different question from "what is not
  yet staged", and the answer to that one empties as you stage.
  **Hovering a bar opens the block it belongs to** — the lines as they read at the base above
  the lines that replaced them — because a bar says *that* something changed, and the only way
  to see *what* was to leave for the PR. A block with nothing removed opens nothing: its added
  lines are already on screen. The card never takes a click; reading is all it is for, and
  acting on a hunk — stage, revert — is git's, per the worktree rule in `docs/model.md`.
  The editor never wraps a line: a gutter row is one file line, and wrapping would split that
  line across rows. Long lines scroll sideways, and wrapped reading stays the transcript's,
  for prose.
- **Highlighting is a rendering attribute, not text.** tree-sitter parses (vendored grammars,
  see `docs/build.md`) and the colors land as TextKit 2 rendering attributes — so the document,
  its undo stack and the dirty state never learn highlighting exists, and the buffer stays
  exactly what a save writes. The whole file is re-parsed rather than incrementally: a parse
  costs less than a person types, and a whole-file one cannot fall out of step with the buffer,
  which an incremental one drifting by a unit at a time very much can. Past a size no one edits
  by hand the file is left plain.
  **A file is often more than one language**, so a grammar's own account of which of its ranges
  belong to somebody else is followed rather than ignored: a fenced block in Markdown is
  coloured as the language it names, and Markdown's emphasis is a second grammar again. A
  language named but not vendored is left plain.
  **A patch is the case that says what an injection actually is.** A `.diff` opened here reads as
  the file it patches: the grammar names the language by naming the file, so the extension table
  answers it, and the rows of a hunk are cut out, joined and parsed *together* — a grammar handed
  a single line gets its strings and comments wrong at both ends, the same reason a commit's diff
  is coloured from the file's parse and not the hunk's. So an injection is a set of ranges rather
  than one, and a span coming back is placed by which of them it fell in. What the join costs is
  that it is approximate by construction: the hunks skip what lies between them, so the text
  parsed is not any file that ever existed. Every editor that colours a patch takes that trade,
  and there is no other on offer — a patch on disk has no file behind it to read instead.
  **Which side a row is on is a band, not a colour.** They are two facts about one row — this
  line was added, this line says `func` — and only one of them can be the foreground. The commit
  tab settled that already, so a patch opened as a file takes the same reading and the same
  colours, or one window would read a diff two ways. It costs a rendering surface that reaches
  past the row's own text, which is what a fragment subclass would charge every paragraph — the
  transcript draws its washes under the fragments instead — and what this editor was built not
  to; so it is asked for only in a file whose grammar bands rows
  at all, and every other file keeps the stock surface. The band never enters the storage — the
  buffer is exactly what `⌘S` writes, which is the line the colours already hold to — so unlike
  the commit tab's, which reads a fill off an attribute in text hukan itself built, this one is
  looked up in a table beside the document.
  **Only a patch carrying the `diff` line it was produced by** is read this way: without one the
  grammar builds no hunks and the payload is left plain. Every patch git writes carries the line,
  which is what makes this worth having in a git-only app; a bare `diff -u` gets its frame
  coloured and nothing else.
  **Bold and italic are drawn, not set.** A rendering attribute cannot carry a font — the
  advances were measured before it arrived — and putting the font in the storage instead would
  be the end of the document not knowing about highlighting. So emphasis is drawn over the
  glyphs the layout already placed, by thickening and shearing them where they stand. Synthetic
  rather than the font's own bold, but the file is monospace prose being checked, not typeset,
  and it keeps the buffer exactly what `⌘S` writes.
  **Plain is a style, not the absence of one.** A grammar's captures are written to correct
  each other — one paints a range and the next says part of it belongs to nobody — so a theme
  that answers "nothing to say" for the second leaves the first standing. Being deliberately
  plain and never having heard of the name are different answers, and the theme gives different
  ones.
  **The parse is the whole file; the question asked of it is what is on screen.** They are two
  costs and only one of them can be narrowed. A parse picked up in the middle gets the strings
  and comments wrong at both ends — the same reason a commit's diff is coloured from the file's
  parse and not the hunk's — so it reads everything, always. Running the highlights query and
  re-parsing every injected language is a *search of the tree the parse built*, and on a long
  file that is most of the time: measured here, a 1568-line Swift file spends 19ms parsing and
  18ms querying, and this file spends 50ms parsing and 146ms on the languages inside its fenced
  blocks. So the query is aimed at the viewport with a margin either side, and a fence outside
  it is not parsed at all. It is safe because tree-sitter returns every match that *intersects*
  a range, so a node enclosing the whole of it still arrives and the nesting the spans are built
  from is the nesting the whole file would have given — which is a property a runtime bump could
  quietly break, and so is what the tests assert rather than the timings.
  **The parse is then kept, and that is not the incremental parse this file declines.** Nothing
  is edited into a tree here; the text it was built from is held beside it, so it can only be
  reused by proving the buffer has not moved, and a tree that no longer matches its text is not
  a stale answer to be noticed later but one the lookup cannot return. What it buys is that
  asking a second question of the same text — which is what following the viewport is — costs
  the question and not the parse.
  **What is on screen is coloured first, and the rest follows without being asked.** Stopping at
  the viewport would mean every scroll starts a query and waits for it, and there is nothing to
  wait for once the tree is built. So the rest of the file is read the moment the viewport has
  been drawn, in one read, leaving the file coloured exactly as a whole-file read would have
  left it. It walked outward a step at a time once, with a beat between steps to keep the main
  thread for the reader, and that staircase was most of the wait — the colour arrived in five
  goes on a long file and reached its end at twice the time one read takes. The viewport is
  what the beat was protecting, and it is already on screen by then. Only the first read
  clears — the second adds to a file that is already on screen, and clearing there would take
  the colour off the lines being read for as long as the rest takes. A scroll before that has
  landed is the one thing this shows: text arrives plain and fills a beat later, which is the
  trade every editor that does this makes.
