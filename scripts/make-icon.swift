import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
        NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.91, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 220, yRadius: 220).fill()
        NSColor(calibratedRed: 0.16, green: 0.39, blue: 0.31, alpha: 1).setStroke()
        let tray = NSBezierPath()
        tray.move(to: NSPoint(x: 236, y: 455)); tray.line(to: NSPoint(x: 236, y: 300))
        tray.curve(to: NSPoint(x: 300, y: 236), controlPoint1: NSPoint(x: 236, y: 250), controlPoint2: NSPoint(x: 250, y: 236))
        tray.line(to: NSPoint(x: 724, y: 236))
        tray.curve(to: NSPoint(x: 788, y: 300), controlPoint1: NSPoint(x: 774, y: 236), controlPoint2: NSPoint(x: 788, y: 250))
        tray.line(to: NSPoint(x: 788, y: 455)); tray.lineWidth = 54; tray.lineCapStyle = .round; tray.lineJoinStyle = .round; tray.stroke()
        let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: 512, y: 776)); arrow.line(to: NSPoint(x: 512, y: 420))
        arrow.move(to: NSPoint(x: 378, y: 554)); arrow.line(to: NSPoint(x: 512, y: 420)); arrow.line(to: NSPoint(x: 646, y: 554))
        arrow.lineWidth = 54; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
