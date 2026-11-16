import Cvirglrenderer
import Foundation
import IOSurface
import OpenGL
import OpenGL.GL3

/// A GPU machine's renderer: this executable started with `VirglLink.launchArgument`, one process
/// per machine (`VirglLink` says why). It is handed guest RAM once, then reads the guest's
/// virtio-gpu requests off its socket and plays them through virglrenderer's vrend on macOS's
/// OpenGL — 4.1 core over Metal — through CGL contexts it hands vrend, since vrend has no CGL winsys
/// of its own. What the guest scans out is blitted into IOSurfaces the device's process shows.
enum VirglRendererProcess {
  private static var parentExit: DispatchSourceProcess?

  /// `--virgl-renderer <bootstrap name> <RAM base> <RAM size> <width> <height>`, the socket on fd 3.
  static func run() -> Never {
    // Socket EOF alone cannot stop a renderer stuck inside GL or a Mach handshake.
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
    let lookedUp = VirglLink.bootstrapLookUp(bootstrap_port, arguments[2], &service)
    guard lookedUp == KERN_SUCCESS else { fail(69, "bootstrap_look_up -> \(lookedUp)") }
    var reply: mach_port_t = 0
    mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &reply)
    VirglLink.send([], id: VirglLink.helloID, to: service, reply: reply)
    guard let memory = VirglLink.receive(on: reply), memory.id == VirglLink.memoryID,
      let entry = memory.ports.first
    else { fail(70, "no guest RAM from the device") }
    var address: mach_vm_address_t = 0
    guard
      mach_vm_map(
        mach_task_self_, &address, mach_vm_size_t(size), 0, VM_FLAGS_ANYWHERE, entry, 0, 0,
        VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE)
        == KERN_SUCCESS, let ram = UnsafeMutableRawPointer(bitPattern: UInt(address))
    else { fail(71, "could not map guest RAM (\(size) bytes)") }
    let renderer = VirglRenderer(
      ram: ram, base: base, size: size, service: service, width: width, height: height)
    renderer.start()
    dispatchMain()
  }

  static func fail(_ code: Int32, _ why: String) -> Never {
    FileHandle.standardError.write(Data("\(Date()) [\(getpid())] renderer: \(why)\n".utf8))
    exit(code)
  }
}

final class VirglRenderer {
  // MARK: The wire

  private enum Command: UInt32 {
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
  private static let okNoData: UInt32 = 0x1100
  private static let okDisplayInfo: UInt32 = 0x1101
  private static let okCapsetInfo: UInt32 = 0x1102
  private static let okCapset: UInt32 = 0x1103
  private static let errUnspecified: UInt32 = 0x1200
  private static let flagFence: UInt32 = 1
  /// VIRGL and VIRGL2: the two capsets vrend answers.
  static let capsets: [UInt32] = [1, 2]

  // MARK: State

  private let queue = DispatchQueue(label: "hukan.virgl.renderer")
  private let socket = VirglLink.socketDescriptor
  private let reader = VirglLink.Reader()
  private var readSource: DispatchSourceRead?
  private var writer: VirglLink.Writer?
  private var pollScheduled = false
  private var nextFence: UInt32 = 0
  private let ram: UnsafeMutableRawPointer
  private let base: UInt64
  private let size: UInt64
  private let service: mach_port_t
  private var width: UInt32
  private var height: UInt32

