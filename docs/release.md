# Formatting and release

## Formatting: swift-format, blocked at commit

Standard swift-format, no house style — Xcode's own binary (`xcrun swift-format`, nothing to
install), and `.swift-format` is `{ "version": 1 }`: the plain defaults, pinned to a config
version so an Xcode update cannot silently move them (the same reason the snapshot references
are pinned). Fix a whole tree with:

```sh
xcrun swift-format format -i -p -r Sources Tests
```

Enforcement is the Release workflow, which lints the whole tree with `--strict` on every push
and every tag — the same gate the tests are, and the snapshot tests are for the look — and a
tracked hook, `.githooks/pre-commit`, which is that gate at the commit: it lints the *staged*
blob of each `.swift` and blocks on any finding, so what is judged is exactly what the commit
records, and a finding is caught before it costs a runner. Activate it once per clone
(`core.hooksPath` is not itself tracked):

```sh
git config core.hooksPath .githooks
```

A handful of rules are lint-only — `format` will not rewrite them: `.forEach { … }` over a for-in
loop, an end-of-line comment past the column, a non-`lowerCamelCase` name. The tree is clean of
them today; fix any new one by hand.

## Release: a tag, and the tap follows it

A release is a tag. Bump `CFBundleShortVersionString` in `Resources/Info.plist`, commit, tag it
`vX.Y.Z` and push the tag: the Release workflow (`.github/workflows/release.yml`) lints, runs the
tests and builds the ad-hoc-signed app on the runner whose SDK the app should be linked against,
publishes the zip as that tag's GitHub Release, and points the cask in `tnayuki/homebrew-hukan` at
it. Every push to main runs the same lint, tests and build without publishing, so a tree that would
not ship is caught before it is tagged.

**The cask was updated by hand at first, and the tag is a better place for it.** What the cask
holds is the version and the zip's sha256 — one of which is the tag, and the other of which the
runner that built the archive is the only party to know without fetching it back, so by hand meant
downloading the Release to re-derive a number the machine that made it had already had. The push
is a **deploy key** (`hukan-release-bot`, registered read-write on the tap and nowhere else)
rather than a personal token, because a token in a runner's environment carries an account's whole
reach — every repository it can touch — where a deploy key reaches exactly the one repository it
was cut for. That is the whole of what a workflow writes to either repository.

**The cask is also what the running app reads to know it is behind** (see `docs/updates.md`),
so the order of these two steps is load-bearing: the Release is published first and the
cask pushed after, which is the window in which the Release API would answer ahead of anything
`brew` could install. Swapping them would be fine; leaving a gap between them would not.
