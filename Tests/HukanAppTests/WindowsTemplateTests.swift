import Darwin
import Foundation
import XCTest

@testable import Hukan

final class WindowsTemplateTests: XCTestCase {
  func testAnswersAreXMLAndKeepUsernameAndEveryLocale() throws {
    let username = "guest & <\"name\">"
    let builder = WindowsTemplateBuilder(
      request: .init(
        title: "Fixture", iso: URL(fileURLWithPath: "/unused.iso"), diskSize: 1,
        username: username))
    for language in ["ja-JP", "en-US", "fr-FR"] {
      let xml = builder.answerFile(language: language)
      let document = try XMLDocument(xmlString: xml)
      for field in ["SystemLocale", "UILanguage", "UserLocale"] {
        let nodes = try document.nodes(forXPath: "//*[local-name()='\(field)']")
        XCTAssertFalse(nodes.isEmpty)
        XCTAssertTrue(nodes.allSatisfy { $0.stringValue == language }, field)
      }
      for field in ["Name", "Username"] {
        let nodes = try document.nodes(forXPath: "//*[local-name()='\(field)']")
        XCTAssertEqual(nodes.map(\.stringValue), [username])
      }
      let inputs = try document.nodes(forXPath: "//*[local-name()='InputLocale']")
      XCTAssertFalse(inputs.isEmpty)
      XCTAssertTrue(
        inputs.allSatisfy {
          $0.stringValue == (language == "ja-JP" ? "0411:00000411" : "0409:00000409")
        })
    }
  }

  func testTheMachineTypeIsWhatTheBareVirtStandsFor() {
    let help = """
      Supported machines are:
      virt-10.2            QEMU 10.2 ARM Virtual Machine
      virt                 QEMU 11.1 ARM Virtual Machine (alias of virt-11.1)
      virt-11.1            QEMU 11.1 ARM Virtual Machine
      xlnx-zcu102          Xilinx ZynqMP ZCU102 board with 4xA53s and 2xR5Fs based on the value
      """
    XCTAssertEqual(WindowsTemplateBuilder.machineType(inHelp: help), "virt-11.1")
    XCTAssertNil(WindowsTemplateBuilder.machineType(inHelp: "virt-11.1  QEMU 11.1 ARM\n"))
  }

  func testABuildIsNamedByItsRelease() {
    XCTAssertEqual(WindowsTemplateBuilder.title(ofBuild: "26100.4349"), "Windows 11 24H2")
    XCTAssertEqual(WindowsTemplateBuilder.title(ofBuild: "26200.6899"), "Windows 11 25H2")
    XCTAssertEqual(WindowsTemplateBuilder.title(ofBuild: "26300.1"), "Windows 11 (26300.1)")
  }

  func testLanguageComesOnlyFromAvailableUILanguagesSection() throws {
    let ini = "[Other]\r\nen-US=1\r\n [AVAILABLE UI LANGUAGES] \r\n ja-JP = 3\r\nen-US=2"
    XCTAssertEqual(try WindowsTemplateBuilder.language(in: Data(ini.utf8)), "ja-JP")
    for invalid in ["", "[Other]\nen-US=1", "[Available UI Languages]\n[Other]\nen-US=1"] {
      XCTAssertThrowsError(try WindowsTemplateBuilder.language(in: Data(invalid.utf8)))
    }
  }

