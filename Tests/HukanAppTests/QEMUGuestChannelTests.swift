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
    channel.onHello = { _ in hello.fulfill() }
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

  func testAUserHalfThatEndsIsDroppedOnTheRootHalfsWordAndANewOneArrives() throws {
    let qemu = QEMUMachine(machine: QEMUMachineTests.machine(at: URL(fileURLWithPath: "/unused")))
    var guests: [String: Int32] = [:]
    var readers: [XCTestExpectation] = []
    for half in ["user", "root"] {
      var sockets: [Int32] = [0, 0]
      XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
      var timeout = timeval(tv_sec: 2, tv_usec: 0)
      XCTAssertEqual(
        setsockopt(
          sockets[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)), 0)
      let channel = QEMUGuestChannel(socket: "unused", half: half)
      channel.receive(descriptor: sockets[0])
      qemu.adopt(channel, as: half)
      guests[half] = sockets[1]
      let finished = expectation(description: "\(half) reader ended")
      readers.append(finished)
      DispatchQueue.global().async {
        channel.readConnection()
        finished.fulfill()
      }
    }
    defer { for fd in guests.values { close(fd) } }
    func say(_ half: String, _ text: String) {
      let data = Data((text + "\n").utf8)
      XCTAssertEqual(
        data.withUnsafeBytes { write(guests[half]!, $0.baseAddress, $0.count) }, data.count)
    }
    func hello(_ half: String, pid: Int) {
      let heard = expectation(description: "\(half) \(pid) heard")
      qemu.onAgentHello = { if $0 == half { heard.fulfill() } }
      say(half, "{\"hello\":\"\(half)\",\"pid\":\(pid)}")
      wait(for: [heard], timeout: 3)
    }

    hello("user", pid: 100)
    hello("root", pid: 5)
    XCTAssertEqual(qemu.agentsHeard, ["user", "root"])
    XCTAssertEqual(qemu.userArrivals, 1)
    hello("user", pid: 100)
    XCTAssertEqual(qemu.userArrivals, 1, "the same agent saying hello again is not a new one")

    var bytes = [UInt8](repeating: 0, count: 1024)
    let count = read(guests["root"]!, &bytes, bytes.count)
    XCTAssertGreaterThan(count, 0)
    let request = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any])
    XCTAssertEqual(request["op"] as? String, "await_exit")
    XCTAssertEqual(request["pid"] as? Int, 100)

    let failed = expectation(description: "the request to the ended agent failed")
    qemu.guestRequest(["op": "ping"], admin: false) { result in
      if case .success = result { XCTFail("an ended agent answered") }
      failed.fulfill()
    }
    say("root", "{\"id\":\(try XCTUnwrap(request["id"] as? Int)),\"ok\":true}")
    wait(for: [failed], timeout: 3)
    XCTAssertEqual(qemu.agentsHeard, ["root"], "the root half is still there to be spoken to")

    hello("user", pid: 200)
    XCTAssertEqual(qemu.agentsHeard, ["user", "root"])
    XCTAssertEqual(qemu.userArrivals, 2)

    for half in ["user", "root"] { shutdown(guests[half]!, SHUT_RDWR) }
    wait(for: readers, timeout: 3)
  }
}
