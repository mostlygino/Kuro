// Draws the keep-awake badge as a capsule, the pill Amphetamine made the icon
// for keeping a Mac awake: an empty grey outline while the Mac sleeps as usual,
// half amber and half white with a gloss along it while it is kept awake.
//
//   capsulemark --state on|off --out /path.png
//   capsulemark --state on --from-state off --transition /path/dir
//
// It was a coffee cup until 2026-09-29. The capsule does what a capsule does:
// switched on, its two halves part a fraction and snap back together on a
// spring, the colour fills in from the seam outwards, and a glint of light runs
// once along it; switched off, the colour drains out as the halves come apart
// and close again, empty. The outline never moves, so it is always the same
// badge.
//
// Usage: swiftc -O capsulemark.swift -o capsulemark

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Two pixels per displayed point, shown at `background.image.scale=0.5`, on the
// 16pt design grid drawn 12.5% up to 18pt like the other badges. Tilted, the
// capsule's ink runs about 1.8 to 14.2, where the cup's did, so the pill's
// spacing in the rc holds.
let pixelScale: CGFloat = 2.25
let side: CGFloat = 16
let transitionFrames = 36  // 0.6 s at motionwatch's 60 fps

let length: CGFloat = 15.2
let thickness: CGFloat = 6.2
let tilt: CGFloat = .pi / 4          // rising to the right
let outlineWidth: CGFloat = 1.15
let maxParting: CGFloat = 1.7        // how far the halves come apart mid-snap

struct RGBA { var r, g, b, a: CGFloat }

let amber = RGBA(r: 1, g: 0x9f / 255, b: 0x0a / 255, a: 1)
let cream = RGBA(r: 0.97, g: 0.96, b: 0.94, a: 1)
let grey = RGBA(r: 0x8e / 255, g: 0x8e / 255, b: 0x93 / 255, a: 1)

func mix(_ a: RGBA, _ b: RGBA, _ t: CGFloat) -> RGBA {
    RGBA(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t, a: a.a + (b.a - a.a) * t)
}
func smooth(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t)); return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
}
func spring(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t)); return c >= 1 ? 1 : 1 - exp(-6.5 * c) * cos(2.4 * .pi * c)
}
func span(_ t: CGFloat, _ start: CGFloat, _ length: CGFloat) -> CGFloat {
    min(1, max(0, (t - start) / length))
}
func cg(_ c: RGBA, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: c.r, green: c.g, blue: c.b, alpha: c.a * alpha)
}
func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data(("capsulemark: " + m + "\n").utf8)); exit(1)
}
func argument(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--" + name), i + 1 < a.count else { return nil }
    return a[i + 1]
}
func state(_ name: String) -> Bool {
    switch argument(name) {
    case "on": return true
    case "off", nil: return false
    default: fail("--\(name) is on or off")
    }
}

/// One frame: the outline's colour, how far the halves stand apart, how much
/// each half is filled (from the seam out), where the glint is along the
/// capsule (-1 to 1, nil for none), and the gloss.
struct Frame {
    var outline: RGBA
    var parting: CGFloat
    var fill: CGFloat
    var glint: CGFloat?
    var gloss: CGFloat
}

func frame(on: Bool) -> Frame {
    on ? Frame(outline: mix(amber, RGBA(r: 0, g: 0, b: 0, a: 1), 0.25), parting: 0, fill: 1, glint: nil, gloss: 1)
       : Frame(outline: grey, parting: 0, fill: 0, glint: nil, gloss: 0)
}

/// Half a capsule in its own coordinates, the seam at x = 0: the left half
/// runs to its rounded end at -length/2, the right half to +length/2.
func halfPath(left: Bool) -> CGPath {
    let r = thickness / 2
    let end = length / 2 - r
    let p = CGMutablePath()
    if left {
        p.move(to: CGPoint(x: 0, y: r))
        p.addLine(to: CGPoint(x: -end, y: r))
        p.addArc(center: CGPoint(x: -end, y: 0), radius: r, startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: 0, y: -r))
    } else {
        p.move(to: CGPoint(x: 0, y: -r))
        p.addLine(to: CGPoint(x: end, y: -r))
        p.addArc(center: CGPoint(x: end, y: 0), radius: r, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: 0, y: r))
    }
    p.closeSubpath()
    return p
}

