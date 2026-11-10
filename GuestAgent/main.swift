// hukan-guest-agent: what hukan reaches a macOS guest through, over vsock.
//
// It runs twice in the guest, from one binary: as a LaunchAgent in the logged-in user's session
// (`--user`, port 7737) — where a command runs as the person would, with the desktop there — and
// as a LaunchDaemon (`--root`, port 7738) for what needs an administrator. Neither listens on the
// network: vsock is a channel between the guest and the host it runs on, and a connection from
// anywhere but the host (CID 2) is closed unanswered, so nothing inside the guest can borrow the
// daemon's root.
//
// One request per connection, one JSON object per line each way:
//   {"op":"ping"}                                  -> {"ok":true,"version":"1","mode":"user"}
//   {"op":"exec","argv":[...],"cwd":?,"env":{}?,"stdin":"<base64>"?,"timeout":seconds?}
//                                                  -> {"ok":true,"exit":0,"stdout":"<b64>","stderr":"<b64>","timedOut":false}
//   {"op":"read","path":...}                       -> {"ok":true,"data":"<base64>"}
//   {"op":"write","path":...,"data":"<b64>","mode":420?}  -> {"ok":true}
//   {"op":"display","width":1920,"height":1200}    -> {"ok":true,"mode":"960x600@2"}
//     (user half: the main display's mode with exactly those pixels, HiDPI first)
//   {"op":"windows"}                               -> {"ok":true,"text":"<one window a line>"}
//   {"op":"ui_tree","app":?,"menus":?,"window":?}  -> {"ok":true,"text":"<one element a line>"}
//   {"op":"ui_press","id":...,"action":?}          -> {"ok":true}
//   {"op":"ui_set","id":...,"value":...}           -> {"ok":true}
//   {"op":"click","x":..,"y":..,"count":?,"right":?,"window":?}  -> {"ok":true}
//   {"op":"type","text":...}                       -> {"ok":true}
//   {"op":"key","key":"return","modifiers":["command"]?}  -> {"ok":true}
//   {"op":"input_source","id":"com.apple.keylayout.ABC","enable":?}  -> {"ok":true}
//     (user half: select that input source, or with "enable" only turn it on)
//     (user half; every position is in the pixels of a screenshot — with "window", of that
//     window's own)
// A failure is {"ok":false,"error":"..."}.
//
// Built by Vendor/build-guest-agent.sh into Resources/hukan-guest-agent; hukan copies it into a
// template while making it.

import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin
import Foundation

let version = "4"
let hostCID: UInt32 = 2

let arguments = CommandLine.arguments
let isRoot = arguments.contains("--root")
let port: UInt32 = isRoot ? 7738 : 7737

// One request, in a process of its own: see `runInChild`.
if let flag = arguments.firstIndex(of: "--once"), arguments.count > flag + 1,
  let object = try JSONSerialization.jsonObject(with: Data(arguments[flag + 1].utf8))
    as? [String: Any]
{
  FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: perform(object)))
  exit(0)
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("hukan-guest-agent: \(message)\n".utf8))
  exit(1)
}

// MARK: Listening

let listener = socket(AF_VSOCK, SOCK_STREAM, 0)
guard listener >= 0 else { fail("socket: \(String(cString: strerror(errno)))") }
var address = sockaddr_vm()
address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
address.svm_family = sa_family_t(AF_VSOCK)
address.svm_port = port
address.svm_cid = UInt32(bitPattern: -1)  // VMADDR_CID_ANY
let bound = withUnsafePointer(to: &address) {
  $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
  }
}
guard bound == 0 else { fail("bind \(port): \(String(cString: strerror(errno)))") }
guard listen(listener, 16) == 0 else { fail("listen: \(String(cString: strerror(errno)))") }

// MARK: Announcing

// The host is told this half is up, rather than finding out by connecting: a connection from the
// host to a guest port nobody listens on yet has crashed Virtualization.framework in the host, so
// hukan only ever dials an agent that has said it is there. Again every fifteen seconds, because
// the host that ran the machine before a relaunch, a restore from a saved state, heard the last
// one and the new one has not.
let helloPort: UInt32 = 7739
Thread.detachNewThread {
  while true {
    announce()
    Thread.sleep(forTimeInterval: 15)
  }
}

