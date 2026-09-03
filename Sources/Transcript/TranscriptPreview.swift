import AppKit

/// Renders transcript styling to a PNG, with no window and no session.
///
/// Iterating on the look inside the running app means launching it, opening a repository,
/// picking a session and scrolling to the right place — and a screenshot only works while the
/// display is awake and nothing is covering the window. This draws the same views offscreen,
/// so the result is a file that can be looked at directly.
///
/// The content is one of the named cases in `RenderCase` rather than a single hardcoded sample,
/// so a new thing to eyeball (or snapshot-test) is a case in the registry, not a one-off `--flag`
/// and a bespoke builder each time:
///
///     hukan-render <case> /tmp/out.png [width]     # any registered case
public enum TranscriptPreview {
  public static func run(to path: String, width: CGFloat, content: NSAttributedString) -> Never {
    let image = image(content: content, width: width)
    guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else {
      FileHandle.standardError.write(Data("could not encode a PNG\n".utf8))
      exit(1)
    }
    do {
      try png.write(to: URL(fileURLWithPath: path))
    } catch {
      FileHandle.standardError.write(Data("could not write \(path): \(error)\n".utf8))
      exit(1)
    }
    print("\(path) \(Int(width))x\(Int(image.size.height))")
    exit(0)
  }

  /// Draw `content` to an image at `width`, sized to fit its laid-out height. Split out from
  /// `run` so a snapshot test can render a case and compare the bitmap without the CLI's
  /// write-and-exit — it exercises exactly the transcript's own drawing path, custom block
  /// fills included.
  public static func image(content: NSAttributedString, width: CGFloat) -> NSImage {
    // Semantic colours resolve against whatever appearance is current, and offscreen that
    // is the light one — so labelColor comes out black and the whole transcript vanishes
    // into the dark background it is designed for.
    let appearance = NSAppearance(named: .darkAqua)!
    NSApplication.shared.appearance = appearance

    let (scrollView, textView) = makeTranscriptTextView()
    textView.appearance = appearance
    textView.textStorage?.setAttributedString(content)

    // A tall container first, so layout is never the thing that truncates.
    scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 20_000)
    textView.frame = scrollView.bounds
    textView.layoutSubtreeIfNeeded()
    guard let layout = textView.textLayoutManager else {
      FileHandle.standardError.write(Data("no TextKit 2 layout manager\n".utf8))
      exit(1)
    }
    layout.ensureLayout(for: layout.documentRange)

    let inset = textView.textContainerInset
    let height = layout.usageBoundsForTextContainer.height + inset.height * 2
    textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
    textView.layoutSubtreeIfNeeded()

    // Drawn fragment by fragment rather than snapshotted with `cacheDisplay`, which comes
    // back empty for a view that was never in a window — and into a bitmap of our own rather
    // than through `lockFocus`, which takes its scale and its colour space from whatever display
    // is attached. A reference recorded that way is a photograph of one machine: half size on a
    // 1x screen, and a count or two off on saturated colours under another display profile.
    let scale: CGFloat = 2
    let pixels = (Int((width * scale).rounded(.up)), Int((height * scale).rounded(.up)))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let cgContext = CGContext(
        data: nil, width: pixels.0, height: pixels.1, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      FileHandle.standardError.write(Data("no sRGB bitmap for the transcript\n".utf8))
      exit(1)
    }
    cgContext.scaleBy(x: scale, y: scale)
    let graphics = NSGraphicsContext(cgContext: cgContext, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    appearance.performAsCurrentDrawingAppearance {
      NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
      NSBezierPath.fill(NSRect(x: 0, y: 0, width: width, height: height))
      guard let context = NSGraphicsContext.current?.cgContext else { return }
      context.saveGState()
      // Text lays out downward from the top; the image context counts up from the bottom.
      context.translateBy(x: inset.width, y: height - inset.height)
      context.scaleBy(x: 1, y: -1)
      layout.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
        fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
        return true
      }
      // What the view draws over its fragments — a message's `…` — in the view's coordinates,
      // which sit one inset out from the container's the fragments were drawn in.
      context.translateBy(x: -inset.width, y: -inset.height)
      (textView as? TranscriptTextView)?.drawMessageMarks(in: textView.bounds)
      context.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let rendered = cgContext.makeImage() else {
      FileHandle.standardError.write(Data("no image from the transcript bitmap\n".utf8))
      exit(1)
    }
    let image = NSImage(size: NSSize(width: width, height: height))
    image.addRepresentation(NSBitmapImageRep(cgImage: rendered))
    return image
  }
}

