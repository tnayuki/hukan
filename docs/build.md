# Build

## Build

`hukan.xcodeproj` is the only build system — no Makefile, no `Package.swift` (SwiftPM as a
separate "fast loop" was measured no faster and dropped). One scheme, two targets (`Hukan`,
`HukanAppTests`):

```sh
xcodebuild build -project hukan.xcodeproj -scheme Hukan -derivedDataPath .build/DerivedData -skipPackagePluginValidation
open ".build/DerivedData/Build/Products/Debug/Hukan Dev.app"   # relaunch; restoration needs open, not the raw binary
xcodebuild test  -project hukan.xcodeproj -scheme Hukan -derivedDataPath .build/DerivedData -skipPackagePluginValidation
```

`-skipPackagePluginValidation` is there for one dependency: SwiftTerm (the terminal emulator, see
the model in CLAUDE.md) ships a build-tool plugin that stamps its version in, and Xcode blocks an unvalidated
plugin — the flag pre-trusts it, since plugin trust is stored per-user (`~/Library/org.swift.swiftpm`)
and so cannot be committed. SwiftTerm and SwiftTreeSitter are the exceptions to the
vendoring rule: pulled as Xcode-managed package dependencies (pinned in `project.pbxproj`, the
whole graph locked in the tracked `Package.resolved`), *not* committed binaries like
`Clibgit2.xcframework`. SwiftTerm pins an exact version; SwiftTreeSitter rides its `main`
branch, because that is how ChimeHQ ships it, so `Package.resolved` is what actually holds it
still.
That does not resurrect the rejected "SwiftPM as the build system" — the build is still
`xcodebuild`, hukan still has no `Package.swift`; they are pure-Swift libraries, which a
hand-built static `xcframework` fights (SwiftTerm's plugin breaks a universal `swift build`), so
letting Xcode resolve them is the path of least resistance where libgit2's network-less custom C
build was not.

The project is hand-authored and tracked — edit `project.pbxproj` directly. Folder groups are
file-system-synchronized, so a new file under `Sources/` just appears. `Resources/hukan.icns`,
`Vendor/Clibgit2.xcframework`, `Vendor/CtreesitterParsers.xcframework`,
`Vendor/Cvirglrenderer.xcframework` and the
query files under `Resources/TreeSitter/` are committed static assets; regenerating any of them is a manual
step, not part of the build. `Resources/hukan-rosetta-low32-*.so`
are the library a Linux template preloads for Rosetta and its empty arm64 stand-in,
cross-compiled with zig by `Vendor/build-rosetta-low32.sh`; `Resources/Hukan.entitlements` carries the one entitlement
Virtualization.framework requires, which ad-hoc signing can hold.

**The guest agents are the exception: they are built, not committed.** They are one Zig program
under `GuestAgent/src`, and the app target's last build phase runs `Vendor/build-guest-agents.sh`
into the bundle's Resources — all three cross-compiled from this Mac, macOS's Objective-C half
compiled by Xcode's clang and linked in, since Zig's own clang carries libc headers the SDK's
frameworks do not build against. They were committed while one was Swift and one C#, and every
rebuild then added megabytes to the history. What makes building them safe is that the build is
reproducible — the same source and Zig give the same bytes, measured from two checkouts at
different paths with separate caches — and that matters, because a guest's agent is replaced at
boot whenever it differs from the one the app ships: a build that drifted would replace every
guest's agent on every rebuild. So **Zig is a build dependency**, its version pinned in
`GuestAgent/zig-version`, which CI installs and the script warns against a mismatch with, and a
Zig upgrade is a new agent in every guest at its next boot — and, Zig being before 1.0, it may
be source changes too. **Zig rather than Go, which they were briefly**: Go links its runtime into
every binary, and the same agent measured 2.9 MB in Go against 0.2 MB in Zig; and Zig is already
what builds the Rosetta library, so it is one toolchain rather than two. ReleaseSafe, because a
mistake in an agent should end it — launchd, systemd or the service manager brings it back — where
the faster modes would carry on past it with whatever memory it left. Windows' user half is the one
nothing would bring back, the Task Scheduler running a task once a logon, so what it starts keeps a
copy of itself running instead (windows/main.zig): Zig has no way back from a panic, which Go,
before it, did. `zig build-exe` keeps no
account of what is up to date, so the script keeps its own — a hash of the source, the script, Zig
and the SDK — and a build with nothing changed costs a tenth of a second rather than eleven.

ripgrep is the one program hukan runs. The files panel's filter and its
content search are a process each, per gesture, started by someone typing and killed by the next
keystroke — which is a different shape from the thing libgit2 is here to prevent below, a spawn
per FSEvents batch per worktree. What it buys is the walk: rg prunes by every `.gitignore` it
passes, nested repositories included and — with `--no-require-git` — directories that are no
repository at all, which is the only reason a directory with no git above it can be opened at
all. **It is Homebrew's, a dependency of the cask, rather than a binary built here and bundled.**
It was bundled once, for two reasons that have since gone: Homebrew's prefix moved with the
architecture, which arm64 alone settled, and a formula the user could remove failed silently —
which the panel now answers by saying ripgrep is missing where a filter or a search would have
said it found nothing. A build that did not come through the cask needs `brew install ripgrep`,
and CI installs it before the tests.

`Clibgit2.xcframework` is the git engine: libgit2, linked in-process so hukan spawns no `git`
at all — the point being that a large repository under a storm of FSEvents used to fork two
`git` processes per batch per worktree and bury the machine. It is built network-less
(`USE_HTTPS=OFF`, `USE_SSH=OFF` — hukan only reads local worktrees, never clones or fetches),
which also drops the OpenSSL and libssh2 dependencies, leaving one self-contained static
archive linked with `-liconv`. Rebuild it — to bump the libgit2 version — with
`Vendor/build-libgit2.sh`; it is not SPM, just an `xcframework` in "Link Binary With Libraries".

`Cvirglrenderer.xcframework` is the same idea for a Linux machine's GPU: virglrenderer's GL
renderer and libepoxy, the one library it needs, built static together from pinned releases by
`Vendor/build-virglrenderer.sh`, with `Vendor/virglrenderer-macos.patch` applied. Its headers sit
one directory down too, for the reason the tree-sitter ones do, and `SWIFT_INCLUDE_PATHS` names
both directories.

`CtreesitterParsers.xcframework` is the same idea for syntax highlighting: the tree-sitter
*grammars*, compiled from pinned tag archives by `Vendor/build-tree-sitter.sh`, which also
refreshes the query files under `Resources/TreeSitter/`.
The tree-sitter *runtime* is deliberately not in there — SwiftTreeSitter brings it, and a
grammar's generated `parser.c` calls nothing in the runtime, so the two link cleanly from their
two directions (the xcframework's headers sit one directory down, `Headers/CtreesitterParsers/`,
so its module map cannot collide with Clibgit2's in the shared products `include/`; the target's
`SWIFT_INCLUDE_PATHS` points into that subdirectory). Adding a language is one line in the
script's grammar list, one entry in `SyntaxHighlighting.grammars`, and a rerun.

Seventeen parsers for sixteen languages — Swift, TypeScript, TSX, JavaScript, Python, Ruby, Rust,
Go, C, C++, C#, shell, JSON, YAML, Markdown and diff, the second-to-last of which is two grammars.
**There is no one place that has them all**, which is the fact that shapes the script: most come
from the tree-sitter organization, YAML, Markdown and diff from the community
`tree-sitter-grammars` one that has what the first never had, and Swift from alex-pinkus — the official Swift grammar was
archived in 2022 and stopped at roughly Swift 5.5, so the live grammar is a community one and
every editor that highlights Swift uses it. Swift is also the only one whose generated parser
ships in a *release* rather than in the repository. Nobody's set is all from one place — Zed
pulls eight of its twenty-two from outside the official one, two of them its own forks — so
the script takes a source per grammar rather than a rule.

**The committed archive is 22 MB.** C# and C++ are the two largest grammars, bigger even than
Swift, and those three are half of it; JSON is 8 KB. That is the price of the decision, paid
once: a grammar is a table, so it never changes between version bumps.

**The build is arm64 only** (`ARCHS` pinned in both configurations), which is a decision about
who can install it rather than a build setting. Homebrew stopped building bottles for Intel
macOS — its own diagnostic says so for every version up to Tahoe, where a formula builds from
source instead — so the machine a universal hukan was for is one that can no longer install the
CLI half of what it needs. Until now it shipped both slices: 62 MB of binary, half of it for
nobody, in an app whose whole argument is being small enough to hold in one head. **The vendored
xcframeworks are arm64 too**, which is the same decision spent in the other pocket: they are
static archives, so the second slice never reached the app and cost repository size instead —
and that was 25 MB of it, the grammar tables going from 44 MB to 22 and libgit2 from 5.2 to 2.6.
Carrying a slice for a machine that cannot install the app is not a cheaper thing to do because
the linker drops it, and the archives are built by hand from pinned sources, so the arch they
are built for is a line in each script rather than a build setting anyone has to remember.

**The Debug build is a separate app from the one CI ships.** Debug carries its own bundle id,
name and icon (`Hukan Dev.app`, amber DEV ribbon); Release keeps the identity the cask installs.
Sharing one identity meant the two builds shared everything macOS keys on it — saved window
state, TCC grants, notification permission, and which one `open` and AppleScript actually reach —
so a copy of the released app could not sit next to the one being built without one of them
answering for the other. The cost is that the dev build answers to a different name: it is
`tell application "Hukan Dev"`, not `"hukan"`. Two settings exist only to keep that split from
leaking: `PRODUCT_MODULE_NAME` is pinned in both configurations, because `PRODUCT_NAME` otherwise
renames the Swift module to `Hukan_Dev` and every `@testable import Hukan` stops compiling, and
the test target's `TEST_HOST` names the Debug bundle. Both icns files ship in both bundles —
`CFBundleIconFile` picks one, and a second 410 KB icon is cheaper than a copy phase that has to
know the configuration.

**Signing is ad-hoc (`-`)** — nothing hukan does needs a stable signature (restoration and
scripting key on the bundle id). The one cost: TCC grants (screen recording, accessibility,
automation) reset every rebuild, so re-approve them in System Settings after rebuilding. Nothing
in hukan depends on those grants: a screen capture of its own window needs one even from inside
the app, which is why looking at the window is `WindowPreviewTests` drawing it by hand instead.

**What hukan ships and did not write ships with its license, in `Resources/Licenses`.** Every
such piece — libgit2, virglrenderer and libepoxy, the tree-sitter grammars, the Swift packages
linked in (SwiftTerm, SwiftTreeSitter, tree-sitter), and Zig's standard library inside the guest
agents — is under a license whose condition for redistribution is shipping its text, and for a
while none of them was shipped. One file per source, headed by its name, version and where it
came from, then the text as the source has it; the folder is bundled as it is, and nothing in the
app shows it. Each file is written by whatever fetches that source — the Vendor script of an
archive, and `Vendor/build-licenses.sh` for the packages, at the commits Package.resolved pins,
and for Zig — so a version bump that reruns the script refreshes its license with it. Homebrew's
ripgrep and QEMU are not shipped, and have no file here.
