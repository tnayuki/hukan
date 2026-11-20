# Virtual machines

Settled decisions, moved out of CLAUDE.md so it stays loadable. Each bullet is a decision
and the reasoning behind it; read the file before changing the area it covers.

- **A session can have a macOS machine of its own, in this process, as a tab on its desk.** Built
  in on Virtualization.framework rather than driving UTM or tart: what the agent needs — a channel
  into the guest, a per-session copy, a saved state — is the part those tools do not hand over. A
  copy is an APFS clone of a template; closing its tab deletes it, after asking, and quitting saves
  it. **Suspend on the tab's right-click is the same save by hand**, Start in its place once the
  machine is stopped, because macOS runs two macOS guests at once, across every app, and without it
  the only way to free a slot was to delete a copy or quit. The agent's tools are the same verbs —
  `vm_create`, `vm_start`, `vm_suspend`, `vm_delete` — and a session may hold several machines. **Deleting its session deletes it too, and closing its repository does not**: a repository
  reopened brings its sessions back to adopt their copies, while a deleted session never returns,
  so a copy it left would be found only in the Virtual Machines window. **Templates are made with
  nothing to answer**, SIP off through Recovery, because a permission prompt with nobody there is a
  wall: a template is for automation and holds nothing worth protecting.
  **Window ▸ Virtual Machines is the store, not a settings window**: every row is a thing on disk,
  nothing in it is a preference. Images and session machines are excluded from Time Machine;
  templates are not.
  **The images templates are made from are a cache, not rows.** New Template names a version —
  the latest macOS, an Ubuntu release, Windows in a language — and the image comes from the cache
  when it is there and is downloaded into it when not, on the build's own row, as the build's first
  part; a template is what was asked for, and an image only the means to it. A newer image replaces
  the older of its line — the other IPSW, the same Ubuntu series and edition, Windows in the same
  language — so the cache stays at one image a line and making a template again downloads nothing.
  What is left to do by hand is to let all of it go, the `…` beside `−`, with what it gives back,
  and not while a template is being made from one. An image nothing names — one put there by an
  older hukan, which also took files and addresses — is never replaced, only let go that way.
  **Only the latest macOS**: an older one was an address the person brought, since nothing lists
  them but third parties, and the cache has no place for an image nobody will fetch again.
  **A kind of machine is shown by a glyph, never a company's logo**: Windows by SF Symbols' four
  panes, which reads as Windows without being Microsoft's mark, and Linux by a penguin of hukan's
  own, drawn as a template in `MachineGlyphs` since SF Symbols has none. UTM bundles the logos
  themselves; that is tolerated rather than permitted, and the monochrome sidebar has no place for
  them anyway.
  **The agent reaches the guest through an agent of hukan's, over vsock**, and tools named for
  where they run: `vm_` acts on the machine from here, `guest_` runs inside it. Creating, first use,
  suspending, saving a template and deleting are each a card. The guest agent is replaced at boot when it
  differs from the one this build ships, so a change to it costs no template.
  **A guest's keyboard is ANSI whatever the Mac's is**, because Virtualization.framework offers
  no other: the type a guest records for a keyboard is not read for its virtual one, a USB one
  instead was tried and fared no better, and every tool built on the framework has the same wall.
  So on a JIS Mac the screen sends what a key prints rather than where it is — a symbol as the
  ANSI keys that type it — and 英数 and かな, which macOS ignores from an ANSI keyboard, are not
  sent at all but turned into the guest's agent selecting the input source. **A Linux guest gets
  a keyboard of its own instead**, which macOS cannot have: its agent makes one through uinput,
  so the guest is put on the jp layout, every key goes by position, and ¥ and ろ — the two keys
  VZ drops — are typed on that keyboard. The guest reads them as a PC's JIS keyboard does, which
  puts a backslash on ろ where a Mac puts an underscore. 英数 and かな still choose the input
  source, by typing GNOME's own Super+Space on it, which reaches Wayland as well as X11; Mozc's
  own on and off keys were the other road, and refused because 24.04's Mozc predates them. What a boot tells the
  guest — that Japanese input, and this Mac's time zone — is told every boot rather than once in
  the template, so a template outlives a change of keyboard or of place.
