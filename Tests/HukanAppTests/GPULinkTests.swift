import Darwin
import XCTest

@testable import Hukan

final class GPULinkTests: XCTestCase {
  func testDuplexBackpressurePreservesFramesAndLetsQueueRun() throws {
    var pair: [Int32] = [-1, -1]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
    let queue = DispatchQueue(label: "gpu.link.test")
    let delivered = expectation(description: "both peers receive both frames")
    delivered.expectedFulfillmentCount = 2
    let responsive = expectation(description: "the queue runs while both sockets are full")
    let payload = Data(repeating: 0xAB, count: 1 << 20)
    var writers: [GPULink.Writer] = []
    var sources: [DispatchSourceRead] = []
    queue.sync {
      for descriptor in pair {
        var capacity: Int32 = 1024
        setsockopt(
          descriptor, SOL_SOCKET, SO_SNDBUF, &capacity, socklen_t(MemoryLayout<Int32>.size))
        let writer = GPULink.Writer(descriptor: descriptor, queue: queue) {
          XCTFail("unexpected socket failure")
        }
        writers.append(writer)
        let reader = GPULink.Reader()
        var tags: [UInt64] = []
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler {
          guard let bytes = GPULink.read(from: descriptor) else {
            XCTFail("unexpected EOF")
            return
          }
          for frame in reader.feed(bytes) {
            XCTAssertEqual(frame.kind, .request)
            XCTAssertEqual(frame.payload, payload)
            tags.append(frame.tag)
            if tags.count == 2 {
              XCTAssertEqual(tags, [1, 2])
              delivered.fulfill()
            }
          }
        }
        source.setCancelHandler { close(descriptor) }
        sources.append(source)
        source.resume()
      }
      // Both writers run before either reader can run, and each frame exceeds the socket buffer.
      for writer in writers {
        for tag: UInt64 in [1, 2] {
          writer.send(GPULink.encode(.request, tag: tag, payload: payload))
        }
      }
      queue.async { responsive.fulfill() }
    }
    wait(for: [responsive, delivered], timeout: 10)
    queue.sync {
      for writer in writers { writer.cancel() }
      for source in sources { source.cancel() }
    }
  }

  func testClosedPeerReportsFailureWithoutSIGPIPE() {
    var pair: [Int32] = [-1, -1]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
    defer { close(pair[0]) }
    close(pair[1])
    let queue = DispatchQueue(label: "gpu.link.closed.test")
    queue.sync {
      var failures = 0
      let writer = GPULink.Writer(descriptor: pair[0], queue: queue) { failures += 1 }
      writer.send(Data([1]))
      XCTAssertEqual(failures, 1)
      writer.cancel()
    }
  }
}
