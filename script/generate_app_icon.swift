import AppKit
import Foundation

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func sparkle(center: NSPoint, radius: CGFloat, waist: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: center.x, y: center.y + radius))
    path.line(to: NSPoint(x: center.x + waist * 0.45, y: center.y + waist * 0.45))
    path.line(to: NSPoint(x: center.x + radius, y: center.y))
    path.line(to: NSPoint(x: center.x + waist * 0.45, y: center.y - waist * 0.45))
    path.line(to: NSPoint(x: center.x, y: center.y - radius))
    path.line(to: NSPoint(x: center.x - waist * 0.45, y: center.y - waist * 0.45))
    path.line(to: NSPoint(x: center.x - radius, y: center.y))
    path.line(to: NSPoint(x: center.x - waist * 0.45, y: center.y + waist * 0.45))
    path.close()
    return path
}

func drawIcon(to outputURL: URL) throws {
    let size: CGFloat = 1024
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "MacCleanerIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create the app icon bitmap."])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))

    let background = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: 222, yRadius: 222)
    NSGradient(colors: [
        color(0.978, 0.988, 1.000),
        color(0.921, 0.954, 0.996),
        color(0.844, 0.902, 0.982)
    ])?.draw(in: background, angle: -38)

    color(1, 1, 1, 0.30).setFill()
    NSBezierPath(ovalIn: NSRect(x: 119, y: 514, width: 786, height: 786)).fill()

    let blue = color(0.055, 0.255, 0.665)

    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: 583, y: 466))
    handle.line(to: NSPoint(x: 785, y: 264))
    handle.lineWidth = 92
    handle.lineCapStyle = .round
    let handleShadow = NSShadow()
    handleShadow.shadowColor = color(0.05, 0.12, 0.27, 0.18)
    handleShadow.shadowBlurRadius = 25
    handleShadow.shadowOffset = NSSize(width: 0, height: -10)
    handleShadow.set()
    blue.setStroke()
    handle.stroke()
    NSShadow().set()

    let handleGlint = NSBezierPath()
    handleGlint.move(to: NSPoint(x: 616, y: 465))
    handleGlint.line(to: NSPoint(x: 758, y: 323))
    handleGlint.lineWidth = 15
    handleGlint.lineCapStyle = .round
    color(0.49, 0.68, 0.96, 0.66).setStroke()
    handleGlint.stroke()

    let lensFrame = NSRect(x: 176, y: 395, width: 478, height: 478)
    let lensOuter = NSBezierPath(ovalIn: lensFrame)
    let lensShadow = NSShadow()
    lensShadow.shadowColor = color(0.05, 0.12, 0.27, 0.17)
    lensShadow.shadowBlurRadius = 28
    lensShadow.shadowOffset = NSSize(width: 0, height: -10)
    lensShadow.set()
    blue.setFill()
    lensOuter.fill()
    NSShadow().set()

    let glassFrame = NSRect(x: 213, y: 432, width: 404, height: 404)
    let glass = NSBezierPath(ovalIn: glassFrame)
    NSGradient(colors: [
        color(0.990, 0.998, 1.000),
        color(0.835, 0.910, 0.990)
    ])?.draw(in: glass, angle: 55)

    let glassRim = NSBezierPath(ovalIn: NSRect(x: 226, y: 445, width: 378, height: 378))
    glassRim.lineWidth = 5
    color(1, 1, 1, 0.72).setStroke()
    glassRim.stroke()

    let mainSparkle = sparkle(center: NSPoint(x: 414, y: 625), radius: 116, waist: 54)
    NSGradient(colors: [color(0.98, 0.72, 0.28), color(0.91, 0.54, 0.18)])?.draw(in: mainSparkle, angle: 70)

    let smallSparkle = sparkle(center: NSPoint(x: 575, y: 778), radius: 49, waist: 23)
    NSGradient(colors: [color(1, 0.83, 0.49), color(0.95, 0.66, 0.27)])?.draw(in: smallSparkle, angle: 45)

    let tinySparkle = sparkle(center: NSPoint(x: 292, y: 748), radius: 27, waist: 13)
    color(1, 1, 1, 0.92).setFill()
    tinySparkle.fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MacCleanerIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode the app icon PNG."])
    }
    try png.write(to: outputURL, options: .atomic)
}

let output = CommandLine.arguments.dropFirst().first
    .map(URL.init(fileURLWithPath:))
    ?? URL(fileURLWithPath: "MacCleaner/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png")
try drawIcon(to: output)
