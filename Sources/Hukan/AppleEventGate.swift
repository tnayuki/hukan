import AppKit

/// Refuses every Apple event a process this hukan started sends it — a session's agent, a shell in
/// one of its terminals, anything either of them runs — before Cocoa scripting sees it.
///
/// The Apple event is the outside's road in: the stdio MCP server relays its calls over it, and a
/// script from a terminal elsewhere speaks it. Who may send one is decided by the person, once per
/// app, in the automation grant — but macOS asks nothing of an event whose responsible process is
/// the app it is sent to, so from inside hukan the grant stands in front of nothing. Inside has
/// roads of its own, each narrowed to what it is for: an agent has the tools hukan hosts on its
/// stream (`HukanMCP`) and Claude Code's own messaging between sessions; the terminals' editor has
/// `EditSocket`. So the rule is one line, with no verb to weigh: from inside, nothing.
///
/// Inside is decided by the *responsible* process, the one TCC itself asks about, not by walking
/// parents: a process that double-forks is re-parented to launchd and walks out of the tree, but
/// stays hukan's responsibility. A process that leaves through another app — `open`, Terminal's
/// `do script` — becomes that app's, and then it is that app's automation grant that is asked,
/// which is the person's to give.
///
/// Let through, from inside too: what Launch Services sends on `open` (open the app, reopen it,
/// open documents or a URL), which shows a file and decides nothing, and AppleScript's own
/// fetch of the dictionary, so a refused script fails on the refusal rather than on a compile
/// error. Everything is let through under `HUKAN_SCRIPTING_GUARDED`, the harness that drives a
/// window on purpose.
enum AppleEventGate {
  static func install() {
    AEInstallSpecialHandler(AEKeyword(keyPreDispatch), predispatch, false)
  }

  /// What the refusal says.
  static let refusal = "hukan takes no Apple events from a process it started"

  private static let predispatch: AEEventHandlerUPP = { event, reply, _ in
    guard let event, !guardedScriptingEnabled(),
      let sender = attribute(keySenderPIDAttr, of: event, as: Int32.self),
      let eventClass = attribute(keyEventClassAttr, of: event, as: FourCharCode.self),
      let eventID = attribute(keyEventIDAttr, of: event, as: FourCharCode.self),
      !AppleEventGate.passes(eventClass: eventClass, id: eventID),
      AppleEventGate.isInside(sender)
    else { return OSErr(errAEEventNotHandled) }
    if let reply, reply.pointee.descriptorType != typeNull {
      var number: Int32 = 1
      AEPutParamPtr(reply, keyErrorNumber, typeSInt32, &number, MemoryLayout<Int32>.size)
      let message = Array(refusal.utf8)
      AEPutParamPtr(reply, keyErrorString, typeUTF8Text, message, message.count)
    }
    return OSErr(noErr)
  }

  /// The events that show something and decide nothing, which are let through from anywhere:
  /// Launch Services' open, reopen, open documents and open a URL, and AppleScript asking for
  /// the dictionary (`gdte`, `gdut`, `gsdf`).
  static func passes(eventClass: FourCharCode, id: FourCharCode) -> Bool {
    let open: Set<String> = ["aevt/oapp", "aevt/rapp", "aevt/odoc", "GURL/GURL"]
    let dictionary: Set<String> = ["ascr/gdte", "ascr/gdut", "ascr/gsdf"]
    let name = string(eventClass) + "/" + string(id)
    return open.contains(name) || dictionary.contains(name)
  }

  private static func string(_ code: FourCharCode) -> String {
    String(
      bytes: (0..<4).reversed().map { UInt8(truncatingIfNeeded: code >> ($0 * 8)) },
      encoding: .macOSRoman) ?? ""
  }

  /// Whether `pid` is this process or one it is responsible for.
  static func isInside(_ pid: pid_t) -> Bool {
    let me = ProcessInfo.processInfo.processIdentifier
    if pid == me { return true }
    if let responsible = responsiblePID(of: pid) { return responsible == me }
    return isDescendant(pid, of: me)
  }

  /// The process TCC holds responsible for `pid`. Private — libsystem has no header for it — so it
  /// is looked up at run time, and its absence falls back to the parent walk, which is weaker (a
  /// double fork walks out of it) but never lets in more than it should from outside.
  static func responsiblePID(of pid: pid_t) -> pid_t? {
    guard let lookup = responsibleLookup else { return nil }
    let responsible = lookup(pid)
    return responsible > 0 ? responsible : nil
  }

  private typealias Lookup = @convention(c) (pid_t) -> pid_t
  private static let responsibleLookup: Lookup? = {
    guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")
    else { return nil }
    return unsafeBitCast(symbol, to: Lookup.self)
  }()

  /// A fixed-size attribute of the event, read as `type`; nil when the event does not carry it.
  private static func attribute<T>(
    _ key: AEKeyword, of event: UnsafePointer<AppleEvent>, as: T.Type
  ) -> T? {
    let type = T.self == Int32.self ? DescType(typeSInt32) : DescType(typeType)
    let value = UnsafeMutableRawPointer.allocate(
      byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
    defer { value.deallocate() }
    var actualType: DescType = 0
    var size = 0
    guard
      AEGetAttributePtr(event, key, type, &actualType, value, MemoryLayout<T>.size, &size) == noErr,
      size == MemoryLayout<T>.size
    else { return nil }
    return value.load(as: T.self)
  }
}

/// Whether `pid` is `ancestor` or one of its descendants, walking parents through the kernel.
func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
  var current = pid
  for _ in 0..<64 {
    if current == ancestor { return true }
    guard current > 1 else { return false }
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
      return false
    }
    current = info.kp_eproc.e_ppid
  }
  return false
}
