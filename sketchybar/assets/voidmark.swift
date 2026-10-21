// Draws the void: the mark an empty display shows where an app's icon would be.
//
//   voidmark --out /path.png                   the still
//   voidmark --transition /path/dir            the event horizon opening
//
// Kuro is black, and an empty display is the one place the desktop is nothing
// but that, so the mark is a small black hole: a disc of pure black edged by a
// thin bright photon ring, an accretion ring tilted across it that passes
// behind the disc at the top and in front of it at the bottom, brighter on the
// side coming towards you, and a faint halo. What makes it a black hole and not
// a ringed planet is the far side of the ring bent up over the top of the disc
// by its gravity, and faintly under it: two thin arcs hugging the horizon. Monochrome with a breath of
// violet, so it sits with the bar rather than on it.
//
// The transition is the horizon opening: the ring draws out of a point as it
// widens, the disc swells to size behind it, the photon ring lights, and the
// halo blooms last. front_app.sh plays it in the app icon's own slot, a frame
// every 16 ms, when a display empties.
//
// The same size as a macOS app icon at the bar's scale: 16pt, drawn at 2x.
//
// Usage: swiftc -O voidmark.swift -o voidmark

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let pixelScale: CGFloat = 2
let side: CGFloat = 16
let centre = CGPoint(x: side / 2, y: side / 2)
let transitionFrames = 36

let horizon: CGFloat = 3.5          // the black disc
let ringRadiusX: CGFloat = 7.2      // the accretion ring, seen at a tilt
let ringRadiusY: CGFloat = 1.55
let ringTilt: CGFloat = -0.2        // radians, rising to the right

struct RGBA { var r, g, b, a: CGFloat }
let white = RGBA(r: 1, g: 1, b: 1, a: 1)
let lilac = RGBA(r: 0.83, g: 0.72, b: 1, a: 1)

func smooth(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t)); return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
}
func spring(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t)); return c >= 1 ? 1 : 1 - exp(-6.5 * c) * cos(2.4 * .pi * c)
}
func span(_ t: CGFloat, _ start: CGFloat, _ length: CGFloat) -> CGFloat {
    min(1, max(0, (t - start) / length))
}
func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data(("voidmark: " + m + "\n").utf8)); exit(1)
}
func argument(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--" + name), i + 1 < a.count else { return nil }
    return a[i + 1]
}
func cg(_ c: RGBA, _ alpha: CGFloat) -> CGColor { CGColor(red: c.r, green: c.g, blue: c.b, alpha: alpha) }

/// One frame: how open the horizon is (the disc's size), how much of the ring
/// is drawn and how wide, how lit the photon ring is, and the halo.
struct Frame {
    var disc: CGFloat = 1
    var ring: CGFloat = 1       // 0 to 1 of its sweep
    var ringScale: CGFloat = 1
    var photon: CGFloat = 1
    var halo: CGFloat = 1
}

/// A point on the tilted ring at angle `a`, and whether it is on the near side.
func ringPoint(_ a: CGFloat, scale: CGFloat) -> (CGPoint, near: Bool) {
    let x = cos(a) * ringRadiusX * scale, y = sin(a) * ringRadiusY * scale
    let p = CGPoint(x: centre.x + x * cos(ringTilt) - y * sin(ringTilt),
                    y: centre.y + x * sin(ringTilt) + y * cos(ringTilt))
    return (p, sin(a) < 0)
}

/// The ring as short segments, far side or near side, each with its brightness:
/// the side turning towards the viewer (the left here) is the brighter one.
func drawRing(_ ctx: CGContext, _ f: Frame, near: Bool) {
    let steps = 96
    let shown = Int(CGFloat(steps) * f.ring)
    guard shown > 0 else { return }
    ctx.setLineCap(.round)
    for i in 0..<shown {
        // Drawn outward from the front-left, so it grows around both ways.
        let a0 = .pi * 1.25 + 2 * .pi * CGFloat(i) / CGFloat(steps)
        let a1 = .pi * 1.25 + 2 * .pi * CGFloat(i + 1) / CGFloat(steps)
        let (p0, isNear) = ringPoint(a0, scale: f.ringScale)
        let (p1, _) = ringPoint(a1, scale: f.ringScale)
        guard isNear == near else { continue }
        let beaming = 0.55 + 0.45 * (-cos(a0 + 0.3))
        let tint = RGBA(r: lilac.r + (white.r - lilac.r) * beaming, g: lilac.g + (white.g - lilac.g) * beaming,
                        b: lilac.b + (white.b - lilac.b) * beaming, a: 1)
        ctx.setStrokeColor(cg(tint, (near ? 0.95 : 0.55) * beaming))
        ctx.setLineWidth(near ? 1.05 : 0.8)
        ctx.move(to: p0)
        ctx.addLine(to: p1)
        ctx.strokePath()
    }
}

