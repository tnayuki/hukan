import AppKit
import IOSurface
import Virtualization

/// A Linux guest's GPU: a virtio-gpu of hukan's own, carrying the guest's Vulkan to this Mac's.
///
/// The guest's Mesa turns its OpenGL into Vulkan (Zink) and its Vulkan into a stream gfxstream's
/// driver sends down a virtio-gpu; gfxstream replays it on KosmicKrisp, Mesa's Vulkan on Metal.
/// Virtualization.framework has no such device, and from macOS 27 lets a process implement one
/// (`VZCustomVirtioDevice`).
///
/// This half is the device: it forwards each request to the machine's renderer, a process of its
/// own (`GPURenderer`, over `GPULink`), and writes back the answers. Guest RAM is handed to the
/// renderer once, as a Mach memory entry, so it reads and writes the guest's pages directly. A blob
/// the guest maps comes back the other way, as a memory entry of the renderer's pages, which this
/// half puts into the device's shared memory region — the one place the framework lets memory into
/// the guest's address space.
///
/// The device also carries the guest's screen: mutter is pointed at it (the template's job), and
/// the renderer draws what it scans out into IOSurfaces the tab shows (`GPUScreenView`). VZ's own
/// virtio screen stays configured beside it, unused by the guest, for the keyboard and pointer:
/// `VZVirtualMachineView` hands them to the guest only for a machine with a screen of VZ's, and maps
/// the pointer against it — so this device follows that screen's size.
///
/// Its state is saved with the machine's: gfxstream's snapshot, written beside the machine's own,
/// and which blob was mapped where, which the framework keeps with the machine's state.
@available(macOS 27, *)
final class GPUDevice: NSObject, VZCustomVirtioDeviceConfigurationDelegate,
  VZCustomVirtioDeviceDelegate
{
  /// Where the generic platform puts guest RAM, as one range: measured from the guest
  /// (`/proc/iomem`'s System RAM), since the framework does not say.
  static let ramBase: UInt64 = 0x7000_0000
  private static let eventDisplay: UInt32 = 1
  /// The shared memory region blobs are mapped into, and its size: the guest asks for its id, and
  /// takes the size as the room it has for mapped blobs.
  private static let blobRegionID: UInt8 = 1
  private static let blobRegionSize: UInt64 = 8 << 30
  /// This Mac's pages, which the region maps in whole.
  private static let hostPage: UInt64 = 16384

  /// The device for a configuration; `snapshot` is where gfxstream's state is saved with the
  /// machine's.
  static func make(width: Int, height: Int, memorySize: UInt64, snapshot: URL) -> (
    VZCustomVirtioDeviceConfiguration, GPUDevice
  ) {
    let gpu = GPUDevice(
      width: UInt32(width), height: UInt32(height), memorySize: memorySize, snapshot: snapshot)
    let configuration = VZCustomVirtioDeviceConfiguration()
    configuration.deviceID = 16  // virtio-gpu
    configuration.pciClassID = 0x03  // display
    configuration.pciSubclassID = 0x80  // other: VZ's own screen is the guest's VGA
    configuration.virtioQueueCount = 2  // control, cursor
    // VIRGL, RESOURCE_BLOB, CONTEXT_INIT: the 3D the guest's driver asks for, blobs it maps, and
    // the gfxstream context it names.
    configuration.optionalFeatures.subset0 = (1 << 0) | (1 << 3) | (1 << 4)
    configuration.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(
      configurationData: gpu.config(events: 0))
    configuration.sharedMemoryRegions = [
      VZVirtioSharedMemoryRegionConfiguration(regionID: blobRegionID, size: blobRegionSize)
    ]
    configuration.supportsSaveRestore = true
    configuration.provider = VZCustomVirtioDeviceDelegateProvider(
      deviceQueue: gpu.queue, delegate: gpu)
    return (configuration, gpu)
  }

  // MARK: State

  private let queue = DispatchQueue(label: "hukan.gpu")
  private let identity = UUID().uuidString
  private var device: VZCustomVirtioDevice?
  private var width: UInt32
  private var height: UInt32
  private let memorySize: UInt64
  private let snapshot: URL

  /// Elements handed to the renderer and not yet answered, by the tag they went with, each with the
  /// request it carried, for an answer of our own should the renderer die first.
  private struct Pending {
    var element: VZVirtioQueueElement
    var request: Data
  }
  private var elements: [UInt64: Pending] = [:]
  /// Requests that came while a renderer could not start yet — guest RAM not mappable for a moment
  /// after a reset — held, with the queue each came on, to go to it once it has.
  private var held: [(element: VZVirtioQueueElement, request: Data, queue: UInt16)] = []
  /// Attempts left at mapping guest RAM for the renderer being started; nil when none is waiting.
  private var ramAttemptsLeft: Int?
  /// The capset requests this device sent a new renderer itself (`GPUCapsets.probes`), by tag.
  private var capsetProbes: [UInt64: Data] = [:]
  private var nextTag: UInt64 = 1

  /// A blob in the guest: where in the region, how much, and this process's mapping of its pages.
  private struct Mapping {
    var offset: UInt64
    var size: UInt64
    var address: mach_vm_address_t
  }
  private var mappings: [UInt32: Mapping] = [:]
  /// Blobs a restore is putting back, which the machine must not resume before.
  private var remapsLeft = 0

  // The renderer: its process, the socket to it, and the Mach service it finds this process by.
  private var renderer: pid_t = 0
  private var shutDownPermanently = false
  private var writer: GPULink.Writer?
  private var socket: Int32 = -1
  private var readSource: DispatchSourceRead?
  private var reader = GPULink.Reader()
  private var service: mach_port_t = 0
  private var ram: VZGuestMemoryMapping?

  /// Told on the main queue: a frame in this IOSurface, the guest's cursor image (nil hides it) and
  /// its hotspot, and the cursor's moves.
  var onFrame: ((IOSurfaceRef) -> Void)?
  var onCursorImage: ((CGImage?, Int, Int) -> Void)?
  var onCursorMove: ((Int, Int) -> Void)?
  /// Told on the main queue when the guest resets the device: what was on the screen was the old
  /// driver's, and the next frame is the new renderer's.
  var onReset: (() -> Void)?
  /// The renderer's IOSurfaces by id; touched on the main queue only.
  private var surfaces: [IOSurfaceID: IOSurfaceRef] = [:]

  private init(width: UInt32, height: UInt32, memorySize: UInt64, snapshot: URL) {
    self.width = width
    self.height = height
    self.memorySize = memorySize
    self.snapshot = snapshot
  }

  /// events_read, events_clear, num_scanouts, num_capsets.
  private func config(events: UInt32) -> Data {
    var data = Data()
    for value in [events, 0, 1, 1] as [UInt32] { data.put32(value) }
    return data
  }

  // MARK: The renderer's process

  /// Start the renderer: guest RAM to it as a memory entry, through a bootstrap name only it is told.
  private func startRenderer(on device: VZCustomVirtioDevice) {
    guard !shutDownPermanently, renderer == 0 else { return }
    // Guest RAM is mapped once per boot and kept until the device resets or stops, for every
    // renderer the boot starts: a machine resumed from a saved state could not map it a second
    // time while the first mapping stood — its first reboot left the GPU without a renderer.
    // Right after a reset the guest's new RAM cannot be mapped for a moment (it failed for the
    // first two DRIVER_OKs of a reboot): asked again every 50 ms for up to five seconds, the
    // guest's requests held meanwhile rather than answered with errors.
    guard
      let ram = self.ram
        ?? device.guestMemoryMapping(atPhysicalAddress: Self.ramBase, length: Int(memorySize))
    else {
      let left = (ramAttemptsLeft ?? 100) - 1
      guard left > 0 else {
        GPULink.note("GPU \(identity): could not map guest RAM")
        ramAttemptsLeft = nil
        for waiting in held { answer(waiting.element, with: Self.unanswerable(waiting.request)) }
        held = []
        return
      }
      ramAttemptsLeft = left
      queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        guard let self, self.ramAttemptsLeft != nil else { return }
        self.startRenderer(on: device)
      }
      return
    }
    if let left = ramAttemptsLeft {
      GPULink.note("GPU \(identity): guest RAM mapped after \(100 - left) attempts")
    }
    ramAttemptsLeft = nil
    var entrySize = memory_object_size_t(memorySize)
    var entry: mach_port_t = 0
    guard
      mach_make_memory_entry_64(
        mach_task_self_, &entrySize, memory_object_offset_t(UInt(bitPattern: ram.mutableBytes)),
        VM_PROT_READ | VM_PROT_WRITE | MAP_MEM_VM_SHARE, &entry, 0) == KERN_SUCCESS
    else {
      GPULink.note("could not share guest RAM")
      return
    }
    defer { mach_port_deallocate(mach_task_self_, entry) }
    let name = "com.tnayuki.hukan.gpu.\(getpid()).\(UUID().uuidString)"
    var service: mach_port_t = 0
    guard GPULink.bootstrapCheckIn(bootstrap_port, name, &service) == KERN_SUCCESS else {
      GPULink.note("could not register the renderer's name")
      return
    }
    var ownsService = true
    defer {
      if ownsService { mach_port_mod_refs(mach_task_self_, service, MACH_PORT_RIGHT_RECEIVE, -1) }
    }
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, pair[1], GPULink.socketDescriptor)
    posix_spawn_file_actions_addinherit_np(&actions, GPULink.socketDescriptor)
    // Its stderr is the log, so a renderer that gives up says where.
    posix_spawn_file_actions_addopen(
      &actions, 2, GPULink.logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    // Nothing of this process's but the socket: fd 3 is the one descriptor it is given.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let arguments = [
      executable, GPULink.launchArgument, name, String(Self.ramBase), String(memorySize),
      String(width), String(height),
    ]
    var argv = arguments.map { strdup($0) } + [nil]
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, executable, &actions, &attributes, &argv, environ)
    for argument in argv { free(argument) }
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attributes)
    close(pair[1])
    guard spawned == 0 else {
      close(pair[0])
      GPULink.note("the renderer did not start (\(spawned))")
      return
    }
    GPULink.note(
      "renderer \(pid) started for \(memorySize >> 30) GB of guest RAM, GPU \(identity)")
    self.ram = ram
    self.renderer = pid
    self.socket = pair[0]
    self.service = service
    self.reader = GPULink.Reader()
    ownsService = false
    writer = GPULink.Writer(descriptor: pair[0], queue: queue) { [weak self] in
      self?.stopRenderer(leavingGuestPages: true)
    }

    // Its capsets asked for at once, so that they are known before the guest's kernel asks.
    for probe in GPUCapsets.probes {
      let tag = nextTag
      nextTag += 1
      capsetProbes[tag] = probe
      writer?.send(GPULink.encode(.request, value: 0, tag: tag, payload: probe))
    }
    // What the guest asked while guest RAM could not be mapped yet, in the order it asked.
    let waiting = held
    held = []
    for request in waiting {
      forward(request.element, request: request.request, queue: request.queue)
    }

    let source = DispatchSource.makeReadSource(fileDescriptor: pair[0], queue: queue)
    source.setEventHandler { [weak self] in
      guard let self, self.renderer == pid else { return }
      self.readSocket()
    }
    let descriptor = pair[0]
    source.setCancelHandler { close(descriptor) }
    source.resume()
    readSource = source

    // Mach on a thread of its own: the hello and RAM first, then the surfaces and the blobs as they
    // are made. It ends when the service's right is destroyed.
    // Keep one send right to the entry until the handshake thread has finished with it.
    mach_port_mod_refs(mach_task_self_, entry, MACH_PORT_RIGHT_SEND, 1)
    Thread.detachNewThread { [weak self] in
      defer { mach_port_deallocate(mach_task_self_, entry) }
      guard let hello = GPULink.receive(on: service), hello.id == GPULink.helloID else {
        return
      }
      GPULink.send([entry], id: GPULink.memoryID, to: hello.reply)
      mach_port_deallocate(mach_task_self_, hello.reply)
      while let message = GPULink.receive(on: service) {
        switch message.id {
        case GPULink.surfacesID:
          let made = message.ports.compactMap { port -> IOSurfaceRef? in
            defer { mach_port_deallocate(mach_task_self_, port) }
            return IOSurfaceLookupFromMachPort(port)
          }
          self?.queue.async { [weak self] in
            guard let self, self.renderer == pid else { return }
            DispatchQueue.main.async { [weak self] in
              self?.surfaces = Dictionary(
                uniqueKeysWithValues: made.map { (IOSurfaceGetID($0), $0) })
            }
          }
        case GPULink.blobID:
          guard let blob = message.blob, let port = message.ports.first else { continue }
          self?.queue.async { [weak self] in
            guard let self, self.renderer == pid else {
              mach_port_deallocate(mach_task_self_, port)
              return
            }
            self.mapBlob(blob, entry: port)
          }
        default:
          for port in message.ports { mach_port_deallocate(mach_task_self_, port) }
        }
      }
    }
  }

  /// The renderer goes, and with it everything it made; what the guest is waiting on is dropped.
  ///
  /// A renderer that died under a running guest (`leavingGuestPages`) leaves its blobs in the region:
  /// the guest still has them mapped, and a guest touching a page taken out from under it stops the
  /// whole machine with an internal Virtualization error. They stay until the device resets or
  /// stops; what the guest was waiting on is answered with an error instead of dropped.
  private func stopRenderer(leavingGuestPages: Bool = false) {
    if renderer != 0 {
      readSource?.cancel()
      readSource = nil
      writer?.cancel()
      writer = nil
      socket = -1
      let pid = renderer
      renderer = 0
      kill(pid, SIGTERM)
      DispatchQueue.global().async {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        GPULink.note("renderer \(pid) ended, status \(status)")
      }
      mach_port_mod_refs(mach_task_self_, service, MACH_PORT_RIGHT_RECEIVE, -1)
      service = 0
      DispatchQueue.main.async { [weak self] in self?.surfaces = [:] }
    }
    if leavingGuestPages {
      if !mappings.isEmpty {
        GPULink.note(
          "GPU \(identity): \(mappings.count) blobs left in the guest, the renderer gone")
      }
      for pending in elements.values {
        answer(pending.element, with: Self.unanswerable(pending.request))
      }
    } else {
      for resource in Array(mappings.keys) { unmapBlob(resource) }
      // An element has to go back to its queue before it is let go, or the framework aborts; these
      // go back unanswered.
      for pending in elements.values { pending.element.returnToQueue() }
    }
    elements = [:]
    capsetProbes = [:]
    ramAttemptsLeft = nil
    for waiting in held {
      if leavingGuestPages {
        answer(waiting.element, with: Self.unanswerable(waiting.request))
      } else {
        waiting.element.returnToQueue()
      }
    }
    held = []
  }

  /// The machine has stopped for good.
  func shutDown() {
    queue.sync {
      GPULink.note("GPU \(identity): shut down")
      shutDownPermanently = true
      stopRenderer()
      ram = nil
      device = nil
    }
  }

  private func readSocket() {
    guard let bytes = GPULink.read(from: socket) else {
      GPULink.note("the renderer's socket closed")
      stopRenderer(leavingGuestPages: true)
      return
    }
    for frame in reader.feed(bytes) { handle(frame) }
  }

  /// One frame from the renderer; what it returns is the frame a save or restore waits for.
  @discardableResult
  private func handle(_ frame: GPULink.Frame) -> GPULink.Frame? {
    switch frame.kind {
    case .response:
      if let probe = capsetProbes.removeValue(forKey: frame.tag) {
        GPUCapsets.learn(frame.payload, for: probe)
        return nil
      }
      guard let pending = elements.removeValue(forKey: frame.tag) else { return nil }
      GPUCapsets.learn(frame.payload, for: pending.request)
      let element = pending.element
      answer(element, with: frame.payload)
    case .frame:
      let id = frame.value
      DispatchQueue.main.async { [weak self] in
        guard let self, let surface = self.surfaces[id] else { return }
        self.onFrame?(surface)
      }
    case .cursorImage:
      let image = Self.cursorImage(frame.payload)
      let hot = (Int(frame.value >> 16), Int(frame.value & 0xFFFF))
      DispatchQueue.main.async { [weak self] in self?.onCursorImage?(image, hot.0, hot.1) }
    case .cursorMove:
      let x = Int(Int16(truncatingIfNeeded: frame.value >> 16))
      let y = Int(Int16(truncatingIfNeeded: frame.value & 0xFFFF))
      DispatchQueue.main.async { [weak self] in self?.onCursorMove?(x, y) }
    case .displayRead:
      // The guest has the new size; a configuration with the event cleared stops it asking again.
      device?.update(VZVirtioDeviceSpecificConfiguration(configurationData: config(events: 0))) {
        _ in
      }
    case .saved, .restored:
      return frame
    case .request, .display, .save, .restore, .exportBlob:
      break
    }
    return nil
  }

  private func answer(_ element: VZVirtioQueueElement, with payload: Data) {
    var response = payload
    if !response.isEmpty {
      let room = element.writeBuffersAvailableByteCount
      if room < response.count { response = response.prefix(room) }
      try? element.write(response)
    }
    element.returnToQueue()
  }

  /// VIRTIO_GPU_RESP_ERR_UNSPEC for a command: its header's flags, fence, context and ring kept,
  /// as the guest matches a fenced answer by them.
  private static func unanswerable(_ request: Data) -> Data {
    guard request.count >= 24 else { return Data() }
    var response = Data()
    response.put32(0x1200)
    response.append(request[request.startIndex + 4..<request.startIndex + 24])
    return response
  }

  private static func cursorImage(_ payload: Data) -> CGImage? {
    guard payload.count >= 8 else { return nil }
    let width = Int(payload.u32(0))
    let height = Int(payload.u32(4))
    let pixels = payload.dropFirst(8)
    guard width > 0, height > 0, pixels.count >= width * height * 4,
      let provider = CGDataProvider(data: Data(pixels) as CFData)
    else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGBitmapInfo.byteOrder32Little.rawValue
          | CGImageAlphaInfo.premultipliedFirst.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  // MARK: Blobs

  /// The renderer's pages for a blob: mapped here from their memory entry, then into the region —
  /// for the guest's RESOURCE_MAP_BLOB, answered once they are there, or for a restore.
  private func mapBlob(_ blob: GPULink.BlobMessage, entry: mach_port_t) {
    defer { mach_port_deallocate(mach_task_self_, entry) }
    let element = elements.removeValue(forKey: blob.tag)?.element
    let offset = element != nil ? blob.offset : mappings[blob.resource]?.offset ?? blob.offset
    var response = withUnsafeBytes(of: blob.response) { Data($0) }
    func fail(_ why: String) {
      GPULink.note("GPU \(identity): resource \(blob.resource): \(why)")
      if element == nil { remapsLeft = max(0, remapsLeft - 1) }
      guard let element else { return }
      response.replaceSubrange(
        0..<4, with: withUnsafeBytes(of: GPURenderer.errUnspecified) { Data($0) })
      answer(element, with: response)
    }
    guard let region = device?.sharedMemoryRegions.first, offset % Self.hostPage == 0,
      offset + blob.size <= Self.blobRegionSize
    else { return fail("no room in the region at \(offset)") }
    // Mapped again by the guest: the old pages leave first.
    if element != nil, mappings[blob.resource] != nil { unmapBlob(blob.resource) }
    var address: mach_vm_address_t = 0
    guard
      mach_vm_map(
        mach_task_self_, &address, mach_vm_size_t(blob.size), 0, VM_FLAGS_ANYWHERE, entry, 0, 0,
        VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE)
        == KERN_SUCCESS, let pages = UnsafeMutableRawPointer(bitPattern: UInt(address))
    else { return fail("its pages could not be mapped here") }
    mappings[blob.resource] = Mapping(offset: offset, size: blob.size, address: address)
    region.mapMemory(pages, atOffset: offset, size: blob.size) { [weak self] error in
      self?.queue.async { [weak self] in
        guard let self else { return }
        if let error {
          GPULink.note("GPU \(self.identity): resource \(blob.resource): \(error)")
          self.mappings[blob.resource] = nil
          mach_vm_deallocate(mach_task_self_, address, mach_vm_size_t(blob.size))
          if let element {
            response.replaceSubrange(
              0..<4, with: withUnsafeBytes(of: GPURenderer.errUnspecified) { Data($0) })
            self.answer(element, with: response)
          }
        } else if let element {
          self.answer(element, with: response)
        }
        if element == nil { self.remapsLeft = max(0, self.remapsLeft - 1) }
      }
    }
  }

  /// A blob out of the guest: out of the region, and this process's mapping of it let go.
  private func unmapBlob(_ resource: UInt32) {
    guard let mapping = mappings.removeValue(forKey: resource) else { return }
    device?.sharedMemoryRegions.first?.unmapMemory(atOffset: mapping.offset, size: mapping.size) {
      _ in
      mach_vm_deallocate(mach_task_self_, mapping.address, mach_vm_size_t(mapping.size))
    }
  }

  // MARK: Following VZ's screen

  /// VZ's screen took a new size: report it as this device's, so the guest takes it as its mode.
  func displayChanged(width: Int, height: Int) {
    queue.async { [self] in
      guard width > 0, height > 0,
        UInt32(width) != self.width || UInt32(height) != self.height
      else { return }
      self.width = UInt32(width)
      self.height = UInt32(height)
      if socket >= 0 {
        writer?.send(GPULink.encode(.display, value: self.width << 16 | self.height))
      }
      device?.update(
        VZVirtioDeviceSpecificConfiguration(configurationData: config(events: Self.eventDisplay))
      ) { _ in }
    }
  }

  // MARK: Save and restore

  /// Frames until one of `kind` comes, handled on the way; nil if the renderer goes or `timeout`
  /// passes. On the device's queue, which is the one the socket is read on.
  private func wait(for kind: GPULink.Kind, timeout: TimeInterval) -> GPULink.Frame? {
    let deadline = Date().addingTimeInterval(timeout)
    while socket >= 0, Date() < deadline {
      var poller = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
      guard poll(&poller, 1, 100) >= 0 || errno == EINTR else { return nil }
      guard poller.revents != 0 else { continue }
      guard let bytes = GPULink.read(from: socket) else {
        stopRenderer(leavingGuestPages: true)
        return nil
      }
      for frame in reader.feed(bytes) {
        if let wanted = handle(frame), wanted.kind == kind { return wanted }
      }
    }
    return nil
  }

  /// Which blob was mapped where: what the framework keeps with the machine's state.
  private struct Saved: Codable {
    var mappings: [UInt32: [UInt64]]
  }

  /// The machine is paused. The guest's last requests are let finish — their answers would be lost
  /// with the elements — and the renderer writes gfxstream's snapshot beside the machine's state.
  func customVirtioDeviceSaveState(forRestore device: VZCustomVirtioDevice) -> Data? {
    guard renderer != 0 else {
      // No renderer, nothing made: the guest has not started its driver.
      return try? JSONEncoder().encode(Saved(mappings: [:]))
    }
    let deadline = Date().addingTimeInterval(5)
    while !elements.isEmpty, Date() < deadline, socket >= 0 {
      _ = wait(for: .saved, timeout: 0.1)
    }
    guard elements.isEmpty else {
      GPULink.note("GPU \(identity): \(elements.count) requests unanswered at save")
      return nil
    }
    try? FileManager.default.removeItem(at: snapshot)
    writer?.send(GPULink.encode(.save, payload: Data(snapshot.path.utf8)))
    writer?.drain()
    guard let saved = wait(for: .saved, timeout: 60), saved.value == 0 else {
      GPULink.note("GPU \(identity): the renderer's snapshot failed")
      return nil
    }
    GPULink.note("GPU \(identity): saved, \(mappings.count) blobs mapped")
    return try? JSONEncoder().encode(
      Saved(mappings: mappings.mapValues { [$0.offset, $0.size] }))
  }

  /// A new renderer, from the snapshot; the blobs go back where they were once it has them, and
  /// `remapped` says when.
  func customVirtioDeviceShouldRestore(_ device: VZCustomVirtioDevice, saveState: Data) -> Bool {
    self.device = device
    guard let saved = try? JSONDecoder().decode(Saved.self, from: saveState) else { return false }
    guard FileManager.default.fileExists(atPath: snapshot.path) else {
      // Saved before the guest started its driver: nothing to bring back.
      return saved.mappings.isEmpty
    }
    startRenderer(on: device)
    guard renderer != 0 else { return false }
    writer?.send(GPULink.encode(.restore, payload: Data(snapshot.path.utf8)))
    writer?.drain()
    guard let restored = wait(for: .restored, timeout: 60), restored.value == 0 else {
      GPULink.note("GPU \(identity): the renderer could not restore")
      stopRenderer()
      return false
    }
    try? FileManager.default.removeItem(at: snapshot)
    // Its mappings come back by resource, each mapped where it was once the renderer has sent it.
    for (resource, placement) in saved.mappings {
      mappings[resource] = Mapping(offset: placement[0], size: placement[1], address: 0)
      remapsLeft += 1
      writer?.send(GPULink.encode(.exportBlob, value: resource, tag: 0))
    }
    GPULink.note("GPU \(identity): restored, \(saved.mappings.count) blobs to map again")
    return true
  }

  /// Whether every blob a restore is putting back is in place, which the machine resumes only after:
  /// a guest touching a blob not yet mapped would read nothing there.
  var remapped: Bool { queue.sync { remapsLeft == 0 } }

  // MARK: Delegate

  func customVirtioConfiguration(
    _ configuration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice
  ) {
    self.device = device
    device.delegate = self
  }

  func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
    GPULink.note("GPU \(identity): driver ok")
    startRenderer(on: device)
  }

  func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
    GPULink.note("GPU \(identity): reset")
    // A reboot resets the device; what the old driver made goes with its renderer. So does the
    // mapping of guest RAM: a guest rebooting in place is given its RAM anew, elsewhere, and a
    // renderer handed the old pages read the last boot's memory for whatever the guest drew in its
    // own — the boot splash and the cursor, as noise.
    stopRenderer()
    ram = nil
    DispatchQueue.main.async { [weak self] in self?.onReset?() }
  }

  func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) {
    GPULink.note("GPU \(identity): stop")
    stopRenderer()
    ram = nil
  }

  func customVirtioDevice(
    _ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue
  ) {
    while let element = queue.nextElement() {
      let size = element.readBuffersAvailableByteCount
      guard size > 0, let request = try? element.readBytes(withExactLength: size) else {
        element.returnToQueue()
        continue
      }
      // A capset the guest's kernel asks for is answered here once known: the kernel waits five
      // seconds for it and then boots on without the GPU, and a renderer, started again at each
      // of the boot's resets, took up to twelve.
      if let known = GPUCapsets.answer(to: request) {
        answer(element, with: known)
        continue
      }
      if ramAttemptsLeft != nil {
        held.append((element, request, queue.queueIndex))
        continue
      }
      guard socket >= 0 else {
        // No renderer to ask: a command is answered with an error rather than left unanswered,
        // which a guest waits on for ever — its boot stopped there when a renderer could not start.
        answer(element, with: Self.unanswerable(request))
        continue
      }
      forward(element, request: request, queue: queue.queueIndex)
    }
  }

  private func forward(_ element: VZVirtioQueueElement, request: Data, queue: UInt16) {
    // A blob leaving the guest leaves the region here, where it was put in; the renderer is told
    // too, and answers.
    if request.count >= 28 {
      let command = GPURenderer.Command(rawValue: request.u32(0))
      if command == .resourceUnmapBlob || command == .resourceUnref {
        unmapBlob(request.u32(24))
      }
    }
    let tag = nextTag
    nextTag += 1
    elements[tag] = Pending(element: element, request: request.prefix(32))
    writer?.send(GPULink.encode(.request, value: UInt32(queue), tag: tag, payload: request))
  }
}

