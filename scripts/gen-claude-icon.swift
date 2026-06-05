#!/usr/bin/env swift
//
// gen-claude-icon.swift — generate the committed "Claude-ish" icon for pesterm.
//
// Draws an original 1024×1024 mark — a chunky, round-tipped rust sunburst on a
// near-black terminal squircle — and writes it as a PNG. This is OUR own art (not
// extracted from Claude.app): the build/install scripts embed this committed asset
// as the bundle icon when branding for the "claude" agent, so branding works on any
// machine with no /Applications/Claude.app dependency.
//
// Usage:
//   scripts/gen-claude-icon.swift [output.png]
//
// Default output is assets/claude-icon-1024.png relative to this script's repo root
// (this script lives in scripts/, so repo root is its parent dir). The drawing is
// deterministic — re-running regenerates the identical PNG.
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

// --- near-black squircle (terminal dark) ---
let corner = S * 0.2237
let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                    cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath); ctx.clip()
let grad = CGGradient(colorsSpace: cs,
                      colors: [col(0.12, 0.12, 0.13), col(0.05, 0.05, 0.06)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// --- rust sunburst: chunky, round-tipped rays (Claude-ish, original) ---
let center = CGPoint(x: S / 2, y: S / 2)
let rust = col(0.86, 0.46, 0.33)
ctx.setStrokeColor(rust)
ctx.setFillColor(rust)
ctx.setLineCap(.round)
ctx.setLineWidth(S * 0.072)             // chunky

let n = 10
let baseR1 = S * 0.32
let r0 = S * 0.045
let lenMul: [CGFloat] = [1.0, 0.76, 0.93, 0.72, 1.0, 0.80, 0.95, 0.74, 1.0, 0.82]

for i in 0..<n {
    let theta = (2.0 * .pi / Double(n)) * Double(i) + .pi / 2   // point up
    let dir = CGPoint(x: CGFloat(cos(theta)), y: CGFloat(sin(theta)))
    let r1 = baseR1 * lenMul[i]
    ctx.move(to: CGPoint(x: center.x + dir.x * r0, y: center.y + dir.y * r0))
    ctx.addLine(to: CGPoint(x: center.x + dir.x * r1, y: center.y + dir.y * r1))
    ctx.strokePath()
}
// solid rounded core
ctx.fillEllipse(in: CGRect(x: center.x - S * 0.07, y: center.y - S * 0.07,
                           width: S * 0.14, height: S * 0.14))

// --- write PNG ---
// Output path: explicit arg, else assets/claude-icon-1024.png relative to repo root
// (this script lives in scripts/, so repo root is its parent dir).
let outPath: String
if CommandLine.arguments.count > 1 {
    outPath = CommandLine.arguments[1]
} else {
    let scriptPath = CommandLine.arguments[0]
    let scriptURL = URL(fileURLWithPath: scriptPath)
    let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    outPath = repoRoot.appendingPathComponent("assets/claude-icon-1024.png").path
}

guard let img = ctx.makeImage() else { fatalError("no image") }
let url = URL(fileURLWithPath: outPath)
let pngType = UTType.png.identifier as CFString
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, pngType, 1, nil) else {
    fatalError("no dest")
}
CGImageDestinationAddImage(dest, img, nil)
if CGImageDestinationFinalize(dest) { print("wrote \(url.path)") } else { fatalError("write failed") }
