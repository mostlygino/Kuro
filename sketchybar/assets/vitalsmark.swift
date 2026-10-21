// Draws the vitals badge: a pixel ghost after NeoHtop's, always solid, its colour
// a heat score of how hard the Mac is working (plugins/vitals.sh: the worse of
// processor and memory), cool teal through green, yellow and orange to red when
// it is maxed out.
//
//   vitalsmark --heat 0..100 --tone calm|busy|critical --out /path.png
//   vitalsmark --heat 60 --tone calm --from-heat 10 --from-tone calm --transition /dir
//
// The processor is averaged (plugins/vitals.sh) and the colour runs continuously
// between the heat stops rather than jumping between five bands, so a build
// warming up is visible as it happens. Memory pressure can only warm it: elevated
// pressure is at least orange, critical is red whatever the processor is doing.
//
// Until 2026-10-06 the ghost was CPU only, five bands with a dead band, and
// memory counted only at elevated pressure, which macOS almost never reports: on
// a 24 GB machine at 80% used it never moved. Memory was then a tank the body
// filled up with, for an afternoon; it read as a broken, half-drawn ghost, and
// the colour already says it.
//
// Pixel art kept pixel-sharp: one design pixel per point, on a 15 by 16 grid, so
// a pixel is two screen pixels on a Retina panel and one on a 1x screen, never a
// blur between two. The eyes are holes, the pill showing through them, and the
// hem is NeoHtop's dithered fringe, its last two rows at part strength.
//
// Still at rest. On a change the colour eases round the colour wheel. It hops only when it comes back to life:
// a reading changes every few polls now, and a hop each time was a twitch.
//
// Dead, grey with crosses for eyes, while the Vitals app is not running
// (`--tone dead`): it shivers and drains as it dies, and hops back to life in
// its colour when Vitals starts again.
//
// It was a heartbeat, then a tile with Vitals' pulse, until 2026-10-06.
//
// Usage: swiftc -O vitalsmark.swift -o vitalsmark

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Two pixels a point in an 18pt box, shown at `background.image.scale=0.5`, the
// footprint of the shield and the battery ring beside it.
let pixelScale: CGFloat = 2
let side: CGFloat = 18
let transitionFrames = 36  // 0.6 s at motionwatch's 60 fps

// The ghost, top row first: # full, + the hem's first dither, . the faintest.
let ghost = [
    "     #####     ",
    "   #########   ",
    "  ###########  ",
    " ############# ",
    " ############# ",
    "###  #####  ###",
    "###  #####  ###",
    "###  #####  ###",
    "###############",
    "###############",
    "###############",
    "###############",
    "###############",
    "### ### ### ###",
    "+ + +   + + +  ",
    ".     .     .  ",
]
// Dead, while the Vitals app is not running: the same ghost with crosses for eyes.
let deadGhost = [
    "     #####     ",
    "   #########   ",
    "  ###########  ",
    " ############# ",
    " ############# ",
    "## # ##### # ##",
    "### ####### ###",
    "## # ##### # ##",
    "###############",
    "###############",
    "###############",
    "###############",
    "###############",
    "### ### ### ###",
    "+ + +   + + +  ",
    ".     .     .  ",
]
let ditherAlpha: [Character: CGFloat] = ["#": 1, "+": 0.55, ".": 0.28]
let deadGrey = RGBA(r: 0x8e / 255, g: 0x8e / 255, b: 0x93 / 255, a: 0.85)

struct RGBA { var r, g, b, a: CGFloat }
func hex(_ v: UInt32) -> RGBA {
    RGBA(r: CGFloat((v >> 16) & 0xff) / 255, g: CGFloat((v >> 8) & 0xff) / 255, b: CGFloat(v & 0xff) / 255, a: 1)
}
// Idle, light, working, heavy, maxed out, at these processor percentages.
// Teal is held flat to 15: a Mac is never at 0%, so a blend from 0 meant the
// idle ghost was never actually teal.
let heat: [RGBA] = [hex(0x66d4cf), hex(0x66d4cf), hex(0x32d74b), hex(0xffd60a), hex(0xff9f0a), hex(0xff453a)]
let heatAt: [CGFloat] = [0, 15, 25, 40, 70, 85]

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data(("vitalsmark: " + m + "\n").utf8)); exit(1)
}
func argument(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--" + name), i + 1 < a.count else { return nil }
    return a[i + 1]
}
func percent(_ name: String) -> CGFloat {
    guard let text = argument(name) else { return 0 }
    guard let n = Double(text) else { fail("--\(name) is 0 to 100") }
    return CGFloat(min(100, max(0, n)))
}
func tone(_ name: String) -> String {
    let t = argument(name) ?? "calm"
    guard ["calm", "busy", "critical", "dead"].contains(t) else { fail("--\(name) is calm, busy, critical or dead") }
    return t
}
/// The colour for a reading: the heat score, warmed by memory pressure.
func colour(heat score: CGFloat, tone: String) -> RGBA {
    switch tone {
    case "dead": return deadGrey
    case "critical": return heat[heat.count - 1]
    case "busy": return heatColour(max(score, heatAt[heatAt.count - 2]))
    default: return heatColour(score)
    }
}
func cg(_ c: RGBA, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: c.r, green: c.g, blue: c.b, alpha: c.a * alpha)
}
func smooth(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t)); return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
}
func spring(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t)); return c >= 1 ? 1 : 1 - exp(-6.5 * c) * cos(2.4 * .pi * c)
}
func span(_ t: CGFloat, _ start: CGFloat, _ length: CGFloat) -> CGFloat { min(1, max(0, (t - start) / length)) }

