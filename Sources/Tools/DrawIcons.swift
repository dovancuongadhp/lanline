import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let files: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in files {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { continue }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.48, blue: 0.64, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.22, blue: 0.38, alpha: 1),
    ])
    gradient?.draw(in: rect, angle: -90)
    NSColor.white.set()
    let side = CGFloat(pixels) * 0.62
    let icon = NSRect(
        x: rect.midX - side / 2,
        y: rect.midY - side / 2 - CGFloat(pixels) * 0.02,
        width: side,
        height: side
    )
    shieldPath(in: icon).fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: output.appendingPathComponent(name))
}

func shieldPath(in rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX, y: rect.maxY - rect.height * 0.16))
    path.curve(
        to: NSPoint(x: rect.midX, y: rect.maxY),
        controlPoint1: NSPoint(x: rect.minX + rect.width * 0.08, y: rect.maxY),
        controlPoint2: NSPoint(x: rect.midX - rect.width * 0.22, y: rect.maxY)
    )
    path.curve(
        to: NSPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.16),
        controlPoint1: NSPoint(x: rect.midX + rect.width * 0.22, y: rect.maxY),
        controlPoint2: NSPoint(x: rect.maxX - rect.width * 0.08, y: rect.maxY)
    )
    path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.46))
    path.curve(
        to: NSPoint(x: rect.midX, y: rect.minY),
        controlPoint1: NSPoint(x: rect.maxX, y: rect.midY - rect.height * 0.02),
        controlPoint2: NSPoint(x: rect.midX + rect.width * 0.18, y: rect.minY + rect.height * 0.12)
    )
    path.curve(
        to: NSPoint(x: rect.minX, y: rect.maxY - rect.height * 0.46),
        controlPoint1: NSPoint(x: rect.midX - rect.width * 0.18, y: rect.minY + rect.height * 0.12),
        controlPoint2: NSPoint(x: rect.minX, y: rect.midY - rect.height * 0.02)
    )
    path.close()
    return path
}
