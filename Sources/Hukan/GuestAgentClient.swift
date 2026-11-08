import Foundation
import Virtualization

/// Talking to `hukan-guest-agent` in a macOS guest, over the machine's vsock device. No network,
/// no address, no credential: the channel exists only between this process and the guest it is
/// running, so being able to open it is the whole of the authority — the same reason the agent
/// answers only the host.
///
/// Two agents, two ports: the logged-in user's (commands run as the person would, with the
/// desktop there) and the administrator's, for what would otherwise need sudo.
enum GuestAgent {
  static let userPort: UInt32 = 7737
  static let rootPort: UInt32 = 7738
  /// The most one reply may be: a file read whole, in base64, with room to spare. Past it the guest
  /// is sending without end, and a reply that size is not one worth holding in memory.
  static let replyLimit = 512 << 20

  /// The binary hukan ships for the guest, and what it is installed as there.
  static var bundledBinary: URL? {
    Bundle.main.url(forResource: "hukan-guest-agent", withExtension: nil)
  }
  static let guestBinaryPath = "/usr/local/libexec/hukan-guest-agent"
  static let agentLabel = "dev.tnayuki.hukan.guest-agent"
  static let daemonLabel = "dev.tnayuki.hukan.guest-agent.root"

  struct ExecResult {
    var exit: Int
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
  }

  /// Send one request and read its one reply. The device belongs to the machine's queue, which is
  /// the main one, so the connection is opened there and the bytes moved off it.
  static func request(
    _ body: [String: Any], to vm: VZVirtualMachine, admin: Bool = false,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    guard vm.state == .running else {
      completion(.failure(MachineError("The machine is not running.")))
      return
    }
    guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
      completion(.failure(MachineError("The machine has no socket device.")))
      return
    }
    device.connect(toPort: admin ? rootPort : userPort) { result in
      // The machine is held until the connection answers: a shutdown asked for through the agent
      // lets the owner drop the machine while this is still in flight, and the framework's
      // callback then runs on a device already freed — which crashed the app.
      withExtendedLifetime(vm) {}
      switch result {
      case .failure(let error):
        completion(
          .failure(MachineError("The guest agent did not answer (\(error.localizedDescription)).")))
      case .success(let connection):
        let fd = fcntl(connection.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        connection.close()
        guard fd >= 0 else {
          completion(.failure(MachineError("Could not hold the connection.")))
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let reply = exchange(fd, body)
          close(fd)
          DispatchQueue.main.async { completion(reply) }
        }
      }
    }
  }

  // Internal with a limit parameter so tests can exercise the wire without a running VM.
  static func exchange(_ fd: Int32, _ body: [String: Any], replyLimit: Int = GuestAgent.replyLimit)
    -> Result<[String: Any], Error>
  {
    guard var data = try? JSONSerialization.data(withJSONObject: body) else {
      return .failure(MachineError("Could not encode the request."))
    }
    data.append(0x0A)
    let sent = data.withUnsafeBytes { buffer -> Bool in
      var offset = 0
      while offset < buffer.count {
        let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
        if written <= 0 { return false }
        offset += written
      }
      return true
    }
    guard sent else { return .failure(MachineError("The guest agent hung up.")) }
    var reply = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = Darwin.read(fd, &chunk, chunk.count)
      if count <= 0 { break }
      reply.append(contentsOf: chunk[0..<count])
      if reply.last == 0x0A { break }
      // A guest sending without end must not be able to spend this process's memory.
      if reply.count > replyLimit {
        return .failure(MachineError("The guest agent's reply was too large."))
      }
    }
    guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
      return .failure(MachineError("The guest agent's reply was not understood."))
    }
    guard object["ok"] as? Bool == true else {
      return .failure(MachineError(object["error"] as? String ?? "The guest agent refused."))
    }
    return .success(object)
  }

  // MARK: Verbs

  static func exec(
    _ argv: [String], on vm: VZVirtualMachine, admin: Bool = false, cwd: String? = nil,
    stdin: Data? = nil, timeout: Double = 600,
    completion: @escaping (Result<ExecResult, Error>) -> Void
  ) {
    var body: [String: Any] = ["op": "exec", "argv": argv, "timeout": timeout]
    if let cwd { body["cwd"] = cwd }
    if let stdin { body["stdin"] = stdin.base64EncodedString() }
    request(body, to: vm, admin: admin) { result in
      completion(
        result.map { reply in
          ExecResult(
            exit: reply["exit"] as? Int ?? -1,
            stdout: (reply["stdout"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data(),
            stderr: (reply["stderr"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data(),
            timedOut: reply["timedOut"] as? Bool ?? false)
        })
    }
  }

  static func read(
    _ path: String, on vm: VZVirtualMachine, admin: Bool = false,
    completion: @escaping (Result<Data, Error>) -> Void
  ) {
    request(["op": "read", "path": path], to: vm, admin: admin) { result in
      completion(
        result.flatMap { reply in
          guard let data = (reply["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            return .failure(MachineError("The guest agent sent no data."))
          }
          return .success(data)
        })
    }
  }

  static func write(
    _ data: Data, to path: String, on vm: VZVirtualMachine, admin: Bool = false,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    request(
      ["op": "write", "path": path, "data": data.base64EncodedString()], to: vm, admin: admin
    ) { result in
      completion(result.map { _ in () })
    }
  }

  /// Put the guest's main display in the mode that draws exactly these pixels — the user half,
  /// since a display mode belongs to the session showing it. Answers the mode, as "960x600@2".
  static func setDisplay(
    width: Int, height: Int, on vm: VZVirtualMachine,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    request(["op": "display", "width": width, "height": height], to: vm) { result in
      completion(result.map { $0["mode"] as? String ?? "" })
    }
  }

  static func ping(
    _ vm: VZVirtualMachine, admin: Bool = false, completion: @escaping (Bool) -> Void
  ) {
    request(["op": "ping"], to: vm, admin: admin) { result in
      if case .success = result { completion(true) } else { completion(false) }
    }
  }

  // MARK: Launchd

  static var agentPlist: String {
    plist(label: agentLabel, mode: "--user", agent: true)
  }

  static var daemonPlist: String {
    plist(label: daemonLabel, mode: "--root", agent: false)
  }

  /// The agent half runs in the logged-in user's Aqua session — where `open` and the desktop
  /// are — and the daemon half in the system domain, as root.
  private static func plist(label: String, mode: String, agent: Bool) -> String {
    let session = agent ? "\n  <key>LimitLoadToSessionType</key><string>Aqua</string>" : ""
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key><string>\(label)</string>
        <key>ProgramArguments</key>
        <array><string>\(guestBinaryPath)</string><string>\(mode)</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>\(session)
      </dict>
      </plist>

      """
  }
}
