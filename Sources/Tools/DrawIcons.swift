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
    NSColor(srgbRed: 0.80, green: 0.89, blue: 0.96, alpha: 1).setFill()
    NSBezierPath(rect: rect).fill()
    let side = CGFloat(pixels) * 0.46
    let height = side * 1.05
    let port = NSRect(
        x: rect.midX - side / 2,
        y: rect.midY - height / 2,
        width: side,
        height: height
    )
    NSColor(srgbRed: 0.18, green: 0.45, blue: 0.72, alpha: 1).setFill()
    lanPort(in: port).housing.fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: output.appendingPathComponent(name))
}

func lanPort(in rect: NSRect) -> (housing: NSBezierPath, socket: NSBezierPath) {
    let body = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.84)
    let latchWidth = rect.width * 0.46
    let latchHeight = rect.height * 0.20
    let latch = NSRect(
        x: rect.midX - latchWidth / 2,
        y: body.maxY - latchHeight * 0.28,
        width: latchWidth,
        height: latchHeight
    )
    let housing = NSBezierPath(roundedRect: body, xRadius: rect.width * 0.16, yRadius: rect.width * 0.16)
    housing.appendRoundedRect(latch, xRadius: latchHeight * 0.45, yRadius: latchHeight * 0.45)
    return (housing, NSBezierPath())
}
