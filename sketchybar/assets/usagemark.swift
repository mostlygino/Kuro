// Draws the Claude usage mark: a radial burst whose rays go out as the session
// is spent, in the shape of the asterisk Anthropic uses for Claude.
//
// It was a battery first, shell and nub and a draining fill, and the shape was
// the problem rather than the drawing. A menu bar already has a battery in it,
// and a second one that is not about power reads as a bug for the first second
// and as clutter after that. A burst says "this is the AI thing" before it says
// anything about a level, which is the right order for a badge that sits next to
// a VPN shield and a clock.
//
// The silhouette never changes: spent rays are drawn in the same geometry at a
// low alpha rather than removed. An icon that loses limbs as it drains is a
// different icon every hour, and the eye has to re-find it each time. Brightness
// carries the level, the outline carries the identity.
//
// Eight rays, so each one is twelve and a half percent. Twelve was drawn first
// and is the prettier asterisk, but half its rays land on angles that no pixel
// grid agrees with, and at 16px the ends smear together until the count cannot
// be read. Eight puts four rays on the axes and four on exact diagonals, which
// is the difference between a gauge and a snowflake. Finer steps than that are
// wasted here anyway: once the count gets low the colour is doing the work.
//
// It is a rendered PNG rather than a font glyph because no glyph set has this
// shape at eight states, and SketchyBar cannot compose two glyphs into one
// item. One PNG per (percent, colour) pair, written to a cache directory and
// reused, so the steady case costs nothing but a `--set`.
//
//   usagemark --percent 84 --color 0xffd97757 --out /path/mark.png
//   usagemark --percent 84 --color 0xffd97757 \
//             --from-percent 97 --from-color 0xffd97757 --transition /path/dir
//   usagemark --error --out /path/mark.png          [--from-error for the way back]
//   usagemark --blocked --out /path/mark.png        [--from-blocked for the way back]
//
// `--error` is "nothing got through": no reading for long enough that the last
// one cannot be trusted. It used to be a fully lit red burst, which is one ray
// away from "nearly out" and says the opposite. Now every ray goes to a ghost
// and a red dot sits in the hub: the shape is still the Claude badge, and it is
// plainly not reporting a level. Going into it the rays go out clockwise and
// the dot pops in; coming back the dot shrinks away as the rays grow out.
//
// `--blocked` is the weekly limit spent: no session, however full, can be used
// until the week resets. The four diagonal rays turn red and close the hub
// between them, so the burst's own lines make a cross, and the four on the axes
// go to ghosts. Into it the cross is drawn a stroke at a time, "\\" then "/";
// out of it the hub opens again and the burst comes back in its colour.
//
// `--out` is the still, the one render_test.sh hashes and the bar shows at
// rest. `--transition` is how the burst gets from the last reading to this one,
// and its last step lands on the still, so the two cut together without a jump.
//
// Usage: swiftc -O usagemark.swift -o usagemark

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Two pixels per point, shown at `background.image.scale=0.5`. The main screen
// is the built-in Retina panel now, and a 1x render there was upscaled into a
// soft smear; a 1x screen downsamples the 2x render cleanly instead. Every
// coordinate below is in points and the half-point insets land on the pixel
// grid at either scale. 2.25 rather than 2: the burst is designed on a 16pt
// grid and drawn 12.5% up, so it shows at 18pt with the same two pixels per
// displayed point.
let pixelScale: CGFloat = 2.25

// Square, and sized to sit beside the Tailscale shield rather than beside the
// text. 16 is the smallest canvas that still leaves the twelve rays a gap
// between them at their outer ends; at 14 the ends merge into a ring.
let side: CGFloat = 16

let rayCount = 8
let innerRadius: CGFloat = 2.6
let outerRadius: CGFloat = 7.2
let rayWidth: CGFloat = 1.5

// Spent rays stay drawn at this alpha, which is low because the lit ones are a
// saturated orange on a grey bar and do not need help standing out. It is still
// far enough above zero to keep the whole asterisk present as a shape, so the
// badge does not appear to shrink as the session is spent.
let spentAlpha: CGFloat = 0.12

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("usagemark: " + message + "\n").utf8))
    exit(1)
}

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--" + name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

// Transitions play at motionwatch's 60fps. 36 frames is 0.6s, the length of a
// system symbol transition. The first version was eight frames of crossfade at
// 12fps and read as a stutter; 22 frames at 36fps followed, until 2026-09-29.
let transitionFrames = 36

struct RGBA { var r, g, b, a: CGFloat }

func mix(_ from: RGBA, _ to: RGBA, _ t: CGFloat) -> RGBA {
    RGBA(r: from.r + (to.r - from.r) * t, g: from.g + (to.g - from.g) * t,
         b: from.b + (to.b - from.b) * t, a: from.a + (to.a - from.a) * t)
}

func ease(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t))
    return c * c * (3 - 2 * c)
}

// Ease-in-out cubic, for fades: gentler at both ends than smoothstep.
func smooth(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t))
    return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
}

