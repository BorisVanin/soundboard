#!/usr/bin/env swift
//
// Generates the Soundboard app icon: a dark macOS squircle inspired by the
// Audio MIDI Setup icon — the six colored pads are kept but shifted UP, and a
// bank of mixer faders is the main feature (where the piano keyboard was).
//
// Usage:  swift tools/make_icon.swift <output-appiconset-dir>
//
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// Pad / fader palette (sampled from the Audio MIDI Setup pads).
let palette: [NSColor] = [
    NSColor(srgbRed: 0.36, green: 0.74, blue: 0.27, alpha: 1), // green
    NSColor(srgbRed: 0.93, green: 0.76, blue: 0.16, alpha: 1), // yellow
    NSColor(srgbRed: 0.92, green: 0.46, blue: 0.18, alpha: 1), // orange
    NSColor(srgbRed: 0.85, green: 0.23, blue: 0.30, alpha: 1), // red
    NSColor(srgbRed: 0.71, green: 0.27, blue: 0.71, alpha: 1), // magenta
    NSColor(srgbRed: 0.18, green: 0.66, blue: 0.87, alpha: 1), // cyan
]
// Faders: which palette color + value (0…1) for each.
let faders: [(color: Int, value: CGFloat)] = [
    (0, 0.58), (1, 0.36), (3, 0.80), (4, 0.50), (5, 0.70),
]

func rrect(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

func draw(size S: CGFloat, into ctx: CGContext) {
    let g = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g

    // Squircle frame (inset for the macOS margin + room for the shadow).
    let inset = S * 0.095
    let frame = NSRect(x: inset, y: inset * 1.15, width: S - inset * 2, height: S - inset * 2)
    let radius = frame.width * 0.2237

    // Drop shadow under the squircle.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -S * 0.012)
    shadow.shadowBlurRadius = S * 0.03
    shadow.set()

    // Body gradient (dark, top→bottom).
    let body = rrect(frame, radius)
    body.addClip()
    let bg = NSGradient(colors: [
        NSColor(srgbRed: 0.24, green: 0.24, blue: 0.25, alpha: 1),
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
    ])!
    bg.draw(in: frame, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Subtle top sheen.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    body.addClip()
    let sheen = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0.0),
    ])!
    sheen.draw(in: NSRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Content area inside the squircle.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    let pad = frame.width * 0.115
    let cx = frame.minX + pad
    let cw = frame.width - pad * 2
    let cTop = frame.maxY - pad
    let cBottom = frame.minY + pad

    // --- Colored pads, shifted UP (top of the content) ---
    let n = palette.count
    let padGapRatio: CGFloat = 0.45
    let padW = cw / (CGFloat(n) + CGFloat(n - 1) * padGapRatio)
    let padGap = padW * padGapRatio
    let padH = padW
    let padY = cTop - padH
    for i in 0..<n {
        let x = cx + CGFloat(i) * (padW + padGap)
        let r = NSRect(x: x, y: padY, width: padW, height: padH)
        let p = rrect(r, padW * 0.28)
        let c = palette[i]
        let grad = NSGradient(colors: [c.blended(withFraction: 0.18, of: .white)!, c])!
        grad.draw(in: r, angle: -90)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        p.lineWidth = max(S * 0.002, 0.5)
        p.stroke()
    }

    // --- Mixer faders, the main feature (fills the area below the pads) ---
    let faderTop = padY - frame.height * 0.045
    let faderBottom = cBottom
    let trackH = faderTop - faderBottom
    let m = faders.count
    let slot = cw / CGFloat(m)
    let trackW = max(slot * 0.10, S * 0.012)
    let capW = slot * 0.62
    let capH = max(trackH * 0.085, S * 0.03)

    for i in 0..<m {
        let center = cx + (CGFloat(i) + 0.5) * slot
        let color = palette[faders[i].color]
        let value = faders[i].value

        // Groove (recessed dark track with a light edge).
        let track = NSRect(x: center - trackW / 2, y: faderBottom, width: trackW, height: trackH)
        NSColor.white.withAlphaComponent(0.08).setFill()
        rrect(track.insetBy(dx: -S * 0.004, dy: -S * 0.004), trackW).fill()
        NSColor.black.withAlphaComponent(0.55).setFill()
        let groove = rrect(track, trackW / 2)
        groove.fill()

        // Filled (colored) portion from the bottom to the cap.
        let capCenterY = faderBottom + capH / 2 + (trackH - capH) * value
        let fillRect = NSRect(x: track.minX, y: track.minY, width: track.width, height: capCenterY - track.minY)
        let fillGrad = NSGradient(colors: [color, color.blended(withFraction: 0.25, of: .black)!])!
        NSGraphicsContext.saveGraphicsState()
        rrect(fillRect, trackW / 2).addClip()
        fillGrad.draw(in: fillRect, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        // Cap (metallic fader knob), clipped to its rounded shape, with shadow.
        let capRect = NSRect(x: center - capW / 2, y: capCenterY - capH / 2, width: capW, height: capH)
        let capGrad = NSGradient(colors: [
            NSColor(white: 0.95, alpha: 1), NSColor(white: 0.72, alpha: 1), NSColor(white: 0.86, alpha: 1),
        ])!
        NSGraphicsContext.saveGraphicsState()
        let capShadow = NSShadow()
        capShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        capShadow.shadowOffset = NSSize(width: 0, height: -S * 0.004)
        capShadow.shadowBlurRadius = S * 0.012
        capShadow.set()
        rrect(capRect, capH * 0.32).fill()              // opaque base so the shadow shows
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        rrect(capRect, capH * 0.32).addClip()
        capGrad.draw(in: capRect, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Centre indent line on the cap.
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: capRect.minX + capW * 0.16, y: capRect.midY))
        line.line(to: NSPoint(x: capRect.maxX - capW * 0.16, y: capRect.midY))
        line.lineWidth = max(S * 0.004, 1)
        line.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    draw(size: CGFloat(px), into: g.cgContext)
    g.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for s in sizes {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(s).png")
    try! render(s).write(to: url)
    print("wrote \(url.lastPathComponent)")
}
