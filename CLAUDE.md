# hukan

Built for one user, on macOS, for git and Claude Code only. No LSP, debugger, cross-platform,
multiple cursors, or elaborate multi-root features — external tools do those better, and
dropping them is what keeps this small.

This file holds the settled decisions, what is TODO, and how development runs. The README
describes only what currently works; the reasoning behind each decision lives in git history
if it is ever needed again.

---

## Model

```
Workspace (one window)
└─ Repository        ← the open/close unit; identity is git's common dir's parent
   └─ Worktree
      ├─ Session (agent)   ← claude -p over pipes
      ├─ Terminal          ← a shell over a PTY (scaffolding only — see TODO)
      └─ File
```

- **Buffer identity is `(Worktree, relative path)` — never the absolute path.** Keying on the
  path splits the same file in two worktrees into two unrelated buffers, and "put main and
  feature side by side" stops working. Practically impossible to retrofit.
- **It is a Worktree, not a Root, and a Repository, not a Project** — git's vocabulary, because
  hukan is git-only and "the folder you opened" is the notion this design argues against. A
  non-git directory still opens as its own repository, but it is the degenerate case, not the
  model.
- **Repository identity is `git rev-parse --git-common-dir`'s parent** — something git
  computes, not a folder someone nominated. Worktrees are enumerated from git, never opened or
  closed individually; they arrive with the repository and today leave only when it is closed
  (see TODO).
- **Session and Terminal are children of a Worktree, not peers of each other** — two
  implementations of one thing, a process running in this worktree, sharing the middle column
  via tabs.
- **A diff is a display mode of the file pane, not a separate pane.** Changed is diffed against
  `HEAD` — uncommitted work only, every worktree the same. The committed review belongs to the
  PR the agent opens; what hukan is uniquely placed to show is the work in flight before the PR
  exists.
- **Master data lives where it already is.** git owns worktrees, Claude Code owns sessions and
  transcripts; hukan stores only open repositories plus UI state — plus the one session-side
  exception, the composer choices the engine forgets across `--resume`.
- **hukan observes worktrees, it does not act on them.** Work reaches main through a PR the
  agent opens itself; cleaning up a merged worktree is a plain `git worktree remove` any
  session can run. No local-merge path, no forced delete — an irreversible decision does not go
  inside hukan without review — and whatever hukan eventually does to a worktree must never be
  modal over the rail.

---

## TODO

- **Terminal** — a shell over a PTY. The scaffolding is in the tree; nothing spawns a PTY or
  creates one yet.
- **Syntax highlighting** — the source pane renders as plain monospace. It is editable now
  (Source mode only; Cmd+S writes back atomically, leaving a file with an unsaved edit asks
  first — Save / Don't Save / Cancel — and a dirty buffer is never clobbered by an agent's
  on-disk refresh), but the text is flat.
  Highlighting is the missing half — still not an editor (see the README): you correct what an
  agent wrote, you do not live in it; no LSP or multiple cursors (see the intro).
- **GitHub / GitHub Enterprise integration** — in the UI, not a `gh` shell-out: hukan talks
  to the GitHub API itself (Enterprise is the same API under a different base URL). A
  worktree's PR belongs next to the work it holds: its state on the rail extends "find what
  is waiting on you" past local approvals — a failed check or a review request is also
  waiting on you, and a merged PR is what lets a worktree leave the rail — and review comments
  read next to the diff lines they discuss. Reading comes first;
  whether hukan ever writes back (a reply, a re-request) is open. A `gh`-based PR-state link
  was prototyped and pulled back out; evaluating the real thing needs a repository with a
  real remote, Enterprise included.
- **Browser: task-context tabs** — worktree = task = one issue, so the tab set belongs to a
  Worktree: switch worktrees and the whole desk switches. Tabs sit in the right column over one
  shared cookie store; later `hukan_read_tab` (MCP) makes an issue page the task's
  specification. Measured with a WKWebView harness (2026-08): SSO redirect chains and Kolide
  device trust **work**; passkeys and iCloud Keychain autofill **do not** (browser-vendor
  entitlements); sharing Safari's login state is officially impossible (plan B: inject
  `Cookies.binarycookies`, needs Full Disk Access). The two pieces still needed were proven at
  ~30 lines: `createWebViewWith` to open popups as real windows, `decidePolicyFor` to forward
  custom schemes (`kolide://`) to `NSWorkspace.open`.

