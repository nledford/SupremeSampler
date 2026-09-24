// Draws the app icon at every size macOS wants and writes the PNGs plus
// `Contents.json` into the asset catalog's `AppIcon.appiconset`.
//
//     swift scripts/make-app-icon.swift Sources/SupremeSampler/Assets.xcassets/AppIcon.appiconset
//
// (or `just icon`). The idea: a grid of dim photo tiles -- the catalog --
// with a few scattered tiles lit up as little landscape photos -- the
// random sample. Small sizes get a 3x3 grid so they stay legible instead
// of turning into noise.

import AppKit

/// An RGB color from a hex literal, like CSS `#2B3A67`.
func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The colors of one lit-up "photo": sky top, sky bottom, mountain, sun.
struct PhotoPalette {
    let skyTop: NSColor
    let skyBottom: NSColor
    let mountain: NSColor
    let sun: NSColor
}

let palettes = [
    PhotoPalette(skyTop: color(0xFFB36B), skyBottom: color(0xFF6F61), mountain: color(0x7A2E4D), sun: color(0xFFF1A8)),
    PhotoPalette(skyTop: color(0x7FE3E0), skyBottom: color(0x2FA4B8), mountain: color(0x1D5A6B), sun: color(0xFFFFFF)),
    PhotoPalette(skyTop: color(0xC7A6FF), skyBottom: color(0x7C6CF2), mountain: color(0x3B2F86), sun: color(0xFFE6FA)),
    PhotoPalette(skyTop: color(0xB9F28C), skyBottom: color(0x4DBB6B), mountain: color(0x21613E), sun: color(0xFFFBD0)),
]

/// Which tiles are "sampled", as (column, row) from the top left, for a
/// grid of each size. Scattered on purpose: a random sample, not a pattern.
let sampledTiles: [Int: [(Int, Int)]] = [
    4: [(1, 0), (3, 1), (0, 2), (2, 3)],
    3: [(2, 0), (0, 2)],
]

/// Draws one tile as a tiny landscape photo inside `rect`.
func drawPhoto(in rect: CGRect, radius: CGFloat, palette: PhotoPalette) {
    let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    NSGradient(starting: palette.skyTop, ending: palette.skyBottom)!.draw(in: rect, angle: -90)

    let sunSize = rect.width * 0.26
    NSBezierPath(ovalIn: CGRect(
        x: rect.minX + rect.width * 0.60, y: rect.minY + rect.height * 0.56, width: sunSize, height: sunSize)).fill(
            with: palette.sun)

    let mountain = NSBezierPath()
    mountain.move(to: CGPoint(x: rect.minX - rect.width * 0.05, y: rect.minY))
    mountain.line(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.58))
    mountain.line(to: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.30))
    mountain.line(to: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.44))
    mountain.line(to: CGPoint(x: rect.maxX + rect.width * 0.05, y: rect.minY))
    mountain.close()
    mountain.fill(with: palette.mountain)
    NSGraphicsContext.restoreGraphicsState()
}

extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}

/// The whole icon, drawn into a square canvas `side` pixels wide.
func drawIcon(side: CGFloat, grid: Int) {
    // Apple's macOS icon grid: the rounded square is 824/1024 of the
    // canvas, centered, leaving room for its shadow.
    let unit = side / 1024
    let body = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185 * unit, yRadius: 185 * unit)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * unit)
    shadow.shadowBlurRadius = 22 * unit
    shadow.set()
    bodyPath.fill(with: color(0x1A2244))
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    NSGradient(starting: color(0x33457D), ending: color(0x121833))!.draw(in: body, angle: -90)
    // A soft highlight across the top, like light on glass.
    NSGradient(starting: NSColor.white.withAlphaComponent(0.10), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let padding = (grid == 4 ? 132 : 150) * unit
    let gap = (grid == 4 ? 28 : 40) * unit
    let tile = (body.width - 2 * padding - CGFloat(grid - 1) * gap) / CGFloat(grid)
    let radius = tile * 0.2
    let sampled = sampledTiles[grid]!

    for row in 0..<grid {
        for column in 0..<grid {
            // Rows count from the top; AppKit's y axis counts from the bottom.
            let rect = CGRect(
                x: body.minX + padding + CGFloat(column) * (tile + gap),
                y: body.maxY - padding - tile - CGFloat(row) * (tile + gap),
                width: tile, height: tile)
            if let index = sampled.firstIndex(where: { $0 == (column, row) }) {
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = NSColor.black.withAlphaComponent(0.45)
                glow.shadowOffset = NSSize(width: 0, height: -6 * unit)
                glow.shadowBlurRadius = 14 * unit
                glow.set()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill(with: color(0x121833))
                NSGraphicsContext.restoreGraphicsState()
                drawPhoto(in: rect, radius: radius, palette: palettes[index % palettes.count])
            } else {
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                    .fill(with: NSColor.white.withAlphaComponent(0.13))
            }
        }
    }
}

/// Renders the icon at `pixels` x `pixels` and returns PNG data.
func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon(side: CGFloat(pixels), grid: pixels <= 64 ? 3 : 4)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift make-app-icon.swift <AppIcon.appiconset>\n".data(using: .utf8)!)
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

// Every point size macOS uses, at 1x and 2x.
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(pixels: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(output.path)")