func announce() {
  let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
  guard fd >= 0 else { return }
  defer { close(fd) }
  var host = sockaddr_vm()
  host.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
  host.svm_family = sa_family_t(AF_VSOCK)
  host.svm_port = helloPort
  host.svm_cid = hostCID
  let connected = withUnsafePointer(to: &host) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(fd, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
    }
  }
  guard connected == 0 else { return }
  respond(fd, ["hello": isRoot ? "root" : "user", "version": version])
}

while true {
  var peer = sockaddr_vm()
  var length = socklen_t(MemoryLayout<sockaddr_vm>.size)
  let client = withUnsafeMutablePointer(to: &peer) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
  }
  guard client >= 0 else {
    if errno == EINTR { continue }
    fail("accept: \(String(cString: strerror(errno)))")
  }
  // The host and nothing else: a process in the guest connecting to its own vsock port must not
  // be handed a root shell by the daemon.
  guard peer.svm_cid == hostCID else {
    close(client)
    continue
  }
  Thread.detachNewThread { serve(client) }
}

// MARK: Serving

func serve(_ fd: Int32) {
  defer { close(fd) }
  guard let line = readLine(fd),
    let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
  else {
    respond(fd, ["ok": false, "error": "malformed request"])
    return
  }
  respond(fd, handle(request))
}

func handle(_ request: [String: Any]) -> [String: Any] {
  switch request["op"] as? String {
  case "ping":
    return ["ok": true, "version": version, "mode": isRoot ? "root" : "user"]
  case "exec":
    return execute(request)
  case "read":
    guard let path = request["path"] as? String else { return failure("read needs a path") }
    guard let data = FileManager.default.contents(atPath: path) else {
      return failure("cannot read \(path)")
    }
    return ["ok": true, "data": data.base64EncodedString()]
  case "write":
    guard let path = request["path"] as? String,
      let data = (request["data"] as? String).flatMap({ Data(base64Encoded: $0) })
    else { return failure("write needs a path and base64 data") }
    let url = URL(fileURLWithPath: path)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
      if let mode = request["mode"] as? Int {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
      }
      return ["ok": true]
    } catch {
      return failure(error.localizedDescription)
    }
  case "display", "windows", "ui_tree", "ui_press", "ui_set", "click", "type", "key",
    "input_source":
    return runInChild(request)
  default:
    return failure("unknown op")
  }
}

/// A request about the screen, run by a fresh copy of this program. CoreGraphics reads a process's
/// displays once and brings them up to date from its run loop, which this one never runs: the first
/// call here saw the panel as it stood, and every later one was told the panel was still that size,
/// however many times the host had resized it since. The same goes for what is frontmost.
func runInChild(_ request: [String: Any]) -> [String: Any] {
  guard let body = try? JSONSerialization.data(withJSONObject: request) else {
    return failure("the request could not be encoded")
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: arguments[0])
  process.arguments = ["--once", String(decoding: body, as: UTF8.self)]
  let output = Pipe()
  process.standardOutput = output
  do {
    try process.run()
  } catch {
    return failure(error.localizedDescription)
  }
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
    return failure("the helper answered nothing (exit \(process.terminationStatus))")
  }
  return answer
}

/// What the child does with the one request it was started for.
func perform(_ request: [String: Any]) -> [String: Any] {
  switch request["op"] as? String {
  case "display":
    guard let width = request["width"] as? Int, let height = request["height"] as? Int else {
      return failure("display needs a width and a height")
    }
    return setDisplay(width: width, height: height)
  case "windows": return listWindows()
  case "ui_tree":
    return uiTree(
      app: request["app"] as? String, menus: request["menus"] as? Bool,
      window: request["window"] as? Int)
  case "ui_press":
    return uiPress(request["id"] as? String, action: request["action"] as? String)
  case "ui_set": return uiSet(request["id"] as? String, value: request["value"] as? String)
  case "click":
    guard let x = request["x"] as? Double, let y = request["y"] as? Double else {
      return failure("click needs x and y")
    }
    return click(
      x: x, y: y, count: request["count"] as? Int ?? 1, right: request["right"] as? Bool ?? false,
      window: request["window"] as? Int)
  case "type":
    guard let text = request["text"] as? String else { return failure("type needs text") }
    return type(text)
  case "key":
    guard let key = request["key"] as? String else { return failure("key needs a key") }
    return press(key, modifiers: request["modifiers"] as? [String] ?? [])
  case "input_source":
    guard let id = request["id"] as? String else { return failure("input_source needs an id") }
    return inputSource(id, enable: request["enable"] as? Bool ?? false)
  default:
    return failure("unknown op")
  }
}

