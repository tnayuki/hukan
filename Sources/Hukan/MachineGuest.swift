import Foundation

/// Reaching into a running guest: where it is on the network, and SSH into it with hukan's own
/// key. A macOS guest's account is created with Remote Login on (`VZMacGuestProvisioningOptions`),
/// so SSH is the door — there is no guest agent to install.
enum MachineGuest {
  // MARK: Address

  /// The guest's address on Virtualization.framework's NAT, read from the host's DHCP leases by
  /// the MAC address the machine was given. The file writes each octet without its leading zero
  /// (`3e:6`), so both sides are compared as numbers.
  static func ipAddress(macAddress: String) -> String? {
    guard let text = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else {
      return nil
    }
    let wanted = octets(macAddress)
    var address: String?
    var hardware: [Int]?
    var found: String?
    for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
      if line == "{" {
        address = nil
        hardware = nil
      } else if line.hasPrefix("ip_address=") {
        address = String(line.dropFirst("ip_address=".count))
      } else if line.hasPrefix("hw_address=") {
        // `1,<mac>`: the type, then the address.
        hardware = line.split(separator: ",").last.map { octets(String($0)) }
      } else if line == "}", hardware == wanted, let address {
        // The file appends; the last lease for a MAC is the current one.
        found = address
      }
    }
    return found
  }

  private static func octets(_ mac: String) -> [Int] {
    mac.split(separator: ":").compactMap { Int($0, radix: 16) }
  }

  static var sshDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/hukan/ssh")
  }

  // MARK: SSH

  struct Output {
    var status: Int32
    var output: String
    var error: String
  }

  /// Run `command` in the guest as `user`, logging in with the account's password — handed to ssh
  /// through an askpass helper, never on a command line. SSH is the door only while a template is
  /// being made: once the guest agent answers over vsock, the template turns Remote Login off and
  /// keeps no key, so nothing reaches a guest over the network afterwards. `input` goes to the
  /// remote command's stdin.
  static func ssh(
    host: String, user: String, command: String, password: String, input: Data? = nil,
    timeout: Int = 10
  ) -> Output {
    var arguments = [
      "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
      "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=\(timeout)",
    ]
    var environment = ProcessInfo.processInfo.environment
    arguments += [
      "-o", "PubkeyAuthentication=no", "-o",
      "PreferredAuthentications=password,keyboard-interactive",
    ]
    environment["SSH_ASKPASS"] = askpassHelper().path
    environment["SSH_ASKPASS_REQUIRE"] = "force"
    environment["HUKAN_GUEST_PASSWORD"] = password
    environment["DISPLAY"] = ":0"
    arguments += ["\(user)@\(host)", command]
    return run("/usr/bin/ssh", arguments, environment: environment, input: input)
  }

  /// A helper that prints the password from the environment — so the password reaches ssh without
  /// ever being written to disk or appearing in a process's arguments.
  private static func askpassHelper() -> URL {
    let url = sshDirectory.appendingPathComponent("askpass")
    let script = "#!/bin/sh\nprintf '%s\\n' \"$HUKAN_GUEST_PASSWORD\"\n"
    if (try? String(contentsOf: url, encoding: .utf8)) != script {
      try? FileManager.default.createDirectory(
        at: sshDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try? script.write(to: url, atomically: true, encoding: .utf8)
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    return url
  }

  static func run(
    _ executable: String, _ arguments: [String], environment: [String: String]? = nil,
    input: Data? = nil
  ) -> Output {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    let output = Pipe()
    let error = Pipe()
    let stdin = Pipe()
    process.standardOutput = output
    process.standardError = error
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
    do {
      try process.run()
    } catch {
      return Output(status: -1, output: "", error: error.localizedDescription)
    }
    if let input {
      stdin.fileHandleForWriting.write(input)
      try? stdin.fileHandleForWriting.close()
    }
    let out = output.fileHandleForReading.readDataToEndOfFile()
    let err = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Output(
      status: process.terminationStatus, output: String(decoding: out, as: UTF8.self),
      error: String(decoding: err, as: UTF8.self))
  }

  // MARK: Setting a template up

  /// After the first boot has made the account: put the guest agent in, as the user's LaunchAgent
  /// and as a root LaunchDaemon, and start both. Blocking; waits for the guest to come up on the
  /// network first. Leaves SSH as it found it — on — so the caller can check the agent answers
  /// before taking the door away.
  static func installAgent(
    macAddress: String, user: String, password: String, deadline: Date
  ) throws {
    guard let binary = GuestAgent.bundledBinary.flatMap({ try? Data(contentsOf: $0) }) else {
      throw MachineError("hukan-guest-agent is missing from the app.")
    }
    var host: String?
    while Date() < deadline {
      if let address = ipAddress(macAddress: macAddress),
        ssh(host: address, user: user, command: "true", password: password, timeout: 5).status
          == 0
      {
        host = address
        break
      }
      Thread.sleep(forTimeInterval: 5)
    }
    guard let host else { throw MachineError("The guest never answered on SSH.") }
    // Three files to /tmp as the user, then one sudo to put them in place: the password is sudo's
    // stdin there, so nothing else can ride on that connection.
    let uploads: [(String, Data)] = [
      ("/tmp/hukan-guest-agent", binary),
      ("/tmp/\(GuestAgent.agentLabel).plist", Data(GuestAgent.agentPlist.utf8)),
      ("/tmp/\(GuestAgent.daemonLabel).plist", Data(GuestAgent.daemonPlist.utf8)),
    ]
    for (path, data) in uploads {
      let upload = ssh(
        host: host, user: user, command: "cat > \(path)", password: password, input: data)
      guard upload.status == 0 else {
        throw MachineError("Could not copy \(path) to the guest: \(upload.error)")
      }
    }
    let agent = "/Library/LaunchAgents/\(GuestAgent.agentLabel).plist"
    let daemon = "/Library/LaunchDaemons/\(GuestAgent.daemonLabel).plist"
    let script = [
      "mkdir -p /usr/local/libexec",
      "install -m 755 -o root -g wheel /tmp/hukan-guest-agent \(GuestAgent.guestBinaryPath)",
      "install -m 644 -o root -g wheel /tmp/\(GuestAgent.agentLabel).plist \(agent)",
      "install -m 644 -o root -g wheel /tmp/\(GuestAgent.daemonLabel).plist \(daemon)",
      // Only the daemon is started now. The agent half belongs to the user's GUI session, and
      // macOS will not let even root put a job into it from SSH (`bootstrap gui/<uid>` answers
      // 125, "Domain does not support specified action"); a job in /Library/LaunchAgents is
      // loaded at login instead, so the caller restarts the guest and automatic login does it.
      "launchctl bootstrap system \(daemon)",
      "rm -f /tmp/hukan-guest-agent /tmp/\(GuestAgent.agentLabel).plist"
        + " /tmp/\(GuestAgent.daemonLabel).plist",
    ].joined(separator: " && ")
    let install = ssh(
      host: host, user: user, command: "sudo -S -p '' sh -c '\(script)'", password: password,
      input: Data((password + "\n").utf8))
    guard install.status == 0 else {
      throw MachineError("Could not install the guest agent: \(install.error)")
    }
  }
}