func lensedArc(_ ctx: CGContext, radius: CGFloat, from: CGFloat, to: CGFloat, alpha: CGFloat, width: CGFloat) {
    let steps = 40
    ctx.setLineCap(.round)
    ctx.setLineWidth(width)
    for i in 0..<steps {
        let u0 = CGFloat(i) / CGFloat(steps), u1 = CGFloat(i + 1) / CGFloat(steps)
        let fade = sin(.pi * (u0 + u1) / 2)
        let tint = RGBA(r: lilac.r + (white.r - lilac.r) * fade, g: lilac.g + (white.g - lilac.g) * fade,
                        b: lilac.b + (white.b - lilac.b) * fade, a: 1)
        ctx.setStrokeColor(cg(tint, alpha * fade))
        ctx.addArc(center: centre, radius: radius, startAngle: from + (to - from) * u0,
                   endAngle: from + (to - from) * u1, clockwise: false)
        ctx.strokePath()
    }
}

func draw(_ f: Frame) -> CGImage {
    let px = Int(side * pixelScale)
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("could not create a bitmap context") }
    ctx.scaleBy(x: pixelScale, y: pixelScale)
    ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))

    // Halo: a soft violet glow around the horizon.
    if f.halo > 0.01, let halo = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [cg(lilac, 0.30 * f.halo), cg(lilac, 0.10 * f.halo), cg(lilac, 0)] as CFArray,
        locations: [0, 0.55, 1]) {
        ctx.drawRadialGradient(halo, startCenter: centre, startRadius: horizon * 0.9,
                               endCenter: centre, endRadius: 7.6, options: [])
    }

    // The far half of the ring, behind the disc.
    drawRing(ctx, f, near: false)

    // The horizon: pure black, so it reads as a hole in the pill rather than a
    // grey dot on it, edged by the photon ring.
    let r = horizon * f.disc
    if r > 0.05 {
        let disc = CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fillEllipse(in: disc)
        if f.photon > 0.01 {
            ctx.setStrokeColor(cg(white, 0.85 * f.photon))
            ctx.setLineWidth(0.55)
            ctx.strokeEllipse(in: disc.insetBy(dx: 0.25, dy: 0.25))
            // The lensed far side of the ring: bright over the top, fading
            // towards its ends, and a fainter echo underneath.
            lensedArc(ctx, radius: r + 0.95, from: 0.08 * .pi, to: 0.92 * .pi, alpha: 0.9 * f.photon, width: 0.95)
            lensedArc(ctx, radius: r + 0.6, from: 1.15 * .pi, to: 1.85 * .pi, alpha: 0.35 * f.photon, width: 0.6)
        }
    }

    // The near half, across the front of the disc.
    drawRing(ctx, f, near: true)

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

guard argument("out") != nil || argument("transition") != nil else { fail("--out or --transition") }
if let out = argument("out") { write(draw(Frame()), to: URL(fileURLWithPath: out)) }

if let dir = argument("transition") {
    let frames = (1...transitionFrames).map { step -> CGImage in
        let t = CGFloat(step) / CGFloat(transitionFrames + 1)
        return draw(Frame(
            disc: spring(span(t, 0.08, 0.6)),
            ring: smooth(span(t, 0, 0.62)),
            ringScale: 0.35 + 0.65 * spring(span(t, 0, 0.7)),
            photon: smooth(span(t, 0.35, 0.4)),
            halo: smooth(span(t, 0.5, 0.5))))
    }
    writeSequence(frames, to: dir)
}
