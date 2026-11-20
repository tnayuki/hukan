import Cgfxstream
import Foundation
import IOSurface

/// A GPU machine's renderer: this executable started with `GPULink.launchArgument`, one process per
/// machine (`GPULink` says why). It is handed guest RAM once, then reads the guest's virtio-gpu
/// requests off its socket and plays them through gfxstream, whose Vulkan runs on KosmicKrisp —
/// Mesa's Vulkan on Metal, in Contents/Frameworks, loaded directly with no Vulkan loader. The guest
/// sends Vulkan: its own Mesa turns its OpenGL into Vulkan (Zink) before it leaves the guest.
///
/// Blobs the guest maps are handed to the device's process as memory entries of their pages, since
/// only that process can put them in the guest's address space. What the guest scans out is read
/// back into IOSurfaces the device's process shows.
enum GPURendererProcess {
  private static var parentExit: DispatchSourceProcess?

  /// `--gpu-renderer <bootstrap name> <RAM base> <RAM size> <width> <height>`, the socket on fd 3.
  static func run() -> Never {
    // Socket EOF alone cannot stop a renderer stuck inside the driver or a Mach handshake.
    let parent = getppid()
    guard parent != 1 else { exit(0) }
    let source = DispatchSource.makeProcessSource(
      identifier: parent, eventMask: .exit, queue: DispatchQueue.global())
    source.setEventHandler { exit(0) }
    parentExit = source
    source.resume()
    guard getppid() == parent else { exit(0) }
    let arguments = CommandLine.arguments
    guard arguments.count >= 7, let base = UInt64(arguments[3]), let size = UInt64(arguments[4]),
      let width = UInt32(arguments[5]), let height = UInt32(arguments[6])
    else { fail(64, "bad arguments \(arguments)") }
    var service: mach_port_t = 0
    let lookedUp = GPULink.bootstrapLookUp(bootstrap_port, arguments[2], &service)
    guard lookedUp == KERN_SUCCESS else { fail(69, "bootstrap_look_up -> \(lookedUp)") }
    var reply: mach_port_t = 0
    mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &reply)
    GPULink.send([], id: GPULink.helloID, to: service, reply: reply)
    guard let memory = GPULink.receive(on: reply), memory.id == GPULink.memoryID,
      let entry = memory.ports.first
    else { fail(70, "no guest RAM from the device") }
    var address: mach_vm_address_t = 0
    guard
      mach_vm_map(
        mach_task_self_, &address, mach_vm_size_t(size), 0, VM_FLAGS_ANYWHERE, entry, 0, 0,
        VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE)
        == KERN_SUCCESS, let ram = UnsafeMutableRawPointer(bitPattern: UInt(address))
    else { fail(71, "could not map guest RAM (\(size) bytes)") }
    let renderer = GPURenderer(
      ram: ram, base: base, size: size, service: service, width: width, height: height)
    renderer.start()
    dispatchMain()
  }

  static func fail(_ code: Int32, _ why: String) -> Never {
    FileHandle.standardError.write(Data("\(Date()) [\(getpid())] renderer: \(why)\n".utf8))
    exit(code)
  }
}

final class GPURenderer {
  // MARK: The wire

  enum Command: UInt32 {
    case getDisplayInfo = 0x0100
    case resourceCreate2D, resourceUnref, setScanout, resourceFlush,
      transferToHost2D, resourceAttachBacking, resourceDetachBacking, getCapsetInfo, getCapset,
      getEDID, resourceAssignUUID, resourceCreateBlob, setScanoutBlob
    case contextCreate = 0x0200
    case contextDestroy, contextAttachResource, contextDetachResource,
      resourceCreate3D, transferToHost3D, transferFromHost3D, submit3D, resourceMapBlob,
      resourceUnmapBlob
    case updateCursor = 0x0300
    case moveCursor
  }
  static let okNoData: UInt32 = 0x1100
  static let okDisplayInfo: UInt32 = 0x1101
  static let okCapsetInfo: UInt32 = 0x1102
  static let okCapset: UInt32 = 0x1103
  static let okMapInfo: UInt32 = 0x1106
  static let errUnspecified: UInt32 = 0x1200
  static let flagFence: UInt32 = 1
  static let flagRingIndex: UInt32 = 2
  /// The one capset offered: gfxstream's Vulkan.
  static let capsetGfxstreamVulkan: UInt32 = 3

  // MARK: State