  func testTheImageIsLaidDownByTheScriptWithDefenderOff() throws {
    let builder = WindowsTemplateBuilder(
      request: .init(
        title: "Fixture", iso: URL(fileURLWithPath: "/unused.iso"), diskSize: 1,
        username: "guest"))
    let document = try XMLDocument(xmlString: builder.answerFile(language: "en-US"))
    for field in ["DiskConfiguration", "ImageInstall"] {
      XCTAssertTrue(try document.nodes(forXPath: "//*[local-name()='\(field)']").isEmpty, field)
    }
    let commands = try document.nodes(
      forXPath: "//*[local-name()='settings'][@pass='windowsPE']//*[local-name()='Path']")
    XCTAssertTrue(commands.last?.stringValue?.contains("call %d:\\hukan-install.cmd") ?? false)

    let script = WindowsTemplateBuilder.installScript
    let order = try [
      "diskpart /s", "dism /Apply-Image",
      "reg load HKLM\\hukan W:\\Windows\\System32\\config\\SYSTEM",
      "reg unload HKLM\\hukan", "reg load HKLM\\hukansw W:\\Windows\\System32\\config\\SOFTWARE",
      "reg unload HKLM\\hukansw", "bcdboot W:\\Windows", "W:\\Windows\\Panther\\unattend.xml",
      "wpeutil reboot", ":failed", "wpeutil shutdown",
    ].map { try XCTUnwrap(script.range(of: $0)?.lowerBound, $0) }
    XCTAssertEqual(order, order.sorted())
    XCTAssertTrue(
      script.contains(
        "in (Sense WdBoot WdFilter WdNisDrv WdNisSvc WinDefend) do reg add HKLM\\hukan"))
    XCTAssertTrue(script.contains("/v Start /t REG_DWORD /d 4 /f"))
    // Updates, Windows Update's drivers among them, are Group Policy's before the first boot.
    for value in [
      "Windows\\WindowsUpdate\\AU /v NoAutoUpdate /t REG_DWORD /d 1",
      "Windows\\WindowsUpdate /v ExcludeWUDriversInQualityUpdate /t REG_DWORD /d 1",
      "Windows\\DriverSearching /v SearchOrderConfig /t REG_DWORD /d 0",
      "Windows\\Device Metadata\" /v PreventDeviceMetadataFromNetwork /t REG_DWORD /d 1",
      "WindowsStore /v AutoDownload /t REG_DWORD /d 2",
    ] {
      XCTAssertTrue(script.contains(value), value)
    }
  }

  func testAFailedWinPEStepPowersOffRatherThanHandingBackToSetup() {
    let script = WindowsTemplateBuilder.installScript
    XCTAssertFalse(script.contains("exit /b 1"))
    for step in ["diskpart /s", "dism /Apply-Image", "bcdboot", "reg load HKLM\\hukansw"] {
      let line = script.components(separatedBy: "\r\n").first { $0.hasPrefix(step) } ?? ""
      XCTAssertTrue(line.hasSuffix("|| goto failed"), line)
    }
  }

  func testTheFirstLogonReportsEachFailedStepAndItsEnd() {
    let script = WindowsTemplateBuilder.setupScript
    XCTAssertTrue(script.contains("set R=\\\\.\\Global\\dev.hukan.setup"))
    XCTAssertTrue(script.contains("|| (echo failed: the agent's service)> %R%"))
    let lines = script.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    XCTAssertEqual(lines.last, "(echo done)> %R%")
    // The serial driver is the first thing installed, being what the rest reports through.
    XCTAssertLessThan(
      try XCTUnwrap(script.range(of: "vioser.inf")?.lowerBound),
      try XCTUnwrap(script.range(of: "set R=")?.lowerBound))
  }

  func testTheBuildIsJudgedByWinPEsRestartAndTheFirstLogonsReport() {
    let problem = WindowsTemplateBuilder.setupProblem
    XCTAssertNotNil(problem(false, "done\r\n"))
    XCTAssertNil(problem(true, "done\r\n"))
    XCTAssertNotNil(problem(true, nil))
    XCTAssertNotNil(problem(true, ""))
    let failed = problem(true, "failed: NetKVM \r\nfailed: EnableLUA\r\ndone\r\n")
    XCTAssertEqual(failed, "Windows' first sign-in could not set up: NetKVM, EnableLUA.")
  }