---

## Development process

Code, comments, documentation and commit messages are in English.

Documentation moves with the code: a change that adds or alters behavior revisits both files
in the same commit — the README gains or corrects what now works, this file's TODO drops what
is no longer open. Both have drifted before (a 7-day rule the code had outgrown, verbs that no
longer existed), and a stale line is worse than none.

### Build

`hukan.xcodeproj` is the only build system — no Makefile, no `Package.swift` (SwiftPM as a
separate "fast loop" was measured no faster and dropped). One scheme, two targets (`Hukan`,
`HukanAppTests`):

```sh
xcodebuild build -project hukan.xcodeproj -scheme Hukan -derivedDataPath .build/DerivedData
open .build/DerivedData/Build/Products/Debug/Hukan.app   # relaunch; restoration needs open, not the raw binary
xcodebuild test  -project hukan.xcodeproj -scheme Hukan -derivedDataPath .build/DerivedData
```

The project is hand-authored and tracked — edit `project.pbxproj` directly. Folder groups are
file-system-synchronized, so a new file under `Sources/` just appears. `Resources/hukan.icns`
is a committed static asset; regenerating it is a manual step, not part of the build.

**Signing is ad-hoc (`-`)** — nothing hukan does needs a stable signature (restoration and
scripting key on the bundle id). The one cost: TCC grants (screen recording, accessibility,
automation) reset every rebuild, so re-approve them in System Settings after rebuilding, and
prefer the scripting surface over `screencapture` — screenshots come back black until Screen
Recording is re-granted.

### Formatting: swift-format, blocked at commit

Standard swift-format, no house style — Xcode's own binary (`xcrun swift-format`, nothing to
install), and `.swift-format` is `{ "version": 1 }`: the plain defaults, pinned to a config
version so an Xcode update cannot silently move them (the same reason the snapshot references
are pinned). Fix a whole tree with:

```sh
xcrun swift-format format -i -p -r Sources Tests
```

Enforcement is a tracked hook, `.githooks/pre-commit`, not CI — there is no remote yet, so the
commit is the only gate, the way the snapshot tests gate the look. It lints the *staged* blob of
each `.swift` with `--strict` and blocks on any finding, so what is judged is exactly what the
commit records. Activate it once per clone (`core.hooksPath` is not itself tracked):

```sh
git config core.hooksPath .githooks
```

When a real remote arrives (see the GitHub TODO), the same `swift-format lint --strict` becomes
the CI gate and the hook stays as the fast local echo. A handful of rules are lint-only —
`format` will not rewrite them: `.forEach { … }` over a for-in loop, an end-of-line comment past
the column, a non-`lowerCamelCase` name. The tree is clean of them today; fix any new one by hand.

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

### Iterating on the transcript's look

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

### Snapshot tests pin the look

`xcodebuild test` renders every `RenderCase` through the app's own drawing path and
pixel-compares against the reference PNGs in `Tests/HukanAppTests/Snapshots/`. When a change
is intended, re-record with `TEST_RUNNER_HUKAN_RECORD=1 xcodebuild test …`, then eyeball the
new PNGs before committing.

### Verifying the GUI: AppleScript, not coordinates

System Events coordinate clicking breaks when a window moves; the scripting surface exists for
this — extend it rather than reaching for coordinates. The dictionary is an object model
(`application → window → repository → worktree → session`):

```sh
osascript -e 'tell application "hukan" to get name of every worktree of every repository of window 1'
osascript -e 'tell application "hukan" to send "..." to (selected session of window 1)'
osascript -e 'tell application "hukan" to get transcript of (selected session of window 1)'
```

`hukan status` returns one line per worktree with its sessions; `screenshot` captures a window
in-app through the bundle's own screen-recording grant. The verbs that stand in for a human
decision — `approve`/`deny` a pending tool call — are honoured only under
`HUKAN_SCRIPTING_GUARDED=1`, since a session's own agent can reach `osascript` and would
otherwise approve its own calls.