// A damped spring from 0 to 1 with about 6% overshoot, settled by the end, the
// shape of a system spring animation rather than of a curve.
func spring(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t))
    return c >= 1 ? 1 : 1 - exp(-6.5 * c) * cos(2.4 * .pi * c)
}

// Rises and falls once over 0...1.
func bump(_ x: CGFloat) -> CGFloat { x <= 0 || x >= 1 ? 0 : sin(x * .pi) }

// 0xAARRGGBB, the same literal form colors.sh uses, so a colour can be moved
// between the two without rewriting it.
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
        a: CGFloat((value >> 24) & 0xFF) / 255
    )
}

func percentArgument(_ name: String) -> Double? {
    guard let text = argument(name) else { return nil }
    guard let value = Double(text) else { fail("--\(name) must be a number") }
    return min(100, max(0, value))
}

let spentColor = RGBA(r: 1, g: 1, b: 1, a: spentAlpha)

// A ray stands for a whole eighth spent, so the count rounds *up*: eight rays
// mean anything from untouched to an eighth gone, and the first one only goes
// out once a full eighth is actually used.
//
// Rounding to nearest was the obvious first choice and it is wrong here. It puts
// the boundaries at half-segments, so the first ray went out at 6.25% used,
// which reads as the gauge twitching at the sight of any use at all. A gauge
// with eight steps should not move until a step's worth has happened.
//
// Anything left keeps at least one ray lit: a fully dim burst means empty, and it
// cannot also mean "nearly empty" without lying about one of them.
func litCount(_ percent: Double) -> Int {
    percent <= 0
        ? 0
        : max(1, min(rayCount, Int((Double(rayCount) * percent / 100).rounded(.up))))
}

func rays(percent: Double, color: RGBA) -> [RGBA] {
    let lit = litCount(percent)
    return (0..<rayCount).map { $0 < lit ? color : spentColor }
}

let pixelSide = Int(side * pixelScale)

// One stroke on the burst: which ray, in what colour, and how much of it, from
// the hub outward. A transition can draw two strokes on the same ray, the
// spent ghost underneath and the lit ray withdrawing over it.
struct Stroke {
    var index: Int
    var color: RGBA
    var length: CGFloat = 1
    var inner: CGFloat = innerRadius
}

let errorRed = RGBA(r: 1, g: 0x45 / 255, b: 0x3a / 255, a: 1)
let hubDotRadius: CGFloat = 1.55

// The cross: the diagonal rays, odd indices clockwise from the top.
func isDiagonal(_ index: Int) -> Bool { index % 2 == 1 }
let blockedRays = (0..<rayCount).map { isDiagonal($0) ? errorRed : spentColor }
// Drawn as a hand draws an X: the stroke from top left to bottom right first.
func firstStroke(_ index: Int) -> Bool { index == 3 || index == 7 }
func span(_ t: CGFloat, _ start: CGFloat, _ length: CGFloat) -> CGFloat { min(1, max(0, (t - start) / length)) }

func blockedStill() -> CGImage {
    draw(strokes: (0..<rayCount).map {
        Stroke(index: $0, color: blockedRays[$0], inner: isDiagonal($0) ? 0 : innerRadius)
    })
}

func draw(_ rays: [RGBA], hub: CGFloat = 0) -> CGImage {
    draw(strokes: rays.enumerated().map { Stroke(index: $0, color: $1) }, hub: hub)
}

func draw(strokes: [Stroke], hub: CGFloat = 0) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: pixelSide,
        height: pixelSide,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fail("could not create a bitmap context")
    }

    context.scaleBy(x: pixelScale, y: pixelScale)
    context.setAllowsAntialiasing(true)
    context.clear(CGRect(x: 0, y: 0, width: side, height: side))
    context.setLineWidth(rayWidth)
    context.setLineCap(.round)

    let center = CGPoint(x: side / 2, y: side / 2)

    // Rays go out clockwise from twelve o'clock, so the burst empties the way a
    // clock face does and the last ray standing is the one at the top.
    for stroke in strokes where stroke.length > 0 && stroke.color.a > 0 {
        let ray = stroke.color
        let angle = CGFloat.pi / 2 - CGFloat(stroke.index) * 2 * CGFloat.pi / CGFloat(rayCount)
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        // Exactly outerRadius at full length, so the still is byte-identical to
        // what it was before strokes had a length at all.
        let outer = stroke.length >= 1
            ? outerRadius : stroke.inner + (outerRadius - stroke.inner) * stroke.length
        context.setStrokeColor(red: ray.r, green: ray.g, blue: ray.b, alpha: ray.a)
        context.move(to: CGPoint(
            x: center.x + direction.x * stroke.inner, y: center.y + direction.y * stroke.inner))
        context.addLine(to: CGPoint(
            x: center.x + direction.x * outer, y: center.y + direction.y * outer))
        context.strokePath()
    }

    // The error dot, `hub` being its size from 0 to 1 (and past 1 on a spring).
    if hub > 0.01 {
        let r = hubDotRadius * hub
        context.setFillColor(red: errorRed.r, green: errorRed.g, blue: errorRed.b, alpha: min(1, hub))
        context.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    }

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

