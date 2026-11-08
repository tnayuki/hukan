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
    case file(URL)
  }

  enum State: Equatable {
    case locating
    case copying
    case downloading(Double)
    case done(URL)
    case failed(String)
  }

  private(set) var state: State = .locating
  private(set) var name: String?
  var onChange: (() -> Void)?

  private var session: URLSession?
  private var task: URLSessionDownloadTask?
  private let source: Source

  init(_ source: Source = .latest) {
    self.source = source
    switch source {
    case .latest: break
    case .address(let url), .file(let url): name = url.lastPathComponent
    }
  }

  func start() {
    switch source {
    case .latest: locateLatest()
    case .address(let url): fetch(url)
    case .file(let url): copy(url)
    }
  }

  private func fetch(_ url: URL) {
    let destination = MachineStore.imagesURL.appendingPathComponent(url.lastPathComponent)
    if FileManager.default.fileExists(atPath: destination.path) {
      finish(.done(destination))
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
    DispatchQueue.global(qos: .userInitiated).async {
      let partial = destination.appendingPathExtension("download")
      let result = Result {
        if FileManager.default.fileExists(atPath: destination.path) { return }
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.copyItem(at: file, to: partial)
        try FileManager.default.moveItem(at: partial, to: destination)
      }
      DispatchQueue.main.async { [weak self] in
        switch result {
        case .success: self?.finish(.done(destination))
        case .failure(let error): self?.finish(.failed(error.localizedDescription))
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
    task?.cancel()
    session?.invalidateAndCancel()
    finish(.failed("Cancelled"))
  }

  private func finish(_ state: State) {
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
    guard totalBytesExpectedToWrite > 0 else { return }
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
    guard let name else { return }
    MachineStore.prepare()
    let destination = MachineStore.imagesURL.appendingPathComponent(name)
    let partial = destination.appendingPathExtension("download")
    do {
      // Moved out of the system's temporary file within this call — it is gone once it returns —
      // and renamed into place only once it is all there.
      try? FileManager.default.removeItem(at: partial)
      try FileManager.default.moveItem(at: location, to: partial)
      try FileManager.default.moveItem(at: partial, to: destination)
      finish(.done(destination))
    } catch {
      finish(.failed(error.localizedDescription))
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error, state != .failed("Cancelled") else { return }
    if case .done = state { return }
    finish(.failed(error.localizedDescription))
  }
}
