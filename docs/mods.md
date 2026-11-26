# Mods

Settled decisions, moved out of CLAUDE.md so it stays loadable. Each bullet is a decision
and the reasoning behind it; read the file before changing the area it covers.

- **hukan draws Claude Code's mods; it does not have a panel system of its own.** A mod is a
  plugin's hooks module running inside the engine: it opens a pane with `$.ui.open` and draws it
  from a `ui.render` hook as a tree of plain-data elements. The same pane then shows in the
  terminal, the desktop app and VS Code, and it brings what a panel would otherwise have had to
  grow here — timers, commands, its own tools, state — from the engine. A hukan panel was built
  first (`panel_install`: a definition the person approved by hash, rendered by an outside command
  into a closed set of parts) and replaced: everything it did a mod does, on every host, and a
  second vocabulary for the same pane would have been one only hukan spoke.
  **What that gives up is the panel's own gate.** Installing a mod is installing a plugin, and a
  plugin is trusted as a whole — there is no per-session approval of what it may run. That is
  Claude Code's line to draw, and hukan does not draw a second one around it.
- **hukan attaches as the `desktop` surface, over the session's own stream.** After `initialize`,
  when its `capabilities` list `ui_surface_v1`, the session sends `ui_attach` and reads the pane
  roster; from then on the engine pushes `ui_panes` and `ui_invalidate`, and hukan asks
  `ui_render` for a pane's tree and hands back `ui_press`, `ui_input` and `ui_select`. All of it is
  control requests and system messages on the stream hukan already speaks, read off the shipped
  binary (2.1.325) and the VS Code extension (2.1.330) — `@internal` on the engine's side, so
  re-verify on upgrades. `desktop` rather than `vscode` because its element table is what a
  window draws, and its panes dock beside the conversation. A pane a mod opens before anything is
  attached waits undrawn and is in the roster read on attach; no turn is needed for any of this.
- **The desktop app's window tools are hosted under its name, `ccd_window`**, so one mod's code
  runs in both hosts with no branch on which it is in. The app hosts that server itself, not the
  engine, and a mod calls it through `$.mcp.call`; without it here a mod's "open this session"
  failed with no such tool. Its four tools, their schemas, its rules — only the caller and the
  sessions it started, only while the caller is on screen, never a pane change under a cursor in a
  text field or terminal — and its result wording are the app's, read off its bundle (7.37095.0).
  The window is hukan's: one main pane, no split view, no pop-out window. So every
  `open_session_in` target shows the session where a click on its row would, and says when it was
  asked for a split or a window; `get_window_layout` answers in the app's shape with one pane;
  `close_split` always finds nothing to close; `set_sidebar_collapsed` folds the rail, and is
  refused while a column is maximized, since the rail's toggle would end the person's mode. Answering
  `split` with a refusal was the alternative, and it would have made a mod handle hukan apart.
  The agent sees the tools too, as it does in the app, and they ask no approval: they move
  nothing but the view.
- **A pane is a tab on its session's desk.** The desk is the session's and stands beside its
  conversation, which is what every host does with a pane: the terminal docks it beside the
  transcript from 110 columns, the desktop app and VS Code beside the chat. The roster decides the
  tabs — a new pane opens a tab, a pane gone closes it, a retitle relabels it — and a new pane the
  mod asked to have shown is brought forward, but the roster moving never takes the desk off what
  the person is reading. Closing the tab asks the engine to close the pane; bringing a tab forward
  tells the engine it is shown. Panes are never saved: the engine that drew one brings it back.
  hukan always says `dock` and never `inline` or `widget`: a desk has one seat.
- **The tree is drawn with AppKit's own controls, read the way VS Code reads it** — the one host
  whose drawing ships where it can be read. A `Box` is a flexbox whose lengths count in cells, a
  column a character's width and a row a line's height, measured from the font, which is also how
  the tab's size is told to the mod. `Text` is styled text with nested spans, `Button`, `Input`,
  `Select` and `Progress` standard controls, `Link` opens on the desk the way a link in the
  transcript does, `Markdown` and `Code` the transcript's renderer. **`Client`, a module the surface
  would have to run, is not drawn** — VS Code does not draw it either, and hukan runs no code of a
  mod's. Colours are read as a mod names them — a theme key, a terminal colour, hex — onto system
  colours, so they hold in light and dark.
- **A tree never sets its column's width.** The tree is as wide as the site only by a wish weaker
  than the window's columns hold their widths by; a tree that cannot be that narrow — a field's
  least width beside a pick, a row of buttons — runs past the edge and scrolls sideways. Tied to
  the site's width outright, it pushed the desk column wider the moment its tab was shown.
