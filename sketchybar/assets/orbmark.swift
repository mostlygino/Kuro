// Draws the OrbStack badge: a small glossy orb, lit from the top left.
//
//   orbmark --color 0xffbf5af2 --out /path.png
//   orbmark --color 0xffbf5af2 --from-color 0xff8e8e93 --transition /path/dir
//
// An orb because that is the product's own mark and name, and a shipping box
// said "Docker" when half of what OrbStack runs here is Linux machines. Drawn
// rather than a symbol: SF Symbols has circles but no sphere, and the depth is
// what makes it read as an orb rather than a status dot.
//
// `--out` is the still, the one render_test.sh hashes. `--transition` blends the
// colour from the last state and gives the orb a small spring as it lands, so
// something starting reads as the orb lighting up. Lighting up also sends a
// ring out from the orb's edge that widens and fades, like a drop in water;
// going idle has no ripple, the orb only cools and settles.
//
// Usage: swiftc -O orbmark.swift -o orbmark

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Two pixels per displayed point, shown at `background.image.scale=0.5`. The
// geometry below is on a 16pt grid and drawn 12.5% up, so the badge shows at
// 18pt and stays pixel-exact rather than being stretched by SketchyBar.
let pixelScale: CGFloat = 2.25
let side: CGFloat = 16
// 12pt across, centred, so the ink runs 2pt to 14pt of the box like the
// shipping box it replaced and the badge spacing in the rc still holds.
let diameter: CGFloat = 12
let transitionFrames = 36  // 0.6 s at motionwatch's 60 fps

struct RGBA { var r, g, b, a: CGFloat }

func mix(_ from: RGBA, _ to: RGBA, _ t: CGFloat) -> RGBA {
    RGBA(r: from.r + (to.r - from.r) * t, g: from.g + (to.g - from.g) * t,
         b: from.b + (to.b - from.b) * t, a: from.a + (to.a - from.a) * t)
}

func smooth(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t))
    return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
}

// A damped spring from 0 to 1, about 6% past the target, settled by the end.
func spring(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t))
    return c >= 1 ? 1 : 1 - exp(-6.5 * c) * cos(2.4 * .pi * c)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("orbmark: " + message + "\n").utf8))
    exit(1)
}

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--" + name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

// 0xAARRGGBB, the same literal form colors.sh uses.
func parseColor(_ text: String?) -> RGBA {
    guard let text else { return RGBA(r: 1, g: 1, b: 1, a: 1) }
    let hex = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
    guard hex.count == 8, let value = UInt32(hex, radix: 16) else {
        fail("--color must be 0xAARRGGBB")
    }
    return RGBA(
        r: CGFloat((value >> 16) & 0xFF) / 255,
        g: CGFloat((value >> 8) & 0xFF) / 255,
        b: CGFloat(value & 0xFF) / 255,
        a: CGFloat((value >> 24) & 0xFF) / 255)
}

func cg(_ c: RGBA, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: c.r, green: c.g, blue: c.b, alpha: c.a * alpha)
}

