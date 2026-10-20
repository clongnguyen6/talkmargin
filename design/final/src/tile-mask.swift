// Write the macOS app icon tile mask: 1024 canvas, 824 pt tile at 100, radius 185.4, continuous corners.
// Usage: swift tile-mask.swift out.png
import AppKit
import QuartzCore

let px = 1024
let layer = CALayer()
layer.frame = CGRect(x: 0, y: 0, width: px, height: px)
let tile = CALayer()
tile.frame = CGRect(x: 100, y: 100, width: 824, height: 824)
tile.cornerRadius = 185.4
tile.cornerCurve = .continuous
tile.backgroundColor = CGColor(gray: 1, alpha: 1)
layer.addSublayer(tile)

let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
ctx.setAllowsAntialiasing(true)
layer.render(in: ctx)
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
