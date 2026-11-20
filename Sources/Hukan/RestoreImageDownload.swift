import CryptoKit
import Foundation
import Virtualization

/// Bringing an image a template can be made from into the store's `Images`: the latest macOS, an
/// address someone gave, or a file already on this Mac.
///
/// The latest is one of the few requests hukan makes for itself: Virtualization.framework says
/// where the newest IPSW this Mac supports is — a file Apple publishes on its CDN — and hukan
/// fetches it. Nothing is sent but the GET, no credential and nothing about the work, which is the
/// line the update check already draws. An older one is an address the person brings: nothing
/// lists them but third parties, and a list kept here would be stale the day after a release. The file is tens of gigabytes, so it goes to a `.download` name beside the
/// others and takes its real name only once it is whole: a half-fetched IPSW must never be
/// offered to a template.
final class RestoreImageDownload: NSObject, URLSessionDownloadDelegate {
  /// Where the image comes from.
  enum Source {
    case latest
    case address(URL)
    /// An address whose publisher states the file's SHA-256, which the download is held to.
    case checked(URL, sha256: String)
    case file(URL)
    /// Windows, as Microsoft's ESD in one language, made into an ISO once it is here.
    case windows(WindowsImage)
  }

  enum State: Equatable {
    case locating
    case copying
    case downloading(Double)
    case packages(String)
    case building(String)
    case done(URL)
    case failed(String)
  }

  private(set) var state: State = .locating
  private(set) var name: String?
  var onChange: (() -> Void)?

  private let cancellation = Progress(totalUnitCount: 1)

  private var session: URLSession?
  private var task: URLSessionDownloadTask?
  private let source: Source
  private var expectedSHA256: String? {
    switch source {
    case .checked(_, let sha256): return sha256.lowercased()
    case .windows(let image): return image.sha256.lowercased()
    default: return nil
    }
  }

  init(_ source: Source = .latest) {
    self.source = source
    switch source {
    case .latest: break
    case .address(let url), .checked(let url, _), .file(let url): name = url.lastPathComponent
    case .windows(let image): name = image.isoName
    }
  }

  func start() {
    guard !cancellation.isCancelled else { return }
    switch source {
    case .latest: locateLatest()
    case .address(let url), .checked(let url, _): fetch(url)
    case .file(let url): copy(url)
    case .windows(let image): fetch(image.url)
    }
  }