/// The GPU's screen, laid over VZ's in the tab: the IOSurface the renderer last drew into, shown by
/// a plain layer, and the guest's cursor on a layer above. It takes no events: they go through to
/// VZ's view below, which hands them on.
@available(macOS 27, *)
final class GPUScreenView: NSView {
  private let screen = CALayer()
  private let cursor = CALayer()
  private var cursorHot = (0, 0)
  private var cursorPosition = (0, 0)
  private var screenSize = (width: 0, height: 0)
  /// Whether the tab is showing the guest's screen at all (VZ's view is not hidden), and whether the
  /// guest has scanned anything out of the device yet: until it has, VZ's screen — the boot's text
  /// console — is what there is to see.
  var shown = true {
    didSet { updateHidden() }
  }
  private var hasFrame = false {
    didSet { updateHidden() }
  }
  private func updateHidden() { isHidden = !(shown && hasFrame) }

  /// VZ's screen, whose size the device mirrors so the guest's mode and the pointer agree.
  private var displayObserver: DisplayObserver?
  private final class DisplayObserver: NSObject, VZGraphicsDisplayObserver {
    let gpu: GPUDevice
    init(gpu: GPUDevice) { self.gpu = gpu }
    func displayDidReconfigure(_ display: VZGraphicsDisplay) {
      gpu.displayChanged(
        width: Int(display.sizeInPixels.width), height: Int(display.sizeInPixels.height))
    }
  }
  func follow(_ display: VZGraphicsDisplay?, gpu: GPUDevice) {
    guard let display else { return }
    let observer = DisplayObserver(gpu: gpu)
    display.addObserver(observer)
    displayObserver = observer
    observer.displayDidReconfigure(display)
  }