  private let queue = DispatchQueue(label: "hukan.gpu.renderer")
  private let socket = GPULink.socketDescriptor
  private let reader = GPULink.Reader()
  private var readSource: DispatchSourceRead?
  private var writer: GPULink.Writer?
  private let ram: UnsafeMutableRawPointer
  private let base: UInt64
  private let size: UInt64
  private let service: mach_port_t
  private var width: UInt32
  private var height: UInt32

  /// Answers waiting on a fence, by the timeline it is on: a context's ring, or the global one,
  /// which gfxstream reports as context 0.
  private struct Timeline: Hashable {
    var context: UInt32
    var ring: UInt32
  }
  private struct Pending {
    let tag: UInt64
    let response: Data
    let fence: UInt64
  }
  private var pending: [Timeline: [Pending]] = [:]
  /// The iovec arrays handed to gfxstream, which keeps them rather than copying, with the guest
  /// addresses they came from — what a restore attaches again.
  private var backings: [UInt32: (vectors: UnsafeMutableBufferPointer<iovec>, guest: [[UInt64]])] =
    [:]
  /// What the scanout shows: a resource, and for a blob, how its pixels lie in it.
  private struct Scanout: Codable {
    var resource: UInt32 = 0
    var blob: Bool = false
    var width: UInt32 = 0
    var height: UInt32 = 0
    var stride: UInt32 = 0
    var offset: UInt32 = 0
  }
  private var scanout = Scanout()
  /// Resources gfxstream has mapped for the guest, to unmap with them.
  private var mapped: Set<UInt32> = []
  private static var features = strdup("VulkanBatchedDescriptorSetUpdate:disabled")

  init(
    ram: UnsafeMutableRawPointer, base: UInt64, size: UInt64, service: mach_port_t, width: UInt32,
    height: UInt32
  ) {
    self.ram = ram
    self.base = base
    self.size = size
    self.service = service
    self.width = width
    self.height = height
  }

  func start() {
    queue.async { [self] in
      Self.configureDriver()
      let cookie = Unmanaged.passUnretained(self).toOpaque()
      var parameters: [stream_renderer_param] = [
        stream_renderer_param(
          key: UInt64(STREAM_RENDERER_PARAM_USER_DATA), value: UInt64(UInt(bitPattern: cookie))),
        stream_renderer_param(
          key: UInt64(STREAM_RENDERER_PARAM_RENDERER_FLAGS),
          value: UInt64(STREAM_RENDERER_FLAGS_USE_VK_BIT.rawValue)),
        stream_renderer_param(
          key: UInt64(STREAM_RENDERER_PARAM_FENCE_CALLBACK),
          value: UInt64(
            UInt(bitPattern: unsafeBitCast(Self.fenceCallback, to: UnsafeRawPointer.self)))),
        stream_renderer_param(
          key: UInt64(STREAM_RENDERER_PARAM_DEBUG_CALLBACK),
          value: UInt64(
            UInt(bitPattern: unsafeBitCast(Self.debugCallback, to: UnsafeRawPointer.self)))),
        stream_renderer_param(
          key: UInt64(STREAM_RENDERER_PARAM_RENDERER_FEATURES),
          value: UInt64(UInt(bitPattern: Self.features))),
      ]
      guard stream_renderer_init(&parameters, UInt64(parameters.count)) == 0 else {
        GPURendererProcess.fail(72, "gfxstream did not start")
      }
      writer = GPULink.Writer(descriptor: socket, queue: queue) { exit(0) }
      let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
      source.setEventHandler { [weak self] in self?.readSocket() }
      source.resume()
      readSource = source
      GPULink.note("renderer: ready")
    }
  }