/// Round the colour wheel, so one heat becomes the next through colours, never
/// through the grey a straight blend of two of them passes.
func hsb(_ c: RGBA) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
    let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
    var h: CGFloat = 0
    if d > 0 {
        if mx == c.r { h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == c.g { h = (c.b - c.r) / d + 2 }
        else { h = (c.r - c.g) / d + 4 }
        h /= 6
        if h < 0 { h += 1 }
    }
    return (h, mx == 0 ? 0 : d / mx, mx)
}
func rgb(h: CGFloat, s: CGFloat, v: CGFloat) -> RGBA {
    let i = floor(h * 6), f = h * 6 - i
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    switch Int(i) % 6 {
    case 0: return RGBA(r: v, g: t, b: p, a: 1)
    case 1: return RGBA(r: q, g: v, b: p, a: 1)
    case 2: return RGBA(r: p, g: v, b: t, a: 1)
    case 3: return RGBA(r: p, g: q, b: v, a: 1)
    case 4: return RGBA(r: t, g: p, b: v, a: 1)
    default: return RGBA(r: v, g: p, b: q, a: 1)
    }
}
func blend(_ a: RGBA, _ b: RGBA, _ t: CGFloat) -> RGBA {
    let x = hsb(a), y = hsb(b)
    var dh = y.h - x.h
    if dh > 0.5 { dh -= 1 } else if dh < -0.5 { dh += 1 }
    var h = x.h + dh * t
    h -= floor(h)
    return rgb(h: h, s: x.s + (y.s - x.s) * t, v: x.v + (y.v - x.v) * t)
}

/// Between the two heat stops either side of `score`, round the wheel.
func heatColour(_ score: CGFloat) -> RGBA {
    guard let next = heatAt.firstIndex(where: { $0 > score }) else { return heat[heat.count - 1] }
    let a = heatAt[next - 1], b = heatAt[next]
    return blend(heat[next - 1], heat[next], (score - a) / (b - a))
}

/// The ghost in `colour`, lifted by `rise` points. Each pixel is a whole point
/// on a whole-point grid; the rise is rounded to the pixel grid of the canvas
/// so a hop frame never smears the pixels across two rows.
func draw(_ colour: RGBA, rise: CGFloat, dead: Bool = false, shift: CGFloat = 0) -> CGImage {
    guard let ctx = CGContext(data: nil, width: Int(side * pixelScale), height: Int(side * pixelScale),
                              bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("could not create a bitmap context") }
    ctx.setShouldAntialias(false)
    ctx.scaleBy(x: pixelScale, y: pixelScale)
    ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
    let cols = CGFloat(ghost[0].count), rows = CGFloat(ghost.count)
    let left = floor((side - cols) / 2) + shift
    let lift = (rise * pixelScale).rounded() / pixelScale
    let top = side - floor((side - rows) / 2) + lift
    for (r, line) in (dead ? deadGhost : ghost).enumerated() {
        for (c, ch) in line.enumerated() {
            guard let alpha = ditherAlpha[ch] else { continue }
            ctx.setFillColor(cg(colour, alpha))
            ctx.fill(CGRect(x: left + CGFloat(c), y: top - CGFloat(r + 1), width: 1, height: 1))
        }
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

let target = colour(heat: percent("heat"), tone: tone("tone"))
let dies = tone("tone") == "dead"
guard argument("out") != nil || argument("transition") != nil else { fail("--out or --transition") }
if let out = argument("out") {
    write(draw(target, rise: 0, dead: dies), to: URL(fileURLWithPath: out))
}
if let dir = argument("transition") {
    let start = colour(heat: percent("from-heat"), tone: tone("from-tone"))
    let wasDead = tone("from-tone") == "dead"
    let frames = (1...transitionFrames).map { step -> CGImage in
        let t = CGFloat(step) / CGFloat(transitionFrames + 1)
        if dies && !wasDead {
            // Dying: three quick shivers a whole point either way, the colour
            // draining to grey, and the eyes crossed out halfway through.
            let shiver: CGFloat = t < 0.42 ? (Int(t * 14) % 2 == 0 ? 1 : -1) : 0
            return draw(blend(start, target, smooth(span(t, 0.1, 0.7))), rise: 0,
                        dead: t >= 0.42, shift: shiver)
        }
        let tint = blend(start, target, smooth(span(t, 0, 0.7)))
        if wasDead {
            // Back to life: up 1.5pt in the first fifth, then down onto a spring
            // that lands it, the eyes opening as it leaves the ground.
            let rise = t < 0.2 ? 1.5 * smooth(t / 0.2) : 1.5 * (1 - spring((t - 0.2) / 0.8))
            return draw(tint, rise: rise, dead: t < 0.12)
        }
        // Alive to alive: the colour eases round to the new one.
        return draw(tint, rise: 0, dead: dies)
    }
    writeSequence(frames, to: dir)
}
