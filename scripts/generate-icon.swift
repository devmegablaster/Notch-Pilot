#!/usr/bin/env swift
//
// generate-icon.swift — renders NotchPilot's app icon as PNGs into an
// `.iconset` directory. Called from scripts/build.sh; the resulting
// iconset is handed to `iconutil -c icns` to produce AppIcon.icns.
//
// The icon is described entirely in code: a black rounded square with
// two green "buddy eyes" centered, matching the BuddyFace green color.
// No binary assets committed — fork-friendly.
//
// Usage: swift scripts/generate-icon.swift <output-iconset-dir>

import AppKit

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: generate-icon.swift <output.iconset>\n", stderr)
    exit(1)
}
let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Standard macOS iconset filename → pixel-size mapping.
let variants: [(filename: String, size: Int)] = [
    ("icon_16x16.png",        16),
    ("icon_16x16@2x.png",     32),
    ("icon_32x32.png",        32),
    ("icon_32x32@2x.png",     64),
    ("icon_128x128.png",     128),
    ("icon_128x128@2x.png",  256),
    ("icon_256x256.png",     256),
    ("icon_256x256@2x.png",  512),
    ("icon_512x512.png",     512),
    ("icon_512x512@2x.png", 1024),
]

// Matches BuddyColor.green in Sources/NotchPilot/BuddyFace.swift
// (#70D46B). Using sRGB so the PNG renders correctly on every display.
let eyeGreen = NSColor(srgbRed: 0.44, green: 0.83, blue: 0.42, alpha: 1.0)

func render(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    )!
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.shouldAntialias = true
    ctx.imageInterpolation = .high

    // Rounded square background — black. macOS icon corner radius is a
    // superellipse in reality but ~22% of side length reads close enough
    // at all rendered scales and the squircle math isn't worth the code.
    let cornerRadius = s * 0.22
    let bgRect = NSRect(x: 0, y: 0, width: s, height: s)
    let bg = NSBezierPath(
        roundedRect: bgRect,
        xRadius: cornerRadius,
        yRadius: cornerRadius
    )
    NSColor.black.setFill()
    bg.fill()

    // Buddy eyes — two solid filled circles, no halo. Concentric
    // translucent rings read as separate disks rather than a glow at
    // icon sizes, so we just go with clean solids.
    let eyeRadius: CGFloat = s * 0.135
    let centerOffset: CGFloat = s * 0.21    // distance from icon center to each eye center
    let cx = s / 2
    let cy = s / 2

    let leftCenter = NSPoint(x: cx - centerOffset, y: cy)
    let rightCenter = NSPoint(x: cx + centerOffset, y: cy)

    eyeGreen.setFill()
    for c in [leftCenter, rightCenter] {
        let eye = NSBezierPath(ovalIn: NSRect(
            x: c.x - eyeRadius,
            y: c.y - eyeRadius,
            width: eyeRadius * 2,
            height: eyeRadius * 2
        ))
        eye.fill()
    }

    return rep
}

for variant in variants {
    let rep = render(size: variant.size)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("failed to encode \(variant.filename)\n", stderr)
        exit(1)
    }
    let url = URL(fileURLWithPath: "\(outDir)/\(variant.filename)")
    do {
        try data.write(to: url)
        print("✓ \(variant.filename) (\(variant.size)×\(variant.size))")
    } catch {
        fputs("failed to write \(url.path): \(error)\n", stderr)
        exit(1)
    }
}