- **A pane asks for its tree when it is shown, when the engine invalidates, and when its width
  changes by a column; a press brings its own back.** A press, a field's submit and a pick carry
  the render of the site they came from, and the answer's `drawn` is the tree as the handler left
  it, with fresh handles. A render asked for after the answer instead was measured to come back a
  step early — the handler not yet settled — which left the old picture up with handles gone
  stale, so a second press did nothing until a resize redrew the pane. (VS Code 2.1.330 asks
  separately.) A field being typed in keeps its text, caret and focus across a redraw, the
  engine's tree being a step behind the keyboard.
  **A mod keeps what it draws from in `$.state`.** A handler and the render that drew its button
  do not share the module's variables — a handler writing one was measured not to change what
  the next render read — so a mod written with module variables answers its first press and no
  other. That is the mod's to get right, as the mods documentation says; hukan cannot mend it.
  A toast is a note in the conversation under the plugin's name; a mod's log goes to the console.
- **The band above the prompt is a card over the composer, and the status lines go in it.** The
  `AbovePrompt` site is asked for under the id every surface gives it (`above-prompt`), after
  attaching, on each invalidation and when a turn starts or ends — `isWorking` is what a progress
  band reads — and drawn under the task list and above a decision card, which stays nearest the
  field. A mod's `$.ui.status` line, one per plugin, sits under the band in the same card: the
  status line under a terminal's prompt, and VS Code's stack over its prompt box, are both the
  strip a person reads while typing. It is the published mods' most common seat after the pane
  (a context and cache clock, a deploy queue, Claude Code's own notes). The band is as tall as its
  tree up to its twelve rows (`maxRows`) and scrolls past them. Its card is kept across the
  column's reloads and drawn again only for a new tree: rebuilt on every status line or turn, it
  would lose its scroll position and the keyboard a control in it held.
- **`Code` is the editor's colours.** A `language` or `path` picks the vendored grammar, a
  `format: "diff"` reads as a patch with its bands, and `startLine` numbers the lines. A `plain`
  `Button` is drawn as its words alone, and an `Input` with `rows` is that many lines tall.
- **A box can light, float and wrap, and a button can have a key.** A `hover` lights its box —
  or, with a `scope`, every box of that group while any is under the pointer — with its
  background and border; a box drawn `display: "none"` whose hover says `display: "flex"` shows
  only while its group is lit, which is how a row reveals its actions. Hover is the pointer's
  alone and hukan answers it locally, no request made. `position: "absolute"` lays a child over
  its box at `top`/`left`/`right`/`bottom` cells rather than in the flow, and a hover may move
  such a box to other offsets — only such a box, the engine's rule, since nothing in the flow
  shifts for it. A row of `flexWrap: "wrap"` breaks onto new lines when the width runs out. A
  button's `hotkey` presses it while the pane has the keyboard, which a click on the pane's
  background gives it, as a click in a terminal's pane does.
- **A box is laid out by Yoga, not by constraints.** A tree's props are flexbox's own words, and
  the desktop app turns each into the CSS of the same name and leaves the layout to the browser
  (read from the app's bundle, 7.37095, 2026-11: a `Box` is `display:flex` in a `row` unless it
  says otherwise, growing and shrinking only as CSS defaults have it; a wrapping `Text` is
  `white-space:pre-wrap; overflow-wrap:anywhere`, so it gives way to any width). Yoga is the
  flexbox engine Ink lays the same tree out with in a terminal, a package Xcode resolves
  (`docs/build.md`), and it is handed the props as they are named: direction and its reverses,
  wrapping, justification, `alignItems` and `alignSelf`, gaps, padding, margin, sizes in cells or
  percent, `flexGrow`, `flexShrink`, and `position: "absolute"`. The measures are the app's
  too: across, a cell is a character; down, a gap, a padding or a margin counts in *half* lines
  and only a height or an offset in whole ones; a spacing named `xs` to `xl` is the app's
  token; a bordered box is padded 12 points down and 16 across wherever the mod names no padding,
  inside a line of 1, 2 (`bold`) or 3 (`double`) points on an 8-point corner, 12 for `round`.
  `overflowX: "scroll"` is a box whose children scroll sideways inside its border and padding,
  every text among them on its one line. A text that does not wrap is cut at its *end* whichever end it names, CSS having no
  other ellipsis; `bold` is drawn semibold and a dimmed colour at three fifths, as the app mixes
  them; `dir: "rtl"` reads and starts from the right. A `Progress` never arrives: the engine
  lowers it to boxes for this surface. **It replaced stack views and
  priorities**, which drew most trees and could not be made to draw the rest: Auto Layout has no
  way to say that two texts short of room shrink in proportion, and a wrapping label left to
  itself measures its width off whatever frame it had last — so the same tree drew a bordered box
  at the pane's width one time, at a first pass's sliver the next, and at its text's one-line
  length, running out of the pane, the time after. Now text is asked what it measures at a
  width, by its cell, and only the outermost box meets Auto Layout: it is as tall as its tree
  comes out at the width it is given. What cannot shrink — a control keeps its width — sets a
  floor under the tree's width, and past it the pane scrolls sideways rather than pushing its
  column wider. The app's own rules for the leaves are kept by hand, Yoga
  knowing only boxes: text and code shrink and a control does not (`flex-shrink:0` on its
  button); in a column a button, a link, a pick and a one-line field keep their own widths
  (`width:fit-content`, and a text input's twenty characters) while a field of several lines
  fills; and a row that names no `alignItems` centres its leaves.
- **Where the hosts differ, hukan draws as the desktop app does**, the surface it attaches as. The
  app's drawing is web code served to it rather than shipped in it; it was read from the assets a
  signed-in app loads (2026-11), and run beside hukan with the same mod. From it: body text is 14
  points on a 20-point line, and a `Text`'s `size`, `weight`, `mono` and `tabular` follow its
  scale; a hotkey is a small key cap inside the button, before a plain button's words and after a
  bordered one's — the terminal writes `n: Next`, VS Code shows and takes no key; a plain button
  is words alone, on a ground that lights under the pointer as the app's ghost button does;
  `variant: "primary"` is the accent fill. **A row that names no `alignItems`
  centres its leaves** — text, buttons, links, fields — on its height and stretches only the boxes
  in it, which is what puts a status dot and a row's button on the middle of a two-line title. A
  `Text` takes a `hover` too, lit by its own scope or by the box with a hover it sits in. VS Code
  ignores most of this (hover, position, plain, hotkeys, code colours), by its own documentation.
- **An element's `hover` rides beside its props on the wire**, as `press` does, not among them
  where the mod wrote it. Reading props alone dropped every hover; the first tests passed because
  they were written with trees shaped as a mod writes them rather than as the engine sends them.
  Colours are the system's throughout, so a pane follows light and dark; only a colour a mod gives
  as hex stays fixed, as on every host.
- **A site's window and keyboard are the engine's to know, both ways** — a pane's and the
  band's alike, one view (`ModSiteView`) drawing either. The person's scroll is
  told as `ui_scroll` once it settles, with where each keyed box and control sits, and every
  render carries the same (`content_rows`, `keyed`, the window in `props.scroll`) — without it a
  mod's `$.ui.scroll` to the end or to a key is denied. A mod's own scroll and focus moves come
  back as `ui_scroll` and `ui_focus` pushes, which the pane follows, keeping to the end while the
  push says so. The keyboard entering or leaving a pane is `ui_pane_focus`, and the ring within it
  `ui_focus`, which a hook may redirect; a mod's `$.ui.focus` is only answered while its pane holds
  the keyboard, measured. Tab walks a pane's controls in the tree's order and comes round, Return
  and Space press, Escape gives the keyboard back to the composer (and closes a pane opened with
  `closeOnEscape`): the keys every host gives a pane. The buttons take the ring without Full
  Keyboard Access, which a pane's controls do everywhere else. A pane that asks for the keyboard
  has it only on the desk on screen with the composer empty and nothing running or waiting on the
  person, and is refused otherwise — the engine's own condition, so a pane opening mid-sentence
  takes no keystrokes. The band has no `ui_pane_focus`: it holds the keyboard by `ui_focus` alone,
  measured to answer a mod's `$.ui.focus` the same way.
- **A hotkey is the site's while it holds the keyboard, never the composer's** — the desktop
  app's reading, read off its code (2026-11). The terminal also presses a band button whose key
  is a number when that number is typed alone into an empty prompt and left there; the desktop
  app does not, and a number typed into the composer here is the start of a message. Built and
  taken back out. Which button a key presses is the app's too: one the person can see, of two on
  one key the later, none when the key is on two plugins' buttons; Shift reaches a number, for a
  layout whose numbers need it, but a capital letter is no hotkey.
- **`Raster` and `Image` are not drawn, because they never come.** The engine's element table
  for `desktop` leaves both out — they are the terminal's — so a mod answering hukan has neither
  to hand it, and a mod that checks `e.surface` draws text instead, as the mods documentation
  tells it to. Drawing them would mean attaching as the terminal, which this surface is not.
- **A mod's theme is not taken.** `$.theme.set` gives a session colours, a backdrop behind the
  conversation (a still `Svg`, or a `Shader` played on the GPU) and a forced light or dark, which
  a surface reads by asking `ui_render` for `Theme` after naming `Theme` (and `Shader`) in
  `ui_attach`'s `draws`. hukan names neither: its colours are the system's, so a pane and the
  window follow light and dark and the person's accent, and a mod's palette would put a second
  look over that. A mod setting a theme hears `isDrawn: false` and can say so.
- **Not drawn yet:** the transcript's rows a mod may redraw (messages, tool calls — a published
  mod folds tool calls to a line).
