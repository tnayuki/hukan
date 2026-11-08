import AppKit
import Virtualization

/// Typing into a guest that has nothing listening yet — macOS Recovery, before any agent runs — by
/// handing key events to a `VZVirtualMachineView`, which passes them to the machine's keyboard as
/// if someone pressed them. The view is the one the machine is drawn into, wherever it is — the
/// window's detail pane, or the build's own window nobody sees — so the typing does not depend on
/// which row the person has selected.
///
/// It is blind, which is the whole of its weakness: each step waits a fixed time for the screen
/// it expects, the way tart's image templates drive Recovery. A Recovery that changes its screens
/// in a macOS update breaks it, and the template build says so rather than guessing.
final class GuestKeyboard {
  enum Step {
    case wait(Double)
    case key(UInt16)
    /// A key with ⇧⌘ held, for Recovery's menu shortcuts — Utilities ▸ Terminal is ⇧⌘T. Should it
    /// miss, the Return typed after it opens Time Machine, the assistant's first choice.
    case commandShiftKey(UInt16)
    case text(String)
  }

  static let returnKey: UInt16 = 36
  static let rightArrow: UInt16 = 124

  private let view: VZVirtualMachineView

  /// The view must be the one showing the machine: Virtualization.framework draws a machine into
  /// one view, and a second view for typing took the screen from the one the person was watching
  /// and left it black.
  init(view: VZVirtualMachineView) {
    self.view = view
  }

  /// One thing the keyboard does: an event handed to the view, or a pause.
  private enum Event {
    case pause(Double)
    case key(UInt16, NSEvent.EventType, NSEvent.ModifierFlags, String)
    case flags(UInt16, NSEvent.ModifierFlags)
  }

  /// How long apart two events are sent — every one, a modifier going down or up included, which
  /// is what Packer's VNC driver does at its default of 100ms.
  private static let gap = 0.1

  /// Run the steps in order, then call `completion` — on the main thread, an event at a time, so a
  /// stop in between leaves nothing typing into a machine that has gone.
  func type(_ steps: [Step], completion: @escaping () -> Void) {
    var events = steps.flatMap(Self.events(for:))[...]
    func next() {
      guard let event = events.popFirst() else {
        completion()
        return
      }
      var delay = Self.gap
      switch event {
      case .pause(let seconds):
        delay = seconds
      case .key(let code, let type, let modifiers, let characters):
        send(code, type, modifiers, characters)
      case .flags(let code, let modifiers):
        flags(code, modifiers)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: next)
    }
    next()
  }

  private static func events(for step: Step) -> [Event] {
    func stroke(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags, _ characters: String)
      -> [Event]
    {
      [.key(code, .keyDown, modifiers, characters), .key(code, .keyUp, modifiers, characters)]
    }
    switch step {
    case .wait(let seconds):
      return [.pause(seconds)]
    case .key(let code):
      return stroke(code, [], "") + [.pause(0.2)]
    case .commandShiftKey(let code):
      return [.flags(55, .command), .flags(56, [.command, .shift])]
        + stroke(code, [.command, .shift], "T")
        + [.flags(56, .command), .flags(55, []), .pause(0.2)]
    case .text(let text):
      return text.flatMap { character -> [Event] in
        guard let (code, shifted) = keyCode(for: character) else { return [] }
        let characters = String(character)
        return shifted
          ? [.flags(56, .shift)] + stroke(code, .shift, characters) + [.flags(56, [])]
          : stroke(code, [], characters)
      } + [.pause(0.2)]
    }
  }

  /// The flags as a real keyboard reports them: beside the device-independent ⇧ and ⌘ bits, the
  /// device-dependent ones saying which of the two keys is down (`NX_DEVICELSHIFTKEYMASK` and the
  /// rest). The view reads those to tell the guest a left or a right modifier went down, and a
  /// flags word without them reached Recovery as no modifier at all — ⇧⌘T arrived as a bare T.
  private static func device(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    var raw = modifiers.rawValue
    if modifiers.contains(.control) { raw |= 0x01 }
    if modifiers.contains(.shift) { raw |= 0x02 }
    if modifiers.contains(.command) { raw |= 0x08 }
    if modifiers.contains(.option) { raw |= 0x20 }
    return NSEvent.ModifierFlags(rawValue: raw | 0x100)
  }

  private func send(
    _ code: UInt16, _ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags,
    _ characters: String
  ) {
    guard
      let event = NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: Self.device(modifiers),
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: view.window?.windowNumber ?? 0,
        context: nil, characters: characters,
        charactersIgnoringModifiers: characters.lowercased(),
        isARepeat: false, keyCode: code)
    else { return }
    if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
  }

  /// A modifier key going down or up, said by the flags held once it has.
  private func flags(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags) {
    guard
      let event = NSEvent.keyEvent(
        with: .flagsChanged, location: .zero, modifierFlags: Self.device(modifiers),
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: view.window?.windowNumber ?? 0,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
        keyCode: code)
    else { return }
    view.flagsChanged(with: event)
  }

  /// The ANSI layout a freshly installed guest starts with: letters, digits, space and the few
  /// punctuation marks a command line and a generated password need.
  private static func keyCode(for character: Character) -> (UInt16, Bool)? {
    let lower: [Character: UInt16] = [
      "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
      "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
      "6": 22, "5": 23, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34,
      "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, ".": 47, "/": 44, " ": 49,
    ]
    if let code = lower[character] { return (code, false) }
    if character.isUppercase, let code = lower[Character(character.lowercased())] {
      return (code, true)
    }
    return nil
  }
}
