// Prints the overlay window's frame and each display's bounds, in global points,
// so screenshots can be cropped and clicks aimed. Usage: swift windows.swift
import CoreGraphics

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for window in windows where (window["kCGWindowOwnerName"] as? String ?? "").contains("Prompter")
    && (window["kCGWindowLayer"] as? Int) == 25 {
    let b = window["kCGWindowBounds"] as! [String: Any]
    print("overlay x=\(b["X"]!) y=\(b["Y"]!) w=\(b["Width"]!) h=\(b["Height"]!)")
}

var ids = [CGDirectDisplayID](repeating: 0, count: 8)
var count: UInt32 = 0
CGGetActiveDisplayList(8, &ids, &count)
for id in ids.prefix(Int(count)) {
    let r = CGDisplayBounds(id)
    print("display \(id) x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height))\(CGDisplayIsMain(id) != 0 ? " (main)" : "")")
}
