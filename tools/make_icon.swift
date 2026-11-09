import AppKit

let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S), flipped: false) { _ in
    let inset: CGFloat = 100
    let box = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let squircle = NSBezierPath(roundedRect: box, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.white.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(srgbRed: 1.0, green: 0.72, blue: 0.36, alpha: 1),
        NSColor(srgbRed: 0.97, green: 0.42, blue: 0.18, alpha: 1),
        NSColor(srgbRed: 0.90, green: 0.25, blue: 0.30, alpha: 1),
    ])!.draw(in: squircle, angle: -60)

    let c = NSPoint(x: S / 2, y: S / 2 - 20)
    let ra: CGFloat = 120, rb: CGFloat = 290
    let n = 6
    for i in 0..<n {
        let seg = 360 / CGFloat(n)
        let th = 90 - CGFloat(i) * seg
        let gap: CGFloat = 26
        let go = (gap / 2) / rb * 180 / .pi, gi = (gap / 2) / ra * 180 / .pi
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: rb, startAngle: th + seg / 2 - go, endAngle: th - seg / 2 + go, clockwise: true)
        p.appendArc(withCenter: c, radius: ra, startAngle: th - seg / 2 + gi, endAngle: th + seg / 2 - gi, clockwise: false)
        p.close()
        p.lineJoinStyle = .round
        p.lineWidth = 14
        let color = i == 1 ? NSColor.white : NSColor(srgbRed: 1, green: 0.93, blue: 0.85, alpha: 0.78)
        color.setFill(); color.setStroke()
        p.fill(); p.stroke()
    }
    let center = NSBezierPath(ovalIn: NSRect(x: c.x - 92, y: c.y - 92, width: 184, height: 184))
    NSColor(srgbRed: 1, green: 0.97, blue: 0.93, alpha: 1).setFill()
    center.fill()

    let leaf = NSBezierPath()
    let base = NSPoint(x: c.x + 30, y: c.y + rb + 6)
    leaf.move(to: base)
    leaf.curve(to: NSPoint(x: base.x + 190, y: base.y + 70), controlPoint1: NSPoint(x: base.x + 40, y: base.y + 110), controlPoint2: NSPoint(x: base.x + 140, y: base.y + 120))
    leaf.curve(to: base, controlPoint1: NSPoint(x: base.x + 150, y: base.y + 10), controlPoint2: NSPoint(x: base.x + 60, y: base.y - 10))
    NSColor(srgbRed: 0.24, green: 0.62, blue: 0.30, alpha: 1).setFill()
    leaf.fill()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
