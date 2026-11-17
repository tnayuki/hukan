import Foundation

/// The road the `hukan` helper takes from a hukan terminal: a Unix socket whose path the terminal
/// is spawned with (`HUKAN_EDIT_SOCKET`), the way an editor's integrated terminal hands its CLI a
/// socket of its own. The Apple event it used to send is refused from inside (`AppleEventGate`),
/// and this road reaches one thing only — opening a path, and holding the answer until its tab
/// closes, which is `$EDITOR`'s contract — so anything that finds it can do no more than show a
/// file.
///
/// A request is three fields, each ended by a NUL — the terminal's TERM_SESSION_ID, `1` to wait
/// or `0` not to, the absolute path — so a path may hold any byte but NUL, which no path does. The
/// answer is one line: `opened`, `closed`, or `error: ` and why.
enum EditSocket {
  /// Where the socket is, once it is up: in this user's temporary directory, which no other user
  /// can enter, and named for this process, so the Dev build and the released one each have
  /// their own.
  private(set) static var path: String?
  private static var listener: DispatchSourceRead?
  private static var connections: [Int32: Connection] = [:]

  static func start() {
    guard path == nil else { return }
    let candidate = (NSTemporaryDirectory() as NSString)
      .appendingPathComponent("hukan-\(getpid()).sock")
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(candidate.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    unlink(candidate)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, chmod(candidate, 0o600) == 0, listen(fd, 8) == 0 else {
      close(fd)
      unlink(candidate)
      return
    }
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    source.setEventHandler { accept(on: fd) }
    source.resume()
    listener = source
    path = candidate
  }

  /// Take the socket's file away with the process, so a stale one is not left for the next pid.
  static func stop() {
    if let path { unlink(path) }
  }

  private static func accept(on listening: Int32) {
    let fd = Darwin.accept(listening, nil, nil)
    guard fd >= 0 else { return }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let connection = Connection(fd: fd)
    connections[fd] = connection
    connection.read { fields in
      guard let fields else { return finish(fd) }
      let outcome = EditRequest.open(
        fields[2], fromTerminal: fields[0], rendered: false, waiting: fields[1] == "1")
      switch outcome {
      case .opened: answer(fd, "opened")
      case .failed(let message): answer(fd, "error: " + message)
      case .waiting(let worktreeID, let path):
        EditWaiters.wait(worktreeID: worktreeID, path: path) { answer(fd, "closed") }
      }
    }
  }

  private static func answer(_ fd: Int32, _ line: String) {
    guard connections[fd] != nil else { return }
    let bytes = Array((line + "\n").utf8)
    _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    finish(fd)
  }

  private static func finish(_ fd: Int32) {
    guard let connection = connections.removeValue(forKey: fd) else { return }
    connection.cancel()
  }

  /// One helper's request, read until its third NUL.
  private final class Connection {
    let fd: Int32
    private var source: DispatchSourceRead?
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    /// Hand over the three fields once they have all arrived, or nil when the helper hangs up
    /// first or sends something that is not a request.
    func read(_ done: @escaping ([String]?) -> Void) {
      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
      source.setEventHandler { [weak self] in
        guard let self else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(self.fd, &chunk, chunk.count)
        guard count > 0, self.buffer.count < 64 * 1024 else {
          self.source?.cancel()
          self.source = nil
          return done(nil)
        }
        self.buffer.append(contentsOf: chunk[0..<count])
        let parts = self.buffer.split(separator: 0, omittingEmptySubsequences: false)
        guard parts.count > 3 else { return }
        // Read no further: the answer is all that is left to say on this connection.
        self.source?.cancel()
        self.source = nil
        let fields = parts.prefix(3).map { String(decoding: $0, as: UTF8.self) }
        done(fields[1] == "0" || fields[1] == "1" ? fields : nil)
      }
      source.resume()
      self.source = source
    }

    func cancel() {
      source?.cancel()
      close(fd)
    }
  }
}
