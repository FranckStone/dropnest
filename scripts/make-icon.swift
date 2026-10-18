import AppKit

// macOS 27 "Golden Gate" icon: a superellipse glass tile, layered light,
// and the DropNest tray rendered with depth instead of flat strokes.
let destination = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func squircle(rect: NSRect, exponent: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let cx = rect.midX, cy = rect.midY
    let a = rect.width / 2, b = rect.height / 2
    let steps = 360
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * .pi * 2
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
        if step == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

func sparkle(center: NSPoint, radius: CGFloat, waist: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: center.x, y: center.y + radius))
    path.curve(to: NSPoint(x: center.x + radius, y: center.y),
               controlPoint1: NSPoint(x: center.x + waist, y: center.y + waist),
               controlPoint2: NSPoint(x: center.x + waist, y: center.y + waist))
    path.curve(to: NSPoint(x: center.x, y: center.y - radius),
               controlPoint1: NSPoint(x: center.x + waist, y: center.y - waist),
               controlPoint2: NSPoint(x: center.x + waist, y: center.y - waist))
    path.curve(to: NSPoint(x: center.x - radius, y: center.y),
               controlPoint1: NSPoint(x: center.x - waist, y: center.y - waist),
               controlPoint2: NSPoint(x: center.x - waist, y: center.y - waist))
    path.curve(to: NSPoint(x: center.x, y: center.y + radius),
               controlPoint1: NSPoint(x: center.x - waist, y: center.y + waist),
               controlPoint2: NSPoint(x: center.x - waist, y: center.y + waist))
    path.close()
    return path
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.shouldAntialias = true
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()

        let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
        let body = squircle(rect: tile, exponent: 5)

        // Deep jade glass body.
        let bodyGradient = NSGradient(colorsAndLocations:
            (NSColor(srgbRed: 0.22, green: 0.78, blue: 0.58, alpha: 1), 0.0),
            (NSColor(srgbRed: 0.07, green: 0.50, blue: 0.38, alpha: 1), 0.45),
            (NSColor(srgbRed: 0.02, green: 0.22, blue: 0.18, alpha: 1), 1.0))!
        bodyGradient.draw(in: body, angle: -62)

        NSGraphicsContext.saveGraphicsState()
        body.addClip()

        // Liquid-glass specular bloom from the upper left.
        let bloom = NSGradient(colors: [
            NSColor(srgbRed: 0.74, green: 1.0, blue: 0.90, alpha: 0.32),
            NSColor(srgbRed: 0.74, green: 1.0, blue: 0.90, alpha: 0.0)
        ])!
        bloom.draw(in: body, angle: 118)
        // Weighted darkness at the lower edge for depth.
        let shade = NSGradient(colors: [
            NSColor.black.withAlphaComponent(0.0),
            NSColor.black.withAlphaComponent(0.26)
        ])!
        shade.draw(in: body, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Inner translucent pane.
        let pane = squircle(rect: tile.insetBy(dx: 46, dy: 46), exponent: 5)
        NSColor.white.withAlphaComponent(0.075).setFill()
        pane.fill()
        NSColor.white.withAlphaComponent(0.20).setStroke()
        pane.lineWidth = 2.5
        pane.stroke()

        // Top rim catches the light.
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        let rim = NSBezierPath()
        rim.move(to: NSPoint(x: 155, y: 840))
        rim.curve(to: NSPoint(x: 870, y: 790),
                  controlPoint1: NSPoint(x: 360, y: 940),
                  controlPoint2: NSPoint(x: 690, y: 920))
        NSColor.white.withAlphaComponent(0.40).setStroke()
        rim.lineWidth = 5
        rim.lineCapStyle = .round
        rim.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Tray + arrow, with a soft shadow so the mark sits in the glass.
        let glyph = NSBezierPath()
        glyph.move(to: NSPoint(x: 320, y: 540))
        glyph.line(to: NSPoint(x: 320, y: 415))
        glyph.curve(to: NSPoint(x: 382, y: 353),
                    controlPoint1: NSPoint(x: 320, y: 388),
                    controlPoint2: NSPoint(x: 354, y: 353))
        glyph.line(to: NSPoint(x: 642, y: 353))
        glyph.curve(to: NSPoint(x: 704, y: 415),
                    controlPoint1: NSPoint(x: 670, y: 353),
                    controlPoint2: NSPoint(x: 704, y: 388))
        glyph.line(to: NSPoint(x: 704, y: 540))

        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 512, y: 748))
        arrow.line(to: NSPoint(x: 512, y: 500))
        arrow.move(to: NSPoint(x: 430, y: 582))
        arrow.line(to: NSPoint(x: 512, y: 500))
        arrow.line(to: NSPoint(x: 594, y: 582))

        for path in [glyph, arrow] {
            path.lineWidth = 46
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
        }

        let glyphShadow = NSShadow()
        glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        glyphShadow.shadowBlurRadius = 26
        glyphShadow.shadowOffset = NSSize(width: 0, height: -10)
        NSGraphicsContext.saveGraphicsState()
        glyphShadow.set()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        glyph.lineWidth = 52
        arrow.lineWidth = 52
        glyph.stroke()
        arrow.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(srgbRed: 1.0, green: 1.0, blue: 0.99, alpha: 1).setStroke()
        glyph.lineWidth = 46
        arrow.lineWidth = 46
        glyph.stroke()
        arrow.stroke()

        // A quiet intelligence spark.
        let star = sparkle(center: NSPoint(x: 760, y: 748), radius: 56, waist: 13)
        let starShadow = NSShadow()
        starShadow.shadowColor = NSColor.white.withAlphaComponent(0.55)
        starShadow.shadowBlurRadius = 24
        starShadow.shadowOffset = .zero
        NSGraphicsContext.saveGraphicsState()
        starShadow.set()
        NSColor.white.withAlphaComponent(0.94).setFill()
        star.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Edge light around the tile.
        NSColor.white.withAlphaComponent(0.38).setStroke()
        body.lineWidth = 3
        body.stroke()

        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
