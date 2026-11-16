import AppKit
import IOSurface
import Virtualization

/// A Linux guest's GPU: a virtio-gpu of hukan's own, carrying the guest's OpenGL to this Mac's.
///
/// The guest's Mesa (its `virgl` driver) turns OpenGL into a command stream and sends it down a
/// virtio-gpu; virglrenderer replays it on macOS's OpenGL — 4.1 core, implemented over Metal, and
/// with the geometry shaders and transform feedback Metal itself lacks. Virtualization.framework has
/// no such device, and from macOS 27 lets a process implement one (`VZCustomVirtioDevice`).
///
/// This half is the device: it forwards each request to the machine's renderer, a process of its
/// own (`VirglRenderer`, over `VirglLink`), and writes back the answers. Guest RAM is handed to the
/// renderer once, as a Mach memory entry, so its transfers read and write the guest's pages
/// directly; nothing here touches GL.
///
/// The device also carries the guest's screen. Xorg is pinned to it (the template's job), and the
/// renderer draws what it scans out into IOSurfaces the tab shows (`VirglScreenView`). VZ's own
/// virtio screen stays configured beside it, unused by the guest, for the keyboard and pointer:
/// `VZVirtualMachineView` hands them to the guest only for a machine with a screen of VZ's, and maps
/// the pointer against it — so this device follows that screen's size.
///
/// What it does not carry: blobs (mapping one needs GL 4.4's persistent buffers) and a saved state
/// (vrend keeps no record of what it made), which is why a GPU machine cannot be suspended.
@available(macOS 27, *)
final class VirglGPU: NSObject, VZCustomVirtioDeviceConfigurationDelegate,
  VZCustomVirtioDeviceDelegate
{
  /// Where the generic platform puts guest RAM, as one range: measured from the guest
  /// (`/proc/iomem`'s System RAM), since the framework does not say.
  static let ramBase: UInt64 = 0x7000_0000
  private static let eventDisplay: UInt32 = 1

  /// The device for a configuration.
  static func make(width: Int, height: Int, memorySize: UInt64) -> (
    VZCustomVirtioDeviceConfiguration, VirglGPU
  ) {
    let gpu = VirglGPU(width: UInt32(width), height: UInt32(height), memorySize: memorySize)
    let configuration = VZCustomVirtioDeviceConfiguration()
    configuration.deviceID = 16  // virtio-gpu
    configuration.pciClassID = 0x03  // display
    configuration.pciSubclassID = 0x80  // other: VZ's own screen is the guest's VGA
    configuration.virtioQueueCount = 2  // control, cursor
    configuration.optionalFeatures.subset0 = 1 << 0  // VIRGL; no blobs, no context init
    configuration.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(
      configurationData: gpu.config(events: 0))
    configuration.supportsSaveRestore = false
    configuration.provider = VZCustomVirtioDeviceDelegateProvider(
      deviceQueue: gpu.queue, delegate: gpu)
    return (configuration, gpu)
  }

  // MARK: State

  private let queue = DispatchQueue(label: "hukan.virgl")
  private let identity = UUID().uuidString
  private var device: VZCustomVirtioDevice?
  private var width: UInt32
  private var height: UInt32
  private let memorySize: UInt64

  /// Elements handed to the renderer and not yet answered, by the tag they went with.
  private var elements: [UInt64: VZVirtioQueueElement] = [:]
  private var nextTag: UInt64 = 1

  // The renderer: its process, the socket to it, and the Mach service it finds this process by.
  private var renderer: pid_t = 0
  private var shutDownPermanently = false
  private var writer: VirglLink.Writer?
  private var socket: Int32 = -1
  private var readSource: DispatchSourceRead?
  private var reader = VirglLink.Reader()
  private var service: mach_port_t = 0
  private var ram: VZGuestMemoryMapping?

  /// Told on the main queue: a frame in this IOSurface, the guest's cursor image (nil hides it) and
  /// its hotspot, and the cursor's moves.
  var onFrame: ((IOSurfaceRef) -> Void)?
  var onCursorImage: ((CGImage?, Int, Int) -> Void)?
  var onCursorMove: ((Int, Int) -> Void)?
  /// The renderer's IOSurfaces by id; touched on the main queue only.
  private var surfaces: [IOSurfaceID: IOSurfaceRef] = [:]

  private init(width: UInt32, height: UInt32, memorySize: UInt64) {
    self.width = width
    self.height = height
    self.memorySize = memorySize
  }

  /// events_read, events_clear, num_scanouts, num_capsets.
  private func config(events: UInt32) -> Data {
    var data = Data()
    for value in [events, 0, 1, UInt32(VirglRenderer.capsets.count)] {
      Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }

  // MARK: The renderer's process

  /// Start the renderer: guest RAM to it as a memory entry, through a bootstrap name only it is told.
  private func startRenderer(on device: VZCustomVirtioDevice) {
    guard !shutDownPermanently, renderer == 0 else { return }
    guard
      let ram = device.guestMemoryMapping(
        atPhysicalAddress: Self.ramBase, length: Int(memorySize))
    else {
      VirglLink.note("could not map guest RAM")
      return
    }
    var entrySize = memory_object_size_t(memorySize)
    var entry: mach_port_t = 0
    guard
      mach_make_memory_entry_64(
        mach_task_self_, &entrySize, memory_object_offset_t(UInt(bitPattern: ram.mutableBytes)),
        VM_PROT_READ | VM_PROT_WRITE | MAP_MEM_VM_SHARE, &entry, 0) == KERN_SUCCESS
    else {
      VirglLink.note("could not share guest RAM")
      return
    }
    defer { mach_port_deallocate(mach_task_self_, entry) }
    let name = "com.tnayuki.hukan.virgl.\(getpid()).\(UUID().uuidString)"
    var service: mach_port_t = 0
    guard VirglLink.bootstrapCheckIn(bootstrap_port, name, &service) == KERN_SUCCESS else {
      VirglLink.note("could not register the renderer's name")
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
    posix_spawn_file_actions_adddup2(&actions, pair[1], VirglLink.socketDescriptor)
    posix_spawn_file_actions_addinherit_np(&actions, VirglLink.socketDescriptor)
    // Its stderr is the log, so a renderer that gives up says where.
    posix_spawn_file_actions_addopen(
      &actions, 2, VirglLink.logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    // Nothing of this process's but the socket: fd 3 is the one descriptor it is given.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let arguments = [
      executable, VirglLink.launchArgument, name, String(Self.ramBase), String(memorySize),
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
      VirglLink.note("the renderer did not start (\(spawned))")
      return
    }
    VirglLink.note(
      "renderer \(pid) started for \(memorySize >> 30) GB of guest RAM, GPU \(identity)")
    self.ram = ram
    self.renderer = pid
    self.socket = pair[0]
    self.service = service
    self.reader = VirglLink.Reader()
    ownsService = false
    writer = VirglLink.Writer(descriptor: pair[0], queue: queue) { [weak self] in
      self?.stopRenderer()
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

    // Mach on a thread of its own: the hello and RAM first, then the surfaces as they are made. It
    // ends when the service's right is destroyed.
    // Keep one send right to the entry until the handshake thread has finished with it.
    mach_port_mod_refs(mach_task_self_, entry, MACH_PORT_RIGHT_SEND, 1)
    Thread.detachNewThread { [weak self] in
      defer { mach_port_deallocate(mach_task_self_, entry) }
      guard let hello = VirglLink.receive(on: service), hello.id == VirglLink.helloID else {
        return
      }
      VirglLink.send([entry], id: VirglLink.memoryID, to: hello.reply)
      mach_port_deallocate(mach_task_self_, hello.reply)
      while let message = VirglLink.receive(on: service) {
        guard message.id == VirglLink.surfacesID else { continue }
        let made = message.ports.compactMap { port -> IOSurfaceRef? in
          defer { mach_port_deallocate(mach_task_self_, port) }
          return IOSurfaceLookupFromMachPort(port)
        }
        self?.queue.async { [weak self] in
          guard let self, self.renderer == pid else { return }
          DispatchQueue.main.async { [weak self] in
            self?.surfaces = Dictionary(uniqueKeysWithValues: made.map { (IOSurfaceGetID($0), $0) })
          }
        }
      }
    }
  }

  /// The renderer goes, and with it everything it made; what the guest is waiting on is dropped.
  private func stopRenderer() {
    guard renderer != 0 else { return }
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
      VirglLink.note("renderer \(pid) ended, status \(status)")
    }
    mach_port_mod_refs(mach_task_self_, service, MACH_PORT_RIGHT_RECEIVE, -1)
    service = 0
    ram = nil
    DispatchQueue.main.async { [weak self] in self?.surfaces = [:] }
    // An element has to go back to its queue before it is let go, or the framework aborts; these
    // go back unanswered.
    for element in elements.values { element.returnToQueue() }
    elements = [:]
  }

  /// The machine has stopped for good.
  func shutDown() {
    queue.sync {
      VirglLink.note("GPU \(identity): shut down")
      shutDownPermanently = true
      stopRenderer()
      device = nil
    }
  }

  private func readSocket() {
    guard let bytes = VirglLink.read(from: socket) else {
      VirglLink.note("the renderer's socket closed")
      stopRenderer()
      return
    }
    for frame in reader.feed(bytes) {
      switch frame.kind {
      case .response:
        guard let element = elements.removeValue(forKey: frame.tag) else { continue }
        var response = frame.payload
        if !response.isEmpty {
          let room = element.writeBuffersAvailableByteCount
          if room < response.count { response = response.prefix(room) }
          try? element.write(response)
        }
        element.returnToQueue()
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
      case .request, .display:
        break
      }
    }
  }

  private static func cursorImage(_ payload: Data) -> CGImage? {
    guard payload.count >= 8 else { return nil }
    let width = Int(
      payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) })
    let height = Int(
      payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
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
        writer?.send(VirglLink.encode(.display, value: self.width << 16 | self.height))
      }
      device?.update(
        VZVirtioDeviceSpecificConfiguration(configurationData: config(events: Self.eventDisplay))
      ) { _ in }
    }
  }

  // MARK: Delegate

  func customVirtioConfiguration(
    _ configuration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice
  ) {
    self.device = device
    device.delegate = self
  }

  func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
    VirglLink.note("GPU \(identity): driver ok")
    startRenderer(on: device)
  }

  func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
    VirglLink.note("GPU \(identity): reset")
    // A reboot resets the device; what the old driver made goes with its renderer.
    stopRenderer()
  }

  func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) {
    VirglLink.note("GPU \(identity): stop")
    stopRenderer()
  }

  func customVirtioDevice(
    _ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue
  ) {
    while let element = queue.nextElement() {
      let size = element.readBuffersAvailableByteCount
      guard socket >= 0, size > 0, let request = try? element.readBytes(withExactLength: size)
      else {
        element.returnToQueue()
        continue
      }
      let tag = nextTag
      nextTag += 1
      elements[tag] = element
      writer?.send(
        VirglLink.encode(.request, value: UInt32(queue.queueIndex), tag: tag, payload: request))
    }
  }
}

/// The GPU's screen, laid over VZ's in the tab: the IOSurface the renderer last drew into, shown by
/// a plain layer — no GL in this process — and the guest's cursor on a layer above. It takes no
/// events: they go through to VZ's view below, which hands them on.
@available(macOS 27, *)
final class VirglScreenView: NSView {
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
    let gpu: VirglGPU
    init(gpu: VirglGPU) { self.gpu = gpu }
    func displayDidReconfigure(_ display: VZGraphicsDisplay) {
      gpu.displayChanged(
        width: Int(display.sizeInPixels.width), height: Int(display.sizeInPixels.height))
    }
  }
  func follow(_ display: VZGraphicsDisplay?, gpu: VirglGPU) {
    guard let display else { return }
    let observer = DisplayObserver(gpu: gpu)
    display.addObserver(observer)
    displayObserver = observer
    observer.displayDidReconfigure(display)
  }

  init(gpu: VirglGPU) {
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