/// The named render cases: each is one region of transcript styling built from the real
/// renderer. Adding a thing to eyeball or snapshot means adding a case here, not a new CLI flag.
/// The focused cases pin the mistakes that have actually happened — emphasis against CJK
/// punctuation, a mixed-width table — while `transcript` keeps one screen of everything.
public enum RenderCase {
  public static let all: [(name: String, content: () -> NSAttributedString)] = [
    ("transcript", transcript),
    ("cjk-emphasis", cjkEmphasis),
    ("tables", tables),
    ("wide-table", wideTable),
    ("tool-states", toolStates),
    ("exit-plan", exitPlan),
    ("markdown-blocks", markdownBlocks),
    ("message-mark", messageMark),
    ("links", links),
  ]

  public static func content(for name: String) -> NSAttributedString? {
    all.first { $0.name == name }?.content()
  }

  public static var names: [String] { all.map(\.name) }

  /// One screen of every block the renderer knows.
  private static func transcript() -> NSAttributedString {
    let text = NSMutableAttributedString()
    // Named rather than left to the machine: a case is compared byte for byte, and the clock's
    // language and zone are the two things about it that are not the drawing.
    text.append(
      Transcript.timeSeparator(
        Date(timeIntervalSince1970: 1_766_000_000), locale: Locale(identifier: "ja_JP"),
        zone: TimeZone(identifier: "Asia/Tokyo") ?? .gmt))
    text.append(cjkEmphasis())
    text.append(toolStates())
    text.append(exitPlan())
    text.append(NSAttributedString(string: "\n", attributes: [.font: Transcript.mono]))
    text.append(markdownBlocks())
    return text
  }

  /// What an agent's addresses look like when they come back. The bare URL is the case that
  /// mattered: markdown syntax is what gets written least, so before this the most useful line in
  /// the whole transcript — the PR that was just opened — was plain black text. The rest are the
  /// ones that must stay black: a filename with a dot, and anything inside code.
  private static func links() -> NSAttributedString {
    Transcript.markdown(
      """
      Opened the PR: https://github.com/tnayuki/hukan/pull/12

      The issue it closes is [#8](https://github.com/tnayuki/hukan/issues/8), and the run is at
      https://github.com/tnayuki/hukan/actions/runs/1234567890 (still going).

      Edited Model.swift and Browser.swift; `curl https://example.com/a` is only quoted here.

      ```
      curl -sSL https://example.com/install.sh | sh
      ```
      """)
  }

  /// Japanese emphasis lands on bracketed/quoted phrases, which CommonMark flanking rules
  /// refuse — the reason inline markup is hand-rolled. This is the case that catches a
  /// regression back to literal asterisks.
  private static func cjkEmphasis() -> NSAttributedString {
    Transcript.userMessage(
      """
      アイコンの配色を変えたい
      **「白黒」**と**（角丸）**が太字になるかも確認
      """)
  }

  /// The `…` a message carries once there is a conversation above it to go back to — drawn at
  /// the vertical centre of the block's trailing edge, over the text, so a message with a mark is
  /// no taller than one without. Both states are here because the difference is the whole point: the first
  /// thing you said has nothing before it, so it is unmarked, and a mark that showed up there
  /// would offer an empty branch. It has to stay quiet enough to ignore while reading and
  /// findable when wanted.
  private static func messageMark() -> NSAttributedString {
    let text = NSMutableAttributedString()
    text.append(Transcript.userMessage("最初の指示。ここより前は無いので印は出ない"))
    text.append(Transcript.markdown("Understood — starting from the top.\n"))
    text.append(
      Transcript.userMessage(
        """
        やっぱり別の方針で行きたい
        `…` から分岐と巻き戻しを選ぶ
        """, forkAnchor: "a1"))
    return text
  }