// An error has no level, so it needs no --percent.
let isBlocked = CommandLine.arguments.contains("--blocked")
let wasBlocked = CommandLine.arguments.contains("--from-blocked")
guard let percent = percentArgument("percent")
        ?? (CommandLine.arguments.contains("--error") || isBlocked ? 0 : nil) else {
    fail("--percent is required and must be a number")
}
let color = parseColor(argument("color"))
let isError = CommandLine.arguments.contains("--error")
let wasError = CommandLine.arguments.contains("--from-error")
let target = isBlocked ? blockedRays
    : isError ? Array(repeating: spentColor, count: rayCount) : rays(percent: percent, color: color)

let outArg = argument("out")
let transitionArg = argument("transition")
guard outArg != nil || transitionArg != nil else {
    fail("one of --out or --transition is required")
}

if let outArg {
    write(isBlocked ? blockedStill() : draw(target, hub: isError ? 1 : 0), to: URL(fileURLWithPath: outArg))
}

if let transitionArg {
    guard let fromPercent = percentArgument("from-percent") ?? (wasError || wasBlocked ? 0 : nil) else {
        fail("--transition needs --from-percent")
    }
    let from = wasBlocked ? blockedRays
        : wasError ? Array(repeating: spentColor, count: rayCount)
        : rays(percent: fromPercent, color: parseColor(argument("from-color") ?? argument("color")))
    let lit = isError || isBlocked ? 0 : litCount(percent)
    let wasLit = wasError || wasBlocked ? 0 : litCount(fromPercent)
    let white = RGBA(r: 1, g: 1, b: 1, a: 1)

    // Three kinds of change, each with its own motion:
    //
    //   a ray goes out    ->  it withdraws into the hub while it fades, and the
    //                         spent ghost fades in underneath;
    //   a ray comes back  ->  it grows out from the hub on a spring;
    //   the colour changes ->  the new colour eases round the burst clockwise
    //                         from the top;
    //   only the number moved -> a soft glint runs once round the lit rays, so
    //                         a refresh is visible without claiming a ray's
    //                         worth of change that did not happen.
    //
    // Several can happen at once, a ray going out as the colour turns red.
    let stagger: CGFloat = 0.35
    let frames = (1...transitionFrames).map { step -> CGImage in
        let t = CGFloat(step) / CGFloat(transitionFrames + 1)
        var strokes: [Stroke] = []
        for index in 0..<rayCount {
            let before = from[index], after = target[index]
            let wasOn = index < wasLit, isOn = index < lit
            if (isBlocked || wasBlocked) && isDiagonal(index) {
                // Into the cross: each diagonal turns red and runs in to meet
                // its opposite through the hub, one stroke after the other. Out
                // of it: the hub opens and the colour eases to the burst's.
                let k = smooth(span(t, firstStroke(index) ? 0.08 : 0.34, 0.5))
                strokes.append(Stroke(index: index, color: spentColor))
                let closed = isBlocked ? k : 1 - k
                var ray = mix(before, after, k)
                // Out to a spent ray the red withdraws into the ghost.
                if wasBlocked && !isOn { ray = errorRed; ray.a = 1 - k }
                strokes.append(Stroke(index: index, color: ray, inner: innerRadius * (1 - closed)))
                continue
            }
            if wasOn && !isOn {
                // Into an error every ray goes, so they go one after another,
                // clockwise, rather than all at once.
                let k = isError ? smooth((t - 0.5 * CGFloat(index) / CGFloat(rayCount)) / 0.5) : smooth(t)
                strokes.append(Stroke(index: index, color: mix(RGBA(r: 1, g: 1, b: 1, a: 0), spentColor, k)))
                var going = before
                going.a *= 1 - k
                strokes.append(Stroke(index: index, color: going, length: 1 - 0.8 * k))
            } else if !wasOn && isOn {
                strokes.append(Stroke(index: index, color: spentColor))
                var coming = after
                coming.a *= smooth(min(1, t * 2))
                strokes.append(Stroke(index: index, color: coming, length: 0.2 + 0.8 * spring(t)))
            } else if wasOn && isOn && (before.r != after.r || before.g != after.g || before.b != after.b) {
                let delay = stagger * CGFloat(index) / CGFloat(rayCount - 1)
                strokes.append(Stroke(index: index, color: mix(before, after, smooth((t - delay) / (1 - stagger)))))
            } else if isOn && wasLit == lit {
                let span: CGFloat = 0.5
                let start = (1 - span) * CGFloat(index) / CGFloat(max(1, lit - 1))
                strokes.append(Stroke(index: index, color: mix(after, white, 0.35 * bump((t - start) / span))))
            } else {
                strokes.append(Stroke(index: index, color: after))
            }
        }
        let hub: CGFloat = isError && !wasError ? spring(max(0, t - 0.45) / 0.55)
            : wasError && !isError ? 1 - smooth(t / 0.5)
            : isError ? 1 : 0
        return draw(strokes: strokes, hub: hub)
    }
    writeSequence(frames, to: transitionArg)
}