- **A Linux machine runs in this process, like a macOS one, with Rosetta.** Virtualization.framework
  runs Linux on its generic platform, so everything a macOS machine has — the screen as a view,
  vsock to the agent, a saved state, a share moved with the session — comes with it, and QEMU is
  not needed; Rosetta is the reason to want Linux here at all, since the program to run in it is
  often an x86_64 one with no Arm build (Unity's editor is the case that asked for it). It is not
  Rosetta's general-purpose half, which macOS retires after 27: from 27 the translation for Linux
  guests is part of the system. **Rosetta is the template's choice, on unless turned off**: off,
  the template has no Rosetta share, no binfmt entry and no amd64 package sources, so apt fetches
  arm64 alone; it is decided when the template is made because the guest is set up for it then.
  **Rosetta ignores `MAP_32BIT`**, the flag x86_64 Linux answers with a mapping below 2GB, and
  Mono's JIT — so Unity's editor — aborts on the address it gets instead. So a template with
  Rosetta preloads a library of hukan's into every x86_64 process that places those mappings
  below 2GB itself — an address given with one too, since Mono hints at the end of its last code
  region for each one after the first, and a hint the kernel takes can land anywhere — and passes
  every other mapping to the kernel untouched: every process rather than
  a wrapper around Unity, because Unity is started by its Hub, by a desktop file and by scripts,
  and a fix that holds for one road and not the others is the failure moved somewhere harder to
  see. It is named through the loader's `$LIB`, so an arm64 process finds an empty library under
  the same name instead of a complaint that it is missing.
  **Ubuntu, from its desktop ISO, by its own installer run
  unattended**, as a macOS template is made from its IPSW and a Windows one from its ISO: a cloud
  image was tried first and refused, being a disk with no desktop on it, so every template cost a
  desktop's worth of downloads. Offered by LTS release rather than as "the latest", since which
  release a kept template is decides what runs on it, and read from Canonical's own lists rather
  than a table here. **The install runs with no network, and what the ISO lacks is fetched before
  it, once.** The installer fetched the kernel itself at first — and Japanese input — so a dropped
  connection failed a template minutes in, on an error screen the installer then waits on for
  good. What the ISO lacks is a fact about the ISO, not the release: 26.04.1's install layer
  carries its kernel and only needs keeping from upgrading it, while 24.04.5 has one only in the
  live system. So what is missing — that kernel, `ibus-mozc`, their dependencies — is read from
  Ubuntu's archive as the last part of the ISO's download, checked from Ubuntu's signing key down
  to each package, and kept per ISO beside the virtio-win drivers, which is the same shape:
  fetched once, then a template made with no network at all. Fetched with the ISO rather than
  with the template, since the download is already the moment that wants a connection, and the
  ISO is put in place only once they are all there: a fetch that fails or is cancelled takes the
  ISO with it, so no ISO is used that would have to go back to the network for a template. An ISO
  already in the cache without them has them fetched before the template is begun; the installer
  never fetches packages. **The packages are found by the ISO's checksum, kept on the ISO** as an
  extended attribute by the download, which hashes it anyway: hashing the ISO again to look them
  up costs seven seconds on a 3.8GB ISO, so the builder authenticates them without it. An ISO with
  no checksum on it reads as missing its packages, and is let go with the rest of the cache and
  downloaded again. Letting an ISO go lets its packages go, which were fetched for it alone. It reaches the installer as a repository
  on the answers disc, and the installer is given no network, so nothing it would refresh, update
  or look up can make a template depend on the connection again.
  **The server ISO is the second Ubuntu, for a machine that is only given commands** — a
  worktree's `docker compose` and its tests are the case that asked for it. The desktop ISO
  cannot stand in: its sources are `ubuntu-desktop-minimal` and `ubuntu-desktop` and nothing
  under them, so a desktop with GNOME left unstarted still writes 4.6GB where the server's
  `ubuntu-server` writes 1.34GB, and the ISOs themselves are no smaller one way or the other
  (3.83GB against 3.97 for 24.04.5). Which one an ISO is, is read off what it carries — the
  server's two casper layers, each manifest a diff against the one below — and recorded on the
  template as `server`; the name only steers the window before a template exists. One installer
  road serves both, branched where they differ: the source, codecs (the desktop installer's
  question alone), networkd for NetworkManager, no Japanese input, and none of the sign-in, GPU
  or lock setup. **The account lingers** instead of signing in, since the agent's user half was
  started by the desktop session and a template is finished only once both halves say hello;
  `loginctl enable-linger` runs from cloud-init once the account exists, which is the earliest
  it can. A server's screen tools are refused by hukan rather than left to fail inside the guest.
- **A Linux guest that restarts does so inside the running machine**, measured on GPU machines on
  macOS 27 — so what hukan tells a guest each boot, said once when the machine started, was not
  said again: this Mac's scale, held by a keeper the restart
  ended, fell back to 1×. The agent's hello carries the kernel's boot id, and a new one is the
  guest restarted, which has hukan tell it all again. A boot id rather than a hello going quiet
  for a while, which would be a guess at how long a restart takes.
- **Nothing in a Linux guest updates by itself**, as in a Windows one: apt's daily refresh and
  unattended upgrades are off (a later file than Ubuntu's `20auto-upgrades`), no new release is
  offered, update-notifier — Software Updater's window, and a crash report's question, over the
  screen — does not start, and every snap is held, which snapd takes only while it runs, so at
  the template's first boot (Ubuntu's App Center is a snap, and there is no GNOME Software). apt
  and snap by hand work. Measured on 24.04: nothing ran by itself, and no window came up after an
  `apt-get update` by hand.
  **When the install layer lacks a kernel, the template gets `linux-virtual`**: the release's own
  kernel (GA), not the later one its point releases default to (HWE) — 24.04.5's installer would
  put 26.04's 7.0 on a 24.04 machine, and nothing recorded asked for it — through Ubuntu's meta
  package for a virtual machine. A meta package, so the machine's apt follows the kernel's
  security updates, which come as new packages a concrete image never gets; and that one, since
  `linux-generic` brings the firmware and extra drivers for real hardware: from 24.04's archive
  on 2026-11-19, `linux-virtual` is 21 packages and 123MB from scratch, `linux-image-generic` 34
  and 848MB. It carries the headers too, so a module built against the kernel follows it. An ISO
  whose install layer already includes a kernel (26.04.1) keeps that kernel.
  **Answers-disc debs use short names (`p0.deb`, …), and both indexes use those names.**
  `hdiutil makehybrid -iso -joliet` changes long names and embedded dots in its primary ISO9660
  namespace, which Linux uses here; Joliet or the host's `tar` view can hide that difference.
  A successful recursive copy merely copied those changed names, leaving APT's original filenames
  unresolved. Subiquity's [`AptConfigurer.setup_target`](https://github.com/canonical/subiquity/blob/main/subiquity/server/apt.py)
  binds `/cdrom` to `/target/cdrom`, and curtin's
  [`install_kernel`](https://github.com/canonical/curtin/blob/main/curtin/commands/curthooks.py)
  runs APT in that target: the missing files were already missing by
  their indexed names before either step. Existing snapshots are renamed when making the answers
  disc too. The early command checks every local deb's indexed path, size and SHA256 before success.
  **`autoinstall` reaches the kernel's command line through a boot disk of hukan's**
  carrying the ISO's own GRUB and a menu of its own, since the ISO's menu cannot be edited but by
  keys typed against a timeout. **Its disks are `.cached`, never `.automatic`**: on the automatic
  mode a Linux guest read back pages that were not what it wrote — journald failing, systemd
  killed by SIGILL, the installer aborting — and the same install cached went through clean.
  **GNOME on Wayland, for every release**: 26.04 has no X11 session, and one road for the agent's
  screen tools beats two — X11 was kept on 24.04 first because Unity's editor was supported there
  and the agent spoke X11, and Unity 6.x supports 24.04's Wayland, its editor an X11 app on
  Xwayland. **The agent is Zig**, a static binary with no libc, cross-compiled here; the
  protocol is shared with the macOS and Windows agents, one program for all three — not Swift,
  which cannot build the Windows one from this Mac (see docs/build.md). **Its screen tools go
  through a GNOME Shell extension of hukan's**, since a Wayland compositor lets no outside client
  read the screen, list windows or type, and the extension runs inside it: the screen through `Shell.Screenshot`, windows from mutter, keys and the pointer as
  Clutter virtual devices, over a socket in the user's runtime directory. Not a portal, which asks
  the person on the screen before each picture, and not uinput alone, which can press keys but not
  see. It travels inside the agent, so it needs no template: the root half writes it under
  `/usr/share/gnome-shell/extensions` when it differs, and the user half adds it to the account's
  enabled extensions; GNOME reads its extensions when it starts, so one written under a running
  desktop works from the next sign-in. A key the keymap lacks is dropped on Wayland, where X11
  took a spare keycode for it, so text past ASCII is committed through IBus's panel, which GNOME
  Shell is: the daemon hands it to whatever input context has focus — an X11 app's own on
  Xwayland, the shell's for a Wayland client — and an app with no input
  method gets ASCII only. Keys still carry ASCII, Return and Tab, since a key is what focuses the
  shell's search and what activates; a run of other characters is one commit, as an input method
  would send it (character by character, close together, a Wayland client kept only the last),
  and keys and commits each wait 50–80ms for the other, since they reach a client by different
  roads. The first text typed after the desktop starts can still arrive out of order. The clipboard stays spice-vdagent's,
  which carries it on Wayland as well — measured both ways on 24.04's GNOME 46. Checked end to
  end, through the agent, on 24.04's GNOME 46 and 26.04's GNOME 50. **The
  framework gives a Linux guest a screen and nothing to render with**, so without the GPU below
  drawing is llvmpipe on the CPU. The account takes this Mac's user id,
  so what either side writes in the shared worktree is the same user's.
- **A Linux machine can have a GPU, and it is gfxstream's Vulkan over KosmicKrisp, with the
  guest's own Zink on top.** From macOS 27 a process can implement a virtio device of its own
  (`VZCustomVirtioDeviceConfiguration`), so hukan implements a virtio-gpu that speaks gfxstream:
  the guest's stock kernel driver carries the Vulkan of Mesa's gfxstream driver down it, and
  gfxstream's host half (`Vendor/build-gfxstream.sh`) replays it on KosmicKrisp, Mesa's Vulkan on
  Metal. The guest's OpenGL is Ubuntu's own Zink on that Vulkan, chosen for the device by a drirc,
  so every program gets it with nothing in its environment: **OpenGL 4.6 core, and Vulkan**.
  **Not virgl**, which it was first: virglrenderer replays a guest's OpenGL on the host's — Zink
  over KosmicKrisp, in the renderer — and offered 4.3 of the 4.6 that host had, and the GPU's
  state lived in host GL contexts nothing can save, so such a machine could not be suspended.
  **Not macOS's own OpenGL**, which virgl ran on before that: it stops at 4.1, with no compute
  shaders, so Unity's GPU skinning and its sRGB writes in a linear-space project failed, and
  Unity's announced move to a 4.3 minimum would have stopped its editor starting at all; it is
  also an API Apple deprecated. **Not ANGLE**, the road UTM takes: it is GLES, which caps a guest's
  desktop GL below the 3.2 core Unity's editor needs. What Zink can honestly offer is what the
  Vulkan driver beneath has, and Metal has no geometry shaders or transform feedback: on MoltenVK,
  or on KosmicKrisp as released, that is GL 2.1. KosmicKrisp builds both from compute, as Asahi
  does for Apple's GPUs under Linux — geometry shaders on Mesa's main branch, transform feedback in
  a merge request applied here — and the one extension still missing for 4.6, RGB32 texel buffers,
  a format Metal lacks before Apple family 11, is patched into KosmicKrisp
  (`Vendor/mesa-kosmickrisp-rgb32-texel-buffer.patch`): such a view is bound as R32 over the same
  bytes, three times as wide, and the shader reads three texels.
  **The guest's Vulkan driver is hukan's, carried in the agent**: Ubuntu's Mesa has a gfxstream
  driver too, but one too old for Zink and without what a buffer shared with the desktop needs, so
  one built from a pinned Mesa commit (`Vendor/build-guest-gpu.sh`) is put in place by the agent's
  root half at each start, on a machine with the device only, and Ubuntu's manifest for its own is
  diverted, which apt keeps across upgrades. A new driver needs a new agent, not a new template.
  **It comes in two architectures**, since what Rosetta runs loads Mesa of its own: Unity's editor
  is x86_64, and with only an arm64 driver its Zink found no device and it drew on llvmpipe, at GL
  4.5. The manifest names the driver without a directory, so each architecture's loader takes the
  one in its own library directory.
  **A blob the guest maps is a Metal heap of KosmicKrisp's**, which it hands out only when built
  for the macOS platform; the renderer passes it to this process as a Mach memory entry, and the
  device maps it into its shared memory region at the place the guest chose. That region is
  mapped in the host's 16K pages and virtio_gpu places blobs on the guest's 4K, so a template made
  with a GPU builds a module with DKMS (`Resources/hukan-gpu-align`) that has virtio_gpu place them
  on 64K; DKMS builds it again for each kernel apt brings.
  **The renderer is a process of its own, one per machine**: this executable started again with
  `--gpu-renderer`. gfxstream's renderer is one per process, and the Vulkan driver it loads is
  KosmicKrisp, by path, with no Vulkan loader between them (a few calls of gfxstream's that went
  through the loader's table are patched, `Vendor/gfxstream-hukan.patch`, which says why hunk by
  hunk). The device in this process only forwards requests, over a socket; guest RAM goes to the
  renderer once, as a Mach memory entry handed over through a bootstrap name only it is told (the
  rendezvous Chromium uses). **The guest's screen is read back into two IOSurfaces**, taken in
  turn, which the tab's layer shows. **VZ's own screen stays, for input only**:
  `VZVirtualMachineView` hands the keyboard and pointer to a guest only through a screen of VZ's,
  so it is kept, left alone by the guest — mutter is told by udev tags at each boot to take the
  GPU's card as its primary and ignore VZ's — and the GPU follows its size, which keeps fit, fixed
  and agent-set resolutions working unchanged. Socket writes are queued and nonblocking on both
  ends: a full socket must leave the queue free to read replies and handle a reset or stop. A
  reset replaces the renderer; releasing the VM owner also shuts its GPU down permanently, so a
  late DRIVER_OK cannot start it again. The renderer watches its parent's exit on its own.
  **Such a machine suspends like any other.** gfxstream snapshots its Vulkan state, captured from
  the renderer's start, beside the machine's own state; the device saves which blobs were mapped
  where, and a restored machine resumes only once the new renderer has handed each of them over
  again and they are mapped. gfxstream does not save a timeline semaphore's value, which left a
  restored guest's frames waiting on one forever, so the patch saves and signals it. A restore
  needs the machine identifier and MAC address it was saved with, which a machine keeps.
  **Chosen when the template is made**, and kept by its copies, since the guest is set up then.
- **A Windows machine runs in QEMU from Homebrew, because Virtualization.framework cannot run
  Windows.** It is the one kind of machine that is not in this process. QEMU is a dependency of
  the cask, as ripgrep is: hukan is built for one person, who uses Windows guests, so the size it
  adds is paid by the one person it is for. **A machine is held at the QEMU machine type it was
  made on** — `virt-11.1`, recorded with it, never the bare `virt`, which means whichever QEMU is
  installed now — because a saved state only loads into the hardware it was saved from, and a
  versioned type is QEMU's promise to keep building that hardware; a Homebrew upgrade must not
  strand a saved machine. A state that will not load all the same is thrown away on the spot and
  the machine boots from its disk, as a macOS one does, rather than left for someone to find.
  There is **no TPM**: Setup's checks are turned
  off by the answer file, and nothing a template is for needs one, which is one program fewer beside
  every machine. **Its screen is spoken to over a unix socket by a small client of hukan's own**,
  since RoyalVNCKit connects only to a host and a port and a listener on localhost is open to every
  process here; having one server to talk to is what keeps that client small. **Keys go by physical
  position, so a guest's layout has to match the Mac's keyboard**, and it is compared when a machine
  starts rather than settled in the template, so a Mac whose keyboard has changed needs no new one:
  the price is one automatic restart the first time they differ. **The worktree is shared over
  SMB, by a Samba the cask depends on and started for each connection the guest makes**, the way
  QEMU's own `smb=` does it, so nothing listens on this Mac; the configuration is hukan's, and what it shares is one link to the
  worktree, which is what lets a session's move reach a running guest — the link is repointed, and
  the guest's connections are ended so it reconnects onto the new one, samba having resolved the
  link once per connection — but only once nothing is open through them, since a connection cut
  under a write leaves the file half-written, so until then the guest goes on seeing the old one. **The link is the share's root, so the worktree is `W:\` and not a
  folder in it**: samba's wide links are all or nothing, and let out for a link at the top they
  let out every link in the worktree too — a repository carrying `host -> /` was this whole Mac to
  the guest. With the link as the root none are needed, and a link inside the worktree is followed
  only while it stays inside it.
  SPICE's WebDAV, UTM's road, needs a SPICE client and a QEMU built with it, which Homebrew's is
  not; virtiofs needs a daemon that runs only on Linux, and Windows has no 9p client.
- **Nothing in a Windows guest updates by itself**: a machine an agent drives was otherwise
  restarted, or shown a prompt over its work, by nobody's choice; checking for updates by hand
  still works. Group Policy's values are written in WinPE, into the registry of a Windows that has
  never started: "Configure Automatic Updates: Disabled" (`NoAutoUpdate`), which Pro honours,
  stops Windows Update's own scans and installs but **not the drivers Windows fetches for its
  devices** — measured: a driver update came down and was installed 38 seconds after a boot, by
  the Device Driver Retrieval Client. So Windows Update is also not searched for a device's
  driver (`SearchOrderConfig`), nor its metadata fetched, nor drivers taken with quality updates;
  and the Store's apps are not downloaded. Written before the first boot because that boot is
  when Windows first looks for its devices' drivers. Measured again with them, nothing was scanned
  or fetched by itself, though Settings still says it checks daily and shows no "managed by your
  organization": what it says is not what it does. What is left is the Store's setup acquisition,
  which installs Windows App Runtime a couple of minutes into each copy's first boot: an app
  added once, not an update, and so not stopped.
- **Windows is downloaded as Microsoft's ESD and made into an ISO here**, because an ISO has no
  address to fetch it from: Microsoft's page issues one per visit, for a day, and refuses scripted
  visitors. The ESD is what the Media Creation Tool fetches, from Microsoft's CDN at a fixed
  address with its SHA-256 in a catalog Microsoft signs. **The catalog is read when hukan is built,
  not when it runs**: `Vendor/update-windows-catalog.sh` writes the ARM64 consumer image of each
  language into `WindowsCatalog.swift`, so a newer Windows comes with a newer hukan — which costs
  nothing a template notices, since it installs with no network and Windows Update, run by
  hand, moves it on from there. Microsoft's own catalog link stopped at 24H2, and the newer ones
  are found through Windows on R's index, which also hosts some of them; so the script takes a
  catalog only once its Authenticode signature checks out against Microsoft's root, pinned by
  fingerprint, and the app never asks the index anything. **The ESD comes over plain http**, the only way Microsoft serves
  it, and is held to the catalog's checksum before anything is made from it; `Info.plist` lets
  that one host through App Transport Security. **The ISO is put back together by wimlib**, a
  dependency of the cask, as Microsoft's tool does it on Windows: Setup's files, WinPE and Setup in
  `boot.wim` with Setup marked to boot, the editions in an `install.esd` left solidly compressed —
  DISM applies it as it does a WIM — and UDF beside ISO9660, since it is over 4GB. **`hdiutil`
  writes the boot entry's sector count as 4**, 2KB of a 1.7MB boot image, and the firmware finds an
  empty FAT and drops to its shell; Microsoft's ISOs give the whole image there, and so does the
  ISO once it is made. **It boots without waiting for a key** (`efisys_noprompt.bin`), since nobody
  is there to press one, and the screen is not read for a prompt: no ISO another way comes in.
  **The ISO is taken out of the machine at the guest's first restart**, WinPE's reboot once
  Windows is on the disk, or every restart Setup makes after would boot it again and start the
  install over. Putting the disk ahead of the ISO in the boot order was tried first: the first
  restart reached the disk, and Setup's next one had rewritten the firmware's order and came back
  to the ISO.