  init(gpu: GPUDevice) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    // Fitted the way VZ's view fits its screen, so the pointer lands where it is drawn.
    screen.contentsGravity = .resizeAspect
    screen.magnificationFilter = .linear
    layer?.addSublayer(screen)
    cursor.magnificationFilter = .nearest
    cursor.isHidden = true
    layer?.addSublayer(cursor)
    isHidden = true
    gpu.onFrame = { [weak self] surface in
      guard let self else { return }
      self.hasFrame = true
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      self.screen.contents = surface
      CATransaction.commit()
      let size = (IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface))
      if size != self.screenSize {
        self.screenSize = size
        self.placeCursor()
      }
    }
    gpu.onCursorImage = { [weak self] image, hotX, hotY in
      guard let self else { return }
      self.cursorHot = (hotX, hotY)
      self.cursor.contents = image
      self.cursor.isHidden = image == nil
      self.placeCursor()
    }
    gpu.onCursorMove = { [weak self] x, y in
      self?.cursorPosition = (x, y)
      self?.placeCursor()
    }
    // A reset: the old driver's last frame and cursor go, and VZ's screen beneath shows until the
    // new renderer's first frame — the firmware's, and the boot's until the guest draws on the GPU.
    gpu.onReset = { [weak self] in
      guard let self else { return }
      self.hasFrame = false
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      self.screen.contents = nil
      self.cursor.contents = nil
      CATransaction.commit()
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    screen.frame = bounds
    CATransaction.commit()
    placeCursor()
  }

  /// The cursor's frame in the view, from screen pixels (top-left origin) through the same fit the
  /// screen is drawn with.
  private func placeCursor() {
    guard let image = cursor.contents, screenSize.width > 0 else { return }
    let (w, h) = (CGFloat(screenSize.width), CGFloat(screenSize.height))
    let scale = min(bounds.width / w, bounds.height / h)
    let origin = CGPoint(x: (bounds.width - w * scale) / 2, y: (bounds.height - h * scale) / 2)
    let size = CGSize(
      width: CGFloat((image as! CGImage).width) * scale,
      height: CGFloat((image as! CGImage).height) * scale)
    let left = CGFloat(cursorPosition.0 - cursorHot.0) * scale
    let top = CGFloat(cursorPosition.1 - cursorHot.1) * scale
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    cursor.frame = CGRect(
      x: origin.x + left, y: origin.y + h * scale - top - size.height, width: size.width,
      height: size.height)
    CATransaction.commit()
  }
}

