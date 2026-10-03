import AppKit
import Foundation

// Draws the install window's background: an arrow from Within to Applications and the
// first-open steps. Finder places the real, draggable icons on top (see make-dmg.sh).
// Writes opaque background.png and background@2x.png; Finder ignores many images with alpha.
// Finder draws windows with a background picture in light mode, so light colors stay readable.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
// Taller than the content: Finder shows scroll bars when icons come near the window's edge.
let size = CGSize(width: 660, height: 540)

func color(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
// The app's light palette (Palette in DesignSystem.swift).
let canvas = color(0xF5F4F0), surface = color(0xFFFFFF), line = color(0xDDDBD6)
let accent = color(0x00624C), text = color(0x1D1D1F), secondary = color(0x6E6E73)

func serif(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size)
    return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}
func draw(_ string: String, font: NSFont, color: NSColor, in rect: CGRect, centered: Bool = false, hangingIndent: CGFloat = 0) {
    let style = NSMutableParagraphStyle()
    style.alignment = centered ? .center : .left
    style.lineSpacing = 3
    style.headIndent = hangingIndent
    NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        .draw(with: rect, options: [.usesLineFragmentOrigin])
}

for scale in [1, 2] {
    let width = Int(size.width) * scale, height = Int(size.height) * scale
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
    // Top-left origin in points, matching Finder's icon positions.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

    canvas.setFill()
    CGRect(origin: .zero, size: size).fill()
    draw("Drag Within into Applications", font: serif(24), color: text, in: CGRect(x: 0, y: 40, width: size.width, height: 34), centered: true)

    // Icons sit at (170, 185) and (490, 185), 96 points wide.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 256, y: 185)); arrow.line(to: NSPoint(x: 402, y: 185))
    arrow.move(to: NSPoint(x: 388, y: 172)); arrow.line(to: NSPoint(x: 404, y: 185)); arrow.line(to: NSPoint(x: 388, y: 198))
    arrow.lineWidth = 5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    accent.setStroke(); arrow.stroke()

    // The Read Me icon sits inside this panel at (540, 362).
    let panel = NSBezierPath(roundedRect: CGRect(x: 28, y: 296, width: 604, height: 150), xRadius: 14, yRadius: 14)
    surface.setFill(); panel.fill()
    line.setStroke(); panel.lineWidth = 1; panel.stroke()
    draw("Opening Within the first time", font: .systemFont(ofSize: 14, weight: .semibold), color: text, in: CGRect(x: 50, y: 314, width: 420, height: 22))
    draw("1. Open Within from Applications.\n2. If macOS says it can’t be opened, click Done.\n3. Open System Settings → Privacy & Security, scroll to Security and click Open Anyway.",
         font: .systemFont(ofSize: 12.5), color: secondary, in: CGRect(x: 50, y: 342, width: 420, height: 96), hangingIndent: 14)

    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage() else { exit(1) }
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = size // 72 dpi at 1x and 144 dpi at 2x, so tiffutil pairs them.
    guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    try data.write(to: directory.appendingPathComponent(scale == 2 ? "background@2x.png" : "background.png"))
}
