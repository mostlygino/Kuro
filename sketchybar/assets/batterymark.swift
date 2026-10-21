// Draws the battery as a ring: the charge is a line running clockwise from
// twelve o'clock over a faint track, the way the battery widget on an iPhone
// draws it.
//
//   batterymark --percent 64 --color 0xff32d74b [--charging] --out /path.png
//   batterymark ... --from-percent 65 --from-color 0xff32d74b [--from-charging] \
//               --transition /path/dir
//
// The colour is the state: green is fine, amber under 35%, red under 12%
// (plugins/battery.sh decides). On power a bolt sits in the middle of the ring.
//
// `--out` is the still that render_test.sh hashes and the bar shows at rest.
// `--transition` sweeps the ring to the new level as its colour turns, and
// springs the bolt in or fades it out, landing on the still. Plugging in also
// sends a bright comet once round the ring, the charge arriving; unplugging
// lets the ring dim for a moment and come back, the machine taking the load.
//
// Usage: swiftc -O batterymark.swift -o batterymark

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Two pixels per displayed point, shown at `background.image.scale=0.5`. The
// geometry below is on a 16pt grid and drawn 12.5% up, so the badge shows at
// 18pt and stays pixel-exact rather than being stretched by SketchyBar.
let pixelScale: CGFloat = 2.25
let side: CGFloat = 16
let centre = CGPoint(x: side / 2, y: side / 2)

// The ring's outer edge lands on the box, so the badge's ink runs edge to edge
// and the pill's spacing arithmetic can treat it like the other badges.
let ringWidth: CGFloat = 1.7
let ringRadius: CGFloat = side / 2 - ringWidth / 2
let trackAlpha: CGFloat = 0.2

let boltHeight: CGFloat = 7.4
let boltWidth: CGFloat = 4.8

let transitionFrames = 36  // 0.6 s at motionwatch's 60 fps

struct RGBA { var r, g, b, a: CGFloat }

func mix(_ a: RGBA, _ b: RGBA, _ t: CGFloat) -> RGBA {
    RGBA(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t, a: a.a + (b.a - a.a) * t)
}
func smooth(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t)); return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
}
func spring(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t)); return c >= 1 ? 1 : 1 - exp(-6.5 * c) * cos(2.4 * .pi * c)
}
func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data(("batterymark: " + m + "\n").utf8)); exit(1)
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
func percent(_ name: String) -> CGFloat {
    guard let text = argument(name) else { return 0 }
    guard let v = Double(text), (0...100).contains(v) else { fail("--\(name) is 0 to 100") }
    return CGFloat(v) / 100
}

struct Frame {
    var level: CGFloat
    var color: RGBA
    var bolt: CGFloat
    // Where the plug-in comet's head is, 0 to 1 once round from twelve, or nil.
    var comet: CGFloat? = nil
    // How bright the ring is, for the dip on unplugging.
    var glow: CGFloat = 1
}

func draw(_ f: Frame) -> CGImage {
    let px = Int(side * pixelScale)
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("could not create a bitmap context") }
    ctx.scaleBy(x: pixelScale, y: pixelScale)
    ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))

    ctx.setLineWidth(ringWidth)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: trackAlpha)
    ctx.addArc(center: centre, radius: ringRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.strokePath()
    if f.level > 0.005 {
        let top = CGFloat.pi / 2
        let c = f.color
        ctx.setStrokeColor(red: c.r, green: c.g, blue: c.b, alpha: c.a * f.glow)
        ctx.addArc(center: centre, radius: ringRadius, startAngle: top,
                   endAngle: top - 2 * .pi * min(1, f.level), clockwise: true)
        ctx.strokePath()
    }

    // The comet: a short bright head with a tail that fades behind it, drawn as
    // a run of small arcs so the fade is smooth at this size.
    if let comet = f.comet {
        let top = CGFloat.pi / 2
        let head = top - 2 * .pi * comet
        let tail = CGFloat.pi * 0.42
        let pieces = 14
        let bright = RGBA(r: 1, g: 1, b: 1, a: 1)
        let tint = RGBA(r: f.color.r + (bright.r - f.color.r) * 0.6, g: f.color.g + (bright.g - f.color.g) * 0.6,
                        b: f.color.b + (bright.b - f.color.b) * 0.6, a: 1)
        // It fades in over the first stretch and out over the last, so it
        // neither pops on at twelve nor stops dead there.
        let presence = min(1, comet / 0.15, (1 - comet) / 0.2)
        ctx.setLineWidth(ringWidth)
        ctx.setLineCap(.round)
        for i in 0..<pieces {
            let a0 = head + tail * CGFloat(i) / CGFloat(pieces)
            let a1 = head + tail * CGFloat(i + 1) / CGFloat(pieces)
            let alpha = pow(1 - CGFloat(i) / CGFloat(pieces), 1.6) * presence
            ctx.setStrokeColor(red: tint.r, green: tint.g, blue: tint.b, alpha: alpha)
            ctx.addArc(center: centre, radius: ringRadius, startAngle: a1, endAngle: a0, clockwise: true)
            ctx.strokePath()
        }
    }

    if f.bolt > 0.01 {
        let k = f.bolt, c = centre
        let h = boltHeight / 2 * k, w = boltWidth / 2 * k
        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x + w * 0.35, y: c.y + h))
        path.addLine(to: CGPoint(x: c.x - w, y: c.y - h * 0.08))
        path.addLine(to: CGPoint(x: c.x - w * 0.05, y: c.y - h * 0.08))
        path.addLine(to: CGPoint(x: c.x - w * 0.35, y: c.y - h))
        path.addLine(to: CGPoint(x: c.x + w, y: c.y + h * 0.08))
        path.addLine(to: CGPoint(x: c.x + w * 0.05, y: c.y + h * 0.08))
        path.closeSubpath()
        let col = f.color
        ctx.setFillColor(red: col.r, green: col.g, blue: col.b, alpha: col.a * min(1, k))
        ctx.addPath(path); ctx.fillPath()
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

let to = Frame(level: percent("percent"), color: parseColor(argument("color")),
               bolt: CommandLine.arguments.contains("--charging") ? 1 : 0)

guard argument("out") != nil || argument("transition") != nil else { fail("--out or --transition") }
if let out = argument("out") { write(draw(to), to: URL(fileURLWithPath: out)) }

if let dir = argument("transition") {
    let from = Frame(level: percent("from-percent"), color: parseColor(argument("from-color") ?? argument("color")),
                     bolt: CommandLine.arguments.contains("--from-charging") ? 1 : 0)
    let frames = (1...transitionFrames).map { step -> CGImage in
        let t = CGFloat(step) / CGFloat(transitionFrames + 1)
        // Level and colour on one curve, so the new colour arrives with the
        // sweep rather than after it.
        var f = Frame(level: from.level + (to.level - from.level) * smooth(t),
                      color: mix(from.color, to.color, smooth(t)), bolt: to.bolt)
        if to.bolt > from.bolt {
            f.bolt = spring(t)
            f.comet = smooth(t)
        } else if to.bolt < from.bolt {
            f.bolt = 1 - smooth(t)
            f.glow = 1 - 0.45 * sin(.pi * t)
        }
        return draw(f)
    }
    writeSequence(frames, to: dir)
}
