import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
for (name, enabled) in [("on", true), ("off", false)] {
    let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
        let background = enabled ? NSColor(calibratedRed: 0.12, green: 0.58, blue: 0.37, alpha: 1) : NSColor(calibratedRed: 0.14, green: 0.21, blue: 0.34, alpha: 1)
        background.setFill()
        NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 202, yRadius: 202).fill()
        NSColor.white.setStroke()
        let frame = NSBezierPath(roundedRect: NSRect(x: 223, y: 367, width: 578, height: 385), xRadius: 40, yRadius: 40)
        frame.lineWidth = 35
        frame.stroke()
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 512, y: 367))
        stand.line(to: NSPoint(x: 512, y: 281))
        stand.move(to: NSPoint(x: 391, y: 281))
        stand.line(to: NSPoint(x: 633, y: 281))
        stand.lineWidth = 35
        stand.lineCapStyle = .round
        stand.stroke()
        let symbol = NSImage(systemSymbolName: enabled ? "power" : "moon.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [.white]))
        symbol?.draw(in: NSRect(x: 424, y: 468, width: 176, height: 176))
        return true
    }
    let set = directory.appendingPathComponent("\(name).iconset", isDirectory: true)
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: pixels, height: pixels)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            let suffix = scale == 2 ? "@2x" : ""
            try rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        }
    }
}