  func testSetupInstallsDriversAndBothAgentHalves() {
    let script = WindowsTemplateBuilder.setupScript
    for driver in [
      "vioserial\\w11\\ARM64\\vioser.inf", "NetKVM\\w11\\ARM64\\netkvm.inf",
      "viogpudo\\w11\\ARM64\\viogpudo.inf",
    ] {
      XCTAssertTrue(script.contains("pnputil /add-driver %D%\\\(driver) /install"))
    }
    XCTAssertTrue(script.contains("copy /y \"%~dp0hukan-guest-agent.exe\""))
    XCTAssertTrue(script.contains("sc create HukanGuestAgent"))
    XCTAssertTrue(script.contains("--root\" start= auto"))
    XCTAssertTrue(script.contains("schtasks /create /tn HukanGuestAgent /sc onlogon"))
    XCTAssertTrue(script.contains("--user\""))
    let winlogon = "\"HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon\""
    XCTAssertTrue(script.contains("reg add \(winlogon) /v ForceAutoLogon /t REG_SZ /d 1 /f"))
    XCTAssertTrue(script.contains("reg delete \(winlogon) /v AutoLogonCount /f"))
    XCTAssertFalse(script.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
  }

  func testRedirectUpgradesHTTPWithoutChangingAddressOrRequest() throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: URL(string: "https://example.invalid/drivers")!)
    let response = HTTPURLResponse(
      url: task.originalRequest!.url!, statusCode: 302,
      httpVersion: nil, headerFields: nil)!
    for scheme in ["http", "https"] {
      var request = URLRequest(url: URL(string: "\(scheme)://example.invalid:8443/a%20b?q=1#part")!)
      request.setValue("fixture", forHTTPHeaderField: "X-Fixture")
      var redirected: URLRequest?
      SecureRedirects().urlSession(
        session, task: task, willPerformHTTPRedirection: response,
        newRequest: request
      ) { redirected = $0 }
      let result = try XCTUnwrap(redirected)
      XCTAssertEqual(result.url?.absoluteString, "https://example.invalid:8443/a%20b?q=1#part")
      XCTAssertEqual(result.value(forHTTPHeaderField: "X-Fixture"), "fixture")
    }
  }

  func testSocketPathsArePrivateAndFitUnixAddress() {
    for name in ["vnc-12345678", "qmp-12345678", "ga-12345678-user", "ga-12345678-root"] {
      let path = QEMUSocket.path(name)
      XCTAssertLessThan(path.utf8.count, 104)
      XCTAssertEqual(
        URL(fileURLWithPath: path).deletingLastPathComponent(),
        FileManager.default.temporaryDirectory)
      XCTAssertFalse(path.hasPrefix("/tmp/"))
    }
  }

  func testDisplayRejectsOversizedScreenAndOutOfBoundsRectangleWithoutBodies() throws {
    // Supply just headers: a client that tries reading a pixel body will time out instead.
    for oversized in [true, false] {
      var sockets: [Int32] = [0, 0]
      XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
      defer {
        close(sockets[0])
        close(sockets[1])
      }
      var timeout = timeval(tv_sec: 1, tv_usec: 0)
      XCTAssertEqual(
        setsockopt(
          sockets[0], SOL_SOCKET, SO_RCVTIMEO, &timeout,
          socklen_t(MemoryLayout<timeval>.size)), 0)
      var bytes = Data("RFB 003.008\n".utf8)
      bytes.append(contentsOf: [1, 1, 0, 0, 0, 0])
      if oversized {
        bytes.append(contentsOf: [0x20, 1, 0, 1])  // 8193 × 1, no pixel format or pixels
      } else {
        bytes.append(contentsOf: [0, 2, 0, 2])
        bytes.append(Data(repeating: 0, count: 20))  // format and empty name
        bytes.append(contentsOf: [0, 0, 0, 1, 0, 1, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0])
      }
      XCTAssertEqual(
        bytes.withUnsafeBytes { write(sockets[1], $0.baseAddress, $0.count) }, bytes.count)
      let client = QEMUDisplayClient(socket: "unused")
      XCTAssertThrowsError(try client.receive(descriptor: sockets[0])) { error in
        XCTAssertEqual(
          error.localizedDescription,
          oversized
            ? "The display asked for a screen of 8193x1."
            : "The display sent a rectangle outside its screen.")
      }
    }
  }
}
