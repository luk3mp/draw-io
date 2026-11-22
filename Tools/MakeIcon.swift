// Renders Draw IO's app icon to a 1024x1024 PNG. Usage: MakeIcon <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt rounded square centred in a 1024 canvas.
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
NSColor.black.setFill(); shape.fill()
NSGraphicsContext.restoreGraphicsState()

// Indigo → pink gradient
NSGradient(colors: [NSColor(red: 0.36, green: 0.30, blue: 0.95, alpha: 1),
                    NSColor(red: 0.93, green: 0.30, blue: 0.62, alpha: 1)])!
    .draw(in: shape, angle: -55)

NSGraphicsContext.saveGraphicsState()
shape.addClip()

// A hand-drawn yellow loop, like circling something on screen
let loop = NSBezierPath()
var pts: [NSPoint] = []
for i in 0...40 {
    let t = 0.3 + Double(i) / 40 * (2 * .pi + 0.5)
    let wobble = 1 + 0.03 * sin(t * 3)
    pts.append(NSPoint(x: 512 + 300 * wobble * cos(t), y: 470 + 190 * wobble * sin(t)))
}
loop.move(to: pts[0])
for i in 1..<pts.count { loop.line(to: pts[i]) }
loop.lineWidth = 34
loop.lineCapStyle = .round
loop.lineJoinStyle = .round
NSColor(red: 1, green: 0.86, blue: 0.25, alpha: 1).setStroke()
loop.stroke()

// White pencil, tilted, on top
let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = pencil.size
    let ps = NSShadow()
    ps.shadowColor = NSColor.black.withAlphaComponent(0.3)
    ps.shadowOffset = NSSize(width: 0, height: -10)
    ps.shadowBlurRadius = 18
    ps.set()
    pencil.draw(in: NSRect(x: 560 - s.width / 2, y: 600 - s.height / 2, width: s.width, height: s.height))
}
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
