import XCTest

@testable import Hukan

final class QEMUMachineTests: XCTestCase {
  // A value-only fixture: no store access or files are needed to construct arguments.
  static func machine(at directory: URL) -> Machine {
    Machine(
      url: directory,
      manifest: .init(
        id: UUID(), kind: .windows, title: "Windows fixture", cpuCount: 3,
        memorySize: 6 << 30, display: .init(width: 1920, height: 1080),
        macAddress: "02:00:00:00:00:01", username: "guest", password: "fixture",
        created: Date(timeIntervalSince1970: 0)))
  }

  func testTheMachineTypeItWasMadeOnIsTheOneItStartsOn() {
    var machine = Self.machine(at: URL(fileURLWithPath: "/unused-machine"))
    machine.manifest.qemuMachine = "virt-10.2"
    let args = QEMUMachine(machine: machine).arguments(resuming: true)
    let index = args.firstIndex(of: "-machine")!
    XCTAssertEqual(args[index + 1], "virt-10.2,highmem=on,gic-version=3")
  }

  func testFreshAndResumedArgumentsWithAndWithoutShare() {
    let machine = Self.machine(at: URL(fileURLWithPath: "/unused-machine"))
    let qemu = QEMUMachine(machine: machine)
    for resumed in [false, true] {
      for share in [nil, "guestfwd=tcp:10.0.2.4:445-cmd:/fixture/smbd"] {
        let args = qemu.arguments(resuming: resumed, smb: share)
        func value(_ flag: String) -> String? {
          guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
          return args[index + 1]
        }
        XCTAssertEqual(value("-machine"), "virt,highmem=on,gic-version=3")
        XCTAssertEqual(value("-accel"), "hvf")
        XCTAssertEqual(value("-cpu"), "host")
        XCTAssertEqual(value("-smp"), "3")
        XCTAssertEqual(value("-m"), "6144")
        XCTAssertEqual(value("-rtc"), "base=localtime")
        XCTAssertEqual(value("-display"), "none")
        XCTAssertEqual(value("-vnc"), "unix:\(qemu.displaySocket)")
        XCTAssertEqual(value("-nic"), "user,model=virtio-net-pci" + (share.map { "," + $0 } ?? ""))
        XCTAssertEqual(value("-incoming"), resumed ? "file:\(machine.stateURL.path)" : nil)
        XCTAssertTrue(args.contains("virtio-gpu-pci,xres=1280,yres=800"))
        XCTAssertTrue(args.contains("nvme,serial=hukan0,drive=disk0"))
        XCTAssertTrue(
          args.contains(
            "if=none,id=disk0,format=raw,cache=writeback,discard=unmap,file=\(machine.diskURL.path)"
          ))
        for half in ["user", "root"] {
          XCTAssertTrue(
            args.contains(
              "socket,id=agent\(half),path=\(qemu.agentSockets[half]!),server=on,wait=off"))
          XCTAssertTrue(
            args.contains(
              "virtserialport,bus=serial0.0,chardev=agent\(half),name=dev.hukan.agent.\(half)"))
        }
        XCTAssertFalse(args.contains("-netdev"))
        XCTAssertFalse(args.contains("-cdrom"))
      }
    }
  }
}
