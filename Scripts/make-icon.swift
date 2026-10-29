// Renders the app icon (1024×1024 PNG): five rising signal bars on a blue gradient.
// Usage: swift Scripts/make-icon.swift <output.png>
import AppKit

let canvas = 1024.0
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824 pt body centered in the 1024 canvas.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [
    NSColor(srgbRed: 0.04, green: 0.20, blue: 0.52, alpha: 1),
    NSColor(srgbRed: 0.05, green: 0.47, blue: 0.85, alpha: 1),
    NSColor(srgbRed: 0.18, green: 0.80, blue: 0.86, alpha: 1),
])!.draw(in: body, angle: 60)

// Faint "ping" rings radiating from the bars' foot.
let center = NSPoint(x: 250, y: 250)
for (index, radius) in [330.0, 500.0, 670.0].enumerated() {
    let ring = NSBezierPath()
    ring.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 90)
    ring.lineWidth = 26
    ring.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.10 - Double(index) * 0.025).setStroke()
    ring.stroke()
}

// Signal bars.
let barWidth = 92.0
let gap = 40.0
let totalWidth = 5 * barWidth + 4 * gap
let baseX = (canvas - totalWidth) / 2
let baseY = 250.0
for index in 0..<5 {
    let height = 130.0 + Double(index) * 105
    let rect = NSRect(x: baseX + Double(index) * (barWidth + gap), y: baseY, width: barWidth, height: height)
    let bar = NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor(srgbRed: 0.0, green: 0.12, blue: 0.35, alpha: 0.35)
    glow.shadowOffset = NSSize(width: 0, height: -8)
    glow.shadowBlurRadius = 18
    glow.set()
    NSColor.white.setFill()
    bar.fill()
    NSGraphicsContext.restoreGraphicsState()
}

// Soft top highlight.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
