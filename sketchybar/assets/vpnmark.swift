// Draws the Tailscale shield in its four states.
//
//   vpnmark --state up|down|pending|attention --out /path.png
//   vpnmark --state up --from-state pending --transition /path/dir
//
//   up         a solid green shield with the check cut out of it
//   down       a grey outline with a slash through it
//   pending    an amber outline with three dots, while `tailscale up` or `down`
//              runs, so the badge says something is happening
//   attention  an amber outline with an exclamation mark: the tailnet needs a
//              login or an approval, which only the app can give
//
// It was SF Symbols through shieldmark, swapped with a spring. A swap can only
// say "this became that"; drawn, each part can do its own thing. Connecting,
// the shield fills and pops and then the check draws itself in, stroke by
// stroke, the way a tick is written. Disconnecting, the check is taken back,
// the fill drains to an outline and the slash is struck through. The dots come
// up one after another, the exclamation mark drops in on a spring.
//
// Usage: swiftc -O vpnmark.swift -o vpnmark

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Two pixels per displayed point, shown at `background.image.scale=0.5`, on the
// 16pt design grid drawn 12.5% up to 18pt. The shield's ink runs 2.6 to 13.4
// across, near enough to the symbol it replaces for the rc's spacing to hold.
let pixelScale: CGFloat = 2.25
let side: CGFloat = 16
let transitionFrames = 36  // 0.6 s at motionwatch's 60 fps

struct RGBA { var r, g, b, a: CGFloat }

let green = RGBA(r: 0x32 / 255, g: 0xd7 / 255, b: 0x4b / 255, a: 1)
let grey = RGBA(r: 0x8e / 255, g: 0x8e / 255, b: 0x93 / 255, a: 1)
let amber = RGBA(r: 1, g: 0x9f / 255, b: 0x0a / 255, a: 1)

let outlineWidth: CGFloat = 1.3

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
func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data(("vpnmark: " + m + "\n").utf8)); exit(1)
}
func argument(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--" + name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

enum State: String { case up, down, pending, attention }

func state(_ name: String) -> State {
    guard let text = argument(name) else { return .down }
    guard let s = State(rawValue: text) else { fail("--\(name) is up, down, pending or attention") }
    return s
}

/// One frame. Every part is a number from 0 (absent) to 1 (there), so any
/// state can blend into any other.
struct Frame {
    var color: RGBA
    var fill: CGFloat       // outline only at 0, solid at 1
    var check: CGFloat      // how much of the tick is drawn
    var slash: CGFloat      // how much of the slash is struck
    var dots: CGFloat       // the three dots of "pending"
    var bang: CGFloat       // the exclamation mark of "attention"
    var scale: CGFloat = 1
}

func frame(_ s: State) -> Frame {
    switch s {
    case .up:        return Frame(color: green, fill: 1, check: 1, slash: 0, dots: 0, bang: 0)
    case .down:      return Frame(color: grey, fill: 0, check: 0, slash: 1, dots: 0, bang: 0)
    case .pending:   return Frame(color: amber, fill: 0, check: 0, slash: 0, dots: 1, bang: 0)
    case .attention: return Frame(color: amber, fill: 0, check: 0, slash: 0, dots: 0, bang: 1)
    }
}

func shieldPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 8, y: 15.0))
    p.addCurve(to: CGPoint(x: 2.7, y: 13.3), control1: CGPoint(x: 5.9, y: 15.0), control2: CGPoint(x: 4.1, y: 14.1))
    p.addLine(to: CGPoint(x: 2.7, y: 8.6))
    p.addCurve(to: CGPoint(x: 8, y: 1.1), control1: CGPoint(x: 2.7, y: 4.9), control2: CGPoint(x: 5.2, y: 2.4))
    p.addCurve(to: CGPoint(x: 13.3, y: 8.6), control1: CGPoint(x: 10.8, y: 2.4), control2: CGPoint(x: 13.3, y: 4.9))
    p.addLine(to: CGPoint(x: 13.3, y: 13.3))
    p.addCurve(to: CGPoint(x: 8, y: 15.0), control1: CGPoint(x: 11.9, y: 14.1), control2: CGPoint(x: 10.1, y: 15.0))
    p.closeSubpath()
    return p
}

/// The first `amount` of a polyline, by length, so a stroke can draw itself.
func partial(_ points: [CGPoint], _ amount: CGFloat) -> CGPath? {
    guard amount > 0.01 else { return nil }
    var lengths: [CGFloat] = []
    for i in 1..<points.count { lengths.append(hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)) }
    var remaining = lengths.reduce(0, +) * min(1, amount)
    let p = CGMutablePath()
    p.move(to: points[0])
    for i in 1..<points.count {
        let l = lengths[i - 1]
        if remaining >= l {
            p.addLine(to: points[i])
            remaining -= l
        } else {
            let k = remaining / l
            p.addLine(to: CGPoint(x: points[i - 1].x + (points[i].x - points[i - 1].x) * k,
                                  y: points[i - 1].y + (points[i].y - points[i - 1].y) * k))
            break
        }
    }
    return p
}

