# The web tab

Settled decisions, moved out of CLAUDE.md so it stays loadable. Each bullet is a decision
and the reasoning behind it; read the file before changing the area it covers.

- **The web tab's one field is an address bar and a search box, and the text decides which** — a
  scheme, a slash or a dot makes it an address; anything else is a search. The files panel's field
  splits its two jobs by *gesture* because one of them costs far more than the other and a person
  has to choose; here both are one Return and one request and being wrong costs a back click, so
  nothing is bought by making anyone choose. No public suffix list stands behind the rule — knowing
  that `.swift` is not a real TLD is far more than this is worth — so `Model.swift` is tried as an
  address, fails to resolve, and **the error page offers the search instead**. The engine is one
  constant, not a preference: hukan has no settings window, and nothing separates the engines for
  "the search you would otherwise have run in Safari".
- **A failed load says so, and it says so as a page.** It used to show nothing at all: WKWebView
  keeps the previous content — on a new tab, a white rectangle — and `didCommit` never fires, so
  even the chrome stayed as it was and every wrong address read as "Return did nothing". Drawn as
  a simulated response rather than as a banner over the page, which keeps the failed address as
  the web view's own URL: the address bar stays right and the reload button goes on meaning "try
  again" without hukan having to remember what it means. Its three offers are the whole of what
  can be done next — retry, search for what was typed, open in Safari (the way out for a page
  hukan cannot sign into, since passkeys and iCloud Keychain autofill need entitlements it has
  not got). A cancelled navigation is not a failure and never reaches it: cancelling in
  `decidePolicyFor` is *how* a `kolide://` handoff is handed over, so reporting one would put an
  error page in the middle of the device-trust flow this browser exists to get through.
- **The web tab's chrome reads the view, and the tab does the host's half of WKWebView.** The
  address, title and history buttons are KVO on the web view, not the navigation delegate:
  `didCommit` fires for a document load and nothing else, and GitHub — the page this browser
  exists for — moves between an issue and its PR without one, so a chrome synced there stayed on
  the first page all day. The field is never written while it is being edited (the sync catches
  up when editing ends), because now that it is a search box the half-written line is its usual
  state. The rest is what a page assumes its browser provides and a bare WKWebView does not, each
  of which failed silently: a popup that closes itself (`webViewDidClose`, how an SSO popup ends)
  took its tab with it or left an empty one; `<input type=file>`, `alert`/`confirm`/`prompt`, a
  download (into Downloads, the Dock stack bouncing — Safari's own signal and the whole of the UI
  a download gets), a name-and-password challenge, a client certificate (looked up by the
  issuers the server names, no chooser — this machine has one device certificate). Reload is Stop
  while loading, with a progress line under the bar. ⌘F is the commit tab's field, in the pane's
  own row: WebKit's find is a step, not a list, so the label says only that there was nothing to
  find. **A popup lands on the desk of the page that opened it**, which is not necessarily the one
  on screen: a sign-in finishing in a background session's tab must not swap the desk out from
  under the rail's selection, so it joins that session's tabs and waits there — and a page whose
  session is gone is declined, so WebKit drops the popup rather than loading it into a view no
  one will see. A page retitles itself several times while loading; that relabels one
  tab in place rather than rebuilding the strip. No process pool: it was set on the belief that it
  shared the sign-in, and it never did — the persistent data store does, and WebKit has managed
  its own processes since macOS 12.
  **A ⌘-click opens the link as a tab of its own, and the tab is what has to read the click.**
  WebKit asks for a new view only when the *page* asks for one — `target=_blank`, `window.open` —
  and hands a modified click over as an ordinary link activation carrying the flags it was made
  with, so a ⌘-click followed the link in place until that was measured. ⌘ opens the tab behind
  the page being read and ⌘⇧ opens it in front, which is Safari's allocation and the whole
  difference between the two: the reason the gesture exists at all is not leaving the page you are
  on, and a tab in front is what every other way of opening one already gives. It goes through the
  same open as those, so the reuse rule holds — an address already open is not opened twice, and
  behind, it is not switched to either, since the strip is carrying it already and not moving is
  what was asked for. A link marked `download` is still a download, whatever was held down. That ⌘
  means something else over the transcript — send it out to the default browser — is the same rule
  read per column rather than a collision: in a page the useful answer is the tab beside this one,
  out of a transcript it is Safari.
  **Reload is the browser's own key, and it never becomes Stop.** A web tab is the one surface on
  the desk with a manual re-read to give — a file, the tree and the history all come back on the
  batch FSEvents hands them — and the button holds both meanings only because it can show which
  one it is holding, where a key that reloads or stops depending on how far the page has got is
  one you cannot press without looking first. Stopping is Escape's instead, and it reaches the tab
  only if the page did not want it: that ordering is the whole reason it is not a menu key
  equivalent, since one of those is matched before the page ever sees the event and would take
  Escape from every menu and dialog a page has.
- **A web tab is shared with the agent per tab, on a card the agent's own call raises.** The
  tools are hukan's — list the desk's tabs, open one, read one, load an address in it, screenshot
  it, run JavaScript in it — hosted in-process on the session's own stream: a name in the engine's
  `initialize` and its JSON-RPC arrives as control requests, the same door `set_model` and Remote
  Control go through. No second process, no config file, no socket, and the call arrives on the
  stream of the session making it, so whose tabs it means is a fact rather than an argument
  anything on the machine could forge. It is read off the shipped binary, like the permission
  prompt tool, and re-verified on upgrades. **The tab is the unit of consent**, where every other
  browser agent scopes it to a site: a site is what nobody is looking at, and a hukan tab belongs
  to a worktree and was opened for its task. **The call is the request**: a tab it has not been
  given stops the session on a card naming the page and the address, with three answers — read,
  read and drive, or not at all — and the answer stays with the tab rather than the call, which is
  what lets the standing yes be narrow instead of the whole permission mode. **Opening a tab is
  the same card asked before the tab exists**, and the tab is made only on a yes, already shared
  and showing — the yes is the click, and opened behind it sat on the strip reading as an open
  that had not happened. It shows only when its session's desk is the one on screen: which desk
  that is belongs to the rail's selection, not to the agent. That is also why
  hukan's own tools never reach the generic approval card, and why the grant is asked for whatever
  the mode says: a `can_use_tool` is not sent under `bypassPermissions` at all, so a gate hung off
  it would be gone exactly where it mattered, and a mode loosened for a checkout was never a
  decision about the person's logins. **Driving lapses when the tab leaves the site it was granted
  on; reading does not.** A read that lapsed on every link would make following a PR a card per
  click, and a drive that survived a navigation would be consent to act on a page nobody saw —
  the shape of the hole that has been found in browser agents' origin checks. The person never
  meets the word origin: the glyph goes hollow, and the next drive asks again. The glyph is the model picker's sparkles —
  the agent's mark in this window already; the symbol set has no robot, and the chip is the
  toolbar's load gauge — and a wand once the tab may be driven, two glyphs rather than a fill. The
  tools reach the calling session's own desk and no other, since that is whose tabs they are.
  **Never
  saved**: a grant back after a relaunch would be hukan making it again tomorrow on nobody's
  behalf, and a grant that lives nowhere on disk is one nothing can forge — the other attack on
  browser agents' permission stores. What the grant is not is a boundary on identity: every tab
  shares one cookie store, so inside a shared tab the agent is the person, on whatever the page
  reaches. That is the whole reason it is asked for, and the reason the hidden `browser` verb's
  loading half is guarded now — a session's agent reaches `osascript` with no prompt in the way,
  and that verb steered a logged-in tab with no card in front of it.