/// The GPU's capsets, as its renderer answers them: the same for every renderer this process starts,
/// so known once and answered by the device itself. A guest's kernel asks for them as virtio_gpu
/// loads and waits five seconds; a renderer started again at each of a boot's device resets took up
/// to twelve to start, and a guest it was late for booted on llvmpipe. Asked for by the device as
/// each renderer starts (`probes`), and learnt from the answers to the guest's own requests too. In
/// memory only: the first renderer a boot starts, at the firmware's DRIVER_OK, has answered them
/// before the kernel's own reset and question, and a file would only have had to be told apart per
/// build and per Mac.
enum GPUCapsets {
  private static let lock = NSLock()
  private static var known: [String: Data] = [:]

  /// GET_CAPSET_INFO for capset index 0 and GET_CAPSET for gfxstream's Vulkan at version 0, the
  /// two a guest asks for.
  static let probes: [Data] = {
    var info = Data()
    for value in [GPURenderer.Command.getCapsetInfo.rawValue, 0, 0, 0, 0, 0, 0, 0] as [UInt32] {
      info.put32(value)
    }
    var capset = Data()
    for value in [
      GPURenderer.Command.getCapset.rawValue, 0, 0, 0, 0, 0, GPURenderer.capsetGfxstreamVulkan, 0,
    ] as [UInt32] {
      capset.put32(value)
    }
    return [info, capset]
  }()

