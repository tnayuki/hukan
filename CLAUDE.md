# hukan

Built for one user, on macOS, for git and Claude Code only. No LSP, debugger, cross-platform,
multiple cursors, or elaborate multi-root features — external tools do those better, and
dropping them is what keeps this small.

This file holds the principles every change has to respect, an index of where each area's
settled decisions are written down, what is TODO, and how development runs. The README
describes only what currently works. The decisions themselves — each with the reasoning and
the measurements behind it — are in `docs/`, one file per area; **read the area's file before
changing anything in it**, since most of what looks arbitrary there was chosen against an
alternative that was tried.

---

## Model

```
Workspace (one window)
└─ Repository        ← the open/close unit; identity is git's common dir's parent
   └─ Worktree
      ├─ Session (agent)   ← claude -p over pipes; owns a desk
      │  └─ Terminal       ← a shell over a PTY, a tab on that desk
      └─ File              ← a buffer, (Worktree, relative path)
```

The principles below are short forms. The full text of most is in `docs/model.md`; the
outbound list is in `docs/updates.md`, and the guarded verbs in `docs/testing.md`.

- **Buffer identity is `(Worktree, relative path)` — never the absolute path.** Otherwise the
  same file in two worktrees is two unrelated buffers. Practically impossible to retrofit.
- **Worktree and Repository, git's vocabulary — not Root and Project.** A non-git directory
  still opens as a repository of its own, the degenerate case.
- **Repository identity is `git rev-parse --git-common-dir`'s parent.** Worktrees are
  enumerated from git, never opened or closed individually. A worktree leaving does not take
  its sessions: they move to the main checkout and keep the branch, struck through.
- **Open Recent is hukan's one app-global store** — a list of repository paths, not a dimmed
  row on the rail, since a closed repository has nothing to say.
- **Where a session is, is read off `EnterWorktree`/`ExitWorktree`**, and the system prompt
  carries one line per tool the window depends on the agent calling — and nothing about what
  hukan is.
- **A desk is a session's, not a worktree's.** Its file tabs follow the session into another
  checkout — except a tab holding an unsaved edit, which stays on the buffer it was typed into;
  a file the new checkout lacks closes. No session, no desk.
- **Master data lives where it already is.** git owns worktrees, Claude Code owns sessions and
  transcripts; hukan stores open repositories and UI state only — plus the composer choices the engine
  forgets across `--resume` — and never writes a transcript.
- **What the engine knows, the engine is asked — over the stream, never by sending a message.**
  A probe must not be a turn. What the engine spells, hukan shows as it arrives.
- **A failed turn is `is_error`, not the subtype**; what it failed of is `terminal_reason`.
- **An outside client reaches the sessions over stdio from the bundle's own executable**, no
  port; it speaks to a session and decides nothing, and says where it came from.
- **Scope decides where a reading goes**: window-wide facts on the toolbar, a conversation's
  facts in its header.
- **hukan observes worktrees, it does not act on them.** Work reaches main through a PR the
  agent opens; no local merge, no forced delete, nothing modal over the rail.
- **hukan's own outbound requests are a closed list** (`docs/updates.md`). libgit2 is built
  network-less; the browser's traffic is the user's.
- **Decisions put to the person stay the person's.** An approval or a question is never
  answered by an outside client or by the session's own agent: `approve`/`deny` are honoured
  only under `HUKAN_SCRIPTING_GUARDED=1`, no Apple event is taken from a process hukan started,
  and a message is refused to a session waiting on a decision, since a send would cut the turn
  and drop it.

### Where each area's decisions are

| File | Covers |
| --- | --- |
| `docs/model.md` | Most of the principles above, in full |
| `docs/desk.md` | Maximize and double-click, ⌘T allocation, tab restoration, unsaved edits on close, terminal tab names, outside paths and `$EDITOR`, column minimum widths |
| `docs/rail.md` | Rail history, the session list and its order, groups, archiving, sessions started elsewhere, names, tags, copying a session's path and id, id spelling |
| `docs/transcript.md` | The document view, links, tables, code blocks, token double-click, find, fork and roll back, the task card, following another process's transcript |
| `docs/composer.md` | Slash completion and completion from past prompts |
| `docs/browser.md` | The web tab: address bar, error page, chrome, sharing a tab with the agent |
| `docs/editor.md` | The file pane, images, Markdown preview, the gutter, highlighting |
| `docs/files-panel.md` | Tree, filter and search (rg), right-click writes, drag and drop, Quick Look, change washes |
| `docs/history-and-commits.md` | The History section, git operations underway, the commit tab, read costs |
| `docs/change-tracking.md` | Untracked files as changes, how an FSEvents batch reaches tabs and git |
| `docs/virtual-machines.md` | macOS, Linux (Rosetta, GPU) and Windows machines |
| `docs/remote-control.md` | Remote Control, its QR code and the replay of remote messages |
| `docs/updates.md` | The update check and the list of hukan's own outbound requests |
| `docs/build.md` | The build system, vendored frameworks, ripgrep, arm64, the Dev app, signing |
| `docs/testing.md` | Parallel tests, transcript previews, snapshot tests and CI, AppleScript verification |
| `docs/release.md` | swift-format and the release chain |

A new decision goes into its area's file, or a new file listed here; this file gains a line
only for a principle that holds across areas.

---

## TODO

