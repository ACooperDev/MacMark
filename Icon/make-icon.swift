// Draws MacMark's app icon: a simplified sigil, as the window draws it.
// Rings of round dots in the three section colours (blue hardware, yellow
// software, pink age), the core's spokes, a filled arc or two, and the
// centre dot, on a dark macOS-style rounded tile. Writes MacMark.icns and
// a 1024 px MacMark.png next to this script (via iconutil).
// Run: swift Icon/make-icon.swift
import AppKit

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
func rgb(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
// macOS's dark-mode system colours, as the window uses them.
let blue = rgb(0x0a84ff), yellow = rgb(0xffd60a), pink = rgb(0xff375f), white = rgb(0xf2f2f7)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // Apple's icon grid: an 824 tile centred in 1024, corner radius ~185.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 18 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    rgb(0x1c1c1e).setFill(); path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(starting: rgb(0x2a2a2e), ending: rgb(0x111113))!.draw(in: path, angle: -90)
    path.addClip()

    let c = CGPoint(x: 512 * s, y: 512 * s)
    // Small icons get fewer, bigger dots, so the rings still read.
    let small = px <= 64
    let minR: CGFloat = small ? 0.6 : 0.5
    func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ col: NSColor) {
        let rr = max(minR, r * s)
        col.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - rr, y: y - rr, width: 2 * rr, height: 2 * rr)).fill()
    }
    // A ring of dots at radius r (1024 units), from turn a0 to a1 (0 at 12
    // o'clock, clockwise), about `gap` apart.
    func ring(_ r: CGFloat, _ size: CGFloat, _ col: NSColor, from a0: CGFloat = 0, to a1: CGFloat = 1, gap: CGFloat) {
        let len = 2 * .pi * r * (a1 - a0), g = small ? gap * 1.8 : gap
        let n = max(2, Int(len / g))
        for i in 0..<n {
            let a = (a0 + (a1 - a0) * CGFloat(i) / CGFloat(a1 - a0 >= 1 ? n : n - 1)) * 2 * .pi
            dot(c.x + sin(a) * r * s, c.y + cos(a) * r * s, size, col)
        }
    }
    // The core: spokes of small dots, as the Cores ring draws them.
    for i in 0..<10 {
        let a = CGFloat(i) / 10 * 2 * .pi + 0.2, long = i % 3 != 2
        let r1: CGFloat = long ? 105 : 72
        var r: CGFloat = 32
        while r <= r1 { dot(c.x + sin(a) * r * s, c.y + cos(a) * r * s, 4.2, blue); r += small ? 22 : 13 }
    }
    // Hardware: memory as a filled arc of large dots over a faint track,
    // then a thin dotted ring.
    ring(140, 3, blue.withAlphaComponent(0.35), gap: 14)
    ring(140, 9.5, blue, from: 0.62, to: 1.28, gap: 26)
    ring(178, 3.6, blue.withAlphaComponent(0.8), gap: 15)
    // Software: a yellow ring of medium dots with a few big ones on it.
    ring(232, 4.6, yellow, gap: 15)
    for a in [0.07, 0.31, 0.55, 0.78] as [CGFloat] {
        let t = a * 2 * .pi
        dot(c.x + sin(t) * 262 * s, c.y + cos(t) * 262 * s, 9, yellow)
    }
    ring(262, 2.6, yellow.withAlphaComponent(0.45), gap: 18)
    // Age: the outer pink ring of large dots, and uptime's arc at the top
    // ending in a white dot.
    ring(318, 8.5, pink, gap: 22)
    ring(350, 2.8, pink.withAlphaComponent(0.5), gap: 16)
    ring(372, 5, blue, from: 0, to: 0.12, gap: 15)
    let end = 0.12 * 2 * CGFloat.pi
    dot(c.x + sin(end) * 372 * s, c.y + cos(end) * 372 * s, 9, white)
    // The centre dot.
    dot(c.x, c.y, 13, white)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = here.appendingPathComponent("MacMark.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: here.appendingPathComponent("MacMark.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", here.appendingPathComponent("MacMark.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print(p.terminationStatus == 0 ? "Wrote Icon/MacMark.icns" : "iconutil failed")
