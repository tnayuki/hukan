import Foundation

/// Runs a panel's argv: as an array, never through a shell, in the worktree, with the PATH the
/// person's own shell builds.
///
/// The PATH is the one thing a shell is asked for. A GUI launch inherits launchd's bare
/// `/usr/bin:/bin:/usr/sbin:/sbin`, where neither `gh` nor a Homebrew `python3` is, and the engine
/// solves that by being started through `$SHELL -l -i` (`ClaudeSession`) at 1.4s a launch — a
/// price a panel redrawn on every turn cannot pay. So the shell is asked once, the answer kept, and
/// every run after is a plain `Process` with that PATH: what is run is the argv the definition
/// spells, and nothing in it is ever a shell's to interpret.
enum PanelRunner {
  struct Result {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool

    var succeeded: Bool { status == 0 && !timedOut }

    /// The last few lines of stderr, for a notice: a reason is a sentence or two.
    var stderrTail: String {
      let lines = String(decoding: stderr, as: UTF8.self).split(separator: "\n")
      return lines.suffix(5).joined(separator: "\n")
    }
  }

  /// The most of stdout a run may write. A panel is a page, not a log.
  static let outputLimit = 1 << 20

  private static let pathQueue = DispatchQueue(label: "com.hukan.panel-path")
  private static var cachedPath: String?

  /// The person's shell's PATH, asked once and kept; the inherited one while that is not known.
  static var path: String {
    pathQueue.sync {
      if let cachedPath { return cachedPath }
      let found =
        askShellForPath() ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
      cachedPath = found
      return found
    }
  }

  private static func askShellForPath() -> String? {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let marker = "__HUKAN_PANEL_PATH__"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-l", "-i", "-c", "printf '\(marker)%s' \"$PATH\""]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard let range = text.range(of: marker, options: .backwards) else { return nil }
    let path = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
  }

  /// The executable an argv's first entry names: itself when it holds a slash, else the first
  /// match on `path`.
  static func executable(_ name: String, path: String) -> URL? {
    if name.contains("/") {
      return FileManager.default.isExecutableFile(atPath: name) ? URL(fileURLWithPath: name) : nil
    }
    for directory in path.split(separator: ":") where !directory.isEmpty {
      let candidate = "\(directory)/\(name)"
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return URL(fileURLWithPath: candidate)
      }
    }
    return nil
  }

  struct NotFound: Error, CustomStringConvertible {
    let name: String
    var description: String { "`\(name)` was not found on PATH" }
  }

  /// Run `argv` in `directory`, `input` on stdin, and answer on the main thread. A run past
  /// `timeout` is terminated and answered as timed out; stdout past `outputLimit` is cut there.
  static func run(
    _ argv: [String], in directory: URL, input: Data = Data(), timeout: TimeInterval,
    environment extra: [String: String] = [:],
    completion: @escaping (Swift.Result<Result, Error>) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let path = Self.path
      guard let executable = executable(argv[0], path: path) else {
        DispatchQueue.main.async { completion(.failure(NotFound(name: argv[0]))) }
        return
      }
      let process = Process()
      process.executableURL = executable
      process.arguments = Array(argv.dropFirst())
      process.currentDirectoryURL = directory
      var environment = ProcessInfo.processInfo.environment
      environment["PATH"] = path
      for (key, value) in extra { environment[key] = value }
      process.environment = environment
      let stdin = Pipe()
      let stdout = Pipe()
      let stderr = Pipe()
      process.standardInput = stdin
      process.standardOutput = stdout
      process.standardError = stderr
      do {
        try process.run()
      } catch {
        DispatchQueue.main.async { completion(.failure(error)) }
        return
      }
      let timedOut = TimeoutFlag()
      let timer = DispatchWorkItem { [weak process] in
        guard let process, process.isRunning else { return }
        timedOut.set()
        process.terminate()
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
      let group = DispatchGroup()
      var errData = Data()
      group.enter()
      DispatchQueue.global().async {
        errData = stderr.fileHandleForReading.readDataToEndOfFile()
        group.leave()
      }
      DispatchQueue.global().async {
        // A script that never reads its stdin must not hold the run up: the write is its own.
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
      }
      var outData = Data()
      let handle = stdout.fileHandleForReading
      while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        if outData.count < outputLimit { outData.append(chunk.prefix(outputLimit - outData.count)) }
      }
      process.waitUntilExit()
      group.wait()
      timer.cancel()
      let result = Result(
        status: process.terminationStatus, stdout: outData, stderr: errData,
        timedOut: timedOut.isSet)
      DispatchQueue.main.async { completion(.success(result)) }
    }
  }
}

private final class TimeoutFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func set() { lock.withLock { value = true } }
  var isSet: Bool { lock.withLock { value } }
}
