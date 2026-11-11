import AppKit

/// The screen of a machine QEMU is running, spoken to over a unix socket. No port: a listener on
/// localhost is open to every process on the machine, and a socket in a directory is not.
///
/// This is an RFB client for one server. QEMU is on the same Mac, so nothing is compressed — raw
/// rectangles only — and QEMU's own extension to the protocol carries keys as physical key
/// positions rather than characters, so the guest's keyboard layout is the guest's business.
final class QEMUDisplayClient {
  /// Told, on the main thread, of each finished update.
  var onFrame: ((CGImage) -> Void)?
  /// Told, on the main thread, when the connection has ended.
  var onClose: (() -> Void)?

  private let path: String
  private var descriptor: Int32 = -1
  private let writes = DispatchQueue(label: "hukan.qemu-display.write")
  private var width = 0
  private var height = 0
  private var pixels = Data()
  private var closed = false

  init(socket path: String) {
    self.path = path
  }

  // Internal so socketpair fixtures exercise the protocol without a running QEMU.
  func receive(descriptor: Int32) throws {
    self.descriptor = descriptor
    try handshake()
    try readMessages()
  }

  func start() {
    Thread.detachNewThread { [self] in
      do {
        try connectToServer()
        try handshake()
        requestUpdate(incremental: false)
        try readMessages()
      } catch {
        // The machine stopping is the usual way this ends.
      }
      DispatchQueue.main.async { [self] in onClose?() }
    }
  }

  func stop() {
    closed = true
    if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
  }

  // MARK: Input

  /// A position in the guest's pixels, and which buttons are down (1 left, 2 middle, 4 right).
  func sendPointer(x: Int, y: Int, buttons: UInt8) {
    var message = Data([5, buttons])
    message.appendBigEndian(UInt16(clamping: x))
    message.appendBigEndian(UInt16(clamping: y))
    send(message)
  }

  /// A physical key, as QEMU numbers them.
  func sendKey(code: UInt32, down: Bool) {
    var message = Data([255, 0])
    message.appendBigEndian(UInt16(down ? 1 : 0))
    message.appendBigEndian(UInt32(0))
    message.appendBigEndian(code)
    send(message)
  }

  // MARK: The protocol

