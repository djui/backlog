#!/usr/bin/env swift
// Renders the app icon into Shared/AppIcon.icon, the Icon Composer file the Mac and iPhone apps use. macOS 26 and
// iOS 26 switch icons for dark mode only through such a file: the ground is a fill per appearance, the card stack a
// layer on top, lit as glass by the system, which also makes the tinted and clear versions from it.
//
// Usage (from the repo root): swift scripts/make_icons.swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func png(size: Int, draw: (CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }

func srgb(_ r: Int, _ g: Int, _ b: Int) -> String {
    String(format: "srgb:%.5f,%.5f,%.5f,1.00000", Double(r) / 255, Double(g) / 255, Double(b) / 255)
}

/// A short stack of saved things: two cards behind, the front one with a play mark — something
/// put aside to watch or read later.
func drawStack(in rect: CGRect) {
    let orange = color(232, 108, 44)
    let amber = color(244, 164, 72)
    let sand = color(250, 214, 150)
    let w = rect.width * 0.56, h = rect.height * 0.36, r = rect.width * 0.07
    let cx = rect.midX
    let cards: [(CGFloat, CGFloat, NSColor)] = [(0.66, 0.84, sand), (0.58, 0.92, amber), (0.44, 1.0, orange)]
    for (yFrac, scale, c) in cards {
        let cw = w * scale, ch = h * scale
        let frame = NSRect(x: cx - cw / 2, y: rect.height * yFrac - ch / 2, width: cw, height: ch)
        c.setFill()
        NSBezierPath(roundedRect: frame, xRadius: r * scale, yRadius: r * scale).fill()
    }
    // The front card: a play disc and two lines of text — something to watch or read.
    let front = NSRect(x: cx - w / 2, y: rect.height * 0.44 - h / 2, width: w, height: h)
    let d = h * 0.46
    let disc = NSRect(x: front.minX + w * 0.11, y: front.midY - d / 2, width: d, height: d)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: disc).fill()
    let tri = NSBezierPath()
    let t = d * 0.34
    tri.move(to: CGPoint(x: disc.midX - t * 0.45, y: disc.midY + t * 0.6))
    tri.line(to: CGPoint(x: disc.midX + t * 0.65, y: disc.midY))
    tri.line(to: CGPoint(x: disc.midX - t * 0.45, y: disc.midY - t * 0.6))
    tri.close()
    orange.setFill()
    tri.fill()
    let lineH = h * 0.11
    let lineX = disc.maxX + w * 0.08
    NSColor.white.withAlphaComponent(0.95).setFill()
    NSBezierPath(roundedRect: NSRect(x: lineX, y: front.midY + lineH * 0.6, width: front.maxX - w * 0.1 - lineX, height: lineH), xRadius: lineH / 2, yRadius: lineH / 2).fill()
    NSColor.white.withAlphaComponent(0.7).setFill()
    NSBezierPath(roundedRect: NSRect(x: lineX, y: front.midY - lineH * 1.6, width: (front.maxX - w * 0.1 - lineX) * 0.65, height: lineH), xRadius: lineH / 2, yRadius: lineH / 2).fill()
}

let iconFile = root.appendingPathComponent("Shared/AppIcon.icon")
try? FileManager.default.removeItem(at: iconFile)
try FileManager.default.createDirectory(at: iconFile.appendingPathComponent("Assets"), withIntermediateDirectories: true)
try png(size: 1024) { drawStack(in: $0) }.write(to: iconFile.appendingPathComponent("Assets/stack.png"))

let icon: [String: Any] = [
    "fill-specializations": [
        ["value": ["linear-gradient": [srgb(255, 250, 244), srgb(246, 234, 220)]]],
        ["appearance": "dark", "value": ["linear-gradient": [srgb(44, 46, 56), srgb(18, 18, 24)]]],
    ],
    "groups": [[
        "layers": [[
            "name": "stack",
            "image-name": "stack.png",
        ]],
        "shadow": ["kind": "neutral", "opacity": 0.5],
        "translucency": ["enabled": true, "value": 0.4],
    ]],
    "supported-platforms": ["squares": "shared"],
]
try JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconFile.appendingPathComponent("icon.json"))
print("Wrote \(iconFile.path)")