  /// What a capset request is answered with, once known; nil for any other request, and for a
  /// fenced one, whose answer the renderer's timeline orders.
  static func answer(to request: Data) -> Data? {
    guard let key = key(for: request), request.u32(4) & GPURenderer.flagFence == 0 else {
      return nil
    }
    lock.lock()
    defer { lock.unlock() }
    guard let body = known[key] else { return nil }
    var response = Data()
    response.put32(key.hasPrefix("info") ? GPURenderer.okCapsetInfo : GPURenderer.okCapset)
    response.put32(0)
    response.append(request[request.startIndex + 8..<request.startIndex + 24])
    response.append(body)
    return response
  }

  static func learn(_ response: Data, for request: Data) {
    guard let key = key(for: request), response.count > 24 else { return }
    let status = response.u32(0)
    guard status == GPURenderer.okCapsetInfo || status == GPURenderer.okCapset else { return }
    let body = response.subdata(in: response.startIndex + 24..<response.endIndex)
    lock.lock()
    known[key] = body
    lock.unlock()
  }

  private static func key(for request: Data) -> String? {
    guard request.count >= 32 else { return nil }
    switch GPURenderer.Command(rawValue: request.u32(0)) {
    case .getCapsetInfo: return "info \(request.u32(24))"
    case .getCapset: return "capset \(request.u32(24)) \(request.u32(28))"
    default: return nil
    }
  }
}
