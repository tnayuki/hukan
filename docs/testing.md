# Testing

## The tests run in parallel, and the log pays for it

The scheme marks `HukanAppTests` parallelizable, so `xcodebuild test` — and `⌘U` — splits the
test classes across several host processes. The suite went from 51s to 17s wall (measured), and
that is not the core count talking. `BrowserTests` loads WebKit into the test host, and from
that point every `Foundation.Process` spawn in *that* process costs about 7×:
`GitTests` 0.36s → 2.65s, `GitHistoryTests` 2.30s → 16.08s, while pure-CPU work
(`SyntaxHighlightingTests`, 0.26s → 0.25s) and the terminal's `forkpty` (3.17s → 3.19s) are
untouched. The git-backed tests build their fixtures with the CLI — the CLI is the oracle, which
is the point of them — so they are nearly all spawn, and they were paying for a browser test two
suites earlier in the alphabet. Splitting the host confines that to one worker: with parallel on,
skipping `BrowserTests` outright no longer moves the wall clock at all (16.38s against 16.36s).
The mechanism behind the 7× was not identified — it does not reproduce in a plain binary that
loads WebKit, only inside the XCTest host — so this is isolation, not a fix.

What it costs is the log. In parallel mode xcodebuild stops printing the serial format, so
`Test Case '-[Suite test]' passed` and `Executed N tests` are simply absent — grep for those and
you get nothing, which reads as "no tests ran". What is printed is
`Test case 'Suite.test()' passed on 'My Mac - Hukan Dev (pid)'`, interleaved between workers and
occasionally cut mid-line, plus a `Failing tests:` list at the end. **An assertion's file, line
and message are not on stdout any more.** They are in the `.xcresult`, which is where a failure
has to be read from now — cheaper than grepping a 128 KB log, and the whole reason in two lines:

```sh
xcodebuild test -project hukan.xcodeproj -scheme Hukan -derivedDataPath .build/DerivedData \
    -skipPackagePluginValidation > /tmp/xb-test.log 2>&1; echo "exit=$?"
R=$(ls -td .build/DerivedData/Logs/Test/*.xcresult | head -1)
xcrun xcresulttool get test-results summary --path "$R" | jq -r \
    '"\(.result): \(.passedTests) passed, \(.failedTests) failed", (.testFailures[] | "  \(.testIdentifierString)\n    \(.failureText)")'
```

Recording is unaffected: re-recording every snapshot under parallel produced byte-identical PNGs,
and each suite writes its own files. `TEST_RUNNER_HUKAN_RECORD=1` still exits 65 on purpose —
that is the "recorded … run again without HUKAN_RECORD to verify" failure, not a parallel one.

## Iterating on the transcript's look

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

## Snapshot tests pin the look