- **Code folding** — the remaining editor piece, and the heavy one: collapsing a function or
  block means teaching TextKit 2's content storage to skip ranges, which is documented thinly.
  The fold ranges themselves are free — the vendored grammar ships a `folds.scm` the build
  script currently leaves out (see `QUERIES` in `Vendor/build-tree-sitter.sh`), and the same
  parse that colors the file would answer them. Still not an editor (see the README): no LSP
  or multiple cursors (see the intro). A new *language*, by contrast, is cheap: one line in
  the build script's grammar list, one entry in `SyntaxHighlighting.grammars`, rerun the
  script.
- **GitHub / GitHub Enterprise integration** — in the UI, not a `gh` shell-out: hukan talks
  to the GitHub API itself (Enterprise is the same API under a different base URL). A
  worktree's PR belongs next to the work it holds: its state on the rail extends "find what
  is waiting on you" past local approvals — a failed check or a review request is also
  waiting on you, and a merged PR is what lets a worktree leave the rail — and review comments
  read next to the diff lines they discuss. Reading comes first;
  whether hukan ever writes back (a reply, a re-request) is open. A `gh`-based PR-state link
  was prototyped and pulled back out; evaluating the real thing needs a repository with a
  real remote, Enterprise included.
- **Browser** — what is left open is the login state: sharing Safari's is officially impossible
  (plan B: inject `Cookies.binarycookies`, needs Full Disk Access). Measured with a WKWebView
  harness (2026-08): SSO redirect chains and Kolide device trust **work**; passkeys and iCloud
  Keychain autofill **do not** (browser-vendor entitlements) — which is what the error page's
  Open in Safari is for.

---

## Development process

Code, comments, documentation and commit messages are in English.

Documentation moves with the code: a change that adds or alters behavior revisits the README,
the area's file in `docs/` and this file's TODO in the same commit. A stale line is worse than
none.

Keyboard shortcuts stay out of every document. The menu carries them at runtime and `main.swift`
defines them; what a document may hold is the *allocation decision* — which family owns a key,
and why — never the list. Gestures are not shortcuts and stay.

### Build and test

`hukan.xcodeproj` is the only build system — no Makefile, no `Package.swift`. The project is
hand-authored and tracked; edit `project.pbxproj` directly. Folder groups are
file-system-synchronized, so a new file under `Sources/` just appears. The vendored
xcframeworks and generated resources are rebuilt by hand with the scripts in `Vendor/`
(`docs/build.md`). The build is arm64 only.

```sh
xcodebuild build -project hukan.xcodeproj -scheme Hukan -derivedDataPath .build/DerivedData -skipPackagePluginValidation
open ".build/DerivedData/Build/Products/Debug/Hukan Dev.app"   # relaunch; restoration needs open, not the raw binary
```

Debug builds `Hukan Dev.app`, a separate app from the released one (`tell application "Hukan
Dev"`). Signing is ad-hoc, so TCC grants reset on every rebuild. ripgrep is the one program
hukan runs, from Homebrew (`brew install ripgrep` for a build not installed through the cask).

The tests run in parallel, so the log carries no assertion messages — read failures from the
`.xcresult`:

```sh
xcodebuild test -project hukan.xcodeproj -scheme Hukan -derivedDataPath .build/DerivedData \
    -skipPackagePluginValidation > /tmp/xb-test.log 2>&1; echo "exit=$?"
R=$(ls -td .build/DerivedData/Logs/Test/*.xcresult | head -1)
xcrun xcresulttool get test-results summary --path "$R" | jq -r \
    '"\(.result): \(.passedTests) passed, \(.failedTests) failed", (.testFailures[] | "  \(.testIdentifierString)\n    \(.failureText)")'
```

Snapshot tests pin the look; re-record with `TEST_RUNNER_HUKAN_RECORD=1` (which exits 65 on
purpose) and eyeball the PNGs before committing. Iterate on a look offscreen with
`TEST_RUNNER_HUKAN_PREVIEW=<case>`, never through the running app. Verify the GUI through the
AppleScript dictionary, never with coordinates — extend it when something cannot be read back.
All three are in `docs/testing.md`.

### Formatting and release

Standard swift-format with the default config. Fix a tree with
`xcrun swift-format format -i -p -r Sources Tests`; the tracked pre-commit hook lints the staged
blobs and blocks on any finding (`git config core.hooksPath .githooks` once per clone), and the
Release workflow lints with `--strict` on every push.

A release is a tag: bump `CFBundleShortVersionString` in `Resources/Info.plist`, commit, tag
`vX.Y.Z`, push the tag. The workflow publishes the GitHub Release and then pushes the cask to
`tnayuki/homebrew-hukan`, with no gap between the two (`docs/release.md`).

### One module, one convention

Everything compiles into the one app module, but three folders carry three conventions:

- **`Sources/Hukan`** — the app: `Workspace`/`AgentSession`, the windows, the columns.
- **`Sources/Transcript`** — the transcript's rendering. Keep it free of
  `Workspace`/`AgentSession`/window — if a render type starts wanting an `AgentSession`, add a
  protocol (`TranscriptStorageMirror` is the pattern), do not reach for it.
- **`Sources/Engine`** — the Claude Code interface: the `claude -p` stdio client and the
  `~/.claude/projects` store. It touches the wire protocol and disk, nothing else — no window,
  no `Workspace`, and no rendering.

The splits are a convention, not a target boundary — the compiler does not enforce them since it
is one module.