func draw(_ f: Frame) -> CGImage {
    let px = Int(side * pixelScale)
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("could not create a bitmap context") }
    ctx.scaleBy(x: pixelScale, y: pixelScale)
    ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.translateBy(x: side / 2, y: side / 2)
    ctx.rotate(by: tilt)
    ctx.setLineJoin(.round)

    for left in [true, false] {
        let path = halfPath(left: left)
        ctx.saveGState()
        ctx.translateBy(x: (left ? -1 : 1) * f.parting / 2, y: 0)

        // The fill, growing from the seam towards the rounded end, with a
        // light top edge so it reads as a solid capsule rather than a flat one.
        if f.fill > 0.005 {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let reach = (length / 2 + 0.5) * smooth(f.fill)
            let colour = left ? amber : cream
            let lit = mix(colour, RGBA(r: 1, g: 1, b: 1, a: 1), 0.35)
            let shade = mix(colour, RGBA(r: 0, g: 0, b: 0, a: 1), 0.12)
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: [cg(lit), cg(colour), cg(shade)] as CFArray,
                                         locations: [0, 0.45, 1]) {
                let band = CGRect(x: left ? -reach : 0, y: -thickness, width: reach, height: 2 * thickness)
                ctx.clip(to: band)
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: thickness / 2),
                                       end: CGPoint(x: 0, y: -thickness / 2), options: [])
            }
            ctx.restoreGState()
        }

        ctx.setStrokeColor(cg(f.outline))
        ctx.setLineWidth(outlineWidth)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Gloss: a thin highlight along the upper edge, both halves, which is the
    // detail that makes it a capsule and not a lozenge.
    if f.gloss > 0.01 {
        ctx.setLineCap(.round)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55 * f.gloss))
        ctx.setLineWidth(0.8)
        let y = thickness * 0.2
        let reach = length / 2 - thickness * 0.55
        ctx.move(to: CGPoint(x: -reach, y: y))
        ctx.addLine(to: CGPoint(x: reach, y: y))
        ctx.strokePath()
    }

    // The glint: a bright soft spot running once along the capsule.
    if let g = f.glint {
        ctx.saveGState()
        ctx.addPath(halfPath(left: true))
        ctx.addPath(halfPath(left: false))
        ctx.clip()
        let centre = CGPoint(x: g * length / 2, y: thickness * 0.1)
        if let spot = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.85),
                                          CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                                 locations: [0, 1]) {
            ctx.drawRadialGradient(spot, startCenter: centre, startRadius: 0,
                                   endCenter: centre, endRadius: thickness * 0.9, options: [])
        }
        ctx.restoreGState()
    }

    guard let image = ctx.makeImage() else { fail("could not render") }
    return image
}

func write(_ image: CGImage, to url: URL) {
    let temp = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
    guard let d = CGImageDestinationCreateWithURL(temp as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("could not open \(temp.path)") }
    CGImageDestinationAddImage(d, image, nil)
    guard CGImageDestinationFinalize(d) else { fail("could not write \(temp.path)") }
    do { _ = try FileManager.default.replaceItemAt(url, withItemAt: temp) } catch {
        try? FileManager.default.removeItem(at: temp); fail("could not move the render into place")
    }
}

func writeSequence(_ images: [CGImage], to path: String) {
    let fm = FileManager.default
    let final = URL(fileURLWithPath: path)
    let temp = final.deletingLastPathComponent()
        .appendingPathComponent(".\(final.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
    try? fm.removeItem(at: temp)
    do { try fm.createDirectory(at: temp, withIntermediateDirectories: true) } catch { fail("mkdir failed") }
    for (i, im) in images.enumerated() {
        write(im, to: temp.appendingPathComponent(String(format: "frame-%02d.png", i)))
    }
    // Same key, same frames: a run that finished first may already be playing

    // its copy, and deleting it under the player is a dropped image.

    if fm.fileExists(atPath: final.path) { try? fm.removeItem(at: temp); return }
    do { try fm.moveItem(at: temp, to: final) } catch {
        try? fm.removeItem(at: temp)
        // Lost the race to an identical render: its copy is the result.
        if fm.fileExists(atPath: final.path) { return }; fail("could not move \(final.path) into place")
    }
}

let on = state("state")
guard argument("out") != nil || argument("transition") != nil else { fail("--out or --transition") }
if let out = argument("out") { write(draw(frame(on: on)), to: URL(fileURLWithPath: out)) }

if let dir = argument("transition") {
    let wasOn = state("from-state")
    let rest = frame(on: on)
    let frames = (1...transitionFrames).map { step -> CGImage in
        let t = CGFloat(step) / CGFloat(transitionFrames + 1)
        if on == wasOn { return draw(rest) }
        let lit = frame(on: true), dark = frame(on: false)
        if on {
            // Part, then snap back on a spring; fill from the seam out; the
            // glint runs once along it as the colour settles.
            let part = t < 0.22 ? smooth(t / 0.22) : 1 - spring((t - 0.22) / 0.78)
            return draw(Frame(
                outline: mix(dark.outline, lit.outline, smooth(span(t, 0.1, 0.4))),
                parting: maxParting * part,
                fill: smooth(span(t, 0.18, 0.45)),
                glint: t > 0.5 ? -1.1 + 2.2 * smooth(span(t, 0.5, 0.45)) : nil,
                gloss: smooth(span(t, 0.45, 0.4))))
        }
        // Off: the gloss and the colour drain while the halves open a little
        // and close again, empty.
        return draw(Frame(
            outline: mix(lit.outline, dark.outline, smooth(span(t, 0.2, 0.6))),
            parting: maxParting * 0.7 * sin(.pi * span(t, 0.05, 0.8)),
            fill: 1 - smooth(span(t, 0, 0.6)),
            glint: nil,
            gloss: 1 - smooth(span(t, 0, 0.3))))
    }
    writeSequence(frames, to: dir)
}
