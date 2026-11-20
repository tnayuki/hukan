import Darwin
import Foundation

/// What runs between a GPU machine's device in this process (`GPUDevice`) and its renderer, which
/// runs in a process of its own (`GPURenderer`): this executable started again with
/// `launchArgument`, one per machine. gfxstream is one renderer per process — its resource and
/// context ids are global, and a guest names them in what it sends — so a process each is what lets
/// two GPU machines run at once.
///
/// Two channels. A socket, inherited as fd 3, carries everything that is bytes: the guest's
/// virtio-gpu requests on the way in, the answers and the frames on the way out, and the save and
/// the restore. Mach carries what is rights rather than bytes — guest RAM, handed over once as a
/// memory entry; the IOSurfaces the renderer draws the guest's screen into; and each blob the guest
/// maps, as a memory entry of its pages, since only this process can put them in the guest — through
/// a bootstrap name this process checks in under and the renderer looks up (the rendezvous Chromium
/// uses for its children).
enum GPULink {
  static let launchArgument = "--gpu-renderer"

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
    /// → renderer: snapshot into the directory the payload names; answered by `saved`.
    case save
    /// ← renderer: the snapshot is written; `value` is 0, or the renderer's failure.
    case saved
    /// → renderer: come back from the snapshot in the directory the payload names; answered by
    /// `restored`.
    case restore
    /// ← renderer: restored; `value` is 0, or the renderer's failure.
    case restored
    /// → renderer: hand over resource `value`'s blob again (a `BlobMessage` with `tag`), for a
    /// restore to map it where it was.
    case exportBlob
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
      while buffer.count >= GPULink.headerSize {
        let start = buffer.startIndex
        func u32(_ offset: Int) -> UInt32 {
          buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        let length = Int(u32(16))
        guard buffer.count >= GPULink.headerSize + length else { break }
        let tag = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
        if let kind = Kind(rawValue: u32(0)) {
          let payload = buffer.subdata(
            in: (start + GPULink.headerSize)..<(start + GPULink.headerSize + length))
          frames.append(Frame(kind: kind, value: u32(4), tag: tag, payload: payload))
        }
        buffer.removeSubrange(start..<(start + GPULink.headerSize + length))
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

    /// Everything queued, written before returning: what a save or restore sends and then waits
    /// for an answer to, on the queue the answer would otherwise come in on.
    func drain() {
      while !buffers.isEmpty {
        flush()
        if !buffers.isEmpty {
          var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
          guard Darwin.poll(&poller, 1, 1000) >= 0 || errno == EINTR else { return }
        }
      }
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

  /// A blob for the guest: its pages as a memory entry, and what to do with them. `tag` is the
  /// element of the RESOURCE_MAP_BLOB being answered (`response`, written into it once the pages
  /// are in the guest), or of an `exportBlob`.
  struct BlobMessage {
    var header = mach_msg_header_t()
    var body = mach_msg_body_t()
    var entry = mach_msg_port_descriptor_t()
    var tag: UInt64 = 0
    var resource: UInt32 = 0
    var reserved: UInt32 = 0
    var offset: UInt64 = 0
    var size: UInt64 = 0
    /// virtio_gpu_resp_map_info: the header, map_info and padding.
    var response = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
  }

  /// Big enough for either message, and the trailer the kernel adds.
  struct Received {
    var blob = BlobMessage()
    var trailer = mach_msg_trailer_t()
  }

  static let helloID: Int32 = 1
  static let memoryID: Int32 = 2
  static let surfacesID: Int32 = 3
  static let blobID: Int32 = 4

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
    if ports.count > 0 { message.ports.0 = descriptor(ports[0], disposition) }
    if ports.count > 1 { message.ports.1 = descriptor(ports[1], disposition) }
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

  /// Send a blob's memory entry, moved: the receiver ends up with the one right to it.
  @discardableResult
  static func send(_ blob: BlobMessage, entry: mach_port_t, to remote: mach_port_t)
    -> kern_return_t
  {
    var message = blob
    message.header.msgh_bits = UInt32(MACH_MSG_TYPE_COPY_SEND) | MACH_MSGH_BITS_COMPLEX
    message.header.msgh_remote_port = remote
    message.header.msgh_local_port = 0
    message.header.msgh_id = blobID
    message.body.msgh_descriptor_count = 1
    message.entry = descriptor(entry, UInt32(MACH_MSG_TYPE_MOVE_SEND))
    let size = MemoryLayout<BlobMessage>.size
    message.header.msgh_size = mach_msg_size_t(size)
    return withUnsafeMutableBytes(of: &message) {
      mach_msg(
        $0.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self), MACH_SEND_MSG,
        mach_msg_size_t(size), 0, 0, 0, 0)
    }
  }

  private static func descriptor(_ port: mach_port_t, _ disposition: UInt32)
    -> mach_msg_port_descriptor_t
  {
    var d = mach_msg_port_descriptor_t()
    d.name = port
    d.disposition = disposition
    d.type = UInt32(MACH_MSG_PORT_DESCRIPTOR)
    return d
  }

  /// One message waited for on `port`: its id, the rights it carried, its reply port, and — for a
  /// blob — the whole of it.
  struct Message {
    var id: Int32
    var ports: [mach_port_t]
    var reply: mach_port_t
    var blob: BlobMessage?
  }

  static func receive(on port: mach_port_t) -> Message? {
    var received = Received()
    let result = withUnsafeMutableBytes(of: &received) {
      mach_msg(
        $0.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self), MACH_RCV_MSG, 0,
        mach_msg_size_t(MemoryLayout<Received>.size), port, 0, 0)
    }
    guard result == KERN_SUCCESS else { return nil }
    let header = received.blob.header
    if header.msgh_id == blobID {
      return Message(
        id: blobID, ports: [received.blob.entry.name], reply: header.msgh_remote_port,
        blob: received.blob)
    }
    // Any other message is a PortMessage, laid over the same bytes.
    let message = withUnsafeBytes(of: &received) { $0.loadUnaligned(as: PortMessage.self) }
    var ports: [mach_port_t] = []
    if header.msgh_bits & MACH_MSGH_BITS_COMPLEX != 0 {
      let count = message.body.msgh_descriptor_count
      if count > 0 { ports.append(message.ports.0.name) }
      if count > 1 { ports.append(message.ports.1.name) }
    }
    return Message(id: header.msgh_id, ports: ports, reply: header.msgh_remote_port, blob: nil)
  }
}

extension Data {
  func u32(_ offset: Int) -> UInt32 {
    withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
  }
  func u64(_ offset: Int) -> UInt64 {
    withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
  }
  mutating func put32(_ value: UInt32) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }
  mutating func put64(_ value: UInt64) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }
}
