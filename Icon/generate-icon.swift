#!/usr/bin/env swift
// Generates the ActionsHub app icon: a 1024×1024 master PNG, a full .iconset,
// and AppIcon.icns — all drawn programmatically (no external image tools).
//
//   swift Icon/generate-icon.swift
//
// Concept: a bright blue macOS "squircle" holding a 2×2 grid of panes (the app's
// split view). Each pane has a few "run rows" and one status light — passed,
// running, awaiting approval, failed — the four states the app watches.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

// MARK: - Drawing

func makeIcon(size S: CGFloat) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let u = S / 1024.0   // scale factor so all constants are in 1024-space

    // --- Squircle body (Apple-style: art inset inside the 1024 canvas) ---
    let margin: CGFloat = 92 * u
    let body = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let radius = body.width * 0.2237
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft contact shadow under the squircle.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 34 * u, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(rgb(0, 0, 0))
    ctx.fillPath()
    ctx.restoreGState()

    // Sky → royal blue gradient, clipped to the squircle.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs,
                          colors: [rgb(0.36, 0.66, 1.00), rgb(0.20, 0.36, 0.90)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY), options: [])
    // Subtle top sheen for depth.
    let sheen = CGGradient(colorsSpace: cs,
                           colors: [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.midY), options: [])
    ctx.restoreGState()

    // --- 2×2 grid of panes ---
    let inset: CGFloat = 170 * u
    let gap: CGFloat = 36 * u
    let grid = body.insetBy(dx: inset - margin, dy: inset - margin)
    let paneW = (grid.width - gap) / 2
    let paneH = (grid.height - gap) / 2

    // Reading order top-left → bottom-right: passed, running, approval, failed.
    let lights: [CGColor] = [
        rgb(0.20, 0.80, 0.42),  // green
        rgb(1.00, 0.62, 0.16),  // orange
        rgb(0.72, 0.38, 0.98),  // purple
        rgb(0.98, 0.30, 0.33),  // red
    ]

    for i in 0..<4 {
        let col = CGFloat(i % 2), row = CGFloat(i / 2)
        let pane = CGRect(x: grid.minX + col * (paneW + gap),
                          y: grid.maxY - paneH - row * (paneH + gap),
                          width: paneW, height: paneH)
        let panePath = CGPath(roundedRect: pane, cornerWidth: 34 * u, cornerHeight: 34 * u, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * u), blur: 18 * u, color: rgb(0.05, 0.12, 0.35, 0.28))
        ctx.addPath(panePath)
        ctx.setFillColor(rgb(1, 1, 1, 0.96))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(panePath)
        ctx.setStrokeColor(rgb(1, 1, 1, 1))
        ctx.setLineWidth(3 * u)
        ctx.strokePath()

        // Status light with a soft glow, top-left of the pane.
        let dotR: CGFloat = 34 * u
        let dot = CGPoint(x: pane.minX + 44 * u + dotR, y: pane.maxY - 44 * u - dotR)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 26 * u, color: lights[i].copy(alpha: 0.6))
        ctx.setFillColor(lights[i])
        ctx.fillEllipse(in: CGRect(x: dot.x - dotR, y: dot.y - dotR, width: dotR * 2, height: dotR * 2))
        ctx.restoreGState()

        // Title bar beside the light, then two "run rows" beneath.
        let barH: CGFloat = 20 * u
        func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ alpha: CGFloat) {
            let r = CGRect(x: x, y: y - barH / 2, width: w, height: barH)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
            ctx.setFillColor(rgb(0.22, 0.32, 0.55, alpha))
            ctx.fillPath()
        }
        let textX = dot.x + dotR + 26 * u
        bar(textX, dot.y, pane.maxX - 44 * u - textX, 0.55)
        bar(pane.minX + 44 * u, dot.y - 92 * u, paneW - 88 * u, 0.20)
        bar(pane.minX + 44 * u, dot.y - 150 * u, paneW * 0.55, 0.20)
    }

    return ctx.makeImage()!
}

// MARK: - Encoding helpers

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Build outputs

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let fm = FileManager.default

// 1024 master.
writePNG(makeIcon(size: 1024), to: here.appendingPathComponent("AppIcon-1024.png"))

// Full .iconset (every size macOS expects, @1x and @2x).
let iconset = here.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let specs: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in specs {
    writePNG(makeIcon(size: CGFloat(px)), to: iconset.appendingPathComponent("\(name).png"))
}

// AppIcon.icns via iconutil.
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", here.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()

print("Wrote AppIcon.icns, AppIcon.iconset, AppIcon-1024.png in \(here.path)")