  /// A short call's plain line, a foldable call's `▸` line, and the same call opened into its
  /// code-block slab — every tool-call state is text, so all three render here.
  private static func toolStates() -> NSAttributedString {
    let text = NSMutableAttributedString()
    text.append(
      Transcript.toolUse(name: "Bash", input: ["command": "git worktree list --porcelain"]))
    let multiline = """
      for w in $(git worktree list --porcelain | awk '/^worktree/{print $2}'); do
        git -C "$w" status --short
      done
      """
    text.append(Transcript.toolUse(name: "Bash", input: ["command": multiline]))
    text.append(Transcript.spacer(4))
    text.append(
      Transcript.toolCallExpandedRun(
        ToolCallToken(
          name: "Bash", summary: "for w in $(git worktree list …", full: multiline)))
    return text
  }

  /// ExitPlanMode in the transcript is a compact foldable record — a `▸ Here is Claude's plan:`
  /// one-liner that opens to the whole plan as markdown (no mechanical tool name). Both the
  /// folded line and the opened whole are here.
  private static func exitPlan() -> NSAttributedString {
    let plan = """
      ## Cache rendered thumbnails

      - **Source**: render once per `(path, size)`, keyed by content hash in an LRU.
      - **Eviction**: cap at 256 entries; drop the oldest on overflow.
      - **Invalidation**: a file save clears its own entries, nothing else.
      - **検証**: scroll a 1,000-file tree twice and compare the timings.

      The store is a new `ThumbnailCache.swift`; the cap is tuned once wired up.
      """
    let text = NSMutableAttributedString()
    text.append(Transcript.toolUse(name: "ExitPlanMode", input: ["plan": plan]))
    text.append(Transcript.spacer(4))
    text.append(
      Transcript.planExpandedRun(
        ToolCallToken(
          name: "ExitPlanMode", summary: "", full: plan, rendersMarkdown: true)))
    return text
  }

  /// A mixed-width table (CJK glyphs whose advance is not a monospace multiple) and a short
  /// one, the pair that drove the column-measuring and header-fill work.
  private static func tables() -> NSAttributedString {
    Transcript.markdown(
      """
      | プロセス | メモリ | 状態 |
      |---|---|---|
      | **検索インデクサ** (pid 4021) | 約1.2GB | 🟢 継続中 |
      | worker (thumbnail) ×4 | 合計 640MB | 待機 |
      | backup (nightly) | 210MB | 停止可 |

      ### 短い表

      | ビルド | 状態 |
      |---|---|
      | #42 | 成功 |
      """)
  }

  /// Five columns of mixed CJK/latin content that no narrow pane can fit on one line, so the
  /// cells have to wrap within their columns (see `TableAttachment`). Render it at a few widths
  /// (`HUKAN_PREVIEW_WIDTH`) to check the reflow.
  private static func wideTable() -> NSAttributedString {
    Transcript.markdown(
      """
      | 指標 | 場所 | 出所 | 表示例 | 粒度 |
      |---|---|---|---|---|
      | 推定コスト($) | 会話ヘッダ右 | transcript のトークン × 料金表 | $6.08(未知モデル混在時 ~$…) | セッションごと |
      | プラン利用率(%) | ツールバー右端 | claude -p /usage(課金ゼロ) | ⏳ 17% 📅 55% Fable 27% | アカウント全体 |
      """)
  }

  /// Lists (nested and numbered), a quote, a fenced code block, a rule and inline runs — the
  /// non-table markdown, plus the tables so this case stands alone as the prose renderer.
  private static func markdownBlocks() -> NSAttributedString {
    Transcript.markdown(
      """
      Got it — here is the **current state**, straight from the `--porcelain` output.

      ## Measured

      | プロセス | メモリ | 状態 |
      |---|---|---|
      | **検索インデクサ** (pid 4021) | 約1.2GB | 🟢 継続中 |
      | worker (thumbnail) ×4 | 合計 640MB | 待機 |
      | backup (nightly) | 210MB | 停止可 |

      ### 短い表

      | ビルド | 状態 |
      |---|---|
      | #42 | 成功 |

      Lists, for completeness:

      - the first item, with **emphasis**
      - the second item
        - a nested item
      1. numbered
      2. the second

      > A block quote renders like this.
      > Its second line joins the same slab.

      ```swift
      func render(_ text: String) -> NSAttributedString {
          // fenced code block
          return Transcript.markdown(text)
      }
      ```

      ---

      A closing paragraph, with a [link](https://example.com) and `inline code`.
      """)
  }
}