  private struct Pending {
    let tag: UInt64
    let response: Data
    let fence: UInt64
    let submitted = Date()
  }
  private var lastFenceWarning = Date.distantPast
  private var pending: [Pending] = []
  /// The iovec arrays handed to vrend, which keeps them rather than copying: one per resource,
  /// freed once detached. Their pages are guest RAM, in this process's mapping of it.
  private var backings: [UInt32: UnsafeMutableBufferPointer<iovec>] = [:]
  private var scanoutResource: UInt32 = 0

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
      // vrend declares integer vertex inputs as integers only on an ARM GPU unless told to, and
      // macOS's OpenGL does not forgive a float input fed integers.
      setenv("VIRGL_USE_INTEGER", "1", 1)
      guard virgl_renderer_init(Unmanaged.passUnretained(self).toOpaque(), 0, &Self.callbacks) == 0
      else { VirglRendererProcess.fail(72, "virglrenderer did not start") }
      writer = VirglLink.Writer(descriptor: socket, queue: queue) { exit(0) }
      let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
      source.setEventHandler { [weak self] in self?.readSocket() }
      source.resume()
      readSource = source
      VirglLink.note("renderer: ready")
    }
  }

  private func readSocket() {
    guard let bytes = VirglLink.read(from: socket) else { exit(0) }  // the machine has gone
    makeCurrent()
    for frame in reader.feed(bytes) {
      switch frame.kind {
      case .request: handle(frame.payload, tag: frame.tag)
      case .display:
        width = frame.value >> 16
        height = frame.value & 0xFFFF
      default: break
      }
    }
    poll()
  }

  private func send(
    _ kind: VirglLink.Kind, value: UInt32 = 0, tag: UInt64 = 0, payload: Data = Data()
  ) {
    writer?.send(VirglLink.encode(kind, value: value, tag: tag, payload: payload))
  }

  // MARK: CGL, for vrend

  private static let pixelFormat: CGLPixelFormatObj? = {
    let attributes: [CGLPixelFormatAttribute] = [
      kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_GL4_Core.rawValue)),
      kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, CGLPixelFormatAttribute(0),
    ]
    var format: CGLPixelFormatObj?
    var count: GLint = 0
    CGLChoosePixelFormat(attributes, &format, &count)
    return format
  }()
  /// The first context vrend asks for; every later one, and the blit's, shares objects with it.
  private var shareContext: CGLContextObj?
  /// The context vrend last made current. CGL's current context is per thread and a serial queue
  /// runs on whichever thread it gets, so every block here puts it back before touching GL.
  private var currentContext: CGLContextObj?
  private func makeCurrent() {
    if CGLGetCurrentContext() != currentContext { CGLSetCurrentContext(currentContext) }
  }

  private static var callbacks: virgl_renderer_callbacks = {
    var callbacks = virgl_renderer_callbacks()
    callbacks.version = 1
    callbacks.write_fence = { cookie, fence in
      guard let cookie else { return }
      Unmanaged<VirglRenderer>.fromOpaque(cookie).takeUnretainedValue().signalled(UInt64(fence))
    }
    callbacks.create_gl_context = { cookie, _, parameters in
      guard let cookie, let p = parameters?.pointee, let format = VirglRenderer.pixelFormat else {
        return nil
      }
      // CGL offers 4.1 core and nothing above it, and no compatibility profile past 2.1.
      if p.compat_ctx != 0 || p.major_ver > 4 || (p.major_ver == 4 && p.minor_ver > 1) {
        return nil
      }
      let renderer = Unmanaged<VirglRenderer>.fromOpaque(cookie).takeUnretainedValue()
      var context: CGLContextObj?
      guard
        CGLCreateContext(format, p.shared ? renderer.shareContext : nil, &context) == kCGLNoError,
        let context
      else { return nil }
      if renderer.shareContext == nil { renderer.shareContext = context }
      return UnsafeMutableRawPointer(context)
    }
    callbacks.destroy_gl_context = { cookie, context in
      guard let cookie, let context else { return }
      let renderer = Unmanaged<VirglRenderer>.fromOpaque(cookie).takeUnretainedValue()
      let cgl = context.assumingMemoryBound(to: _CGLContextObject.self)
      if renderer.currentContext == cgl {
        CGLSetCurrentContext(nil)
        renderer.currentContext = nil
      }
      CGLDestroyContext(cgl)
    }
    callbacks.make_current = { cookie, _, context in
      guard let cookie else { return -1 }
      let renderer = Unmanaged<VirglRenderer>.fromOpaque(cookie).takeUnretainedValue()
      let cgl = context?.assumingMemoryBound(to: _CGLContextObject.self)
      renderer.currentContext = cgl
      return CGLSetCurrentContext(cgl) == kCGLNoError ? 0 : -1
    }
    return callbacks
  }()

  // MARK: Fences

  /// Without its sync thread (it needs eventfd) vrend signals fences only when polled.
  private func poll() {
    guard !pending.isEmpty, !pollScheduled else { return }
    if let first = pending.first, Date().timeIntervalSince(first.submitted) >= 5,
      Date().timeIntervalSince(lastFenceWarning) >= 5
    {
      lastFenceWarning = Date()
      VirglLink.note("renderer: waiting for fence \(first.fence), \(pending.count) pending")
    }
    makeCurrent()
    virgl_renderer_poll()
    guard !pending.isEmpty else { return }
    pollScheduled = true
    queue.asyncAfter(deadline: .now() + .microseconds(500)) { [weak self] in
      guard let self else { return }
      self.pollScheduled = false
      self.poll()
    }
  }

  private func signalled(_ fence: UInt64) {
    guard let index = pending.firstIndex(where: { $0.fence == fence }) else { return }
    let completed = Array(pending[...index])
    pending.removeFirst(index + 1)
    for first in completed {
      send(.response, tag: first.tag, payload: first.response)
    }
  }

  // MARK: Commands

  /// Guest pages as iovecs in this process's mapping of guest RAM; nil if any falls outside it.
  private func guestPages(_ request: Data, at start: Int, count: Int) -> [iovec]? {
    var vectors: [iovec] = []
    for i in 0..<count {
      let offset = start + i * 16
      guard offset + 16 <= request.count else { return nil }
      let address = request.u64(offset)
      let length = UInt64(request.u32(offset + 8))
      guard address >= base, address + length <= base + size else { return nil }
      vectors.append(iovec(iov_base: ram + Int(address - base), iov_len: Int(length)))
    }
    return vectors
  }

  private func detach(_ resource: UInt32) {
    virgl_renderer_resource_detach_iov(Int32(resource), nil, nil)
    backings.removeValue(forKey: resource)?.deallocate()
  }

  private func handle(_ request: Data, tag: UInt64) {
    guard request.count >= 24 else {
      send(.response, tag: tag)
      return
    }
    let flags = request.u32(4)
    let fence = request.u64(8)
    let context = request.u32(16)
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
      let index = Int(request.u32(24))
      let id = index < Self.capsets.count ? Self.capsets[index] : 0
      var version: UInt32 = 0
      var capsetSize: UInt32 = 0
      if id != 0 { virgl_renderer_get_cap_set(id, &version, &capsetSize) }
      status = Self.okCapsetInfo
      for value in [id, version, capsetSize, 0] { body.put32(value) }

    case .getCapset:
      let id = request.u32(24)
      let version = request.u32(28)
      var maxVersion: UInt32 = 0
      var capsetSize: UInt32 = 0
      virgl_renderer_get_cap_set(id, &maxVersion, &capsetSize)
      var caps = [UInt8](repeating: 0, count: Int(capsetSize))
      virgl_renderer_fill_caps(id, version, &caps)
      status = Self.okCapset
      body.append(contentsOf: caps)

    case .contextCreate:
      let nameLength = request.u32(24)
      let name = request.subdata(in: 32..<(32 + Int(min(nameLength, 64))))
      // No context init (the feature is not offered) is the legacy virgl context.
      let capset = request.u32(28) == 0 ? 2 : request.u32(28)
      let result = name.withUnsafeBytes {
        virgl_renderer_context_create_with_flags(
          context, capset, nameLength, $0.baseAddress?.assumingMemoryBound(to: CChar.self))
      }
      if result != 0 { status = Self.errUnspecified }

    case .contextDestroy:
      virgl_renderer_context_destroy(context)
    case .contextAttachResource:
      virgl_renderer_ctx_attach_resource(Int32(context), Int32(request.u32(24)))
    case .contextDetachResource:
      virgl_renderer_ctx_detach_resource(Int32(context), Int32(request.u32(24)))

    case .resourceCreate2D:
      var arguments = virgl_renderer_resource_create_args(
        handle: request.u32(24), target: 2, format: request.u32(28), bind: 1 << 1,
        width: request.u32(32), height: request.u32(36), depth: 1, array_size: 1, last_level: 0,
        nr_samples: 0, flags: 0)
      if virgl_renderer_resource_create(&arguments, nil, 0) != 0 { status = Self.errUnspecified }

    case .resourceCreate3D:
      var arguments = virgl_renderer_resource_create_args(
        handle: request.u32(24), target: request.u32(28), format: request.u32(32),
        bind: request.u32(36), width: request.u32(40), height: request.u32(44),
        depth: request.u32(48), array_size: request.u32(52), last_level: request.u32(56),
        nr_samples: request.u32(60), flags: request.u32(64))
      if virgl_renderer_resource_create(&arguments, nil, 0) != 0 { status = Self.errUnspecified }

    case .resourceAttachBacking:
      let resource = request.u32(24)
      if backings[resource] != nil { detach(resource) }
      guard let vectors = guestPages(request, at: 32, count: Int(request.u32(28))) else {
        status = Self.errUnspecified
        break
      }
      let pinned = UnsafeMutableBufferPointer<iovec>.allocate(capacity: max(vectors.count, 1))
      _ = pinned.initialize(from: vectors)
      backings[resource] = pinned
      if virgl_renderer_resource_attach_iov(
        Int32(resource), pinned.baseAddress, Int32(vectors.count))
        != 0
      {
        backings.removeValue(forKey: resource)?.deallocate()
        status = Self.errUnspecified
      }

    case .resourceDetachBacking:
      detach(request.u32(24))

    case .resourceUnref:
      let resource = request.u32(24)
      detach(resource)
      virgl_renderer_resource_unref(resource)

    case .transferToHost2D:
      var box = virgl_box(
        x: request.u32(24), y: request.u32(28), z: 0, w: request.u32(32), h: request.u32(36), d: 1)
      if virgl_renderer_transfer_write_iov(
        request.u32(48), 0, 0, 0, 0, &box, request.u64(40), nil, 0)
        != 0
      {
        status = Self.errUnspecified
      }

    case .transferToHost3D, .transferFromHost3D:
      var box = virgl_box(
        x: request.u32(24), y: request.u32(28), z: request.u32(32), w: request.u32(36),
        h: request.u32(40), d: request.u32(44))
      let offset = request.u64(48)
      let resource = request.u32(56)
      let level = request.u32(60)
      let stride = request.u32(64)
      let layerStride = request.u32(68)
      let result =
        command == .transferToHost3D
        ? virgl_renderer_transfer_write_iov(
          resource, context, Int32(level), stride, layerStride, &box, offset, nil, 0)
        : virgl_renderer_transfer_read_iov(
          resource, context, level, stride, layerStride, &box, offset, nil, 0)
      if result != 0 { status = Self.errUnspecified }

    case .submit3D:
      let length = Int(request.u32(24))
      guard 32 + length <= request.count else {
        status = Self.errUnspecified
        break
      }
      var commands = request.subdata(in: 32..<(32 + length))
      let result = commands.withUnsafeMutableBytes {
        virgl_renderer_submit_cmd($0.baseAddress, Int32(context), Int32(length / 4))
      }
      if result != 0 { status = Self.errUnspecified }

    case .setScanout:
      if request.u32(40) == 0 {
        scanoutResource = request.u32(44)
        present(scanoutResource)
      }

    case .resourceFlush:
      present(request.u32(40))

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
    response.put32(flags & Self.flagFence)
    response.put64(fence)
    response.put32(context)
    response.put32(0)
    response.append(body)

    if flags & Self.flagFence != 0, status < Self.errUnspecified {
      // The wire fence is a guest's opaque 64-bit id; vrend's legacy callback returns 32 bits.
      // Use our own sequence, preserving the guest's id only in the response.
      nextFence &+= 1
      let rendererFence = UInt64(nextFence)
      pending.append(Pending(tag: tag, response: response, fence: rendererFence))
      if virgl_renderer_create_fence(Int32(bitPattern: nextFence), context) != 0 {
        // A failed fence says nothing about earlier GPU work.
        let failed = pending.removeLast()
        send(.response, tag: failed.tag, payload: failed.response)
      }
    } else {
      send(.response, tag: tag, payload: response)
    }
  }

  // MARK: The screen

  /// Two IOSurfaces taken in turn, so the one being shown is never the one being drawn into, and so
  /// handing over the other is what tells the layer there is a new frame.
  private var surfaces: [IOSurfaceRef] = []
  private var surfaceTextures: [GLuint] = []
  private var surfaceSize = (width: 0, height: 0)
  private var nextSurface = 0
  /// A context of the blit's own, in vrend's share group: framebuffers are per context, so vrend's
  /// are left alone.
  private var blitContext: CGLContextObj?
  private var readFramebuffer: GLuint = 0
  private var drawFramebuffer: GLuint = 0

  private func makeSurfaces(width: Int, height: Int) {
    surfaces = (0..<2).compactMap { _ in
      IOSurfaceCreate(
        [
          kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
          kIOSurfacePixelFormat: 0x4247_5241,  // 'BGRA'
        ] as CFDictionary)
    }
    guard surfaces.count == 2, let blitContext else { return }
    if !surfaceTextures.isEmpty {
      glDeleteTextures(GLsizei(surfaceTextures.count), surfaceTextures)
    }
    surfaceTextures = [0, 0]
    glGenTextures(2, &surfaceTextures)
    for (surface, texture) in zip(surfaces, surfaceTextures) {
      glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), texture)
      CGLTexImageIOSurface2D(
        blitContext, GLenum(GL_TEXTURE_RECTANGLE), GLenum(GL_RGBA), GLsizei(width),
        GLsizei(height), GLenum(GL_BGRA), GLenum(GL_UNSIGNED_INT_8_8_8_8_REV), surface, 0)
    }
    surfaceSize = (width, height)
    VirglLink.send(
      surfaces.map { IOSurfaceCreateMachPort($0) }, id: VirglLink.surfacesID, to: service,
      disposition: UInt32(MACH_MSG_TYPE_MOVE_SEND))
  }

  /// Copy the scanout into the next IOSurface and say which; the texture is vrend's, in its share
  /// group, and keeps its top row first, as an IOSurface does.
  private func present(_ resource: UInt32) {
    guard resource != 0, resource == scanoutResource, let share = shareContext,
      let format = Self.pixelFormat
    else { return }
    var info = virgl_renderer_resource_info()
    guard virgl_renderer_resource_get_info(Int32(resource), &info) == 0, info.width > 0 else {
      return
    }
    glFlush()  // vrend's commands for the frame, before another context reads the texture
    if blitContext == nil {
      CGLCreateContext(format, share, &blitContext)
      CGLSetCurrentContext(blitContext)
      glGenFramebuffers(1, &readFramebuffer)
      glGenFramebuffers(1, &drawFramebuffer)
    }
    CGLSetCurrentContext(blitContext)
    if surfaceSize != (Int(info.width), Int(info.height)) {
      makeSurfaces(width: Int(info.width), height: Int(info.height))
    }
    guard surfaces.count == 2 else {
      makeCurrent()
      return
    }
    let w = GLint(info.width)
    let h = GLint(info.height)
    glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), readFramebuffer)
    glFramebufferTexture2D(
      GLenum(GL_READ_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D),
      GLuint(info.tex_id), 0)
    glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), drawFramebuffer)
    glFramebufferTexture2D(
      GLenum(GL_DRAW_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_RECTANGLE),
      surfaceTextures[nextSurface], 0)
    glBlitFramebuffer(
      0, 0, w, h, 0, 0, w, h, GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_NEAREST))
    glFlush()
    send(.frame, value: IOSurfaceGetID(surfaces[nextSurface]))
    nextSurface ^= 1
    makeCurrent()
  }

  /// The cursor is a small resource of its own: width, height and BGRA pixels, read back.
  private func cursorImage(_ resource: UInt32) -> Data {
    var info = virgl_renderer_resource_info()
    guard resource != 0, virgl_renderer_resource_get_info(Int32(resource), &info) == 0,
      info.width > 0, info.height > 0
    else { return Data() }
    let stride = Int(info.width) * 4
    var pixels = Data(count: stride * Int(info.height))
    let result = pixels.withUnsafeMutableBytes { buffer -> Int32 in
      var vector = iovec(iov_base: buffer.baseAddress, iov_len: buffer.count)
      var box = virgl_box(x: 0, y: 0, z: 0, w: info.width, h: info.height, d: 1)
      return virgl_renderer_transfer_read_iov(
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

extension Data {
  fileprivate func u32(_ offset: Int) -> UInt32 {
    withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
  }
  fileprivate func u64(_ offset: Int) -> UInt64 {
    withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
  }
  fileprivate mutating func put32(_ value: UInt32) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }
  fileprivate mutating func put64(_ value: UInt64) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }
}
