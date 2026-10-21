// Draws Wi-Fi as four dots, lit left to right as the signal climbs, the way an
// iPhone draws signal strength.
//
//   wifimark --dots 3 --color 0xff64d2ff [--off] --out /path.png
//   wifimark ... --from-dots 1 --from-color 0xffff9f0a [--from-off] --transition /path/dir
//
// Every lit dot in one colour, which plugins/wifi.sh picks by the count:
// orange, pink, cyan, purple for one to four, red when the internet stops
// answering. Unlit dots are faint ghosts. Off, there is no signal to count, so there are no dots: the
// four run together into one flat grey line across the badge, a flatline.
//
// `--transition` lights dots one after another with a small swell, left to
// right when the signal rises and right to left when it falls. Switching off,
// the dots glide together and flatten into the line, the outer ones first
// because they have further to go. Switching on, they pop back out of it one
// by one, left to right, overshooting a little as they round out.
//
// Usage: swiftc -O wifimark.swift -o wifimark

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Two pixels per point, shown at `background.image.scale=0.5`. Drawn at its
// real size rather than scaled up like the other badges, because its box has to
// come out a whole number of points wide.
let pixelScale: CGFloat = 2
// Wider than the other badges' 18pt so four dots have room to be bold.
let boxWidth: CGFloat = 26
let boxHeight: CGFloat = 18

// Four dots edge to edge across the box, so the ink runs from one side to the
// other and the pill's spacing arithmetic treats it like the other badges.
let dotRadius: CGFloat = 2.8
let dotPitch: CGFloat = (boxWidth - 2 * dotRadius) / 3
// The flatline: nearly the width of the dot row, so the badge keeps its
// footprint, and thin enough to read as a line rather than a bar.
let lineX0: CGFloat = 1.5
let lineX1: CGFloat = boxWidth - 1.5
let lineHeight: CGFloat = 2.2
// How far a lighting dot swells; kept under the space between two dots.
let swell: CGFloat = 0.18

let transitionFrames = 36  // 0.6 s at motionwatch's 60 fps

struct RGBA: Equatable { var r, g, b, a: CGFloat }

let ghost = RGBA(r: 1, g: 1, b: 1, a: 0.22)
// The bar's one "off" grey, 0xff8e8e93, the same as the slashed shield and the
// cup's saucer. Opaque, unlike the ghosts: the four segments that make the line
// overlap at their joins, and a translucent grey would show every join as a
// darker spot.
let lineGrey = RGBA(r: 0x8e / 255, g: 0x8e / 255, b: 0x93 / 255, a: 1)

// Colours blend round the colour wheel, not through the middle of it. The dots
// change hue with the signal, orange to pink to cyan to purple, and a straight
// RGB blend from orange to purple passes through a muddy salmon grey halfway;
// walking the hue the short way keeps every frame as saturated as the two ends.
// A colour with no hue of its own, a ghost dot or the grey flatline, takes the
// other end's hue, so it only brightens or fades rather than tinting on the way.
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

func rgb(h: CGFloat, s: CGFloat, v: CGFloat, a: CGFloat) -> RGBA {
    let i = floor(h * 6), f = h * 6 - i
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    switch Int(i) % 6 {
    case 0: return RGBA(r: v, g: t, b: p, a: a)
    case 1: return RGBA(r: q, g: v, b: p, a: a)
    case 2: return RGBA(r: p, g: v, b: t, a: a)
    case 3: return RGBA(r: p, g: q, b: v, a: a)
    case 4: return RGBA(r: t, g: p, b: v, a: a)
    default: return RGBA(r: v, g: p, b: q, a: a)
    }
}