// MARK: The interface, through Accessibility

/// Pixels of a screenshot per point of the screen: AX and CGEvent speak points, and a screenshot is
/// what an agent reads positions off.
func screenScale() -> Double {
  guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()), mode.width > 0 else { return 1 }
  return Double(mode.pixelWidth) / Double(mode.width)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
    return nil
  }
  return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
  attribute(element, "AXChildren") as? [AXUIElement] ?? []
}

func axValue<T: BitwiseCopyable>(_ ref: CFTypeRef?, _ type: AXValueType, _ empty: T) -> T? {
  guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
  var result = empty
  return AXValueGetValue(ref as! AXValue, type, &result) ? result : nil
}

/// An element's id is its process and the child indices down to it, so nothing has to be held
/// between two calls — each is a process of its own. A window that has changed since it was read
/// lands the id on something else, which is why a tree is read again after anything moves.
func element(_ id: String?) -> AXUIElement? {
  guard let id, let slash = id.firstIndex(of: "/"), let pid = pid_t(id[..<slash]) else {
    return nil
  }
  var current = AXUIElementCreateApplication(pid)
  for part in id[id.index(after: slash)...].split(separator: ".") {
    guard let index = Int(part) else { return nil }
    let list = children(current)
    guard list.indices.contains(index) else { return nil }
    current = list[index]
  }
  return current
}

/// What the window server knows of one window, or of every window on screen.
func windowInfo(_ id: Int? = nil) -> [[String: Any]] {
  let list =
    id.map { CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID($0)) }
    ?? CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
  return list as? [[String: Any]] ?? []
}

func windowBounds(_ info: [String: Any]) -> CGRect? {
  guard let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
  return CGRect(dictionaryRepresentation: bounds)
}

func listWindows() -> [String: Any] {
  let scale = screenScale()
  var lines = ["id\tapp\ttitle\tframe"]
  for info in windowInfo() where info[kCGWindowLayer as String] as? Int == 0 {
    guard let id = info[kCGWindowNumber as String] as? Int, let bounds = windowBounds(info) else {
      continue
    }
    let app = info[kCGWindowOwnerName as String] as? String ?? "?"
    let title = info[kCGWindowName as String] as? String ?? ""
    lines.append(
      "\(id)\t\(app)\t\(title)\t[\(Int(bounds.minX * scale)),\(Int(bounds.minY * scale))"
        + " \(Int(bounds.width * scale))x\(Int(bounds.height * scale))]")
  }
  return ["ok": true, "text": lines.joined(separator: "\n")]
}

