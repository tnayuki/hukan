# Updates and hukan's own outbound requests

Settled decisions, moved out of CLAUDE.md so it stays loadable. Each bullet is a decision
and the reasoning behind it; read the file before changing the area it covers.

- **hukan says when a newer hukan has been released, and Claude Code is not watched at all.** The
  engine updates itself — the native installer writes `autoUpdates: false` to disable the *legacy*
  npm updater and sets `autoUpdatesProtectedForNative`, which exempts its own — so there is nothing
  to tell you that will not have happened by morning anyway. The cask does not follow anything, so
  hukan is the one of the two that can go quietly stale.
  **Six outbound requests are hukan's own, and the line around them is the whole of why they are
  allowed.** The cask check: one fixed URL, GET, nothing sent, no credentials, nothing about the
  work. A macOS restore image: where the latest is, asked of Apple through Virtualization.framework
  when the template sheet's macOS is chosen, so the sheet can say which macOS it is; the IPSW
  itself fetched from there only when a template asks for one the cache lacks. An Ubuntu desktop or server ISO, likewise only when asked for:
  Canonical's list of supported LTS releases (`meta-release-lts`), each release's `SHA256SUMS` to
  find its newest point release and hold the download to, and the ISO. Windows 11 for Arm, likewise
  only when asked for: Microsoft's ESD in the language chosen, from the address and held to the
  checksum in the catalog the build carries (`docs/virtual-machines.md`), over plain http, the only
  way Microsoft serves it. And the virtio-win drivers, from one
  fixed address, once, the first time a Windows template is made. And the packages an Ubuntu ISO
  lacks for an install, from Ubuntu's archive, once per ISO, as the end of its download. libgit2
  is built network-less on purpose and
  the browser's traffic is the user's own, as is what a panel's commands reach (`docs/panels.md`),
  each declared in a definition the user approved; these are neither, so they are stated as a constraint
  rather than as a beginning.
  **It reads the cask, not the tag's GitHub Release.** The two disagree for a minute at a time —
  `release.yml` publishes the Release and pushes the cask that points at it afterwards — so a check
  against the Release API lights up in a window where `brew` still has nothing to give, which is
  hukan and Homebrew answering one question two ways in one glance. Reading what actually installs
  makes them one file. Hourly, `If-None-Match` so a 304 costs no body, and a failed read leaves the
  last answer standing: a machine with no network has not learned there is no new version. Release
  builds only, since a Dev build's version is whatever the working tree says and would announce
  every release from the moment it shipped.
  **The arrow sits at the toolbar's trailing edge** by the scope rule (`docs/model.md`) — true of the whole
  window, as its two neighbours are — and only while a release is ahead, the way the plan usage
  shows only once there is a plan. Accented rather than secondary-tinted, because it is the one
  item in that cluster that acts instead of reads; both version numbers are in the tooltip, the bar
  having no room for them and the glyph having only to carry that there is something to do.
  **Asking early is a menu item, and it is pointedly not a second answer.** `Check for Updates`
  sits under About, the block that names the app itself, since what it asks about is which hukan
  this is. The check is hourly and a 304 costs no body, so the command is not what keeps the answer
  current — it is only the way to make it current at the moment you thought to wonder. So its title
  never moves and it opens nothing: a row reading `0.5.1 available` under a bar already carrying
  that would be the same fact twice, and one reading `up to date` would be a second place to look
  for one answer. It carries no ellipsis for the same reason. The About panel held the reading
  first and that is the wrong room — About is where you go once you already suspect, where a menu
  is already open in front of you. Disabled while a check is in flight, so a second press does not
  read as the first having missed — and on a Debug build, which is never what Homebrew installed:
  without that, a Dev window offers to upgrade the Release app beside it, a button whose action is
  about a different program than the one it is sitting in.
  **Pressing it hands one command line to Terminal.app, the road `/login` already takes** — one
  handoff (`ExternalTerminal`) rather than two, for opposite reasons: the login needs a TTY the
  stream-json engine has not got, and the upgrade needs a process that is not hukan's child, since
  what it replaces is the bundle hukan is running out of. **Nothing quits**, which is what keeps
  what is handed over to a single literal instead of a script with quoting inside it: Homebrew
  unlinks the old bundle rather than writing over it, so the running process keeps the inode it
  started from and is untouched until it exits. A quit-first version had to wait for the app to go,
  abort if a Cancel on an unsaved edit refused it, and carry all of that through three levels of
  escaping — for nothing, since the last word is a relaunch either way, said in that terminal.
  **The cask is named in full** (`tnayuki/hukan/hukan`), which is not decoration: Homebrew
  auto-updates before `upgrade` once every 24 hours by default, so a release published today is
  invisible to a plain `brew upgrade --cask hukan` for the rest of the day — hukan pointing at a
  version Homebrew then reports it already has. An argument naming a third-party tap in full drops
  that interval to five minutes, which the shell does for exactly this reason. `brew update` in
  front would close the remaining minutes and pay for every tap on the machine to do it.
