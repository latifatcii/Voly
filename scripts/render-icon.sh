#!/bin/bash
# Render the app icon: draw the SVGs in assets/icon/ at every size macOS asks
# for and write the PNGs into Voly/Assets.xcassets/AppIcon.appiconset.
#
# Usage: scripts/render-icon.sh
#
# Run it after editing either SVG, then commit the regenerated PNGs.
#
# The 16 and 32 pixel renditions come from voly-icon-small.svg, a simplified
# drawing that stays readable in Finder lists; the larger ones come from
# voly-icon.svg. The standard macOS icon drop shadow is added here, so the
# SVGs hold only the artwork.
#
# Needs nothing beyond the Xcode command line tools: AppKit draws the SVGs.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ICON_DIR="$ROOT/assets/icon" OUT_DIR="$ROOT/Voly/Assets.xcassets/AppIcon.appiconset" swift - <<'SWIFT'
import AppKit

let environment = ProcessInfo.processInfo.environment
let iconDirectory = URL(fileURLWithPath: environment["ICON_DIR"]!)
let outputDirectory = URL(fileURLWithPath: environment["OUT_DIR"]!)

func loadSVG(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: iconDirectory.appendingPathComponent(name)) else {
        fatalError("cannot read \(name)")
    }
    return image
}

let detailed = loadSVG("voly-icon.svg")
let simplified = loadSVG("voly-icon-small.svg")

func render(pixels: Int, to name: String) throws {
    let artwork = pixels <= 32 ? simplified : detailed
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    // The shadow from Apple's macOS icon template, given there for a 1024 canvas.
    let scale = CGFloat(pixels) / 1024
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.shadowBlurRadius = 10 * scale
    shadow.set()
    artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    // The SVG colours are sRGB values; say so in the file.
    let png = bitmap.retagging(with: .sRGB)!.representation(using: .png, properties: [:])!
    try png.write(to: outputDirectory.appendingPathComponent(name))
    print("   \(name)  (\(pixels)px)")
}

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points, to: "icon_\(points)x\(points).png")
    try render(pixels: points * 2, to: "icon_\(points)x\(points)@2x.png")
}
SWIFT

echo "== wrote $ROOT/Voly/Assets.xcassets/AppIcon.appiconset"
