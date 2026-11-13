// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics

// Renders the app icon: a play triangle filled with EQ-coloured bars on a gradient squircle.
// Drawn in a 1024pt design space and rendered natively at each output size,
// so nothing is upscaled. 16/32pt use three solid bars with no gaps, which stay legible.
//
// Regenerate after editing:
//   swift Tools/makeicon.swift AudioEqualizer/Resources/Assets.xcassets/AppIcon.appiconset
//
// Not part of the app target — it has top-level code and builds standalone.

let outDir = CommandLine.arguments[1]
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [r, g, b, a])!
}

let faderColors = [
    color(0.30, 0.87, 0.52),   // green   – lows
    color(0.24, 0.80, 0.82),   // teal
    color(0.99, 0.80, 0.26),   // yellow
    color(0.99, 0.44, 0.36),   // red     – highs
]


func render(size: Int) -> CGImage? {
    let scale = CGFloat(size) / 1024.0
    func p(_ v: CGFloat) -> CGFloat { v * scale }

    guard let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS icon grid: 824pt rounded square centred in a 1024pt canvas.
    let margin: CGFloat = 100
    let side: CGFloat = 1024 - margin * 2
    let plate = CGRect(x: p(margin), y: p(margin), width: p(side), height: p(side))
    let platePath = CGPath(roundedRect: plate, cornerWidth: p(185), cornerHeight: p(185), transform: nil)

    // Drop shadow under the plate.
    if size >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -p(14)), blur: p(30),
                      color: color(0, 0, 0, 0.40))
        ctx.addPath(platePath)
        ctx.setFillColor(color(0, 0, 0, 1))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Plate gradient.
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: srgb, colors: [
        color(0.22, 0.29, 0.55),
        color(0.07, 0.09, 0.19),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.minY), options: [])

    // Soft highlight along the top edge.
    let sheen = CGGradient(colorsSpace: srgb, colors: [
        color(1, 1, 1, 0.16),
        color(1, 1, 1, 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.midY), options: [])
    ctx.restoreGState()

    // A rounded play triangle filled with the four EQ colours as vertical
    // bars, so it reads as "player" first and "equalizer" second.
    let left: CGFloat = 330, right: CGFloat = 790
    let top: CGFloat = 770, bottom: CGFloat = 254, mid: CGFloat = 512
    let corner: CGFloat = 70
    let a = CGPoint(x: p(left), y: p(bottom))
    let b = CGPoint(x: p(left), y: p(top))
    let c = CGPoint(x: p(right), y: p(mid))
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: p(left), y: p(mid)))
    tri.addArc(tangent1End: b, tangent2End: c, radius: p(corner))
    tri.addArc(tangent1End: c, tangent2End: a, radius: p(corner))
    tri.addArc(tangent1End: a, tangent2End: b, radius: p(corner))
    tri.closeSubpath()

    // Shadow under the triangle.
    if size >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -p(12)), blur: p(28), color: color(0, 0, 0, 0.45))
        ctx.addPath(tri)
        ctx.setFillColor(color(0, 0, 0, 1))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(tri)
    ctx.clip()
    let count = size <= 32 ? 3 : 4
    let gap: CGFloat = 0
    let span = right - left
    let barW = (span - gap * CGFloat(count - 1)) / CGFloat(count)
    for index in 0..<count {
        let x = left + (barW + gap) * CGFloat(index)
        let tint = faderColors[size <= 32 ? index * 4 / 3 : index]
        let bar = CGRect(x: p(x), y: p(bottom - 10), width: p(barW), height: p(top - bottom + 20))
        ctx.saveGState()
        ctx.clip(to: bar)
        let shade = CGGradient(colorsSpace: srgb, colors: [
            tint,
            color(tint.components![0] * 0.78, tint.components![1] * 0.78, tint.components![2] * 0.78),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: p(top)),
                               end: CGPoint(x: 0, y: p(bottom)), options: [])
        ctx.restoreGState()
        // Thin dark seam between bars (not drawn at the smallest sizes).
        if index > 0 && size >= 64 {
            ctx.setFillColor(color(0.05, 0.07, 0.16, 0.55))
            ctx.fill(CGRect(x: p(x - 4), y: p(bottom - 10), width: p(8), height: p(top - bottom + 20)))
        }
    }
    ctx.restoreGState()

    return ctx.makeImage()
}

for size in sizes {
    guard let image = render(size: size) else {
        FileHandle.standardError.write("failed to render \(size)\n".data(using: .utf8)!)
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(size).png")
    try! data.write(to: url)
    print("wrote \(url.lastPathComponent)")
}
