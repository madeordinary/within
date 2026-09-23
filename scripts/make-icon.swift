import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedRed: 0.975, green: 0.97, blue: 0.955, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 192, yRadius: 192).fill()
        let path = NSBezierPath()
        let points: [(Double, Double)] = [(228,512),(320,512),(370,625),(425,360),(478,658),(533,352),(584,620),(635,418),(687,512),(796,512)]
        path.move(to: NSPoint(x: points[0].0, y: points[0].1))
        for point in points.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
        path.lineWidth = 42; path.lineCapStyle = .round; path.lineJoinStyle = .round
        NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.28, alpha: 1).setStroke(); path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