func mix(_ a: RGBA, _ b: RGBA, _ t: CGFloat) -> RGBA {
    let x = hsb(a), y = hsb(b)
    let hueless: CGFloat = 0.08
    let hx = x.s < hueless ? y.h : x.h, hy = y.s < hueless ? x.h : y.h
    var dh = hy - hx
    if dh > 0.5 { dh -= 1 } else if dh < -0.5 { dh += 1 }
    var h = hx + dh * t
    h -= floor(h)
    return rgb(h: h, s: x.s + (y.s - x.s) * t, v: x.v + (y.v - x.v) * t, a: a.a + (b.a - a.a) * t)
}
func smooth(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t)); return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
}
func spring(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t)); return c >= 1 ? 1 : 1 - exp(-6.5 * c) * cos(2.4 * .pi * c)
}
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data(("wifimark: " + m + "\n").utf8)); exit(1)
}
func argument(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--" + name), i + 1 < a.count else { return nil }
    return a[i + 1]
}
func parseColor(_ text: String?) -> RGBA {
    guard let text else { return RGBA(r: 1, g: 1, b: 1, a: 1) }
    let hex = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
    guard hex.count == 8, let v = UInt32(hex, radix: 16) else { fail("colours are 0xAARRGGBB") }
    return RGBA(r: CGFloat((v >> 16) & 0xff) / 255, g: CGFloat((v >> 8) & 0xff) / 255,
                b: CGFloat(v & 0xff) / 255, a: CGFloat((v >> 24) & 0xff) / 255)
}
func count(_ name: String) -> Int {
    guard let text = argument(name) else { return 0 }
    guard let v = Int(text), (0...4).contains(v) else { fail("--\(name) is 0 to 4") }
    return v
}

// One dot in one frame: its colour, how far it has flattened into its quarter
// of the line (0 a round dot, 1 a segment; below 0 while springing back out,
// which makes it briefly rounder and bigger than at rest), and its scale, which
// swells briefly as a dot lights.
struct Dot { var color: RGBA; var flat: CGFloat; var scale: CGFloat }

func palette(_ text: String?) -> [RGBA] { Array(repeating: parseColor(text), count: 4) }

func dots(lit: Int, colors: [RGBA], on: Bool) -> [Dot] {
    (0..<4).map { i in
        on ? Dot(color: i < lit ? colors[i] : ghost, flat: 0, scale: 1) : Dot(color: lineGrey, flat: 1, scale: 1)
    }
}


/// Where dot `i` sits as a round dot, and as its quarter of the flatline.
/// Segments reach half a line height past their joins so the rounded ends
/// meet as one straight edge.
func dotRect(_ i: Int, scale: CGFloat) -> CGRect {
    let r = dotRadius * max(0, scale)
    // A swelling dot grows towards the middle of the box so it never spills
    // past the edge.
    let x = min(boxWidth - r, max(r, dotRadius + CGFloat(i) * dotPitch))
    return CGRect(x: x - r, y: boxHeight / 2 - r, width: r * 2, height: r * 2)
}
func segmentRect(_ i: Int) -> CGRect {
    let width = (lineX1 - lineX0) / 4
    let left = lineX0 + CGFloat(i) * width - (i > 0 ? lineHeight / 2 : 0)
    let right = lineX0 + CGFloat(i + 1) * width + (i < 3 ? lineHeight / 2 : 0)
    return CGRect(x: left, y: boxHeight / 2 - lineHeight / 2, width: right - left, height: lineHeight)
}

func draw(_ row: [Dot]) -> CGImage {
    let pw = Int(boxWidth * pixelScale), ph = Int(boxHeight * pixelScale)
    guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("could not create a bitmap context") }
    ctx.scaleBy(x: pixelScale, y: pixelScale)
    ctx.clear(CGRect(x: 0, y: 0, width: boxWidth, height: boxHeight))

    for (i, dot) in row.enumerated() {
        let round = dotRect(i, scale: dot.scale), line = segmentRect(i)
        let f = dot.flat
        let width = max(0, lerp(round.width, line.width, f))
        let height = max(0, lerp(round.height, line.height, f))
        let midX = lerp(round.midX, line.midX, min(1, max(0, f)))
        let rect = CGRect(x: midX - width / 2, y: boxHeight / 2 - height / 2, width: width, height: height)
        let radius = min(width, height) / 2
        let c = dot.color
        ctx.setFillColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    guard let image = ctx.makeImage() else { fail("could not render") }
    return image
}