// The body is a radial gradient from a lifted tint at the upper left to the
// colour itself and then a deeper shade at the rim, which is what turns a
// disc into a sphere. A thin highlight crescent and a soft specular dot finish
// it; both are white at low alpha so they work on grey and purple alike.
func draw(_ color: RGBA, scale: CGFloat = 1, ripple: (progress: CGFloat, color: RGBA)? = nil) -> CGImage {
    let pixels = Int(side * pixelScale)
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fail("could not create a bitmap context")
    }
    context.scaleBy(x: pixelScale, y: pixelScale)
    context.setAllowsAntialiasing(true)
    context.clear(CGRect(x: 0, y: 0, width: side, height: side))

    let radius = diameter / 2 * scale
    let center = CGPoint(x: side / 2, y: side / 2)
    let body = CGRect(x: center.x - radius, y: center.y - radius,
                      width: radius * 2, height: radius * 2)

    let lifted = mix(color, RGBA(r: 1, g: 1, b: 1, a: color.a), 0.45)
    let deep = mix(color, RGBA(r: 0, g: 0, b: 0, a: color.a), 0.35)

    context.saveGState()
    context.addEllipse(in: body)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [cg(lifted), cg(color), cg(deep)] as CFArray, locations: [0, 0.55, 1]) {
        // Light from the upper left: the bright centre sits up and left of the
        // middle, and the gradient reaches the far rim.
        let light = CGPoint(x: center.x - radius * 0.35, y: center.y + radius * 0.4)
        context.drawRadialGradient(
            gradient, startCenter: light, startRadius: 0,
            endCenter: center, endRadius: radius * 1.05,
            options: [.drawsAfterEndLocation])
    }
    context.restoreGState()

    // Specular dot.
    let dot = radius * 0.32
    context.setFillColor(cg(RGBA(r: 1, g: 1, b: 1, a: 1), alpha: 0.55 * color.a))
    context.fillEllipse(in: CGRect(
        x: center.x - radius * 0.42 - dot / 2, y: center.y + radius * 0.38 - dot / 2,
        width: dot, height: dot))

    // The ripple, outside the orb: from its edge to the box's, thinning and
    // fading as it goes.
    if let ripple, ripple.progress > 0, ripple.progress < 1 {
        let p = ripple.progress
        let r = diameter / 2 + (side / 2 - 0.5 - diameter / 2) * p
        context.setStrokeColor(cg(ripple.color, alpha: 0.75 * (1 - p)))
        context.setLineWidth(1.2 * (1 - p) + 0.3)
        context.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    }

    // A hairline rim in the deep shade, so the orb keeps its edge on a grey pill.
    context.setStrokeColor(cg(deep, alpha: 0.6))
    context.setLineWidth(0.5)
    context.strokeEllipse(in: body.insetBy(dx: 0.25, dy: 0.25))

    guard let image = context.makeImage() else { fail("could not render the image") }
    return image
}

// Written to a neighbouring temp file and moved into place, because the reader
// is SketchyBar loading the same path: a half-written PNG is a dropped icon.
func write(_ image: CGImage, to url: URL) {
    let temp = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
    guard let destination = CGImageDestinationCreateWithURL(
        temp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("could not open \(temp.path) for writing")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(temp.path)") }
    do {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    } catch {
        try? FileManager.default.removeItem(at: temp)
        fail("could not move the render into place: \(error.localizedDescription)")
    }
}

// A sequence is a directory of frame-NN.png, built beside its final name and
// renamed into place whole, so motionwatch never lists a half-written one.
func writeSequence(_ images: [CGImage], to path: String) {
    let fm = FileManager.default
    let final = URL(fileURLWithPath: path)
    let temp = final.deletingLastPathComponent()
        .appendingPathComponent(".\(final.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
    try? fm.removeItem(at: temp)
    do {
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
    } catch {
        fail("could not create \(temp.path)")
    }
    for (index, image) in images.enumerated() {
        write(image, to: temp.appendingPathComponent(String(format: "frame-%02d.png", index)))
    }
    // Same key, same frames: a run that finished first may already be playing

    // its copy, and deleting it under the player is a dropped image.

    if fm.fileExists(atPath: final.path) { try? fm.removeItem(at: temp); return }
    do {
        try fm.moveItem(at: temp, to: final)
    } catch {
        try? fm.removeItem(at: temp)
        // Lost the race to an identical render: its copy is the result.
        if fm.fileExists(atPath: final.path) { return }
        fail("could not move \(final.path) into place")
    }
}

let target = parseColor(argument("color"))
let outArg = argument("out")
let transitionArg = argument("transition")
guard outArg != nil || transitionArg != nil else {
    fail("one of --out or --transition is required")
}

if let outArg { write(draw(target), to: URL(fileURLWithPath: outArg)) }

if let transitionArg {
    let from = parseColor(argument("from-color") ?? argument("color"))
    // The colour eases across while the orb dips a little and springs back.
    // Lighting up is the target being the more saturated colour of the two.
    func saturation(_ c: RGBA) -> CGFloat { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
    let lightingUp = saturation(target) > saturation(from) + 0.05
    let frames = (1...transitionFrames).map { step -> CGImage in
        let t = CGFloat(step) / CGFloat(transitionFrames + 1)
        let ripple = lightingUp ? (progress: max(0, (t - 0.25) / 0.75), color: target) : nil
        return draw(mix(from, target, smooth(t)), scale: 0.82 + 0.18 * spring(t), ripple: ripple)
    }
    writeSequence(frames, to: transitionArg)
}
