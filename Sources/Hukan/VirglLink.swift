import Darwin
import Foundation

/// What runs between a GPU machine's device in this process (`VirglGPU`) and its renderer, which
/// runs in a process of its own (`VirglRenderer`): this executable started again with
/// `launchArgument`, one per machine. virglrenderer is one renderer per process — its resource and
/// context ids are global, and a guest writes them into its command stream — so a process each is
/// what lets two GPU machines run at once.
///
/// Two channels. A socket, inherited as fd 3, carries everything that is bytes: the guest's
/// virtio-gpu requests on the way in, the answers and the frames on the way out. Mach carries the
/// two things that are rights rather than bytes — guest RAM, handed over once as a memory entry, and
/// the IOSurfaces the renderer draws the guest's screen into — through a bootstrap name this process
/// checks in under and the renderer looks up (the rendezvous Chromium uses for its children).
enum VirglLink {
  static let launchArgument = "--virgl-renderer"

  /// Where both halves write what went wrong: the device here, and the renderer, whose stderr it is.
  static let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/hukan-gpu.log")

  static func note(_ message: String) {
    let line = "\(Date()) [\(getpid())] \(message)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    } else {
      try? Data(line.utf8).write(to: logURL)
    }
  }
  /// The descriptor the socket is inherited as in the renderer.
  static let socketDescriptor: Int32 = 3

  enum Kind: UInt32 {
    /// → renderer: a virtio-gpu request; `value` is the virtqueue, `tag` names the element.
    case request = 1
    /// → renderer: the screen's size in pixels; `value` is width << 16 | height.
    case display
    /// ← renderer: the answer for `tag`, to be written into its element.
    case response
    /// ← renderer: a frame is in the IOSurface whose id is `value`.
    case frame
    /// ← renderer: the cursor: `value` is hot x << 16 | hot y, the payload width, height and BGRA
    /// pixels (none hides it).
    case cursorImage
    /// ← renderer: the cursor's position; `value` is x << 16 | y, as signed 16-bit halves.
    case cursorMove
    /// ← renderer: the guest has read the screen's new size; the device's event can be cleared.
    case displayRead
  }

  struct Frame {
    var kind: Kind
    var value: UInt32
    var tag: UInt64
    var payload: Data
  }

  private static let headerSize = 20

  static func encode(_ kind: Kind, value: UInt32 = 0, tag: UInt64 = 0, payload: Data = Data())
    -> Data
  {
    var data = Data(capacity: headerSize + payload.count)
    for word in [kind.rawValue, value] {
      Swift.withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
    }
    Swift.withUnsafeBytes(of: tag.littleEndian) { data.append(contentsOf: $0) }
    Swift.withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
    data.append(payload)
    return data
  }

  /// Frames out of a stream that arrives in pieces.
  final class Reader {
    private var buffer = Data()
    func feed(_ bytes: Data) -> [Frame] {
      buffer.append(bytes)
      var frames: [Frame] = []
      while buffer.count >= VirglLink.headerSize {
        let start = buffer.startIndex
        func u32(_ offset: Int) -> UInt32 {
          buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        let length = Int(u32(16))
        guard buffer.count >= VirglLink.headerSize + length else { break }
        let tag = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
        if let kind = Kind(rawValue: u32(0)) {
          let payload = buffer.subdata(
            in: (start + VirglLink.headerSize)..<(start + VirglLink.headerSize + length))
          frames.append(Frame(kind: kind, value: u32(4), tag: tag, payload: payload))
        }
        buffer.removeSubrange(start..<(start + VirglLink.headerSize + length))
      }
      return frames
    }
  }

  /// A nonblocking, ordered writer. Reading and lifecycle callbacks must keep running when the
  /// peer's socket is full; waiting here can deadlock two peers that are both sending.
  /// All methods run on the socket's serial queue. The owner closes the descriptor after cancel.
  final class Writer {
    private let descriptor: Int32
    private let queue: DispatchQueue
    private let onFailure: () -> Void
    private var source: DispatchSourceWrite?
    private var buffers: [Data] = []
    private var offset = 0

    init(descriptor: Int32, queue: DispatchQueue, onFailure: @escaping () -> Void) {
      self.descriptor = descriptor
      self.queue = queue
      self.onFailure = onFailure
      _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }

    func send(_ data: Data) {
      buffers.append(data)
      flush()
    }

    private func flush() {
      while let data = buffers.first {
        let count = data.withUnsafeBytes {
          Darwin.send(descriptor, $0.baseAddress! + offset, $0.count - offset, MSG_NOSIGNAL)
        }
        if count < 0, errno == EINTR { continue }
        if count < 0, errno == EAGAIN {
          if source == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.flush() }
            self.source = source
            source.resume()
          }
          return
        }
        guard count > 0 else {
          cancel()
          onFailure()
          return
        }
        offset += count
        if offset == data.count {
          buffers.removeFirst()
          offset = 0
        }
      }
      source?.cancel()
      source = nil
    }

    func cancel() {
      source?.cancel()
      source = nil
      buffers.removeAll()
      offset = 0
    }
  }

  /// What is waiting on the socket, or nil at its end.
  static func read(from descriptor: Int32) -> Data? {
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    let count = Darwin.read(descriptor, &chunk, chunk.count)
    if count < 0 { return errno == EAGAIN || errno == EINTR ? Data() : nil }
    return count == 0 ? nil : Data(chunk[0..<count])
  }

  // MARK: Mach

  // Not in Swift's view of Darwin, but plain C symbols in libSystem.
  @_silgen_name("bootstrap_check_in")
  static func bootstrapCheckIn(
    _ bootstrap: mach_port_t, _ name: UnsafePointer<CChar>,
    _ service: UnsafeMutablePointer<mach_port_t>
  ) -> kern_return_t
  @_silgen_name("bootstrap_look_up")
  static func bootstrapLookUp(
    _ bootstrap: mach_port_t, _ name: UnsafePointer<CChar>,
    _ service: UnsafeMutablePointer<mach_port_t>
  ) -> kern_return_t

  /// A message carrying up to two port rights, laid out as the kernel reads one.
  struct PortMessage {
    var header = mach_msg_header_t()
    var body = mach_msg_body_t()
    var ports = (mach_msg_port_descriptor_t(), mach_msg_port_descriptor_t())
  }
  struct ReceivedPortMessage {
    var message = PortMessage()
    var trailer = mach_msg_trailer_t()
  }

  static let helloID: Int32 = 1
  static let memoryID: Int32 = 2
  static let surfacesID: Int32 = 3

  /// Send `ports` (copied, not moved) to `remote`; the message's own reply port is `reply`.
  @discardableResult
  static func send(
    _ ports: [mach_port_t], id: Int32, to remote: mach_port_t, reply: mach_port_t = 0,
    disposition: UInt32 = UInt32(MACH_MSG_TYPE_COPY_SEND)
  ) -> kern_return_t {
    var message = PortMessage()
    let replyBits: UInt32 = reply == 0 ? 0 : UInt32(MACH_MSG_TYPE_MAKE_SEND)
    message.header.msgh_bits =
      UInt32(MACH_MSG_TYPE_COPY_SEND) | (replyBits << 8)
      | (ports.isEmpty ? 0 : MACH_MSGH_BITS_COMPLEX)
    message.header.msgh_remote_port = remote
    message.header.msgh_local_port = reply
    message.header.msgh_id = id
    message.body.msgh_descriptor_count = UInt32(ports.count)
    func descriptor(_ port: mach_port_t) -> mach_msg_port_descriptor_t {
      var d = mach_msg_port_descriptor_t()
      d.name = port
      d.disposition = disposition
      d.type = UInt32(MACH_MSG_PORT_DESCRIPTOR)
      return d
    }
    if ports.count > 0 { message.ports.0 = descriptor(ports[0]) }
    if ports.count > 1 { message.ports.1 = descriptor(ports[1]) }
    let size =
      ports.isEmpty
      ? MemoryLayout<mach_msg_header_t>.size
      : MemoryLayout<mach_msg_header_t>.size + MemoryLayout<mach_msg_body_t>.size + ports.count
        * MemoryLayout<mach_msg_port_descriptor_t>.size
    message.header.msgh_size = mach_msg_size_t(size)
    // The whole message, not `&message.header`: a pointer to one field of a struct may be to a
    // copy of that field alone, and the kernel reads on past it.
    return withUnsafeMutableBytes(of: &message) {
      mach_msg(
        $0.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self), MACH_SEND_MSG,
        mach_msg_size_t(size), 0, 0, 0, 0)
    }
  }

  /// Wait on `port` for one message: its id, the rights it carried, and its reply port.
  static func receive(on port: mach_port_t) -> (
    id: Int32, ports: [mach_port_t], reply: mach_port_t
  )? {
    var message = ReceivedPortMessage()
    let result = withUnsafeMutableBytes(of: &message) {
      mach_msg(
        $0.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self), MACH_RCV_MSG, 0,
        mach_msg_size_t(MemoryLayout<ReceivedPortMessage>.size), port, 0, 0)
    }
    guard result == KERN_SUCCESS else { return nil }
    var ports: [mach_port_t] = []
    if message.message.header.msgh_bits & MACH_MSGH_BITS_COMPLEX != 0 {
      let count = message.message.body.msgh_descriptor_count
      if count > 0 { ports.append(message.message.ports.0.name) }
      if count > 1 { ports.append(message.message.ports.1.name) }
    }
    return (message.message.header.msgh_id, ports, message.message.header.msgh_remote_port)
  }
}