`xcodebuild test` renders every `RenderCase` through the app's own drawing path and
pixel-compares against the reference PNGs in `Tests/HukanAppTests/Snapshots/`. When a change
is intended, re-record with `TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test …`, then eyeball the
new PNGs before committing. The approval, question and task cards — real AppKit views, which the
transcript's harness cannot reach — are pinned the same way by `CardSnapshotTests`, and the
editor pane — highlighted source, gutter, every change-bar state — by `EditorSnapshotTests`
(`editor.png`; eyeball it with `TEST_RUNNER_HUKAN_PREVIEW=editor`, which writes
/tmp/hukan-preview-editor.png instead). That suite has two more references, because they are the
same pane answering the same question differently and one image cannot hold three: `patch.png`
(`…PREVIEW=patch`), rows banded and the payload coloured by the language being patched, and
`image.png` (`…PREVIEW=image`), a file whose content is pixels — drawn at actual pixels rather
than fitted, centred on the backing grid, over the checkerboard, with the drawn caption under it.
Its picture is built in the test out of greys, not committed beside the reference: every other
fixture in that suite is a string in the source, and a grey is what survives the device-RGB to
sRGB conversion under any display profile. The files panel's History section is pinned by
`HistorySnapshotTests` (`history.png`, `…PREVIEW=history`), drawn at the panel's minimum width
because that is where a summary truncates, and the commit tab by `CommitSnapshotTests`
(`commit.png`, `…PREVIEW=commit`), drawn through `present(_:sections:)` so the cards can be posed
— one open over a real highlighted diff, one too large to show, one binary — without a repository
standing behind them. Both draw through `displayIgnoringOpacity` into their own context rather
than `cacheDisplay`, which fills an opaque background and drops layer-backed subviews (it returned
the History rows under a blank strip where the header's title should have been).
The command list is pinned by `CompletionSnapshotTests` (`completions.png`, `…PREVIEW=completions`),
and the web tab's chrome by `BrowserSnapshotTests` (`browser.png`, `…PREVIEW=browser`) — the bar
and nothing under it, in the three states it is ever in, since a rendered page is WebKit's work
and pinning it would be pinning a browser engine rather than hukan.

**A snapshot must not be a photograph of the machine that took it**, which is what every one of
these was. Three things about the display reached the reference, each measured against a runner
that draws on a 1× 1024×768 virtual screen where this machine is 2×. A window's
`backingScaleFactor` is the grid AppKit aligns layout to — 0.5pt at 2×, 1.0pt at 1× — so the same
view puts its text a device pixel off, per element; `NSImage.lockFocus` and
`bitmapImageRepForCachingDisplay` take their scale from the display, so a reference came back half
size; and a `.deviceRGB` bitmap is *device* RGB, where greys survive the conversion and saturated
colours do not. So they all draw through `SnapshotSurface` now: one window class that reports the
recording scale wherever it runs, and one sRGB bitmap at that scale. The command list adds a
fourth — its panel's root is an `NSVisualEffectView`, whose material *does* render into a bitmap
of our own, as whatever the machine's Reduce Transparency setting makes of it — so an opaque view
goes in under the rows and the snapshot pins the rows, which is what it is for.

**Three of those are the machine's settings rather than its display**, and the workflow writes
them before it runs: Reduce Transparency, which is what an `NSVisualEffectView` and every semantic
system fill read; a preferred language, since CoreText picks the CJK fallback from it and with
none of them Japanese a kanji arrives from PingFang SC in Chinese glyph forms at Chinese advances;
and scroll bars, which when always shown narrow every scroll view until a summary truncates a word
early. Each was measured against a runner, and each moved a reference on its own.

**What CI still skips is what the screen decides.** AppKit rounds a control's intrinsic size to
the *screen's* backing grid and not to the window's, which no amount of pinning reaches: an
`NSButton` holding a symbol measures 13.5pt on a 2× display and 14pt on a 1× one, so the browser's
bar and everything after it sits a device pixel over, and the same rounding catches the commit
tab, the History section's tag rule and the approval card's icon row — and the grant card's,
which is built the same way. The reader tests were skipped too, for a second thing the screen decides — they
open a window wider than it, and AppKit constrains a frame to fit — but that one a resolution
*can* answer, so the workflow asks the display for the widest mode it advertises. They all run
now: the two that used to fail in a parallel whole-suite run and pass alone were waiting a fixed
beat for a resize to land, which is a guess about how busy the machine is, and they wait for the
column to stop moving instead. A tolerance is the one answer this comparison refuses, so those stay
skipped and the rest — the transcript, the editor, the cards, the command list, the emphasis
drawing — are a gate CI keeps now. Closing the last of it needs a real 2× display, which only
`CGVirtualDisplay`'s private hiDPI flag can conjure and which Chromium's own test infrastructure
declines to use on a headless bot; `displayplacer` cannot, its twelve modes all being `scaling:off`.

## Verifying the GUI: AppleScript, not coordinates

System Events coordinate clicking breaks when a window moves; the scripting surface exists for
this — extend it rather than reaching for coordinates. The dictionary is an object model
(`application → window → repository → worktree → session`):

```sh
osascript -e 'tell application "Hukan Dev" to get name of every worktree of every repository of window 1'
osascript -e 'tell application "Hukan Dev" to files'   # then: files filtering "…" / files searching "…" / files menu "…" / files previewing "…"
osascript -e 'tell application "Hukan Dev" to send "..." to (selected session of window 1)'
osascript -e 'tell application "Hukan Dev" to get transcript of (selected session of window 1)'
osascript -e 'tell application "Hukan Dev" to get history of worktree "main" of repository 1 of window 1'
osascript -e 'tell application "Hukan Dev" to commit "<full oid>"'   # then: commit / commit toggling 3 / commit finding "…"'
osascript -e 'tell application "Hukan Dev" to tabs'
osascript -e 'tell application "Hukan Dev" to completions typing "/co"'   # then: completions moving 1 / accepting true / completing true
osascript -e 'tell application "Hukan Dev" to recents'   # then: recents opening "<path>"
```

The session verbs address the session as the receiver — `stop session X`, or `tell session X to
stop` / `start` / `interrupt` / `restart` / `fork` / `roll back` — the way `close repository X`
does; `send` is the
exception, naming its target with `to` (`send "…" to session X`) because its direct parameter is the
message. The standalone utility verbs (`hukan status`, a bare `restart` to relaunch the app) stay
app- or window-scoped; `hukan status` returns one line per worktree with its sessions. The commit tab has a hidden verb of its own — `commit` opens one, reports its cards a line each,
and folds or searches them — because the tab is a stack of cards with no text of its own to read
back, and checking it any other way means clicking at coordinates. It takes the whole oid, the way
libgit2 does. The verbs
that stand in
for a human decision — `approve`/`deny` a pending tool call (`approve session X`) — are honoured
only under `HUKAN_SCRIPTING_GUARDED=1`, since a session's own agent can reach `osascript` and would
otherwise approve its own calls. The verbs that steer a session — `send`, `stop`, `interrupt`,
`restart`, `roll back`, and the outside client's `mcp call` — are refused to any process this hukan
started, which is every agent and every terminal shell in it: a neighbour steered from there is the
agent driving the app, and a send landing on a session waiting on a card throws the decision away.
A script from anywhere else is the person's, and `send` takes the outside client's road — refused
to a session waiting on you, and noted in the transcript as a script's. The files panel has a hidden verb for the same reason the tabs
do — it is rows and not text, so `files` reports what the panel is showing and which of the two
gestures put it there, and `filtering`/`searching` run them. `files menu "<path>"` reads back the
right-click menu that row would carry, a line each, and `files previewing "<path>"` is Space on
that row — the Quick Look panel is the system's own and has nothing to read back, so what it is
showing is reported through `files` itself; the writes that menu makes
(`creating`/`folder`/`renaming … to …`/`deleting`) are guarded, because each of them stands in for
a human's answer — a name typed on the row, or the alert before a delete. `tabs` is the same
answer for the strip as a whole, which is what a relaunch has to be checked against: which tabs
came back, in what order, which one is showing, and which of them have been read yet — all of it
buttons, and otherwise only reachable by clicking at coordinates. `completions` is another of that
kind: the command list is rows on a panel floating over the window, so checking that a `/` opened
it — and that `⏎` took the row the arrows had reached — is otherwise a click at coordinates.
`typing` goes through the text view's own edit path rather than a shortcut only a script can
take, so what it exercises is the list a person would get. `transfer "<path>"` is the drop between two rails — a repository moved, live, from the window
holding it into the front one, or into a new window when the front one is holding it, which is
the only way a script can have a second window to move into. `recents` is one of the same kind: Open Recent hangs in three places, two of them
context menus that cannot be opened without a right-click at coordinates, so the verb reports what
a row would say and what it would open, and `opening` takes one the way clicking it would.
`selected sessions` is the last of them, and
it reads *and writes*: a multi-selection is rows on a list with nothing to read back, and a
property that could only be read would leave the half worth checking — that a batch survives the
reload every FSEvents batch triggers — reachable only by ⌘-clicking at coordinates.
