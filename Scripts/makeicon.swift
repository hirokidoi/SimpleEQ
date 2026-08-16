// makeicon: render SimpleEQ's app icon (black squircle + glowing equalizer bars) entirely in
// code, writing the PNG set into the AppIcon.appiconset that Xcode's asset catalog compiles.
// Colors and composition follow the in-app brand mark (teal -> blue -> magenta glow on black).
// No external assets.
// Usage: makeicon <AppIcon.appiconset dir>
import CoreGraphics
import ImageIO
import Foundation

let bgTop = CGColor(red: 0.051, green: 0.059, blue: 0.086, alpha: 1) // squircle gradient
let bgBot = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

// Bar colors sampled across the app's teal -> blue -> magenta glow gradient.
let barColors: [CGColor] = [
    CGColor(red: 0.063, green: 0.906, blue: 0.706, alpha: 1), // teal   #10E7B4
    CGColor(red: 0.161, green: 0.663, blue: 0.988, alpha: 1), // cyan-blue
    CGColor(red: 0.184, green: 0.420, blue: 1.000, alpha: 1), // blue   #2F6BFF
    CGColor(red: 0.588, green: 0.302, blue: 1.000, alpha: 1), // violet
    CGColor(red: 0.761, green: 0.231, blue: 1.000, alpha: 1), // magenta #C23BFF
]

// Bar heights as a fraction of the available track height (unequal = "playing" liveliness).
// Kept equal to EQLayout.IconMotif.barHeightRatios by hand: this script builds standalone via
// `swiftc`, outside the app target, so it cannot import Sources/SimpleEQ to share the constant.
let barHeights: [CGFloat] = [0.42, 0.72, 1.0, 0.58, 0.85]

func renderIcon(_ S: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let bounds = CGRect(x: 0, y: 0, width: S, height: S)

    let margin = S * 0.09
    let rect = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let radius = rect.width * 0.2237                              // Apple squircle corner ratio
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let grad = CGGradient(colorsSpace: cs, colors: [bgTop, bgBot] as CFArray, locations: [0, 1])!

    ctx.saveGState(); ctx.addPath(squircle); ctx.clip()
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()

    // Equalizer bars: evenly spaced capsules, unequal heights, glowing per bar color.
    let n = barHeights.count
    let trackW = rect.width * 0.64
    let trackX = rect.midX - trackW / 2
    let bottomY = rect.minY + rect.height * 0.16
    let trackH = rect.height * 0.70
    let gapRatio: CGFloat = 0.42
    let barW = trackW / (CGFloat(n) + CGFloat(n - 1) * gapRatio)
    let step = barW * (1 + gapRatio)

    ctx.saveGState(); ctx.addPath(squircle); ctx.clip()
    for i in 0..<n {
        let h = trackH * barHeights[i]
        let x = trackX + CGFloat(i) * step
        let barRect = CGRect(x: x, y: bottomY, width: barW, height: h)
        let cap = min(barW, h) / 2
        let barPath = CGPath(roundedRect: barRect, cornerWidth: cap, cornerHeight: cap, transform: nil)
        let color = barColors[i]

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: S * 0.045, color: color.copy(alpha: 0.85))
        ctx.addPath(barPath); ctx.setFillColor(color); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.restoreGState()

    _ = bounds
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    _ = CGImageDestinationFinalize(dest)
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let specs: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in specs { writePNG(renderIcon(size), "\(outDir)/\(name).png") }
print("wrote \(specs.count) png(s) to \(outDir)")