  /// Read by gfxstream and Mesa as they start, so set before the first call.
  private static func configureDriver() {
    // KosmicKrisp, loaded directly: gfxstream falls back to the driver's own entry point when the
    // library it opens is no Vulkan loader.
    setenv("ANDROID_EMU_VK_ICD", "kosmickrisp", 1)
    if let frameworks = Bundle.main.privateFrameworksURL {
      setenv(
        "ANDROID_EMU_VK_LOADER_PATH",
        frameworks.appendingPathComponent("libvulkan_kosmickrisp.dylib").path, 1)
    }
    // What a snapshot needs gfxstream to have kept from the start: what made each Vulkan object.
    setenv("ANDROID_GFXSTREAM_CAPTURE_VK_SNAPSHOT", "1", 1)
    // Compiled shaders are kept between runs, where a Mac app keeps a cache.
    if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
      let directory = caches.appendingPathComponent(
        "\(Bundle.main.bundleIdentifier ?? "hukan")/mesa", isDirectory: true)
      setenv("MESA_SHADER_CACHE_DIR", directory.path, 1)
    }
  }

  private static let fenceCallback:
    @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<stream_renderer_fence>?) -> Void =
      { cookie, fence in
        guard let cookie, let fence = fence?.pointee else { return }
        let renderer = Unmanaged<GPURenderer>.fromOpaque(cookie).takeUnretainedValue()
        let ringed = fence.flags & UInt32(STREAM_RENDERER_FLAG_FENCE_RING_IDX) != 0
        let timeline = Timeline(
          context: ringed ? fence.ctx_id : 0, ring: ringed ? UInt32(fence.ring_idx) : 0)
        renderer.queue.async { renderer.signalled(timeline, fence: fence.fence_id) }
      }

  private static let debugCallback:
    @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<stream_renderer_debug>?) -> Void =
      { _, debug in
        guard let debug = debug?.pointee, let message = debug.message,
          debug.debug_type <= UInt32(STREAM_RENDERER_DEBUG_WARN)
        else { return }
        GPULink.note("renderer: gfxstream: \(String(cString: message))")
      }

  private func readSocket() {
    guard let bytes = GPULink.read(from: socket) else { exit(0) }  // the machine has gone
    for frame in reader.feed(bytes) {
      switch frame.kind {
      case .request: handle(frame.payload, tag: frame.tag)
      case .display:
        width = frame.value >> 16
        height = frame.value & 0xFFFF
      case .save: save(to: String(decoding: frame.payload, as: UTF8.self))
      case .restore: restore(from: String(decoding: frame.payload, as: UTF8.self))
      case .exportBlob: _ = exportBlob(frame.value, tag: frame.tag, offset: 0, response: nil)
      default: break
      }
    }
  }

  private func send(
    _ kind: GPULink.Kind, value: UInt32 = 0, tag: UInt64 = 0, payload: Data = Data()
  ) {
    writer?.send(GPULink.encode(kind, value: value, tag: tag, payload: payload))
  }

  // MARK: Fences

  private func signalled(_ timeline: Timeline, fence: UInt64) {
    guard var waiting = pending[timeline] else { return }
    while let first = waiting.first, first.fence <= fence {
      waiting.removeFirst()
      send(.response, tag: first.tag, payload: first.response)
    }
    pending[timeline] = waiting.isEmpty ? nil : waiting
  }

  // MARK: Commands

  /// Guest pages as iovecs in this process's mapping of guest RAM; nil if any falls outside it.
  private func guestPages(_ guest: [[UInt64]]) -> UnsafeMutableBufferPointer<iovec>? {
    let vectors = UnsafeMutableBufferPointer<iovec>.allocate(capacity: max(guest.count, 1))
    for (i, page) in guest.enumerated() {
      let (address, length) = (page[0], page[1])
      guard address >= base, address + length <= base + size else {
        vectors.deallocate()
        return nil
      }
      vectors[i] = iovec(iov_base: ram + Int(address - base), iov_len: Int(length))
    }
    return vectors
  }

  /// The guest address and length of each entry in a request's list, from `start`.
  private static func entries(_ request: Data, at start: Int, count: Int) -> [[UInt64]]? {
    var entries: [[UInt64]] = []
    for i in 0..<count {
      let offset = start + i * 16
      guard offset + 16 <= request.count else { return nil }
      entries.append([request.u64(offset), UInt64(request.u32(offset + 8))])
    }
    return entries
  }

  private func detach(_ resource: UInt32) {
    guard let backing = backings.removeValue(forKey: resource) else { return }
    stream_renderer_resource_detach_iov(Int32(resource), nil, nil)
    backing.vectors.deallocate()
  }

  private func handle(_ request: Data, tag: UInt64) {
    guard request.count >= 24 else {
      send(.response, tag: tag)
      return
    }
    let flags = request.u32(4)
    let fence = request.u64(8)
    let context = request.u32(16)
    let ring = UInt32(request[request.startIndex + 20])
    let command = Command(rawValue: request.u32(0))
    var body = Data()
    var status = Self.okNoData

    switch command {
    case .getDisplayInfo:
      status = Self.okDisplayInfo
      for i in 0..<16 {
        for value in [0, 0, i == 0 ? width : 0, i == 0 ? height : 0, i == 0 ? 1 : 0, 0] as [UInt32]
        {
          body.put32(value)
        }
      }
      send(.displayRead)

    case .getCapsetInfo:
      var version: UInt32 = 0
      var capsetSize: UInt32 = 0
      let id = request.u32(24) == 0 ? Self.capsetGfxstreamVulkan : 0
      if id != 0 { stream_renderer_get_cap_set(id, &version, &capsetSize) }
      status = Self.okCapsetInfo
      for value in [id, version, capsetSize, 0] { body.put32(value) }

    case .getCapset:
      let id = request.u32(24)
      let version = request.u32(28)
      var maxVersion: UInt32 = 0
      var capsetSize: UInt32 = 0
      stream_renderer_get_cap_set(id, &maxVersion, &capsetSize)
      var caps = [UInt8](repeating: 0, count: Int(capsetSize))
      stream_renderer_fill_caps(id, version, &caps)
      status = Self.okCapset
      body.append(contentsOf: caps)

    case .contextCreate:
      let nameLength = request.u32(24)
      let name = request.subdata(in: 32..<(32 + Int(min(nameLength, 64))))
      let result = name.withUnsafeBytes {
        stream_renderer_context_create(
          context, nameLength, $0.baseAddress?.assumingMemoryBound(to: CChar.self),
          request.u32(28))
      }
      if result != 0 { status = Self.errUnspecified }

    case .contextDestroy:
      stream_renderer_context_destroy(context)
    case .contextAttachResource:
      stream_renderer_ctx_attach_resource(Int32(context), Int32(request.u32(24)))
    case .contextDetachResource:
      stream_renderer_ctx_detach_resource(Int32(context), Int32(request.u32(24)))

    case .resourceCreate2D:
      var arguments = stream_renderer_resource_create_args(
        handle: request.u32(24), target: 2, format: request.u32(28), bind: 1 << 1,
        width: request.u32(32), height: request.u32(36), depth: 1, array_size: 1, last_level: 0,
        nr_samples: 0, flags: 0)
      if stream_renderer_resource_create(&arguments, nil, 0) != 0 { status = Self.errUnspecified }

    case .resourceCreate3D:
      var arguments = stream_renderer_resource_create_args(
        handle: request.u32(24), target: request.u32(28), format: request.u32(32),
        bind: request.u32(36), width: request.u32(40), height: request.u32(44),
        depth: request.u32(48), array_size: request.u32(52), last_level: request.u32(56),
        nr_samples: request.u32(60), flags: request.u32(64))
      if stream_renderer_resource_create(&arguments, nil, 0) != 0 { status = Self.errUnspecified }

    case .resourceCreateBlob:
      // virtio_gpu_resource_create_blob: resource 24, mem 28, flags 32, entries 36, id 40, size 48.
      let resource = request.u32(24)
      guard let guest = Self.entries(request, at: 56, count: Int(request.u32(36))),
        let vectors = guestPages(guest)
      else {
        status = Self.errUnspecified
        break
      }
      var blob = stream_renderer_create_blob(
        blob_mem: request.u32(28), blob_flags: request.u32(32), blob_id: request.u64(40),
        size: request.u64(48))
      let result = stream_renderer_create_blob(
        context, resource, &blob, guest.isEmpty ? nil : vectors.baseAddress, UInt32(guest.count),
        nil)
      if result != 0 {
        vectors.deallocate()
        status = Self.errUnspecified
      } else if guest.isEmpty {
        vectors.deallocate()
      } else {
        backings[resource] = (vectors, guest)
      }

    case .resourceAttachBacking:
      let resource = request.u32(24)
      detach(resource)
      guard let guest = Self.entries(request, at: 32, count: Int(request.u32(28))),
        let vectors = guestPages(guest)
      else {
        status = Self.errUnspecified
        break
      }
      backings[resource] = (vectors, guest)
      if stream_renderer_resource_attach_iov(
        Int32(resource), vectors.baseAddress, Int32(guest.count))
        != 0
      {
        backings.removeValue(forKey: resource)?.vectors.deallocate()
        status = Self.errUnspecified
      }

    case .resourceDetachBacking:
      detach(request.u32(24))

    case .resourceUnref:
      let resource = request.u32(24)
      if mapped.remove(resource) != nil { stream_renderer_resource_unmap(resource) }
      detach(resource)
      stream_renderer_resource_unref(resource)
      if resource == scanout.resource { scanout = Scanout() }

    case .transferToHost2D:
      var box = stream_renderer_box(
        x: request.u32(24), y: request.u32(28), z: 0, w: request.u32(32), h: request.u32(36), d: 1)
      if stream_renderer_transfer_write_iov(
        request.u32(48), 0, 0, 0, 0, &box, request.u64(40), nil, 0)
        != 0
      {
        status = Self.errUnspecified
      }

    case .transferToHost3D, .transferFromHost3D:
      var box = stream_renderer_box(
        x: request.u32(24), y: request.u32(28), z: request.u32(32), w: request.u32(36),
        h: request.u32(40), d: request.u32(44))
      let offset = request.u64(48)
      let resource = request.u32(56)
      let level = request.u32(60)
      let stride = request.u32(64)
      let layerStride = request.u32(68)
      let result =
        command == .transferToHost3D
        ? stream_renderer_transfer_write_iov(
          resource, context, Int32(level), stride, layerStride, &box, offset, nil, 0)
        : stream_renderer_transfer_read_iov(
          resource, context, level, stride, layerStride, &box, offset, nil, 0)
      if result != 0 { status = Self.errUnspecified }

    case .submit3D:
      let length = Int(request.u32(24))
      guard 32 + length <= request.count else {
        status = Self.errUnspecified
        break
      }
      var commands = request.subdata(in: 32..<(32 + length))
      let result = commands.withUnsafeMutableBytes { buffer -> Int32 in
        var submitted = stream_renderer_command(
          ctx_id: context, cmd_size: UInt32(length),
          cmd: buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), num_in_fences: 0,
          fences: nil)
        return stream_renderer_submit_cmd(&submitted)
      }
      if result != 0 { status = Self.errUnspecified }

    case .resourceMapBlob:
      // Answered by the device once the pages are in the guest (`exportBlob`), not here.
      var response = Data()
      response.put32(Self.okMapInfo)
      response.put32(flags & (Self.flagFence | Self.flagRingIndex))
      response.put64(fence)
      response.put32(context)
      response.put32(ring)
      var mapInfo: UInt32 = 0
      stream_renderer_resource_map_info(request.u32(24), &mapInfo)
      response.put32(mapInfo & 0x0F)
      response.put32(0)
      if !exportBlob(request.u32(24), tag: tag, offset: request.u64(32), response: response) {
        status = Self.errUnspecified
        break
      }
      return

    case .resourceUnmapBlob:
      let resource = request.u32(24)
      if mapped.remove(resource) != nil { stream_renderer_resource_unmap(resource) }

    case .setScanout:
      // virtio_gpu_set_scanout: rect 24, scanout 40, resource 44.
      if request.u32(40) == 0 {
        scanout = Scanout(resource: request.u32(44))
        present()
      }

    case .setScanoutBlob:
      // virtio_gpu_set_scanout_blob: rect 24, scanout 40, resource 44, width 48, height 52,
      // format 56, padding 60, strides 64 (four), offsets 80 (four).
      if request.u32(40) == 0 {
        scanout = Scanout(
          resource: request.u32(44), blob: request.u32(44) != 0, width: request.u32(48),
          height: request.u32(52), stride: request.u32(64), offset: request.u32(80))
        present()
      }

    case .resourceFlush:
      if request.u32(40) == scanout.resource { present() }

    case .updateCursor, .moveCursor:
      // virtio_gpu_update_cursor: pos { scanout, x, y, pad } at 24, resource 40, hot_x 44, hot_y 48.
      let x = UInt32(UInt16(truncatingIfNeeded: Int32(bitPattern: request.u32(28))))
      let y = UInt32(UInt16(truncatingIfNeeded: Int32(bitPattern: request.u32(32))))
      if command == .updateCursor {
        let hot = (request.u32(44) & 0xFFFF) << 16 | (request.u32(48) & 0xFFFF)
        send(.cursorImage, value: hot, payload: cursorImage(request.u32(40)))
      }
      send(.cursorMove, value: x << 16 | y)
      // The cursor queue's requests take no answer: an empty one returns the element as it is.
      send(.response, tag: tag)
      return

    default:
      status = Self.errUnspecified
    }

    var response = Data()
    response.put32(status)
    response.put32(flags & (Self.flagFence | Self.flagRingIndex))
    response.put64(fence)
    response.put32(context)
    response.put32(ring)
    response.append(body)

    if flags & Self.flagFence != 0, status < Self.errUnspecified {
      // A fence without a ring is on gfxstream's global timeline, which it reports as context 0.
      let ringed = flags & Self.flagRingIndex != 0
      let timeline = Timeline(context: ringed ? context : 0, ring: ringed ? ring : 0)
      pending[timeline, default: []].append(Pending(tag: tag, response: response, fence: fence))
      var signal = stream_renderer_fence(
        flags: UInt32(STREAM_RENDERER_FLAG_FENCE)
          | (ringed ? UInt32(STREAM_RENDERER_FLAG_FENCE_RING_IDX) : 0),
        fence_id: fence, ctx_id: context, ring_idx: UInt8(ringed ? ring : 0))
      if stream_renderer_create_fence(&signal) != 0 { signalled(timeline, fence: fence) }
    } else {
      send(.response, tag: tag, payload: response)
    }
  }

  // MARK: Blobs

  /// Hand a blob's pages to the device as a memory entry, for it to map at `offset` of the shared
  /// memory region and answer the guest with `response` (none for a restore's remapping).
  private func exportBlob(_ resource: UInt32, tag: UInt64, offset: UInt64, response: Data?) -> Bool
  {
    var address: UnsafeMutableRawPointer?
    var length: UInt64 = 0
    guard stream_renderer_resource_map(resource, &address, &length) == 0, let address else {
      GPULink.note("renderer: resource \(resource) could not be mapped")
      return false
    }
    mapped.insert(resource)
    // The guest's pages are 4K and this Mac's 16K: the region maps whole pages of its own.
    let pages = (length + 16383) & ~UInt64(16383)
    var entrySize = memory_object_size_t(pages)
    var entry: mach_port_t = 0
    guard
      mach_make_memory_entry_64(
        mach_task_self_, &entrySize, memory_object_offset_t(UInt(bitPattern: address)),
        VM_PROT_READ | VM_PROT_WRITE | MAP_MEM_VM_SHARE, &entry, 0) == KERN_SUCCESS
    else {
      GPULink.note("renderer: no memory entry for resource \(resource)")
      return false
    }
    var message = GPULink.BlobMessage()
    message.tag = tag
    message.resource = resource
    message.offset = offset
    message.size = pages
    if let response {
      withUnsafeMutableBytes(of: &message.response) { response.copyBytes(to: $0) }
    }
    return GPULink.send(message, entry: entry, to: service) == KERN_SUCCESS
  }

  // MARK: Save and restore

  /// What gfxstream's snapshot does not hold: where each resource's guest pages were, and what the
  /// scanout showed.
  private struct State: Codable {
    var backings: [UInt32: [[UInt64]]]
    var scanout: Scanout
  }

  private func save(to directory: String) {
    let started = Date()
    try? FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)
    var result = stream_renderer_snapshot(directory)
    if result == 0 {
      let state = State(backings: backings.mapValues(\.guest), scanout: scanout)
      do {
        try JSONEncoder().encode(state).write(
          to: URL(fileURLWithPath: directory).appendingPathComponent("hukan.json"))
      } catch {
        result = -1
      }
    }
    GPULink.note(
      "renderer: snapshot -> \(result) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    send(.saved, value: UInt32(bitPattern: result))
  }

  private func restore(from directory: String) {
    let started = Date()
    var result = stream_renderer_restore(directory)
    if result == 0,
      let data = try? Data(
        contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("hukan.json")),
      let state = try? JSONDecoder().decode(State.self, from: data)
    {
      for (resource, guest) in state.backings {
        guard let vectors = guestPages(guest) else { continue }
        backings[resource] = (vectors, guest)
        if stream_renderer_resource_attach_iov(
          Int32(resource), vectors.baseAddress, Int32(guest.count)) != 0
        {
          backings.removeValue(forKey: resource)?.vectors.deallocate()
        }
      }
      scanout = state.scanout
    } else if result == 0 {
      result = -1
    }
    GPULink.note(
      "renderer: restore -> \(result) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    send(.restored, value: UInt32(bitPattern: result))
  }

  // MARK: The screen

  /// Two IOSurfaces taken in turn, so the one being shown is never the one being drawn into, and so
  /// handing over the other is what tells the layer there is a new frame.
  private var surfaces: [IOSurfaceRef] = []
  private var surfaceSize = (width: 0, height: 0)
  private var nextSurface = 0
  private var pixels = Data()

  private func makeSurfaces(width: Int, height: Int) {
    surfaces = (0..<2).compactMap { _ in
      IOSurfaceCreate(
        [
          kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
          kIOSurfacePixelFormat: 0x4247_5241,  // 'BGRA'
        ] as CFDictionary)
    }
    guard surfaces.count == 2 else { return }
    surfaceSize = (width, height)
    GPULink.send(
      surfaces.map { IOSurfaceCreateMachPort($0) }, id: GPULink.surfacesID, to: service,
      disposition: UInt32(MACH_MSG_TYPE_MOVE_SEND))
  }

  /// Read the scanout into the next IOSurface and say which. A blob's pixels are read where gfxstream
  /// maps it; anything else is read back through gfxstream, tightly packed, then laid into the
  /// surface's rows.
  private func present() {
    let resource = scanout.resource
    guard resource != 0 else { return }
    var info = stream_renderer_resource_info()
    let (width, height): (Int, Int)
    if scanout.blob {
      (width, height) = (Int(scanout.width), Int(scanout.height))
    } else {
      guard stream_renderer_resource_get_info(Int32(resource), &info) == 0 else { return }
      (width, height) = (Int(info.width), Int(info.height))
    }
    guard width > 0, height > 0 else { return }
    if surfaceSize != (width, height) { makeSurfaces(width: width, height: height) }
    guard surfaces.count == 2 else { return }
    let surface = surfaces[nextSurface]
    IOSurfaceLock(surface, [], nil)
    defer { IOSurfaceUnlock(surface, [], nil) }
    let destination = IOSurfaceGetBaseAddress(surface)
    let destinationStride = IOSurfaceGetBytesPerRow(surface)
    let row = width * 4
    if scanout.blob {
      var address: UnsafeMutableRawPointer?
      var length: UInt64 = 0
      guard stream_renderer_resource_map(resource, &address, &length) == 0, let address else {
        return
      }
      defer { if !mapped.contains(resource) { stream_renderer_resource_unmap(resource) } }
      let stride = Int(scanout.stride)
      let offset = Int(scanout.offset)
      guard offset + stride * (height - 1) + row <= Int(length) else { return }
      for y in 0..<height {
        (destination + y * destinationStride).copyMemory(
          from: address + offset + y * stride, byteCount: row)
      }
    } else {
      if pixels.count != row * height { pixels = Data(count: row * height) }
      let result = pixels.withUnsafeMutableBytes { buffer -> Int32 in
        var vector = iovec(iov_base: buffer.baseAddress, iov_len: buffer.count)
        var box = stream_renderer_box(x: 0, y: 0, z: 0, w: UInt32(width), h: UInt32(height), d: 1)
        return stream_renderer_transfer_read_iov(
          resource, 0, 0, UInt32(row), 0, &box, 0, &vector, 1)
      }
      guard result == 0 else { return }
      pixels.withUnsafeBytes { source in
        for y in 0..<height {
          (destination + y * destinationStride).copyMemory(
            from: source.baseAddress! + y * row, byteCount: row)
        }
      }
    }
    send(.frame, value: IOSurfaceGetID(surface))
    nextSurface ^= 1
  }

  /// The cursor is a small resource of its own: width, height and BGRA pixels, read back.
  private func cursorImage(_ resource: UInt32) -> Data {
    var info = stream_renderer_resource_info()
    guard resource != 0, stream_renderer_resource_get_info(Int32(resource), &info) == 0,
      info.width > 0, info.height > 0
    else { return Data() }
    let stride = Int(info.width) * 4
    var pixels = Data(count: stride * Int(info.height))
    let result = pixels.withUnsafeMutableBytes { buffer -> Int32 in
      var vector = iovec(iov_base: buffer.baseAddress, iov_len: buffer.count)
      var box = stream_renderer_box(x: 0, y: 0, z: 0, w: info.width, h: info.height, d: 1)
      return stream_renderer_transfer_read_iov(
        resource, 0, 0, UInt32(stride), 0, &box, 0, &vector, 1)
    }
    guard result == 0 else { return Data() }
    var payload = Data()
    payload.put32(info.width)
    payload.put32(info.height)
    payload.append(pixels)
    return payload
  }
}
