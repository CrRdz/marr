#!/usr/bin/env swift
// Package the approved glass companion, clipping only the circular exterior.
// Run from the repository root: swift scripts/package-marr-app-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let design = root.appendingPathComponent("DesignAssets/MarrAppIcon")
let assets = root.appendingPathComponent("Marr/Assets.xcassets")
let dock = assets.appendingPathComponent("AppIcon.appiconset")
let status = assets.appendingPathComponent("MarrStatusIcon.imageset")
let source = NSBitmapImageRep(data: try Data(contentsOf: design.appendingPathComponent("glass-companion.png")))!
let sourceImage = source.cgImage!

// Measure visible coverage to normalize the generator's transparent padding.
// Keep the same framing and source pixels inside the circular mask.
var minX = source.pixelsWide, minY = source.pixelsHigh, maxX = 0, maxY = 0
for y in 0..<source.pixelsHigh {
    for x in 0..<source.pixelsWide where (source.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 {
        minX = min(minX, x); minY = min(minY, y)
        maxX = max(maxX, x); maxY = max(maxY, y)
    }
}
precondition(maxX > minX && maxY > minY, "The source artwork is empty")
let coverage = CGRect(x: minX, y: source.pixelsHigh - 1 - maxY,
                      width: maxX - minX + 1, height: maxY - minY + 1)

func render(pixels: Int, fill: CGFloat) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    let side = CGFloat(pixels)
    let scale = side * fill / max(coverage.width, coverage.height)
    context.interpolationQuality = .high
    // Keep the accepted artwork intact; only remove pixels outside its circle.
    // The same mask applies at every Dock/status size, with no backing tile.
    let diameter = side * fill
    let inset = (side - diameter) / 2
    context.addEllipse(in: CGRect(x: inset, y: inset, width: diameter, height: diameter))
    context.clip()
    context.draw(sourceImage, in: CGRect(
        x: side / 2 - coverage.midX * scale,
        y: side / 2 - coverage.midY * scale,
        width: CGFloat(source.pixelsWide) * scale,
        height: CGFloat(source.pixelsHigh) * scale))
    return bitmap
}

func save(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

func manifest(_ images: [[String: String]], at directory: URL, original: Bool = false) throws {
    var contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    if original { contents["properties"] = ["template-rendering-intent": "original"] }
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("Contents.json"))
}

try FileManager.default.createDirectory(at: dock, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: status, withIntermediateDirectories: true)
var dockImages: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in 1...2 {
        let name = "Marr-Dock-\(points)@\(scale)x.png"
        try save(render(pixels: points * scale, fill: 864.0 / 1024), to: dock.appendingPathComponent(name))
        dockImages.append(["idiom": "mac", "size": "\(points)x\(points)",
                           "scale": "\(scale)x", "filename": name])
    }
}
try manifest(dockImages, at: dock)
try save(render(pixels: 1024, fill: 864.0 / 1024), to: design.appendingPathComponent("dock-preview.png"))

// Template rendering would discard RGB and turn this sphere into a disk.
var statusImages: [[String: String]] = []
for scale in 1...3 {
    let name = "Marr-Status@\(scale)x.png"
    try save(render(pixels: 18 * scale, fill: 16.0 / 18), to: status.appendingPathComponent(name))
    statusImages.append(["idiom": "universal", "scale": "\(scale)x", "filename": name])
}
try manifest(statusImages, at: status, original: true)
print("Exported 10 Dock entries (16–1024 px) and 3 status-bar entries (18–54 px).")
