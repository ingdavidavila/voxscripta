import AppKit
import Foundation

// Generates VoxScripta's app icon: a sound wave resolving into lines of text (§2).
//
// Drawn rather than shipped as a binary asset, so the icon is reproducible, and
// so the concept stays editable — the wave-to-text transition is the whole idea
// and it should be adjustable in one place.

/// Deterministic bar heights, so every regeneration is identical.
func waveHeights(count: Int) -> [CGFloat] {
    var state: UInt64 = 0x564F_5856   // "VOXV"
    return (0..<count).map { index in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let noise = CGFloat(state >> 33) / CGFloat(UInt32.max)
        // A slow envelope under the noise, so it reads as speech rather than
        // as a random bar chart.
        let envelope = 0.45 + 0.55 * sin(Double(index) / Double(count) * .pi * 1.6)
        return CGFloat(0.22 + 0.78 * noise * envelope)
    }
}

func drawIcon(into context: CGContext, size: CGFloat, fullBleed: Bool) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // Rounded-square ground, in the deep teal the project uses throughout.
    //
    // Full bleed on iOS, which applies its own corner mask: an icon that
    // brings its own inset and rounding is then drawn inside that mask and
    // reads as a small picture of an icon rather than as one.
    let inset = fullBleed ? 0 : size * 0.055
    let body = rect.insetBy(dx: inset, dy: inset)
    let corner = fullBleed ? 0 : size * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)
    context.saveGState()
    context.addPath(path)
    context.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.043, green: 0.30, blue: 0.33, alpha: 1),
        CGColor(red: 0.024, green: 0.16, blue: 0.20, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: size, y: 0),
                               options: [])

    // ── The wave, resolving into text ───────────────────────────────────────
    //
    // Two motifs sharing a baseline: vertical bars on the left, horizontal rules
    // on the right. An earlier version tried to morph one continuously into the
    // other, and the text half read as scattered specks — text is legible because
    // its marks are *horizontal and joined*, which a field of shortened vertical
    // bars can never become. The transition is instead carried by the wave bars
    // shrinking toward the midline as they approach the text.
    let field = body.insetBy(dx: size * 0.13, dy: size * 0.22)
    let midline = field.midY
    let waveWidth = field.width * 0.46
    let textStart = field.minX + field.width * 0.56

    // Wave: full height at the left, collapsing toward the midline at the right.
    let barCount = 17
    let heights = waveHeights(count: barCount)
    let slot = waveWidth / CGFloat(barCount)

    for index in 0..<barCount {
        let t = CGFloat(index) / CGFloat(barCount - 1)
        // Hold full height across most of the wave, then fall away quickly.
        let decay = 1 - pow(max((t - 0.55) / 0.45, 0), 1.7)
        let half = heights[index] * field.height * 0.46 * decay
        let width = slot * 0.44
        let x = field.minX + CGFloat(index) * slot + (slot - width) / 2
        let bar = CGRect(x: x, y: midline - half, width: width, height: half * 2)
        guard bar.height > 0.5 else { continue }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.93))
        let radius = min(width, bar.height) / 2
        context.addPath(CGPath(roundedRect: bar, cornerWidth: radius,
                               cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    // Text: four ruled lines, the last one short, as a paragraph looks.
    let rows: [CGFloat] = [1.0, 0.92, 0.97, 0.55]
    let rowHeight = field.height * 0.085
    let rowGap = field.height * 0.20
    let textWidth = field.maxX - textStart

    for (row, fraction) in rows.enumerated() {
        let y = midline + rowGap * 1.5 - CGFloat(row) * rowGap - rowHeight / 2
        let line = CGRect(x: textStart, y: y, width: textWidth * fraction, height: rowHeight)
        context.setFillColor(CGColor(red: 0.94, green: 0.68, blue: 0.31, alpha: 0.95))
        context.addPath(CGPath(roundedRect: line, cornerWidth: rowHeight / 2,
                               cornerHeight: rowHeight / 2, transform: nil))
        context.fillPath()
    }

    context.restoreGState()
}

/// The macOS iconset slices, drawn the way they always were.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }
    if let context = NSGraphicsContext.current?.cgContext {
        drawIcon(into: context, size: size, fullBleed: false)
    }
    return image
}

/// PNG data at an exact pixel size.
///
/// Into a bitmap of its own rather than through `NSImage.lockFocus`, which
/// takes the screen's backing scale and so renders a 1024-point icon as a
/// 2048-pixel file on any Retina Mac. iOS wants exactly 1024, and it rejects
/// an icon with an alpha channel outright, so both are fixed here instead of
/// being corrected afterwards by a second tool.
func iconPNG(pixels: Int, fullBleed: Bool) -> Data? {
    // `noneSkipLast` rather than a 24-bit bitmap: CoreGraphics has no
    // three-component context, so asking NSBitmapImageRep for one without
    // alpha yields a rep that cannot be drawn into at all. This keeps a
    // fourth byte per pixel and ignores it, and the image that comes out
    // carries no alpha channel — which is what iOS requires.
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }

    let appKit = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = appKit
    drawIcon(into: context, size: CGFloat(pixels), fullBleed: fullBleed)
    NSGraphicsContext.restoreGraphicsState()

    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

// ── Write the iconset ───────────────────────────────────────────────────────

let output = CommandLine.arguments.count > 1
    ? URL(filePath: CommandLine.arguments[1])
    : URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "build")

let iconset = output.appending(path: "VoxScripta.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, size) in variants {
    let image = drawIcon(size: size)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appending(path: "\(name).png"))
}

print("wrote \(iconset.path)")

// ── The iOS app icon ────────────────────────────────────────────────────────
//
// One 1024 square, which is the whole of a modern iOS icon set. Written
// straight into the Xcode target's asset catalogue so that regenerating the
// icon updates the app, rather than producing a file someone then has to
// remember to copy.
let appIconSet = URL(filePath: #filePath)
    .deletingLastPathComponent()      // Tools
    .deletingLastPathComponent()      // the package root
    .appending(path: "ios/VoxScripta/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)

guard let appIcon = iconPNG(pixels: 1024, fullBleed: true) else {
    FileHandle.standardError.write(Data("could not render the iOS icon\n".utf8))
    exit(1)
}
try appIcon.write(to: appIconSet.appending(path: "AppIcon-1024.png"))
try #"""
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""# .write(to: appIconSet.appending(path: "Contents.json"), atomically: true, encoding: .utf8)

print("wrote \(appIconSet.path)")
