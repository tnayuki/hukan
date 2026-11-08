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
// A failure is {"ok":false,"error":"..."}.
//
// Built by Vendor/build-guest-agent.sh into Resources/hukan-guest-agent; hukan copies it into a
// template while making it.

import CoreGraphics
import Darwin
import Foundation

let version = "2"
let hostCID: UInt32 = 2

let arguments = CommandLine.arguments
let isRoot = arguments.contains("--root")
let port: UInt32 = isRoot ? 7738 : 7737

// One display change, in a process of its own: see `setDisplayInChild`.
if let flag = arguments.firstIndex(of: "--set-display"), arguments.count > flag + 2,
  let width = Int(arguments[flag + 1]), let height = Int(arguments[flag + 2])
{
  let answer = try JSONSerialization.data(withJSONObject: setDisplay(width: width, height: height))
  FileHandle.standardOutput.write(answer)
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
  case "display":
    guard let width = request["width"] as? Int, let height = request["height"] as? Int else {
      return failure("display needs a width and a height")
    }
    return setDisplayInChild(width: width, height: height)
  default:
    return failure("unknown op")
  }
}

/// `setDisplay`, run by a fresh copy of this program. CoreGraphics reads a process's displays once
/// and brings them up to date from its run loop, which this one never runs: the first call here
/// saw the panel as it stood, and every later one was told the panel was still that size, however
/// many times the host had resized it since.
func setDisplayInChild(width: Int, height: Int) -> [String: Any] {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: arguments[0])
  process.arguments = ["--set-display", String(width), String(height)]
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
    return failure("the display helper answered nothing (exit \(process.terminationStatus))")
  }
  return answer
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