  private func connectToServer() throws {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw MachineError("Could not open a socket.") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      close(fd)
      throw MachineError("The display's socket path is too long.")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    for _ in 0..<200 where !closed {
      let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
      }
      if result == 0 {
        descriptor = fd
        return
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    close(fd)
    throw MachineError("The machine's display did not open.")
  }

  private func handshake() throws {
    _ = try read(12)
    try writeAll(Data("RFB 003.008\n".utf8))
    let count = try read(1)[0]
    let types = try read(Int(count))
    guard types.contains(1) else { throw MachineError("The display asks for a password.") }
    try writeAll(Data([1]))
    guard try readUInt32() == 0 else { throw MachineError("The display refused the connection.") }
    try writeAll(Data([1]))  // shared
    width = Int(try readUInt16())
    height = Int(try readUInt16())
    try checkSize(width, height)
    _ = try read(16)
    try skip(Int(try readUInt32()))
    pixels = Data(count: width * height * 4)

    // 32-bit little-endian BGRX, so a pixel can go to CoreGraphics as it arrives.
    var format = Data([0, 0, 0, 0, 32, 24, 0, 1])
    for _ in 0..<3 { format.appendBigEndian(UInt16(255)) }
    format.append(contentsOf: [16, 8, 0, 0, 0, 0])
    try writeAll(format)
    let encodings: [Int32] = [
      0,  // raw
      -223,  // the desktop changing size
      -258,  // QEMU's keys by position
    ]
    var message = Data([2, 0])
    message.appendBigEndian(UInt16(encodings.count))
    for encoding in encodings { message.appendBigEndian(UInt32(bitPattern: encoding)) }
    try writeAll(message)
  }

  private func requestUpdate(incremental: Bool) {
    var message = Data([3, incremental ? 1 : 0])
    message.appendBigEndian(UInt16(0))
    message.appendBigEndian(UInt16(0))
    message.appendBigEndian(UInt16(clamping: width))
    message.appendBigEndian(UInt16(clamping: height))
    send(message)
  }

  private func readMessages() throws {
    while !closed {
      switch try read(1)[0] {
      case 0:
        try readUpdate()
      case 1:  // colour map, which a true-colour format never needs
        _ = try read(3)
        _ = try read(Int(try readUInt16()) * 6)
      case 2:  // bell
        break
      case 3:  // the guest's clipboard
        _ = try read(3)
        try skip(Int(try readUInt32()))
      default:
        throw MachineError("The display sent something not understood.")
      }
    }
  }

  private func readUpdate() throws {
    _ = try read(1)
    let count = Int(try readUInt16())
    for _ in 0..<count {
      let x = Int(try readUInt16())
      let y = Int(try readUInt16())
      let w = Int(try readUInt16())
      let h = Int(try readUInt16())
      switch Int32(bitPattern: try readUInt32()) {
      case 0:
        // Checked before the body is read, so a length is never an allocation the server chose.
        guard x + w <= width, y + h <= height else {
          throw MachineError("The display sent a rectangle outside its screen.")
        }
        let row = w * 4
        let data = try read(row * h)
        let stride = width * 4
        pixels.withUnsafeMutableBytes { target in
          data.withUnsafeBytes { source in
            for line in 0..<h where y + line < height && x + w <= width {
              memcpy(
                target.baseAddress! + (y + line) * stride + x * 4,
                source.baseAddress! + line * row, row)
            }
          }
        }
      case -223:
        try checkSize(w, h)
        width = w
        height = h
        pixels = Data(count: w * h * 4)
      default:
        break  // -258 only says the server understood; it carries nothing
      }
    }
    publish()
    requestUpdate(incremental: true)
  }

  private func publish() {
    guard width > 0, height > 0, let provider = CGDataProvider(data: pixels as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(
          rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return }
    DispatchQueue.main.async { [self] in onFrame?(image) }
  }

  /// The largest screen taken: the guest's largest mode with room to spare, and a bound on what a
  /// size the server sends can cost.
  private func checkSize(_ width: Int, _ height: Int) throws {
    guard width <= 8192, height <= 8192 else {
      throw MachineError("The display asked for a screen of \(width)x\(height).")
    }
  }

  /// Reads past what is not wanted a piece at a time, whatever length it claims.
  private func skip(_ count: Int) throws {
    var left = count
    while left > 0 {
      left -= try read(min(left, 65536)).count
    }
  }

  private func read(_ count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let got = data.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress! + offset, count - offset)
      }
      guard got > 0 else { throw MachineError("The display closed.") }
      offset += got
    }
    return data
  }

  private func readUInt16() throws -> UInt16 {
    let data = try read(2)
    return UInt16(data[0]) << 8 | UInt16(data[1])
  }

  private func readUInt32() throws -> UInt32 {
    try read(4).reduce(0) { $0 << 8 | UInt32($1) }
  }

  private func send(_ data: Data) {
    writes.async { [self] in try? writeAll(data) }
  }

  private func writeAll(_ data: Data) throws {
    var offset = 0
    while offset < data.count {
      let sent = data.withUnsafeBytes {
        write(descriptor, $0.baseAddress! + offset, data.count - offset)
      }
      guard sent > 0 else { throw MachineError("The display closed.") }
      offset += sent
    }
  }
}

extension Data {
  fileprivate mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
}