func uiTree(app name: String?, menus: Bool?, window: Int?) -> [String: Any] {
  guard AXIsProcessTrusted() else {
    return failure("hukan-guest-agent does not have Accessibility in this guest")
  }
  // A window's tree is its application's, narrowed to the element standing where the window
  // server says that window is — AX has no public way to ask for a window by its number.
  var windowOrigin = CGPoint.zero
  var windowPID: pid_t?
  if let window {
    guard let info = windowInfo(window).first, let bounds = windowBounds(info),
      let pid = info[kCGWindowOwnerPID as String] as? Int32
    else { return failure("no window \(window)") }
    windowOrigin = bounds.origin
    windowPID = pid
  }
  let running =
    windowPID.flatMap { NSRunningApplication(processIdentifier: $0) }
    ?? (name == nil
      ? NSWorkspace.shared.frontmostApplication
      : NSWorkspace.shared.runningApplications.first {
        $0.localizedName == name || $0.bundleIdentifier == name
      })
  guard let running else { return failure("no such application is running") }
  let scale = screenScale()
  var lines = ["app \(running.localizedName ?? "?")"]
  let limit = 2000
  func clipped(_ text: String) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    return flat.count > 120 ? String(flat.prefix(120)) + "…" : flat
  }
  func walk(_ node: AXUIElement, id: String, depth: Int) {
    guard lines.count < limit, depth < 40 else { return }
    let role = attribute(node, "AXRole") as? String ?? "?"
    if role == "AXMenuBar", menus != true { return }
    var line =
      String(repeating: " ", count: depth) + id + " "
      + role.replacingOccurrences(
        of: "AX", with: "")
    for key in ["AXTitle", "AXDescription", "AXLabel"] {
      if let text = attribute(node, key) as? String, !text.isEmpty {
        line += " \"\(clipped(text))\""
        break
      }
    }
    if let value = attribute(node, "AXValue") {
      if let text = value as? String, !text.isEmpty {
        line += " value=\"\(clipped(text))\""
      } else if let number = value as? NSNumber {
        line += " value=\(number)"
      }
    }
    if let origin = axValue(attribute(node, "AXPosition"), .cgPoint, CGPoint.zero),
      let size = axValue(attribute(node, "AXSize"), .cgSize, CGSize.zero)
    {
      line +=
        " [\(Int((origin.x - windowOrigin.x) * scale)),\(Int((origin.y - windowOrigin.y) * scale))"
        + " \(Int(size.width * scale))x\(Int(size.height * scale))]"
    }
    var actions: CFArray?
    if AXUIElementCopyActionNames(node, &actions) == .success,
      // An app's own actions arrive as several lines of description, and are not names to press.
      case let names = (actions as? [String] ?? []).filter({ $0.hasPrefix("AX") }), !names.isEmpty
    {
      line +=
        " {"
        + names.map { $0.replacingOccurrences(of: "AX", with: "") }
        .joined(separator: ",") + "}"
    }
    lines.append(line)
    for (index, child) in children(node).enumerated() {
      walk(child, id: id.hasSuffix("/") ? "\(id)\(index)" : "\(id).\(index)", depth: depth + 1)
    }
  }
  let application = AXUIElementCreateApplication(running.processIdentifier)
  let root = "\(running.processIdentifier)/"
  if let window {
    guard let bounds = windowInfo(window).first.flatMap(windowBounds),
      let (index, node) = children(application).enumerated().first(where: { _, node in
        guard attribute(node, "AXRole") as? String == "AXWindow",
          let origin = axValue(attribute(node, "AXPosition"), .cgPoint, CGPoint.zero),
          let size = axValue(attribute(node, "AXSize"), .cgSize, CGSize.zero)
        else { return false }
        return abs(origin.x - bounds.minX) < 1 && abs(origin.y - bounds.minY) < 1
          && abs(size.width - bounds.width) < 1 && abs(size.height - bounds.height) < 1
      })
    else { return failure("window \(window) is not in its application's interface") }
    walk(node, id: "\(root)\(index)", depth: 0)
  } else {
    walk(application, id: root, depth: 0)
  }
  if lines.count >= limit { lines.append("… cut at \(limit) lines") }
  return ["ok": true, "text": lines.joined(separator: "\n")]
}

func uiPress(_ id: String?, action: String?) -> [String: Any] {
  guard let node = element(id) else { return failure("no element \(id ?? "")") }
  let name = "AX" + (action ?? "Press")
  let error = AXUIElementPerformAction(node, name as CFString)
  return error == .success ? ["ok": true] : failure("\(name) failed (\(error.rawValue))")
}

func uiSet(_ id: String?, value: String?) -> [String: Any] {
  guard let node = element(id), let value else { return failure("no element \(id ?? "")") }
  let error = AXUIElementSetAttributeValue(node, "AXValue" as CFString, value as CFString)
  return error == .success ? ["ok": true] : failure("setting the value failed (\(error.rawValue))")
}

// MARK: Mouse and keyboard

