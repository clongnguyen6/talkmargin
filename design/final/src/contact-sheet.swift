// Contact sheet: app icon from the shipped .icns at native pixels, menu glyph on light and dark bars.
// Sheet is 1 px per pt; @2x rows are drawn at 2 px per pt.
// Bars simulate the system template tint (black 85% on light, white on dark); not a device capture.
// --sf-compare adds SF Symbols to the bars (13 pt next to 16 pt, 15 pt next to 18 pt: same image height).
// That output contains Apple artwork: local only, never commit or publish it.
// Usage: swift contact-sheet.swift <repo-root> <out.png> [--sf-compare]
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let compare = CommandLine.arguments.contains("--sf-compare")
let res = root.appendingPathComponent("Resources")
let W = 2200, H = 1340
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
ctx.interpolationQuality = .none

func fill(_ r: CGRect, _ c: NSColor, radius: CGFloat = 0) {
    c.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
}
func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 17, bold: Bool = false, color: NSColor = NSColor(white: 0.3, alpha: 1)) {
    let f = bold ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size)
    NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color]).draw(at: NSPoint(x: x, y: y))
}
// Draw a bitmap at its native pixel size (or an integer zoom) with no resampling.
func blit(_ img: CGImage, _ x: CGFloat, _ y: CGFloat, zoom: CGFloat = 1) {
    ctx.saveGState()
    ctx.translateBy(x: x, y: y + CGFloat(img.height) * zoom); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(img.width) * zoom, height: CGFloat(img.height) * zoom))
    ctx.restoreGState()
}
// Rasterize a template image into a px-per-pt bitmap, tinted.
func tinted(_ image: NSImage, pt: NSSize, scale: Int, color: NSColor) -> CGImage {
    let w = Int(ceil(pt.width)) * scale, h = Int(ceil(pt.height)) * scale
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    color.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill(using: .sourceIn)
    NSGraphicsContext.restoreGraphicsState()
    return c.makeImage()!
}
func cg(_ rep: NSImageRep) -> CGImage { (rep as! NSBitmapImageRep).cgImage! }

fill(CGRect(x: 0, y: 0, width: W, height: H), NSColor(srgbRed: 0.94, green: 0.945, blue: 0.955, alpha: 1))
text("TalkMargin · final icon assets", 32, 22, size: 24, bold: true, color: NSColor(white: 0.1, alpha: 1))
text("App icon from Resources/AppIcon.icns at native pixels. Menu glyph from Resources/MenuBarIconTemplate.{png,@2x.png,pdf}. View at 100%.", 32, 58)

// App icon: icns representations at their own pixel sizes.
let icns = NSImage(contentsOf: res.appendingPathComponent("AppIcon.icns"))!
func iconRep(_ px: Int) -> CGImage { cg(icns.representations.first { $0.pixelsWide == px }!) }
fill(CGRect(x: 24, y: 100, width: 1072, height: 1216), .white, radius: 14)
blit(iconRep(1024), 48, 124)
text("1024 px on white", 48, 1166)
// 512 sits to the right of the 1024 master on a dark tile to check edges.
fill(CGRect(x: 1120, y: 100, width: 560, height: 600), NSColor(white: 0.16, alpha: 1), radius: 14)
blit(iconRep(512), 1144, 124)
text("512 px on dark", 1144, 650, color: NSColor(white: 0.8, alpha: 1))
var sx: CGFloat = 1710
for px in [128, 32, 16] {
    fill(CGRect(x: sx - 12, y: 100, width: CGFloat(max(px, 40)) + 24, height: CGFloat(px) + 54), .white, radius: 10)
    blit(iconRep(px), sx, 112); text("\(px)", sx, CGFloat(118 + px), size: 13)
    sx += CGFloat(max(px, 40)) + 36
}

// Menu glyph rows.
let glyph = NSImage(contentsOf: res.appendingPathComponent("MenuBarIconTemplate.pdf"))!
let png1 = NSImage(contentsOf: res.appendingPathComponent("MenuBarIconTemplate.png"))!
let symbols = compare ? ["bubble.left.fill", "text.bubble.fill", "wifi", "speaker.wave.2.fill", "battery.100"] : []
let barW: CGFloat = compare ? 520 : 200
let light = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1), dark = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
let ink: [NSColor] = [NSColor(white: 0, alpha: 0.85), .white]

func glyphImage(pt: Int, scale: Int) -> CGImage {
    if pt == 18 {  // the shipped PNGs, untouched
        let rep = png1.representations.first { $0.pixelsWide == 18 * scale }
        if let rep { return cg(rep) }
    }
    let g = NSImage(size: NSSize(width: pt, height: pt), flipped: false) { r in glyph.draw(in: r); return true }
    return tinted(g, pt: NSSize(width: pt, height: pt), scale: scale, color: .black)
}
func tint(_ img: CGImage, _ color: NSColor) -> CGImage {
    let ns = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
    return tinted(ns, pt: ns.size, scale: 1, color: color)
}

var y: CGFloat = 730
if compare {
    text("Menu bar glyph (first in each bar), then SF Symbols. LOCAL ONLY, do not publish.", 1120, y, bold: true, color: NSColor(white: 0.15, alpha: 1))
    text(symbols.joined(separator: ", "), 1120, y + 24, size: 15)
} else {
    text("Menu bar glyph on light and dark bars", 1120, y, bold: true, color: NSColor(white: 0.15, alpha: 1))
}
y += compare ? 58 : 34
for (pt, scale) in [(16, 1), (18, 1), (16, 2), (18, 2)] {
    let symPt: CGFloat = pt == 16 ? 13 : 15
    text("\(pt) pt @\(scale)x · glyph \(pt * scale) px" + (compare ? " · SF Symbols at \(Int(symPt)) pt" : ""), 1120, y, size: 15)
    let s = CGFloat(scale), barH = 24 * s
    for (i, bg) in [light, dark].enumerated() {
        let bx: CGFloat = 1120 + CGFloat(i) * (barW + 20)
        let by = y + 24
        fill(CGRect(x: bx, y: by, width: barW, height: barH), bg)
        var ix = bx + 10 * s
        let g = tint(glyphImage(pt: pt, scale: scale), ink[i])
        blit(g, ix, by + floor((barH - CGFloat(g.height)) / 2))
        ix += CGFloat(g.width) + 12 * s
        for name in symbols {
            let cfg = NSImage.SymbolConfiguration(pointSize: symPt, weight: .regular)
            let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
            let img = tinted(sym, pt: sym.size, scale: scale, color: ink[i])
            if ix + CGFloat(img.width) > bx + barW { break }
            blit(img, ix, by + floor((barH - CGFloat(img.height)) / 2))
            ix += CGFloat(img.width) + 12 * s
        }
    }
    y += 24 + barH + 26
}
// Pixel zoom of the shipped 18 pt PNGs.
text("Shipped PNGs, nearest-neighbour zoom: 18 px x8, 36 px x4", 1120, y, size: 15)
for (i, scale) in [1, 2].enumerated() {
    let g = glyphImage(pt: 18, scale: scale)
    let zx: CGFloat = 1120 + CGFloat(i) * 184
    fill(CGRect(x: zx, y: y + 26, width: 160, height: 160), .white)
    blit(g, zx + 8, y + 34, zoom: CGFloat(8 / scale))
}

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("wrote \(CommandLine.arguments[2])")
