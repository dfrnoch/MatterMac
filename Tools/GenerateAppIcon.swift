// Original MatterMac geometric app icon generator; MIT licensed with the project.
// Development tool only: swift Tools/GenerateAppIcon.swift <output-directory>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

/// Fills a speech bubble: rounded body plus a separately filled tail (separate
/// fills avoid winding-rule holes where the two shapes overlap).
func fillBubble(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, tailLeft: Bool, tail: CGFloat, color: CGColor) {
    ctx.setFillColor(color)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
    let x = tailLeft ? rect.minX + rect.width * 0.3 : rect.maxX - rect.width * 0.3
    let dir: CGFloat = tailLeft ? 1 : -1
    ctx.move(to: CGPoint(x: x, y: rect.minY + tail * 0.6))
    ctx.addLine(to: CGPoint(x: x - dir * tail * 0.35, y: rect.minY - tail))
    ctx.addLine(to: CGPoint(x: x + dir * tail * 0.9, y: rect.minY + tail * 0.6))
    ctx.closePath()
    ctx.fillPath()
}

func render(_ n: Int) -> CGImage {
    let s = CGFloat(n)
    let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let u = s / 1024
    // Big Sur style grid: 824pt body inset 100pt, ~185pt corner radius.
    let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil))
    ctx.setFillColor(rgb(36, 72, 160))
    ctx.fillPath()
    fillBubble(ctx, CGRect(x: 380 * u, y: 250 * u, width: 420 * u, height: 300 * u),
               radius: 110 * u, tailLeft: false, tail: 80 * u, color: rgb(94, 209, 196))
    let front = CGRect(x: 224 * u, y: 440 * u, width: 470 * u, height: 330 * u)
    fillBubble(ctx, front, radius: 120 * u, tailLeft: true, tail: 90 * u, color: rgb(255, 255, 255))
    if n >= 64 {
        ctx.setFillColor(rgb(36, 72, 160))
        let r = 30 * u
        for i in 0..<3 {
            let cx = front.midX + CGFloat(i - 1) * 110 * u
            ctx.fillEllipse(in: CGRect(x: cx - r, y: front.midY - r, width: 2 * r, height: 2 * r))
        }
    }
    return ctx.makeImage()!
}

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift Tools/GenerateAppIcon.swift <output-directory>")
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let slots: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in slots {
    let url = out.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(px), nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
}
