#!/usr/bin/env swift
//
// gen-pesterm-icon.swift — generate the committed amber fallback icon for pesterm.
//
// Draws a 1024×1024 amber-squircle terminal-window glyph with a red notification badge
// and writes it as a PNG. This is the GENERIC / fallback icon source: the build/install
// scripts build the bundle icns from this PNG (via iconset + iconutil/sips) for generic
// or unknown agents, and as a fallback when the committed claude asset is missing. The
// "claude" agent brands from assets/claude-icon-1024.png (scripts/gen-claude-icon.swift).
//
// Usage:
//   scripts/gen-pesterm-icon.swift [output.png]
//
// Default output is assets/pesterm-icon-1024.png relative to this script's repo root.
// The drawing is byte-for-byte the working generator vendored from /tmp/pesterm-icon.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}
func col(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])!
}
let S = CGFloat(size)

// --- amber squircle background ---
let corner = S * 0.2237                       // Apple-ish continuous corner
let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                    cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath); ctx.clip()
let grad = CGGradient(colorsSpace: cs,
                      colors: [col(1.0, 0.74, 0.28), col(0.94, 0.55, 0.06)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// --- terminal window ---
let w = S * 0.60, h = S * 0.44
let tx = (S - w) / 2, ty = (S - h) / 2 - S * 0.015
let winRect = CGRect(x: tx, y: ty, width: w, height: h)
let winPath = CGPath(roundedRect: winRect, cornerWidth: S * 0.055, cornerHeight: S * 0.055, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03, color: col(0, 0, 0, 0.28))
ctx.addPath(winPath); ctx.setFillColor(col(0.11, 0.12, 0.14)); ctx.fillPath()
ctx.restoreGState()

// title-bar traffic lights (subtle "terminal" cue)
let dotR = S * 0.018
let dotY = ty + h - S * 0.052
for (i, c) in [col(1, 0.37, 0.34), col(1, 0.74, 0.2), col(0.3, 0.8, 0.35)].enumerated() {
    let dx = tx + S * 0.055 + CGFloat(i) * S * 0.06
    ctx.setFillColor(c)
    ctx.fillEllipse(in: CGRect(x: dx - dotR, y: dotY - dotR, width: 2 * dotR, height: 2 * dotR))
}

// prompt chevron ">"
ctx.setStrokeColor(col(0.46, 0.92, 0.52))     // terminal green
ctx.setLineWidth(S * 0.030)
ctx.setLineCap(.round); ctx.setLineJoin(.round)
let cx = tx + w * 0.27, cy = ty + h * 0.43
let ax = w * 0.12, ay = h * 0.15
ctx.move(to: CGPoint(x: cx - ax, y: cy + ay))
ctx.addLine(to: CGPoint(x: cx + ax, y: cy))
ctx.addLine(to: CGPoint(x: cx - ax, y: cy - ay))
ctx.strokePath()

// cursor block
let curW = w * 0.17, curH = h * 0.13
ctx.setFillColor(col(0.92, 0.93, 0.95))
ctx.fill(CGRect(x: cx + ax + w * 0.07, y: cy - curH / 2, width: curW, height: curH))

// --- notification badge (top-right of window) ---
let br = S * 0.115
let bc = CGPoint(x: tx + w, y: ty + h)
let badge = CGRect(x: bc.x - br, y: bc.y - br, width: 2 * br, height: 2 * br)
ctx.setFillColor(col(1, 1, 1))                 // white ring
ctx.fillEllipse(in: badge.insetBy(dx: -S * 0.014, dy: -S * 0.014))
ctx.setFillColor(col(0.96, 0.26, 0.21))        // red
ctx.fillEllipse(in: badge)

// --- write PNG ---
// Output path: explicit arg, else assets/pesterm-icon-1024.png relative to repo root
// (this script lives in scripts/, so repo root is its parent dir).
let outPath: String
if CommandLine.arguments.count > 1 {
    outPath = CommandLine.arguments[1]
} else {
    let scriptPath = CommandLine.arguments[0]
    let scriptURL = URL(fileURLWithPath: scriptPath)
    let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    outPath = repoRoot.appendingPathComponent("assets/pesterm-icon-1024.png").path
}

guard let img = ctx.makeImage() else { fatalError("no image") }
let url = URL(fileURLWithPath: outPath)
let pngType = UTType.png.identifier as CFString
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, pngType, 1, nil) else {
    fatalError("no dest")
}
CGImageDestinationAddImage(dest, img, nil)
if CGImageDestinationFinalize(dest) { print("wrote \(url.path)") } else { fatalError("write failed") }