let tick = [CGPoint(x: 5.3, y: 8.3), CGPoint(x: 7.2, y: 6.3), CGPoint(x: 10.9, y: 10.3)]
let strike = [CGPoint(x: 3.4, y: 14.4), CGPoint(x: 12.9, y: 1.9)]

func cg(_ c: RGBA, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: c.r, green: c.g, blue: c.b, alpha: c.a * alpha)
}

func draw(_ f: Frame) -> CGImage {
    let px = Int(side * pixelScale)
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("could not create a bitmap context") }
    ctx.scaleBy(x: pixelScale, y: pixelScale)
    ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Scale about the shield's middle, for the pop on connecting.
    ctx.translateBy(x: 8, y: 8)
    ctx.scaleBy(x: f.scale, y: f.scale)
    ctx.translateBy(x: -8, y: -8)

    let shield = shieldPath()

    // The fill, lighter at the top like the rest of the bar's solid marks.
    if f.fill > 0.01 {
        ctx.saveGState()
        ctx.addPath(shield)
        ctx.clip()
        let top = mix(f.color, RGBA(r: 1, g: 1, b: 1, a: 1), 0.22)
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [cg(top, f.fill), cg(f.color, f.fill)] as CFArray,
                                     locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 8, y: 15), end: CGPoint(x: 8, y: 1), options: [])
        }
        ctx.restoreGState()
    }

    ctx.setStrokeColor(cg(f.color))
    ctx.setLineWidth(outlineWidth)
    ctx.addPath(shield)
    ctx.strokePath()

    // The tick is cut out of the fill rather than drawn on it, so it is the
    // pill showing through: it reads on any background and never clashes.
    if let tickPath = partial(tick, f.check) {
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(1.75)
        ctx.addPath(tickPath)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // The slash, with a clear halo either side so it reads as struck through
    // the outline rather than lying on it.
    if let strikePath = partial(strike, f.slash) {
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(3.4)
        ctx.addPath(strikePath)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setStrokeColor(cg(f.color))
        ctx.setLineWidth(outlineWidth)
        ctx.addPath(strikePath)
        ctx.strokePath()
    }

    // Three dots, each fading and rising into place a beat after the last.
    for i in 0..<3 {
        let a = smooth(span(f.dots, CGFloat(i) * 0.2, 0.6))
        guard a > 0.01 else { continue }
        let r: CGFloat = 0.8
        let c = CGPoint(x: 5.6 + CGFloat(i) * 2.4, y: 8.2 - (1 - a) * 1.2)
        ctx.setFillColor(cg(f.color, a))
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    // The exclamation mark, dropped in from above on a spring.
    if f.bang > 0.01 {
        let drop = (1 - f.bang) * 2.5
        ctx.setStrokeColor(cg(f.color, min(1, f.bang * 1.5)))
        ctx.setLineWidth(1.55)
        ctx.move(to: CGPoint(x: 8, y: 11.4 + drop))
        ctx.addLine(to: CGPoint(x: 8, y: 7.4 + drop))
        ctx.strokePath()
        ctx.setFillColor(cg(f.color, min(1, f.bang * 1.5)))
        ctx.fillEllipse(in: CGRect(x: 8 - 0.85, y: 4.4 + drop, width: 1.7, height: 1.7))
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

/// A part going away leaves early, a part arriving comes late, so nothing is
/// ever drawn on top of what it replaces: the slash is gone before the check
/// starts, the check is gone before the slash is struck.
func blend(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat {
    let k = to > from ? smooth(span(t, 0.38, 0.52)) : smooth(span(t, 0, 0.36))
    return from + (to - from) * k
}

let target = state("state")
let to = frame(target)
guard argument("out") != nil || argument("transition") != nil else { fail("--out or --transition") }
if let out = argument("out") { write(draw(to), to: URL(fileURLWithPath: out)) }

if let dir = argument("transition") {
    let from = frame(state("from-state"))
    let frames = (1...transitionFrames).map { step -> CGImage in
        let t = CGFloat(step) / CGFloat(transitionFrames + 1)
        let early = smooth(span(t, 0, 0.5))
        var f = Frame(color: mix(from.color, to.color, early),
                      fill: from.fill + (to.fill - from.fill) * early,
                      check: blend(from.check, to.check, t),
                      slash: blend(from.slash, to.slash, t),
                      dots: blend(from.dots, to.dots, t),
                      bang: from.bang + (to.bang - from.bang) * (to.bang > from.bang
                            ? spring(span(t, 0.3, 0.7)) : smooth(span(t, 0, 0.36))))
        // Connecting pops the shield; anything else only breathes in and out.
        f.scale = target == .up ? 0.84 + 0.16 * spring(t) : 1 - 0.06 * sin(.pi * t)
        return draw(f)
    }
    writeSequence(frames, to: dir)
}
