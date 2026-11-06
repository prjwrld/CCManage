// Draws the app icon - three overlapping account avatars above two usage
// bars - at every size macOS wants, and packs them into Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift        (run from the repo root)
//
// The icon is original artwork; it deliberately does not use Anthropic's logo.

import AppKit

let root = FileManager.default.currentDirectoryPath
let iconset = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// Everything is laid out on Apple's 1024-point icon grid, then scaled.
func draw(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)

    // Squircle-ish tile: 824 pt with a 100 pt margin, as in Apple's template.
    let background = rgb(0.13, 0.13, 0.12)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                       cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setFillColor(background)
    ctx.fillPath()

    // Three avatars, overlapping left to right; a ring in the tile colour
    // separates each from the one behind it.
    let colors = [rgb(0.85, 0.47, 0.34), rgb(0.27, 0.52, 0.95), rgb(0.69, 0.36, 0.87)]
    for (i, color) in colors.enumerated() {
        let center = CGPoint(x: 352 + CGFloat(i) * 160, y: 600)
        let disc = CGRect(x: center.x - 125, y: center.y - 125, width: 250, height: 250)
        ctx.setFillColor(background)
        ctx.fillEllipse(in: disc.insetBy(dx: -22, dy: -22))
        ctx.setFillColor(color)
        ctx.fillEllipse(in: disc)
    }

    // Two usage bars: track, then the used part.
    for (y, used, color) in [(CGFloat(355), CGFloat(0.72), colors[0]), (CGFloat(265), CGFloat(0.38), colors[1])] {
        let track = CGRect(x: 262, y: y, width: 500, height: 44)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: 22, cornerHeight: 22, transform: nil))
        ctx.setFillColor(rgb(1, 1, 1, 0.14))
        ctx.fillPath()
        let fill = CGRect(x: track.minX, y: y, width: track.width * used, height: 44)
        ctx.addPath(CGPath(roundedRect: fill, cornerWidth: 22, cornerHeight: 22, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
    }
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(pixels: size).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(size)x\(size).png"))
    try draw(pixels: size * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(size)x\(size)@2x.png"))
}
try draw(pixels: 1024).write(to: URL(fileURLWithPath: root + "/Resources/AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", root + "/Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
