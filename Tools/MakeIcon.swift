import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let sizes = [16, 32, 64, 128, 256, 512, 1024]
for size in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()
    let rect = NSRect(x: 70, y: 70, width: 884, height: 884)
    let path = NSBezierPath(roundedRect: rect, xRadius: 204, yRadius: 204)
    NSGradient(starting: NSColor(calibratedWhite: 0.17, alpha: 1), ending: NSColor(calibratedWhite: 0.025, alpha: 1))!.draw(in: path, angle: -90)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    path.lineWidth = 3
    path.stroke()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: 350, y: 800, width: 324, height: 154), xRadius: 54, yRadius: 54).fill()
    NSColor(calibratedRed: 0.56, green: 0.91, blue: 0.73, alpha: 1).setStroke()
    let tray = NSBezierPath()
    tray.lineWidth = 35
    tray.lineJoinStyle = .round
    tray.lineCapStyle = .round
    tray.move(to: NSPoint(x: 292, y: 490))
    tray.line(to: NSPoint(x: 242, y: 325))
    tray.line(to: NSPoint(x: 242, y: 245))
    tray.curve(to: NSPoint(x: 280, y: 210), controlPoint1: NSPoint(x: 242, y: 222), controlPoint2: NSPoint(x: 255, y: 210))
    tray.line(to: NSPoint(x: 744, y: 210))
    tray.curve(to: NSPoint(x: 782, y: 245), controlPoint1: NSPoint(x: 769, y: 210), controlPoint2: NSPoint(x: 782, y: 222))
    tray.line(to: NSPoint(x: 782, y: 325))
    tray.line(to: NSPoint(x: 732, y: 490))
    tray.move(to: NSPoint(x: 250, y: 330))
    tray.line(to: NSPoint(x: 405, y: 330))
    tray.curve(to: NSPoint(x: 619, y: 330), controlPoint1: NSPoint(x: 430, y: 225), controlPoint2: NSPoint(x: 594, y: 225))
    tray.line(to: NSPoint(x: 774, y: 330))
    tray.stroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = 36
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 512, y: 690))
    arrow.line(to: NSPoint(x: 512, y: 410))
    arrow.move(to: NSPoint(x: 412, y: 510))
    arrow.line(to: NSPoint(x: 512, y: 410))
    arrow.line(to: NSPoint(x: 612, y: 510))
    arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    let names: [String]
    switch size {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try data.write(to: output.appendingPathComponent(name)) }
}