  private func fetch(_ url: URL) {
    let destination = MachineStore.imagesURL.appendingPathComponent(name ?? url.lastPathComponent)
    if FileManager.default.fileExists(atPath: destination.path) {
      // An ISO this built is not what Microsoft's checksum is of, and was put in place only
      // after the ESD it came from had passed it.
      if case .windows = source {
        imageReady(destination)
        return
      }
      guard let expected = expectedSHA256 else {
        imageReady(destination)
        return
      }
      state = .copying
      onChange?()
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        let actual = Self.sha256(of: destination)
        DispatchQueue.main.async { [self] in
          guard !cancellation.isCancelled else { return }
          if actual == expected {
            imageReady(destination)
          } else {
            finish(.failed("The existing ISO does not match its publisher's checksum."))
          }
        }
      }
      return
    }
    let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    self.session = session
    let task = session.downloadTask(with: url)
    self.task = task
    state = .downloading(0)
    onChange?()
    task.resume()
  }

  /// A clone where the file is on the same volume, so a file already here costs nothing; a copy
  /// from elsewhere is a minute of a disk, so it is done off the main thread, under the same
  /// `.download` name a fetch is.
  private func copy(_ file: URL) {
    state = .copying
    onChange?()
    MachineStore.prepare()
    let destination = MachineStore.imagesURL.appendingPathComponent(file.lastPathComponent)
    let partial = destination.appendingPathExtension("download")
    DispatchQueue.global(qos: .userInitiated).async {
      // Held until the copy is in place, packages and all, so another hukan starting meanwhile
      // does not take it for one left behind. Taken here, not on the main thread: it waits for
      // a claim an earlier copy of the same file still holds, and that one is let go on main.
      let claim = MachineStore.Claim.take(partial)
      let result = Result {
        if FileManager.default.fileExists(atPath: destination.path) { return false }
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.copyItem(at: file, to: partial)
        return true
      }
      DispatchQueue.main.async { [self] in
        let release: () -> Void = { claim?.release() }
        switch result {
        case .success(true): settle(partial, at: destination, then: release)
        case .success(false):
          release()
          imageReady(destination)
        case .failure(let error):
          release()
          finish(.failed(error.localizedDescription))
        }
      }
    }
  }

  private func locateLatest() {
    VZMacOSRestoreImage.fetchLatestSupported { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .failure(let error):
          self.finish(.failed(error.localizedDescription))
        case .success(let image):
          self.name = image.url.lastPathComponent
          self.fetch(image.url)
        }
      }
    }
  }

  func cancel() {
    cancellation.cancel()
    task?.cancel()
    session?.invalidateAndCancel()
    finish(.failed("Cancelled"))
  }

  private func finish(_ state: State) {
    guard !cancellation.isCancelled || state == .failed("Cancelled") else { return }
    self.state = state
    session?.finishTasksAndInvalidate()
    session = nil
    onChange?()
  }

  // MARK: URLSessionDownloadDelegate

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    guard !cancellation.isCancelled, totalBytesExpectedToWrite > 0 else { return }
    let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    // A redraw per percent, not per packet.
    if case .downloading(let shown) = state, Int(fraction * 100) == Int(shown * 100) { return }
    state = .downloading(fraction)
    onChange?()
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard !cancellation.isCancelled, let name else { return }
    MachineStore.prepare()
    let destination = MachineStore.imagesURL.appendingPathComponent(name)
    let partial = destination.appendingPathExtension("download")
    // Claimed before anything is written there, and without waiting: a claim already held is
    // another hukan adding the same ISO, whose file this must not replace.
    guard let (_, claim) = MachineStore.Claim.takeAbandoned(partial) else {
      finish(.failed("Another hukan is adding this ISO."))
      return
    }
    if case .windows = source {
      buildWindows(from: location, partial: partial, at: destination, claim: claim)
      return
    }
    do {
      // Moved out of the system's temporary file within this call — it is gone once it returns —
      // and renamed into place only once it is all there.
      try? FileManager.default.removeItem(at: partial)
      try FileManager.default.moveItem(at: location, to: partial)
    } catch {
      claim.release()
      finish(.failed(error.localizedDescription))
      return
    }
    guard let expected = expectedSHA256 else {
      settle(partial, at: destination, then: claim.release)
      return
    }
    // A download that stopped short, or came from somewhere else, is not offered to a template.
    state = .copying
    onChange?()
    DispatchQueue.global(qos: .userInitiated).async {
      let actual = Self.sha256(of: partial)
      DispatchQueue.main.async { [weak self] in
        let release: () -> Void = { claim.release() }
        guard actual == expected else {
          try? FileManager.default.removeItem(at: partial)
          release()
          self?.finish(.failed("The download failed its checksum and was not kept."))
          return
        }
        guard let self else { return release() }
        self.settle(partial, at: destination, then: release)
      }
    }
  }

  /// Windows comes as an ESD, which is checked against the catalog and then made into the ISO, all
  /// inside a `.download` directory: a quit or a cancel partway leaves one thing for the store to
  /// sweep, as a half-fetched file would.
  private func buildWindows(
    from location: URL, partial: URL, at destination: URL, claim: MachineStore.Claim
  ) {
    let esd = partial.appendingPathComponent("image.esd")
    do {
      try? FileManager.default.removeItem(at: partial)
      try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: location, to: esd)
    } catch {
      try? FileManager.default.removeItem(at: partial)
      claim.release()
      finish(.failed(error.localizedDescription))
      return
    }
    let expected = expectedSHA256
    let cancellation = cancellation
    state = .copying
    onChange?()
    DispatchQueue.global(qos: .userInitiated).async {
      let result = Result<URL, Error> {
        guard Self.sha256(of: esd) == expected else {
          throw MachineError("The download failed its checksum and was not kept.")
        }
        DispatchQueue.main.async { [weak self] in
          guard let self, !cancellation.isCancelled else { return }
          self.state = .building("Making the ISO…")
          self.onChange?()
        }
        let iso = partial.appendingPathComponent("image.iso")
        try WindowsImage.makeISO(from: esd, at: iso, in: partial, cancellation: cancellation)
        try FileManager.default.moveItem(at: iso, to: destination)
        return destination
      }
      try? FileManager.default.removeItem(at: partial)
      DispatchQueue.main.async { [weak self] in
        claim.release()
        guard let self, !cancellation.isCancelled else { return }
        switch result {
        case .success(let url): self.finish(.done(url))
        case .failure(let error): self.finish(.failed(error.localizedDescription))
        }
      }
    }
  }

  /// Put the download in place — after what an Ubuntu ISO lacks for an install has been fetched
  /// with it, still under its `.download` name: an ISO is offered only with everything a template
  /// made from it needs, so a fetch that fails or is cancelled takes the ISO with it rather than
  /// leaving one that would have to fetch again when a template is made.
  private func settle(_ partial: URL, at destination: URL, then done: @escaping () -> Void = {}) {
    guard !cancellation.isCancelled else {
      try? FileManager.default.removeItem(at: partial)
      done()
      return
    }
    guard UbuntuRelease.title(ofImage: destination) != nil else {
      place(partial, at: destination)
      done()
      return
    }
    fetchPackages(reading: partial) { [self] error in
      defer { done() }
      if let error {
        try? FileManager.default.removeItem(at: partial)
        finish(.failed(error))
      } else {
        place(partial, at: destination)
      }
    }
  }

  private func place(_ partial: URL, at destination: URL) {
    do {
      try FileManager.default.moveItem(at: partial, to: destination)
      finish(.done(destination))
    } catch {
      finish(.failed(error.localizedDescription))
    }
  }

  /// An ISO already in place from before: what it lacks is fetched now if it was not then, and a
  /// failure leaves the ISO as it was, since it was not this download that brought it.
  private func imageReady(_ destination: URL) {
    guard !cancellation.isCancelled else { return }
    guard UbuntuRelease.title(ofImage: destination) != nil else {
      finish(.done(destination))
      return
    }
    fetchPackages(reading: destination) { [self] error in
      finish(error.map { .failed($0) } ?? .done(destination))
    }
  }

  private func fetchPackages(reading iso: URL, then: @escaping (String?) -> Void) {
    state = .packages("Reading Ubuntu ISO…")
    onChange?()
    let cancellation = cancellation
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let result = Result {
        _ = try UbuntuPackages.prepare(
          iso: iso, cancellation: cancellation,
          progress: { message in
            DispatchQueue.main.async { [weak self] in
              guard let self, !cancellation.isCancelled else { return }
              self.state = .packages(message)
              self.onChange?()
            }
          })
      }
      DispatchQueue.main.async {
        // A cancel that came after the packages were kept is too late to undo them, so the ISO
        // they belong to is kept with them rather than leaving packages nothing can delete.
        // Earlier than that, the answer still goes back, so the ISO waiting on it goes.
        if cancellation.isCancelled, case .failure = result { return then("Cancelled") }
        switch result {
        case .success: then(nil)
        case .failure(let error): then(error.localizedDescription)
        }
      }
    }
  }

  /// The file's SHA-256, read a megabyte at a time: an ISO is gigabytes.
  static func sha256(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error, state != .failed("Cancelled") else { return }
    if case .done = state { return }
    finish(.failed(error.localizedDescription))
  }
}