// MARK: Ethernet
//
// A cable in: the badge becomes a network port, a socket with its latch tab and
// four contact pins, in the box the dots use. Plugging in, the four dots slide
// across and stretch into the four pins, and the socket springs in around them;
// unplugging runs it back. Purple, the colour of four dots, while the cable has
// the internet, red when it does not, like the dots.

let socketRect = CGRect(x: boxWidth / 2 - 7, y: 2.4, width: 14, height: 13.2)
let socketLine: CGFloat = 1.5

func pinRect(_ i: Int) -> CGRect {
    let pitch: CGFloat = 2.9, w: CGFloat = 1.7, h: CGFloat = 4.4
    let x = boxWidth / 2 + (CGFloat(i) - 1.5) * pitch
    return CGRect(x: x - w / 2, y: socketRect.maxY - 2.6 - h, width: w, height: h)
}

/// Where dot `i` starts from: a round dot, or its quarter of the flatline.
func dotShape(_ i: Int, _ dot: Dot) -> CGRect {
    let round = dotRect(i, scale: dot.scale), line = segmentRect(i), f = dot.flat
    let width = lerp(round.width, line.width, f), height = lerp(round.height, line.height, f)
    let midX = lerp(round.midX, line.midX, f)
    return CGRect(x: midX - width / 2, y: boxHeight / 2 - height / 2, width: width, height: height)
}

func lerpRect(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
           width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
}

