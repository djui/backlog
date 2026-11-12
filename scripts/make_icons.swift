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

/// A short stack of saved things: two cards fanned behind, the front one with a play disc and two
/// lines of text — something put aside to watch or read later. Fills most of the canvas so it reads
/// at Dock and Home Screen sizes; the system adds the glass.
func drawStack(in rect: CGRect) {
    let W = rect.width
    func card(_ frame: NSRect, radius: CGFloat, top: NSColor, bottom: NSColor, angle: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: frame.midX, yBy: frame.midY)
        t.rotate(byDegrees: angle)
        t.translateX(by: -frame.midX, yBy: -frame.midY)
        t.concat()
        let path = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        NSGradient(starting: top, ending: bottom)!.draw(in: path, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }
    let w = W * 0.70, h = W * 0.46, r = W * 0.085
    let cx = rect.midX
    // Back cards, fanned.
    card(NSRect(x: cx - w * 0.44, y: W * 0.50, width: w * 0.88, height: h * 0.88), radius: r * 0.9,
         top: color(255, 222, 160), bottom: color(250, 196, 120), angle: 7)
    card(NSRect(x: cx - w * 0.47, y: W * 0.43, width: w * 0.94, height: h * 0.94), radius: r * 0.95,
         top: color(255, 178, 92), bottom: color(244, 142, 60), angle: -4)
    // Front card.
    let front = NSRect(x: cx - w / 2, y: W * 0.20, width: w, height: h)
    card(front, radius: r, top: color(245, 120, 54), bottom: color(214, 76, 30), angle: 0)

    let d = h * 0.48
    let disc = NSRect(x: front.minX + w * 0.11, y: front.midY - d / 2, width: d, height: d)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: disc).fill()
    let t = d * 0.36
    let tri = NSBezierPath()
    tri.move(to: CGPoint(x: disc.midX - t * 0.42, y: disc.midY + t * 0.62))
    tri.line(to: CGPoint(x: disc.midX + t * 0.68, y: disc.midY))
    tri.line(to: CGPoint(x: disc.midX - t * 0.42, y: disc.midY - t * 0.62))
    tri.close()
    color(220, 82, 34).setFill()
    tri.fill()
    let lineH = h * 0.12
    let lineX = disc.maxX + w * 0.08
    let lineW = front.maxX - w * 0.1 - lineX
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: lineX, y: front.midY + lineH * 0.55, width: lineW, height: lineH), xRadius: lineH / 2, yRadius: lineH / 2).fill()
    NSColor.white.withAlphaComponent(0.72).setFill()
    NSBezierPath(roundedRect: NSRect(x: lineX, y: front.midY - lineH * 1.55, width: lineW * 0.62, height: lineH), xRadius: lineH / 2, yRadius: lineH / 2).fill()
}

let iconFile = root.appendingPathComponent("Shared/AppIcon.icon")
try? FileManager.default.removeItem(at: iconFile)
try FileManager.default.createDirectory(at: iconFile.appendingPathComponent("Assets"), withIntermediateDirectories: true)
try png(size: 1024) { drawStack(in: $0) }.write(to: iconFile.appendingPathComponent("Assets/stack.png"))

let icon: [String: Any] = [
    "fill-specializations": [
        ["value": ["linear-gradient": [srgb(255, 248, 238), srgb(250, 226, 200)]]],
        ["appearance": "dark", "value": ["linear-gradient": [srgb(48, 38, 36), srgb(20, 16, 16)]]],
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
for (name, top, bottom) in [("icon-light", color(255, 248, 238), color(250, 226, 200)), ("icon-dark", color(48, 38, 36), color(20, 16, 16))] {
    let data = png(size: 1024) { rect in
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
        NSGradient(starting: top, ending: bottom)!.draw(in: path, angle: -90)
        drawStack(in: rect)
    }
    try data.write(to: root.appendingPathComponent("site/assets/\(name).png"))
}
print("Wrote \(iconFile.path) and site/assets/icon-*.png")
