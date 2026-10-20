// Mouse input in global display points (origin at the top-left of the main display;
// displays above it have negative y). Usage:
//   swift mouse.swift click <x> <y> [count]     (count 2 = double-click)
//   swift mouse.swift drag <x1> <y1> <x2> <y2>
//   swift mouse.swift move <x> <y>
//   swift mouse.swift wheel <x> <y> <pixels>     (positive scrolls up)
import CoreGraphics
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let numbers = args.dropFirst().map { Double($0)! }

func post(_ type: CGEventType, _ point: CGPoint, clickState: Int64 = 1) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
    event.setIntegerValueField(.mouseEventClickState, value: clickState)
    event.post(tap: .cghidEventTap)
}

let start = CGPoint(x: numbers[0], y: numbers[1])
post(.mouseMoved, start)
usleep(150_000)

switch args[0] {
case "click":
    let count = numbers.count > 2 ? Int64(numbers[2]) : 1
    for n in 1...count {
        post(.leftMouseDown, start, clickState: n)
        usleep(30_000)
        post(.leftMouseUp, start, clickState: n)
        usleep(80_000)
    }
case "drag":
    let end = CGPoint(x: numbers[2], y: numbers[3])
    post(.leftMouseDown, start)
    usleep(100_000)
    for step in 1...20 {
        let f = Double(step) / 20
        post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f))
        usleep(15_000)
    }
    post(.leftMouseUp, end)
case "move":
    break
case "wheel":
    for _ in 0..<8 {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(numbers[2]), wheel2: 0, wheel3: 0)!
            .post(tap: .cghidEventTap)
        usleep(16_000)
    }
default:
    FileHandle.standardError.write("unknown action \(args[0])\n".data(using: .utf8)!)
    exit(1)
}
