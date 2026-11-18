import Cvirglrenderer
import Foundation
import IOSurface

/// A GPU machine's renderer: this executable started with `VirglLink.launchArgument`, one process
/// per machine (`VirglLink` says why). It is handed guest RAM once, then reads the guest's
/// virtio-gpu requests off its socket and plays them through virglrenderer's vrend on Mesa's Zink
/// over KosmicKrisp — OpenGL 4.6 on Vulkan on Metal, the libraries in Contents/Frameworks — in
/// surfaceless EGL contexts it hands vrend. Every GL and EGL call, vrend's and this file's, goes
/// through libepoxy to Mesa's; Apple's OpenGL is not used. What the guest scans out is read back
/// by the GPU into IOSurfaces the device's process shows.
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
      // vrend declares integer vertex inputs as integers only on an ARM GPU unless told to, and a
      // float input fed integers arrives as garbage.
      setenv("VIRGL_USE_INTEGER", "1", 1)
      Self.configureMesa()
      guard Self.display != nil else { VirglRendererProcess.fail(73, "no EGL display from Mesa") }
      guard virgl_renderer_init(Unmanaged.passUnretained(self).toOpaque(), 0, &Self.callbacks) == 0
      else { VirglRendererProcess.fail(72, "virglrenderer did not start") }
      releaseCurrent()
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
    defer { releaseCurrent() }
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

  // MARK: EGL, for vrend

  /// Read by Mesa as it starts, so set before the first EGL call.
  private static func configureMesa() {
    // Zink is the only GL driver the libraries carry; named, so nothing is inferred.
    setenv("GALLIUM_DRIVER", "zink", 1)
    // Metal has no RGB32 texel buffer format before Apple family 11, and that one extension is all
    // that holds Zink's GL below 4.0; vrend never hands it the format (virglrenderer-hukan.patch).
    // With it, Mesa works the version out as 4.6 — but EGL checks a context request against the
    // version from before the override, so that is overridden to what Mesa then reports.
    setenv("MESA_EXTENSION_OVERRIDE", "+GL_ARB_texture_buffer_object_rgb32", 1)
    setenv("MESA_GL_VERSION_OVERRIDE", "4.6", 1)
    // Compiled shaders are kept between runs, where a Mac app keeps a cache.
    if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
      let directory = caches.appendingPathComponent(
        "\(Bundle.main.bundleIdentifier ?? "hukan")/mesa", isDirectory: true)
      setenv("MESA_SHADER_CACHE_DIR", directory.path, 1)
    }
  }

  private typealias GetPlatformDisplay =
    @convention(c) (
      EGLenum, UnsafeMutableRawPointer?, UnsafePointer<EGLint>?
    ) -> EGLDisplay?

  /// Mesa's surfaceless platform: contexts with no window, which is all vrend and the screen need.
  /// Asked of eglGetProcAddress: epoxy looks an EGL 1.5 function up only once a display has told
  /// it the version, and this is how the display is got.
  private static let display: EGLDisplay? = {
    guard let address = epoxy_eglGetProcAddress("eglGetPlatformDisplayEXT") else { return nil }
    let getDisplay = unsafeBitCast(address, to: GetPlatformDisplay.self)
    guard let display = getDisplay(EGLenum(EGL_PLATFORM_SURFACELESS_MESA), nil, nil),
      epoxy_eglInitialize(display, nil, nil) != 0,
      epoxy_eglBindAPI(EGLenum(EGL_OPENGL_API)) != 0
    else { return nil }
    return display
  }()

  private static func createContext(
    major: Int32, minor: Int32, compatibility: Bool, share: EGLContext?
  ) -> EGLContext? {
    guard let display else { return nil }
    let profile =
      compatibility
      ? EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT : EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT
    let attributes: [EGLint] = [
      EGLint(EGL_CONTEXT_MAJOR_VERSION), major, EGLint(EGL_CONTEXT_MINOR_VERSION), minor,
      EGLint(EGL_CONTEXT_OPENGL_PROFILE_MASK), EGLint(profile), EGLint(EGL_NONE),
    ]
    // The API a context is made for is per thread, and OpenGL ES on a thread that never said, which
    // a serial queue's next block may well run on; a GLES context cannot share with a GL one.
    _ = epoxy_eglBindAPI(EGLenum(EGL_OPENGL_API))
    let context = epoxy_eglCreateContext(display, nil, share, attributes)
    if context == nil {
      VirglLink.note(
        "renderer: eglCreateContext \(major).\(minor)\(compatibility ? " compat" : "")"
          + "\(share != nil ? " shared" : "") failed: 0x\(String(epoxy_eglGetError(), radix: 16))")
    }
    return context
  }

  /// The first live context vrend asked for — context 0's, once the version probe is gone; every
  /// later one, and the screen's, shares objects with it.
  private var shareContext: EGLContext?
  /// The context vrend last made current. EGL's current context is per thread and a serial queue
  /// runs on whichever thread it gets, so every block here puts it back before touching GL — and
  /// lets go of it when done (`releaseCurrent`): unlike CGL, EGL refuses to make a context current
  /// on one thread while another still holds it, and every later block would run with none.
  private var currentContext: EGLContext?
  private func makeCurrent() {
    if epoxy_eglGetCurrentContext() != currentContext {
      _ = epoxy_eglMakeCurrent(Self.display, nil, nil, currentContext)
    }
  }
  /// The end of every block that touched GL. `currentContext` stays what vrend last asked for.
  private func releaseCurrent() {
    if epoxy_eglGetCurrentContext() != nil {
      _ = epoxy_eglMakeCurrent(Self.display, nil, nil, nil)
    }
  }

  private static var callbacks: virgl_renderer_callbacks = {
    var callbacks = virgl_renderer_callbacks()
    callbacks.version = 1
    callbacks.write_fence = { cookie, fence in
      guard let cookie else { return }
      Unmanaged<VirglRenderer>.fromOpaque(cookie).takeUnretainedValue().signalled(UInt64(fence))
    }
    callbacks.create_gl_context = { cookie, _, parameters in
      guard let cookie, let p = parameters?.pointee else { return nil }
      let renderer = Unmanaged<VirglRenderer>.fromOpaque(cookie).takeUnretainedValue()
      guard
        let context = VirglRenderer.createContext(
          major: p.major_ver, minor: p.minor_ver, compatibility: p.compat_ctx != 0,
          share: p.shared ? renderer.shareContext : nil)
      else { return nil }
      if renderer.shareContext == nil { renderer.shareContext = context }
      return context
    }
    callbacks.destroy_gl_context = { cookie, context in
      guard let cookie, let context else { return }
      let renderer = Unmanaged<VirglRenderer>.fromOpaque(cookie).takeUnretainedValue()
      if renderer.currentContext == context {
        _ = epoxy_eglMakeCurrent(VirglRenderer.display, nil, nil, nil)
        renderer.currentContext = nil
      }
      // vrend's first context only probes the version and is destroyed before context 0 is made;
      // EGL, unlike CGL, refuses a destroyed context as a share, so the next one takes its place.
      if renderer.shareContext == context { renderer.shareContext = nil }
      _ = epoxy_eglDestroyContext(VirglRenderer.display, context)
    }
    callbacks.make_current = { cookie, _, context in
      guard let cookie else { return -1 }
      let renderer = Unmanaged<VirglRenderer>.fromOpaque(cookie).takeUnretainedValue()
      renderer.currentContext = context
      guard epoxy_eglMakeCurrent(VirglRenderer.display, nil, nil, context) != 0 else {
        VirglLink.note(
          "renderer: eglMakeCurrent failed: 0x\(String(epoxy_eglGetError(), radix: 16))")
        return -1
      }
      return 0
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
      self.releaseCurrent()
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
  /// Each IOSurface's own pages, pinned as a GL buffer (GL_AMD_pinned_memory, which Zink builds on
  /// KosmicKrisp's host-pointer import): the scanout is read back into them by the GPU, with no
  /// copy on this side. Nothing more direct exists — KosmicKrisp shares memory with the outside as
  /// a Metal heap or a host pointer only, and an IOSurface's texture cannot live in a heap.
  private var packBuffers: [GLuint] = []
  private var surfaceSize = (width: 0, height: 0)
  private var nextSurface = 0
  /// A context of the screen's own, in vrend's share group: framebuffers are per context, so
  /// vrend's are left alone.
  private var screenContext: EGLContext?
  private var readFramebuffer: GLuint = 0
  /// Read-backs the GPU has not finished, oldest first: a frame is handed over only once its
  /// pixels are in the IOSurface, which a fence says, polled rather than waited on so the guest's
  /// commands keep flowing meanwhile.
  private var framesInFlight: [(sync: GLsync, surface: Int)] = []
  private var framePollScheduled = false

  /// In the screen context.
  private func makeSurfaces(width: Int, height: Int) {
    // What is in flight names the surfaces about to be replaced.
    while !framesInFlight.isEmpty { finishFrames(upTo: framesInFlight.count) }
    if !packBuffers.isEmpty { epoxy_glDeleteBuffers(GLsizei(packBuffers.count), packBuffers) }
    packBuffers = []
    surfaces = (0..<2).compactMap { _ in
      IOSurfaceCreate(
        [
          kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
          kIOSurfacePixelFormat: 0x4247_5241,  // 'BGRA'
        ] as CFDictionary)
    }
    guard surfaces.count == 2 else { return }
    packBuffers = [0, 0]
    epoxy_glGenBuffers(2, &packBuffers)
    let target = GLenum(GL_EXTERNAL_VIRTUAL_MEMORY_BUFFER_AMD)
    for (surface, buffer) in zip(surfaces, packBuffers) {
      // An IOSurface is page aligned and a whole number of pages, which the import requires.
      epoxy_glBindBuffer(target, buffer)
      epoxy_glBufferData(
        target, GLsizeiptr(IOSurfaceGetAllocSize(surface)), IOSurfaceGetBaseAddress(surface),
        GLenum(GL_STREAM_READ))
    }
    epoxy_glBindBuffer(target, 0)
    surfaceSize = (width, height)
    VirglLink.send(
      surfaces.map { IOSurfaceCreateMachPort($0) }, id: VirglLink.surfacesID, to: service,
      disposition: UInt32(MACH_MSG_TYPE_MOVE_SEND))
  }

  /// Read the scanout back into the next IOSurface, and say which once the GPU is done; the texture
  /// is vrend's, in its share group, and keeps its top row first, as an IOSurface does.
  private func present(_ resource: UInt32) {
    guard resource != 0, resource == scanoutResource, let share = shareContext else { return }
    var info = virgl_renderer_resource_info()
    guard virgl_renderer_resource_get_info(Int32(resource), &info) == 0, info.width > 0 else {
      return
    }
    epoxy_glFlush()  // vrend's commands for the frame, before another context reads the texture
    if screenContext == nil {
      screenContext = Self.createContext(major: 4, minor: 3, compatibility: false, share: share)
      guard let screenContext, epoxy_eglMakeCurrent(Self.display, nil, nil, screenContext) != 0
      else {
        makeCurrent()
        return
      }
      epoxy_glGenFramebuffers(1, &readFramebuffer)
    }
    _ = epoxy_eglMakeCurrent(Self.display, nil, nil, screenContext)
    defer { makeCurrent() }
    if surfaceSize != (Int(info.width), Int(info.height)) {
      makeSurfaces(width: Int(info.width), height: Int(info.height))
    }
    guard surfaces.count == 2 else { return }
    // Two surfaces: the GPU must be done with the one about to be written again.
    while framesInFlight.count >= 2 { finishFrames(upTo: 1) }
    let surface = surfaces[nextSurface]
    epoxy_glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), readFramebuffer)
    epoxy_glFramebufferTexture2D(
      GLenum(GL_READ_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D),
      GLuint(info.tex_id), 0)
    epoxy_glBindBuffer(GLenum(GL_PIXEL_PACK_BUFFER), packBuffers[nextSurface])
    epoxy_glPixelStorei(GLenum(GL_PACK_ROW_LENGTH), GLint(IOSurfaceGetBytesPerRow(surface) / 4))
    epoxy_glReadPixels(
      0, 0, GLsizei(info.width), GLsizei(info.height), GLenum(GL_BGRA),
      GLenum(GL_UNSIGNED_INT_8_8_8_8_REV), nil)
    epoxy_glBindBuffer(GLenum(GL_PIXEL_PACK_BUFFER), 0)
    if let sync = epoxy_glFenceSync(GLenum(GL_SYNC_GPU_COMMANDS_COMPLETE), 0) {
      framesInFlight.append((sync, nextSurface))
    }
    epoxy_glFlush()
    nextSurface ^= 1
    scheduleFramePoll()
  }

  /// Hand over every read-back the GPU has finished; in the screen context.
  private func finishFrames(upTo wait: Int = 0) {
    var waited = 0
    while let first = framesInFlight.first {
      let timeout: GLuint64 = waited < wait ? 1_000_000_000 : 0
      let result = epoxy_glClientWaitSync(
        first.sync, GLbitfield(GL_SYNC_FLUSH_COMMANDS_BIT), timeout)
      if result == GLenum(GL_TIMEOUT_EXPIRED) { return }
      waited += 1
      epoxy_glDeleteSync(first.sync)
      framesInFlight.removeFirst()
      if result != GLenum(GL_WAIT_FAILED) {
        send(.frame, value: IOSurfaceGetID(surfaces[first.surface]))
      }
    }
  }

  private func scheduleFramePoll() {
    guard !framesInFlight.isEmpty, !framePollScheduled else { return }
    framePollScheduled = true
    queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in
      guard let self, let screenContext = self.screenContext else { return }
      self.framePollScheduled = false
      _ = epoxy_eglMakeCurrent(Self.display, nil, nil, screenContext)
      self.finishFrames()
      self.releaseCurrent()
      self.scheduleFramePoll()
    }
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
