import AppKit
import Foundation

// Generates VoxVerba's app icon: a sound wave resolving into lines of text (§2).
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

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return image }
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // Rounded-square ground, in the deep teal the project uses throughout.
    let inset = size * 0.055
    let body = rect.insetBy(dx: inset, dy: inset)
    let corner = size * 0.225
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
    return image
}

// ── Write the iconset ───────────────────────────────────────────────────────

let output = CommandLine.arguments.count > 1
    ? URL(filePath: CommandLine.arguments[1])
    : URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "build")

let iconset = output.appending(path: "VoxVerba.iconset")
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
