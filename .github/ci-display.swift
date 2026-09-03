import CoreGraphics
import Foundation

// The runner's virtual display opens at 1024x768, which is narrower than the windows the reader
// tests open — AppKit constrains a frame to the screen, so those tests measure a column they were
// not written against. The display advertises modes up to 1920x1080, so this asks for the widest
// one. It cannot help with the *scale*, which is what every other skipped test needs and which no
// advertised mode carries.
let display = CGMainDisplayID()
guard let modes = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode] else {
  FileHandle.standardError.write(Data("no display modes\n".utf8))
  exit(1)
}
for mode in modes.sorted(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }) {
  print(
    "MODE \(mode.width)x\(mode.height) pixels=\(mode.pixelWidth)x\(mode.pixelHeight) "
      + "hz=\(mode.refreshRate)")
}
guard
  let widest = modes.max(by: {
    ($0.pixelWidth * $0.pixelHeight, $0.refreshRate) < (
      $1.pixelWidth * $1.pixelHeight, $1.refreshRate
    )
  })
else { exit(1) }
print("MODE choosing \(widest.width)x\(widest.height)")
var configuration: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&configuration) == .success,
  CGConfigureDisplayWithDisplayMode(configuration, display, widest, nil) == .success,
  CGCompleteDisplayConfiguration(configuration, .permanently) == .success
else {
  FileHandle.standardError.write(Data("could not set the display mode\n".utf8))
  exit(1)
}
print("MODE now \(CGDisplayPixelsWide(display))x\(CGDisplayPixelsHigh(display))")
