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
  below 2GB itself and passes every other one to the kernel untouched: every process rather than
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
  ISO with it, so no ISO is offered that would have to go back to the network for a template. An
  ISO added from a file is held to the same rule, its copy finished only once they are fetched;
  template creation never fetches packages. New Template checks the selected ISO and authenticates
  its saved packages in the background, with Create disabled while checking or when they are
  missing or damaged. Such an ISO must be removed with − and downloaded or added again; the
  builder repeats the offline validation before creating a template. Deleting an ISO
  deletes its packages, which were fetched for it alone. It reaches the installer as a repository
  on the answers disc, and the installer is given no network, so nothing it would refresh, update
  or look up can make a template depend on the connection again.
  **Select the concrete HWE image, not its meta package, when the install layer lacks a kernel.**
  The meta package's image selector identifies the version; only that concrete image's required
  dependency closure is fetched. This drops headers and physical-device firmware. Hard dependencies
  remain: noble's 7.0 `linux-modules` requires `linux-main-modules-zfs`, so that package stays.
  With the authenticated archive snapshot of 2026-11-16, 24.04.5 needs six debs totalling
  316,816,180 bytes (formerly 30 / 990,948,948): `linux-image-7.0.0-43-generic`,
  `linux-modules-7.0.0-43-generic`, `linux-main-modules-zfs-7.0.0-43-generic`, `ibus-mozc`,
  `mozc-data`, and `mozc-server`. Later archive snapshots may select a newer kernel.
  An ISO whose install layer already includes a kernel (26.04.1) keeps that kernel as before.
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
  **GNOME, on X11 where the release has it**, because that is what Unity's editor is supported on
  and what the agent's screen tools speak; 26.04 has no X11 session and is offered knowing those
  tools fail there. **The agent is Go**, a static binary cross-compiled here that drives the
  screen over the X11 protocol itself, so the guest needs nothing installed for it; the protocol
  is a package of its own, which the macOS and Windows agents are to move onto in turn — Go
  rather than Swift because Go builds the Windows one from this Mac, which Swift cannot. **The
  framework gives a Linux guest a screen and nothing to render with**, so without the GPU below
  drawing is llvmpipe on the CPU. The account takes this Mac's user id,
  so what either side writes in the shared worktree is the same user's.
- **A Linux machine can have a GPU, and it is virgl on macOS's own OpenGL.** From macOS 27 a
  process can implement a virtio device of its own (`VZCustomVirtioDeviceConfiguration`), so
  hukan implements a virtio-gpu: the guest's stock kernel driver and Mesa's `virgl` send its
  OpenGL down it, and virglrenderer replays that on macOS's OpenGL 4.1 core through CGL contexts
  hukan hands it. **Not Zink over a Vulkan-on-Metal driver**: Metal has no geometry shaders or
  transform feedback, so honest Zink on MoltenVK or KosmicKrisp is GL 2.1 and needs a version
  override to claim more. **Not ANGLE**, the road UTM takes: it is GLES, which caps a guest's
  desktop GL below the 3.2 core Unity's editor needs. Apple's 4.1 implements both over Metal
  itself, so the guest gets 4.1 core with nothing claimed it does not have — at the price of
  standing on an API Apple deprecated, the risk that keeps ANGLE as the fallback. **vrend assumes a
  Linux host**, and macOS's GL is older and stricter, so the release is patched
  (`Vendor/virglrenderer-macos.patch`, which says why hunk by hunk) and built with GL errors
  non-fatal. **The renderer is a process of its own, one per machine**: this executable started
  again with `--virgl-renderer`. virglrenderer is one renderer per process — its resource and
  context ids are global, and a guest writes them into its command stream, so two guests in one
  process collide on them, and remapping them would mean parsing every command. The device in
  this process only forwards requests, over a socket; guest RAM goes to the renderer once, as a
  Mach memory entry handed over through a bootstrap name only it is told (the rendezvous Chromium
  uses), so its transfers touch the guest's pages directly. **The guest's screen is the GPU's,
  drawn without a readback**: the renderer blits the scanout into IOSurfaces, two taken in turn,
  and the tab's layer shows them, with no GL in this process at all (blitting rather than reading
  frames back took the drawing from 59% of a core to 6.7%). **VZ's own screen stays, for input only**:
  `VZVirtualMachineView` hands the keyboard and pointer to a guest only through a screen of VZ's,
  so it is kept, left alone by the guest — Xorg is pinned to the GPU by PCI address at each boot,
  by address because a path Xorg opens itself bypasses logind and gets no DRM master — and the
  GPU follows its size, which keeps fit, fixed and agent-set resolutions working unchanged.
  Socket writes are queued and nonblocking on both ends: a full socket must leave the queue free
  to read replies and handle a reset or stop. Guest fence ids stay opaque 64-bit values in replies;
  vrend gets a separate 32-bit sequence, and only one fence poll is scheduled at a time. A reset
  replaces the renderer; releasing the VM owner also shuts its GPU down permanently, so a late
  DRIVER_OK cannot start it again. The renderer watches its parent's exit independently of GL and
  socket handling. GPU lifecycle logs include a device identity to distinguish a reboot's renderer
  replacements from separate devices; fences pending for five seconds are logged by the renderer.
  **Chosen when the template is made**, and kept by its copies, since the guest is set up then.
  **Such a machine cannot be suspended**: its state lives in this Mac's GL and is not saved, so
  a resumed guest would wake with every context gone. Its Suspend is off rather than renamed —
  a shutdown cannot be carried on from, and an item in Suspend's place reads as one that can —
  and what saves a machine on the way out (a quit, its session going) shuts it down instead.
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
