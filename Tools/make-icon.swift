// Renders the app icon as an .iconset, then `make-icon.sh` turns it into .icns.
// Kept as source rather than a committed-only binary so the icon can be changed
// without a design tool.
import AppKit
import CoreGraphics
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "Trackr.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// Three quota bars at different fills — the app's whole idea in one glyph.
/// Fractions are of the canvas, so every size renders identically.
let bars: [(fill: CGFloat, color: CGColor)] = [
    (0.30, CGColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)),   // plenty left
    (0.58, CGColor(red: 1.00, green: 0.69, blue: 0.13, alpha: 1)),   // getting on
    (0.93, CGColor(red: 0.91, green: 0.27, blue: 0.22, alpha: 1)),   // nearly spent
]

func render(_ size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS icons sit inset inside their canvas rather than filling it.
    let inset = s * 0.085
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let body = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225,
                      cornerHeight: rect.width * 0.225, transform: nil)

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 0.16, green: 0.18, blue: 0.23, alpha: 1),
                 CGColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY),
                           end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()

    // A hairline rim keeps the icon from dissolving into a dark dock background.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.strokePath()
    ctx.restoreGState()

    let barHeight = rect.height * 0.105
    let barWidth = rect.width * 0.62
    let barX = rect.minX + (rect.width - barWidth) / 2
    let gap = rect.height * 0.085
    let block = barHeight * 3 + gap * 2
    var y = rect.midY + block / 2 - barHeight

    for bar in bars {
        let track = CGRect(x: barX, y: y, width: barWidth, height: barHeight)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: barHeight / 2,
                           cornerHeight: barHeight / 2, transform: nil))
        ctx.fillPath()

        let filled = CGRect(x: barX, y: y, width: max(barHeight, barWidth * bar.fill),
                            height: barHeight)
        ctx.setFillColor(bar.color)
        ctx.addPath(CGPath(roundedRect: filled, cornerWidth: barHeight / 2,
                           cornerHeight: barHeight / 2, transform: nil))
        ctx.fillPath()

        y -= barHeight + gap
    }
    return ctx.makeImage()
}

// The sizes `iconutil` expects, each in 1x and 2x.
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        guard let image = render(px) else { continue }
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: base, height: base)
        guard let data = rep.representation(using: .png, properties: [:]) else { continue }
        try data.write(to: outDir.appendingPathComponent(name))
    }
}
print("wrote iconset to \(outDir.path)")
