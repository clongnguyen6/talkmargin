// Posts a key with Option held, as the hardware would, for exercising the
// app's right-Option shortcuts. Usage: swift key.swift <keycode> <seconds> <right|left>
// Examples: 35 = P, 44 = /, 125 = down arrow, 123 = left arrow.
import CoreGraphics
import Foundation

let key = CGKeyCode(Int(CommandLine.arguments[1])!)
let seconds = Double(CommandLine.arguments[2])!
// 0x40 / 0x20 are the device bits for right / left Option (IOLLEvent.h).
var flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | (CommandLine.arguments[3] == "right" ? 0x40 : 0x20))
// Real arrow keys always carry these; without them the shortcut does not match.
if (123...126).contains(key) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }

let source = CGEventSource(stateID: .hidSystemState)
let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)!
down.flags = flags
down.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: seconds)
let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)!
up.flags = flags
up.post(tap: .cghidEventTap)