func click(x: Double, y: Double, count: Int, right: Bool, window: Int?) -> [String: Any] {
  let scale = screenScale()
  // Where the window is now rather than where it was when its picture was taken: a position in
  // the picture stays right however the window has been moved since.
  var origin = CGPoint.zero
  var target: (bounds: CGRect, pid: pid_t)?
  if let window {
    guard let info = windowInfo(window).first, let bounds = windowBounds(info),
      let pid = info[kCGWindowOwnerPID as String] as? Int32
    else { return failure("no window \(window)") }
    origin = bounds.origin
    target = (bounds, pid)
  }
  let point = CGPoint(x: origin.x + x / scale, y: origin.y + y / scale)
  if let window, let target, let problem = obstruction(at: point, window: window, target: target) {
    return failure(problem)
  }
  let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
    right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
  CGEvent(
    mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?
    .post(tap: .cghidEventTap)
  usleep(50_000)
  for number in 1...max(count, 1) {
    for type in [down, up] {
      let event = CGEvent(
        mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
      event?.setIntegerValueField(.mouseEventClickState, value: Int64(number))
      event?.flags = []
      event?.post(tap: .cghidEventTap)
      usleep(30_000)
    }
  }
  return ["ok": true]
}

/// Why a click meant for a window would land on something else, or nil if it would not. A click
/// goes to whatever is on top at that point, and one aimed at a window that the Dock was covering
/// started Safari, so it is asked what is there first.
func obstruction(at point: CGPoint, window: Int, target: (bounds: CGRect, pid: pid_t)) -> String? {
  var hit: AXUIElement?
  guard
    AXUIElementCopyElementAtPosition(
      AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
    let hit
  else { return "that point of window \(window) is off the screen" }
  var pid: pid_t = 0
  AXUIElementGetPid(hit, &pid)
  let owner =
    NSRunningApplication(processIdentifier: target.pid)?.localizedName ?? "its application"
  let raise = "; bring it to the front first (open -a \"\(owner)\") or move it"
  guard pid == target.pid else {
    let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "something else"
    return "that point of window \(window) is covered by \(name)" + raise
  }
  if let other = attribute(hit, "AXWindow"), CFGetTypeID(other) == AXUIElementGetTypeID() {
    // Same application: its other windows are told apart by where they stand.
    let node = other as! AXUIElement
    if let origin = axValue(attribute(node, "AXPosition"), .cgPoint, CGPoint.zero),
      abs(origin.x - target.bounds.minX) >= 1 || abs(origin.y - target.bounds.minY) >= 1
    {
      return "that point of window \(window) is covered by another of its application's windows;"
        + " move one of them first"
    }
  }
  return nil
}

func type(_ text: String) -> [String: Any] {
  for character in text {
    let units = Array(String(character).utf16)
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
      event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
      event?.flags = []
      event?.post(tap: .cghidEventTap)
      usleep(8_000)
    }
  }
  return ["ok": true]
}

func press(_ key: String, modifiers: [String]) -> [String: Any] {
  // Local, not a global: top-level code runs in order, and a helper is finished at the top of
  // this file, before a global declared down here has been given its value.
  let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
    "5": 23,
    "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
    "i": 34,
    "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
    "m": 46,
    ".": 47, "`": 50, "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "left": 123,
    "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
    "f10": 109, "f11": 103, "f12": 111,
  ]
  guard let code = keyCodes[key.lowercased()] else { return failure("no key named \(key)") }
  var flags = CGEventFlags()
  for modifier in modifiers {
    switch modifier.lowercased() {
    case "command", "cmd": flags.insert(.maskCommand)
    case "shift": flags.insert(.maskShift)
    case "option", "alt": flags.insert(.maskAlternate)
    case "control", "ctrl": flags.insert(.maskControl)
    default: return failure("no modifier named \(modifier)")
    }
  }
  for down in [true, false] {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
    usleep(30_000)
  }
  // The window server takes the flags of the last event posted as what is held down, and a new
  // event starts from those: after ⌘A everything typed or clicked next was a ⌘-chord, so it did
  // nothing. Nothing is held once the key is up, so that is said too — and the events above and
  // in `click` and `type` set their own flags rather than inherit whatever was left.
  let released = CGEvent(source: nil)
  released?.type = .flagsChanged
  released?.flags = []
  released?.post(tap: .cghidEventTap)
  return ["ok": true]
}

/// Put the main display in the mode that draws exactly `width` x `height` pixels. The host sizes
/// the virtual panel; which mode the guest then uses on it is the guest's to choose, and it
/// chooses the way a MacBook does — a scaled "looks like" mode drawn larger and shrunk to fit — so
/// a panel of 1920x1200 drew at 2048x1280 and every screenshot came back that size. Of the modes
/// with exactly those pixels, the HiDPI one is taken: the same pixels, drawn at twice the detail.
func setDisplay(width: Int, height: Int) -> [String: Any] {
  let display = CGMainDisplayID()
  let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
  guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else {
    return failure("the display lists no modes")
  }
  // The panel first: until the guest has seen the host's resize, the old panel still lists a
  // scaled mode of these pixels, and taking it puts a shrunk picture on the wrong panel. The
  // native mode is the panel's own size.
  let nativeFlag: UInt32 = 0x0200_0000  // kDisplayModeNativeFlag
  if let native = modes.first(where: { $0.ioFlags & nativeFlag != 0 }),
    native.pixelWidth != width || native.pixelHeight != height
  {
    return failure("the panel is still \(native.pixelWidth)x\(native.pixelHeight)")
  }
  let matching = modes.filter { $0.pixelWidth == width && $0.pixelHeight == height }
  guard let mode = matching.min(by: { $0.width < $1.width }) else {
    let sizes = Set(modes.map { "\($0.pixelWidth)x\($0.pixelHeight)" }).sorted()
    return failure(
      "no mode draws \(width)x\(height); the display offers \(sizes.joined(separator: " "))")
  }
  var config: CGDisplayConfigRef?
  guard CGBeginDisplayConfiguration(&config) == .success else {
    return failure("cannot configure the display")
  }
  CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
  let error = CGCompleteDisplayConfiguration(config, .permanently)
  guard error == .success else {
    return failure("the display refused the mode (\(error.rawValue))")
  }
  return [
    "ok": true, "mode": "\(mode.width)x\(mode.height)@\(mode.pixelWidth / max(mode.width, 1))",
  ]
}

func failure(_ message: String) -> [String: Any] { ["ok": false, "error": message] }

func execute(_ request: [String: Any]) -> [String: Any] {
  guard let argv = request["argv"] as? [String], let executable = argv.first else {
    return failure("exec needs argv")
  }
  let process = Process()
  // A bare name is looked up the way a shell would, on the PATH a login would have.
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [executable] + argv.dropFirst()
  var environment = ProcessInfo.processInfo.environment
  environment["PATH"] =
    "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  for (key, value) in (request["env"] as? [String: String]) ?? [:] { environment[key] = value }
  process.environment = environment
  if let cwd = request["cwd"] as? String { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
  let output = Pipe()
  let errors = Pipe()
  let input = Pipe()
  process.standardOutput = output
  process.standardError = errors
  process.standardInput = input
  do {
    try process.run()
  } catch {
    return failure("cannot run \(executable): \(error.localizedDescription)")
  }
  if let stdin = (request["stdin"] as? String).flatMap({ Data(base64Encoded: $0) }) {
    input.fileHandleForWriting.write(stdin)
  }
  try? input.fileHandleForWriting.close()
  // Both pipes drained at once, or a command filling one while the other is read deadlocks.
  var out = Data()
  var err = Data()
  let group = DispatchGroup()
  group.enter()
  DispatchQueue.global().async {
    out = output.fileHandleForReading.readDataToEndOfFile()
    group.leave()
  }
  group.enter()
  DispatchQueue.global().async {
    err = errors.fileHandleForReading.readDataToEndOfFile()
    group.leave()
  }
  let timeout = (request["timeout"] as? Double) ?? 600
  var timedOut = false
  if group.wait(timeout: .now() + timeout) == .timedOut {
    timedOut = true
    process.terminate()
    _ = group.wait(timeout: .now() + 5)
  }
  process.waitUntilExit()
  return [
    "ok": true, "exit": Int(process.terminationStatus), "stdout": out.base64EncodedString(),
    "stderr": err.base64EncodedString(), "timedOut": timedOut,
  ]
}

// MARK: Lines

func readLine(_ fd: Int32) -> Data? {
  var data = Data()
  var byte: UInt8 = 0
  while read(fd, &byte, 1) == 1 {
    if byte == 0x0A { return data }
    data.append(byte)
    if data.count > 512 << 20 { return nil }
  }
  return data.isEmpty ? nil : data
}

func respond(_ fd: Int32, _ object: [String: Any]) {
  guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
  data.append(0x0A)
  data.withUnsafeBytes { buffer in
    var offset = 0
    while offset < buffer.count {
      let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
      if written <= 0 { break }
      offset += written
    }
  }
}

// MARK: Input sources

/// The host's かな and 英数 keys, and the Japanese input a JIS keyboard expects. The guest's
/// keyboard is ANSI whatever the Mac's is — Virtualization.framework offers no other — and macOS
/// ignores those two keys from an ANSI keyboard, so the host asks for the input source instead.
func inputSource(_ id: String, enable: Bool) -> [String: Any] {
  let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
  guard
    let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue()
      as? [TISInputSource],
    let source = sources.first
  else { return failure("no input source \(id)") }
  let status = enable ? TISEnableInputSource(source) : TISSelectInputSource(source)
  return status == noErr ? ["ok": true] : failure("input source \(id): \(status)")
}