/// `morph` 0 is the dots as `row` has them, 1 the pins; `socket` 0 to 1 brings
/// the socket in, and may run past 1 on its spring.
func drawPort(row: [Dot], pin: RGBA, morph: CGFloat, socket: CGFloat) -> CGImage {
    let pw = Int(boxWidth * pixelScale), ph = Int(boxHeight * pixelScale)
    guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("could not create a bitmap context") }
    ctx.scaleBy(x: pixelScale, y: pixelScale)
    ctx.clear(CGRect(x: 0, y: 0, width: boxWidth, height: boxHeight))

    let alpha = min(1, max(0, socket))
    if alpha > 0.01 {
        ctx.saveGState()
        let scale = 0.8 + 0.2 * socket
        ctx.translateBy(x: socketRect.midX, y: socketRect.midY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -socketRect.midX, y: -socketRect.midY)
        let outline = socketRect.insetBy(dx: socketLine / 2, dy: socketLine / 2)
        ctx.setStrokeColor(red: pin.r, green: pin.g, blue: pin.b, alpha: pin.a * alpha)
        ctx.setLineWidth(socketLine)
        ctx.addPath(CGPath(roundedRect: outline, cornerWidth: 2.4, cornerHeight: 2.4, transform: nil))
        ctx.strokePath()
        // The latch tab, a solid step up from the bottom edge.
        let tab = CGRect(x: socketRect.midX - 2.6, y: socketRect.minY + socketLine - 0.2, width: 5.2, height: 2.6)
        ctx.setFillColor(red: pin.r, green: pin.g, blue: pin.b, alpha: pin.a * alpha)
        ctx.addPath(CGPath(roundedRect: tab, cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }
    for (i, dot) in row.enumerated() {
        let rect = lerpRect(dotShape(i, dot), pinRect(i), min(1, max(0, morph)))
        let radius = min(rect.width, rect.height) / 2
        let c = mix(dot.color, pin, min(1, max(0, morph)))
        ctx.setFillColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }
    guard let image = ctx.makeImage() else { fail("could not render") }
    return image
}

func span(_ t: CGFloat, _ start: CGFloat, _ length: CGFloat) -> CGFloat { min(1, max(0, (t - start) / length)) }

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

let ethernet = CommandLine.arguments.contains("--ethernet")
let fromEthernet = CommandLine.arguments.contains("--from-ethernet")
if ethernet || fromEthernet {
    let pin = parseColor(argument("color"))
    guard argument("out") != nil || argument("transition") != nil else { fail("--out or --transition") }
    if ethernet, let out = argument("out") {
        write(drawPort(row: dots(lit: 4, colors: palette(argument("color")), on: true), pin: pin, morph: 1, socket: 1),
              to: URL(fileURLWithPath: out))
    }
    if let dir = argument("transition") {
        let frames: [CGImage]
        if ethernet && fromEthernet {
            // Still a cable; only the colour moves.
            let was = parseColor(argument("from-color") ?? argument("color"))
            frames = (1...transitionFrames).map { step in
                let t = smooth(CGFloat(step) / CGFloat(transitionFrames + 1))
                let c = mix(was, pin, t)
                return drawPort(row: dots(lit: 4, colors: Array(repeating: c, count: 4), on: true), pin: c, morph: 1, socket: 1)
            }
        } else if ethernet {
            // Plugging in: the dots slide into pins, then the socket springs in.
            let fromOn = !CommandLine.arguments.contains("--from-off")
            let row = dots(lit: fromOn ? count("from-dots") : 0,
                           colors: palette(argument("from-color") ?? argument("color")), on: fromOn)
            frames = (1...transitionFrames).map { step in
                let t = CGFloat(step) / CGFloat(transitionFrames + 1)
                return drawPort(row: row, pin: pin, morph: smooth(span(t, 0, 0.6)), socket: spring(span(t, 0.3, 0.7)))
            }
        } else {
            // Unplugging: the socket goes, and the pins round back into dots.
            let on = !CommandLine.arguments.contains("--off")
            let row = dots(lit: on ? count("dots") : 0, colors: palette(argument("color")), on: on)
            let was = parseColor(argument("from-color") ?? argument("color"))
            frames = (1...transitionFrames).map { step in
                let t = CGFloat(step) / CGFloat(transitionFrames + 1)
                return drawPort(row: row, pin: was, morph: 1 - smooth(span(t, 0.25, 0.7)), socket: 1 - smooth(span(t, 0, 0.45)))
            }
        }
        writeSequence(frames, to: dir)
    }
    exit(0)
}

let on = !CommandLine.arguments.contains("--off")
let litTo = on ? count("dots") : 0
let to = dots(lit: litTo, colors: palette(argument("color")), on: on)

guard argument("out") != nil || argument("transition") != nil else { fail("--out or --transition") }
if let out = argument("out") { write(draw(to), to: URL(fileURLWithPath: out)) }

if let dir = argument("transition") {
    let fromOn = !CommandLine.arguments.contains("--from-off")
    let litFrom = fromOn ? count("from-dots") : 0
    let from = dots(lit: litFrom, colors: palette(argument("from-color") ?? argument("color")), on: fromOn)
    let rising = litTo >= litFrom
    let frames = (1...transitionFrames).map { step -> CGImage in
        let t = CGFloat(step) / CGFloat(transitionFrames + 1)
        return draw((0..<4).map { i in
            let was = from[i], now = to[i]
            if fromOn && !on {
                // Flattening: the outer dots set off first, having furthest
                // to travel, so all four arrive in the line together.
                let delay = 0.12 * (1.5 - abs(CGFloat(i) - 1.5))
                let local = min(1, max(0, (t - delay) / 0.72))
                return Dot(color: mix(was.color, now.color, smooth(local)), flat: smooth(local), scale: 1)
            }
            if !fromOn && on {
                // Popping out: left to right, springing past round and back.
                let local = min(1, max(0, (t - CGFloat(i) * 0.09) / 0.7))
                return Dot(color: mix(was.color, now.color, smooth(local)), flat: 1 - spring(local), scale: 1)
            }
            let order = CGFloat(rising ? i : 3 - i)
            let local = min(1, max(0, (t - order * 0.1) / 0.7))
            let lighting = was.color == ghost && now.color != ghost
            return Dot(color: mix(was.color, now.color, smooth(local)), flat: 0,
                       scale: lighting ? 1 + swell * sin(.pi * local) * (1 - local * 0.4) : 1)
        })
    }
    writeSequence(frames, to: dir)
}