/// What a QEMU machine's screen is drawn in, and where its keyboard and mouse come from.
final class QEMUScreenView: NSView {
  private var client: QEMUDisplayClient?
  private var pixelSize = CGSize.zero
  private var buttons: UInt8 = 0
  private var heldModifiers = NSEvent.ModifierFlags()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    layer?.contentsGravity = .resizeAspect
    updateTrackingAreas()
  }

  required init?(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  /// The screen gaining (true) or losing the keyboard — by a click elsewhere, or by this window, or
  /// this app, giving it up while the screen still holds it, which is how a copy made in the
  /// guest is most often carried to another app.
  var onFocus: ((Bool) -> Void)?

  override func becomeFirstResponder() -> Bool {
    onFocus?(true)
    return true
  }

  override func resignFirstResponder() -> Bool {
    onFocus?(false)
    return true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self)
    guard let window else { return }
    for (name, focused) in [
      (NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false),
    ] {
      NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
        [weak self] _ in
        guard let self, self.window?.firstResponder === self else { return }
        self.onFocus?(focused)
      }
    }
  }

  func connect(socket: String) {
    let client = QEMUDisplayClient(socket: socket)
    client.onFrame = { [weak self] image in
      self?.pixelSize = CGSize(width: image.width, height: image.height)
      self?.layer?.contents = image
    }
    self.client = client
    client.start()
  }

  func disconnect() {
    client?.stop()
    client = nil
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
  }

  // MARK: The mouse

  /// Where a point in the view falls on the guest's screen, which is scaled to fit and centred.
  private func guestPoint(_ event: NSEvent) -> (x: Int, y: Int)? {
    guard pixelSize.width > 0, bounds.width > 0, bounds.height > 0 else { return nil }
    let point = convert(event.locationInWindow, from: nil)
    let scale = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
    let originX = (bounds.width - pixelSize.width * scale) / 2
    let originY = (bounds.height - pixelSize.height * scale) / 2
    let x = (point.x - originX) / scale
    let y = pixelSize.height - (point.y - originY) / scale
    guard x >= 0, y >= 0, x < pixelSize.width, y < pixelSize.height else { return nil }
    return (Int(x), Int(y))
  }

  private func sendPointer(_ event: NSEvent, extra: UInt8 = 0) {
    guard let point = guestPoint(event) else { return }
    client?.sendPointer(x: point.x, y: point.y, buttons: buttons | extra)
  }

  private func press(_ bit: UInt8, _ event: NSEvent) {
    window?.makeFirstResponder(self)
    buttons |= bit
    sendPointer(event)
  }

  private func release(_ bit: UInt8, _ event: NSEvent) {
    buttons &= ~bit
    sendPointer(event)
  }

  override func mouseDown(with event: NSEvent) { press(1, event) }
  override func mouseUp(with event: NSEvent) { release(1, event) }
  override func rightMouseDown(with event: NSEvent) { press(4, event) }
  override func rightMouseUp(with event: NSEvent) { release(4, event) }
  override func otherMouseDown(with event: NSEvent) { press(2, event) }
  override func otherMouseUp(with event: NSEvent) { release(2, event) }
  override func mouseMoved(with event: NSEvent) { sendPointer(event) }
  override func mouseDragged(with event: NSEvent) { sendPointer(event) }
  override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
  override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

  override func scrollWheel(with event: NSEvent) {
    guard event.scrollingDeltaY != 0 else { return }
    // A wheel is a button pressed and let go: 8 up, 16 down.
    sendPointer(event, extra: event.scrollingDeltaY > 0 ? 8 : 16)
    sendPointer(event)
  }

  // MARK: The keyboard

  /// With the keyboard on the machine, a shortcut is the machine's: AppKit would otherwise offer it
  /// to the menus first, and ⌘W would close the tab rather than reach the guest. ⌃⌘ stays hukan's,
  /// the family that says what the window is showing, so there is always a way out by keyboard.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self, event.type == .keyDown,
      !event.modifierFlags.isSuperset(of: [.control, .command])
    else { return super.performKeyEquivalent(with: event) }
    // AppKit never delivers the release of a key pressed with ⌘, so it is sent here as well.
    sendKey(event, down: true)
    if event.modifierFlags.contains(.command) { sendKey(event, down: false) }
    return true
  }

  override func keyDown(with event: NSEvent) { sendKey(event, down: true) }

  override func keyUp(with event: NSEvent) {
    // macOS keeps the press of 英数 and かな for its own input-source switching, and lets only the
    // release through to a view. So a release of either is the whole keystroke.
    if event.keyCode == 102 || event.keyCode == 104 { sendKey(event, down: true) }
    sendKey(event, down: false)
  }

  private func sendKey(_ event: NSEvent, down: Bool) {
    guard let code = Self.qemuKeys[event.keyCode] else { return }
    client?.sendKey(code: code, down: down)
  }

  override func flagsChanged(with event: NSEvent) {
    guard let code = Self.qemuKeys[event.keyCode],
      let flag = Self.modifierFlags[event.keyCode]
    else { return }
    client?.sendKey(code: code, down: event.modifierFlags.contains(flag))
  }

  private static let modifierFlags: [UInt16: NSEvent.ModifierFlags] = [
    55: .command, 54: .command, 56: .shift, 60: .shift, 58: .option, 61: .option, 59: .control,
    62: .control, 57: .capsLock,
  ]

  /// A Mac key's position, as QEMU numbers the same position: scan code set 1, with 0x80 added for
  /// the keys that set prefixes with E0. ⌘ is the Windows key, where a Mac keyboard has it.
  // Internal so physical key positions can be checked without the host keyboard.
  static let qemuKeys: [UInt16: UInt32] = [
    0: 0x1E, 1: 0x1F, 2: 0x20, 3: 0x21, 4: 0x23, 5: 0x22, 6: 0x2C, 7: 0x2D, 8: 0x2E, 9: 0x2F,
    11: 0x30, 12: 0x10, 13: 0x11, 14: 0x12, 15: 0x13, 16: 0x15, 17: 0x14, 18: 0x02, 19: 0x03,
    20: 0x04, 21: 0x05, 22: 0x07, 23: 0x06, 24: 0x0D, 25: 0x0A, 26: 0x08, 27: 0x0C, 28: 0x09,
    29: 0x0B, 30: 0x1B, 31: 0x18, 32: 0x16, 33: 0x1A, 34: 0x17, 35: 0x19, 36: 0x1C, 37: 0x26,
    38: 0x24, 39: 0x28, 40: 0x25, 41: 0x27, 42: 0x2B, 43: 0x33, 44: 0x35, 45: 0x31, 46: 0x32,
    47: 0x34, 48: 0x0F, 49: 0x39, 50: 0x29, 51: 0x0E, 53: 0x01, 54: 0xDC, 55: 0xDB, 56: 0x2A,
    57: 0x3A, 58: 0x38, 59: 0x1D, 60: 0x36, 61: 0xB8, 62: 0x9D, 65: 0x53, 67: 0x37, 69: 0x4E,
    71: 0x45, 75: 0xB5, 76: 0x9C, 78: 0x4A, 82: 0x52, 83: 0x4F, 84: 0x50, 85: 0x51, 86: 0x4B,
    87: 0x4C, 88: 0x4D, 89: 0x47, 91: 0x48, 92: 0x49, 93: 0x7D, 94: 0x73, 96: 0x3F, 97: 0x40,
    98: 0x41, 99: 0x3D, 100: 0x42, 101: 0x43, 102: 0x7B, 103: 0x57, 104: 0x70, 109: 0x44,
    111: 0x58, 115: 0xC7, 116: 0xC9, 117: 0xD3, 118: 0x3E, 119: 0xCF, 120: 0x3C, 121: 0xD1,
    122: 0x3B, 123: 0xCB, 124: 0xCD, 125: 0xD0, 126: 0xC8,
  ]
}
