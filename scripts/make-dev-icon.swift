#!/usr/bin/swift
// Regenerate AppIconDev.appiconset (the Debug build's icon) from
// AppIcon.appiconset by stamping an amber "DEV" ribbon across the
// bottom of every size, so the two apps are distinguishable in the
// Dock and app switcher. Re-run after changing the base icon:
//
//   /usr/bin/swift scripts/make-dev-icon.swift
//
// (/usr/bin/swift, same as scripts/eval: the swiftly toolchain on this
// machine doesn't match the system SDK.)
import AppKit

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Sources/Pigeon/Assets.xcassets/AppIcon.appiconset")
let dest = root.appendingPathComponent("Sources/Pigeon/Assets.xcassets/AppIconDev.appiconset")

let fm = FileManager.default
try fm.createDirectory(at: dest, withIntermediateDirectories: true)

// Composite the source icon plus a DEV ribbon into a fresh bitmap.
// (Drawing directly into the decoded PNG's rep is unreliable:
// NSGraphicsContext(bitmapImageRep:) returns nil for formats it can't
// attach to and the drawing silently no-ops.)
func badged(_ sourceRep: NSBitmapImageRep) -> NSBitmapImageRep {
    let w = CGFloat(sourceRep.pixelsWide), h = CGFloat(sourceRep.pixelsHigh)
    guard let image = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: sourceRep.pixelsWide, pixelsHigh: sourceRep.pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: image)
    else { fatalError("cannot create drawing context") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    sourceRep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))

    // macOS icon artwork sits inside a margin (~10% each side); align the
    // ribbon to the artwork, not the canvas.
    let inset = w * 0.10
    let ribbonHeight = h * 0.26
    let ribbon = NSRect(x: inset, y: h * 0.06, width: w - inset * 2, height: ribbonHeight)
    let path = NSBezierPath(roundedRect: ribbon, xRadius: ribbonHeight * 0.3, yRadius: ribbonHeight * 0.3)
    NSColor(calibratedRed: 0.95, green: 0.60, blue: 0.10, alpha: 0.95).setFill()
    path.fill()

    let text = "DEV" as NSString
    var fontSize = ribbonHeight * 0.72
    var attrs: [NSAttributedString.Key: Any]
    var size: NSSize
    repeat {
        attrs = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
            .foregroundColor: NSColor.white,
        ]
        size = text.size(withAttributes: attrs)
        fontSize *= 0.95
    } while size.width > ribbon.width * 0.85
    text.draw(
        at: NSPoint(x: ribbon.midX - size.width / 2, y: ribbon.midY - size.height / 2),
        withAttributes: attrs)

    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return image
}

for name in try fm.contentsOfDirectory(atPath: source.path).sorted() {
    let from = source.appendingPathComponent(name)
    let to = dest.appendingPathComponent(name)
    if name.hasSuffix(".png") {
        guard let rep = NSBitmapImageRep(data: try Data(contentsOf: from)) else {
            fatalError("unreadable png: \(name)")
        }
        guard let out = badged(rep).representation(using: .png, properties: [:]) else {
            fatalError("png encode failed: \(name)")
        }
        try out.write(to: to)
        print("badged \(name)")
    } else if name == "Contents.json" {
        try? fm.removeItem(at: to)
        try fm.copyItem(at: from, to: to)
    }
}
print("done → \(dest.path)")
