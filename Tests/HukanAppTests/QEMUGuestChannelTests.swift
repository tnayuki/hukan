import Darwin
import XCTest

@testable import Hukan

final class QEMUGuestChannelTests: XCTestCase {
  func testWindowsCommandsUsePowerShellAndUTF8WithoutShellQuotingTheCommand() {
    let command = "Write-Output '日本語 & <hello>'; $value = 42"
    XCTAssertEqual(
      WorktreeDeskViewController.guestCommand(command, windows: true),
      [
        "powershell.exe", "-NoProfile", "-Command",
        "[Console]::OutputEncoding = [Text.Encoding]::UTF8; " + command,
      ])
    XCTAssertEqual(
      WorktreeDeskViewController.guestCommand(command, windows: false),
      ["/bin/zsh", "-c", command])
  }

  func testRepliesMatchIDsOutOfOrderAcrossPartialAndCombinedLines() throws {
    var sockets: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
    defer { close(sockets[1]) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    for fd in sockets {
      XCTAssertEqual(
        setsockopt(
          fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
          socklen_t(MemoryLayout<timeval>.size)), 0)
    }
    let channel = QEMUGuestChannel(socket: "unused", half: "user")
    channel.receive(descriptor: sockets[0])
    let first = expectation(description: "first reply")
    let second = expectation(description: "second reply")
    let hello = expectation(description: "hello")
    channel.onHello = { hello.fulfill() }
    channel.send(["op": "first"]) { result in
      XCTAssertEqual(try? result.get()["value"] as? String, "first")
      first.fulfill()
    }
    channel.send(["op": "second"]) { result in
      XCTAssertEqual(try? result.get()["value"] as? String, "second")
      second.fulfill()
    }
    // Read actual request IDs, also ensuring each request is newline framed.
    var requests = Data()
    while requests.filter({ $0 == 10 }).count < 2 {
      var bytes = [UInt8](repeating: 0, count: 1024)
      let count = read(sockets[1], &bytes, bytes.count)
      guard count > 0 else { return XCTFail("Missing requests") }
      requests.append(contentsOf: bytes.prefix(count))
    }
    let objects = try requests.split(separator: 10).map {
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
    }
    let ids = try objects.map { try XCTUnwrap($0["id"] as? Int) }
    XCTAssertNotEqual(ids[0], ids[1])
    let readFinished = expectation(description: "connection ended")
    DispatchQueue.global().async {
      channel.readConnection()
      readFinished.fulfill()
    }
    func send(_ text: String) {
      let data = Data(text.utf8)
      XCTAssertEqual(
        data.withUnsafeBytes { write(sockets[1], $0.baseAddress, $0.count) }, data.count)
    }
    send("{\"id\":\(ids[1]),\"ok\":true,\"value\":\"sec")
    send("ond\"}\n{\"hello\":true}\n{\"id\":\(ids[0]),\"ok\":true,\"value\":\"first\"}\n")
    wait(for: [second, hello, first], timeout: 3, enforceOrder: true)
    channel.stop()
    wait(for: [readFinished], timeout: 3)
  }

  func testUnterminatedReplyPastLimitFailsPendingRequest() throws {
    var sockets: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
    defer { close(sockets[1]) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    for fd in sockets {
      XCTAssertEqual(
        setsockopt(
          fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
          socklen_t(MemoryLayout<timeval>.size)), 0)
    }
    let channel = QEMUGuestChannel(socket: "unused", half: "root")
    channel.receive(descriptor: sockets[0])
    let failed = expectation(description: "pending request failed")
    channel.send(["op": "ping"]) { result in
      if case .success = result { XCTFail("a reply past the limit was taken") }
      failed.fulfill()
    }
    // Drain the request before the reader closes its descriptor.
    var request = [UInt8](repeating: 0, count: 1024)
    XCTAssertGreaterThan(read(sockets[1], &request, request.count), 0)
    let bytes = Data(repeating: 65, count: 65)
    XCTAssertEqual(bytes.withUnsafeBytes { write(sockets[1], $0.baseAddress, $0.count) }, 65)
    let finished = expectation(description: "reader gave up while peer remains open")
    DispatchQueue.global().async {
      channel.readConnection(replyLimit: 64)
      finished.fulfill()
    }
    wait(for: [failed, finished], timeout: 3)
  }
}
