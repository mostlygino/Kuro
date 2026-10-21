// Keeps the macOS menu bar from ever coming down. Kuro's bar replaces it, and
// the real one sliding over the top on every brush of the screen's top edge
// greyed the bar out under it and shut whatever card was open.
//
//   topguard              run, until killed
//   topguard --gap 300    the same, with a 300pt opening at the top centre
//   topguard --self-test  check the edge rule against made-up screens
//
// The opening is `MENUBAR_REVEAL_WIDTH` in local.sh, 0 or unset for none: a
// stretch in the middle of each screen's top edge where the wall is left out,
// so resting the pointer there brings the real menu bar down the way macOS
// always did, and the rest of the edge still never does.
//
// There is no setting for this. "Automatically hide and show the menu bar" can
// hide it but not keep it hidden: the pointer in the top strip of a screen for
// about a tenth of a second brings it down, measured on 2026-09-29 (60ms left
// it up, 120ms brought it down; the strip is about 6pt deep, the menu bar came
// down at 4pt and stayed away at 8). Nothing in the system reads a preference
// that turns that off.
//
// Moving the pointer back out once it is there does not work: a hand pushing
// up puts it back in the strip on every event, and a warp 2ms later still let
// the menu bar come down. What works is never letting it in. This taps mouse
// events where they enter the event system and moves any that would land in a
// screen's top strip down to its edge, so the pointer stops 6pt below the top
// the way it stops at the side of a screen. The bar's pills start below that,
// so nothing on the bar goes out of reach.
//
// Only a top edge with no screen above it is a wall. Where a screen sits on top
// of another the pointer still crosses between them.
//
// Needs Accessibility, like the clock's Notification Center shortcut: it runs
// under SketchyBar, which already has it. Without it the tap cannot be made,
// this says so and exits, and plugins/menubar_reveal.sh still clears the bar
// out of the menu bar's way as before.
//
// Usage: swiftc -O topguard.swift -o topguard

import CoreGraphics
import Foundation

let strip: CGFloat = 6

/// Where a pointer at `p` may go: unchanged, or held at the strip's edge when
/// it is in a top strip that has no screen above it. Screens in global
/// coordinates, origin top left, y down.
func guarded(_ p: CGPoint, screens: [CGRect], gap: CGFloat = 0) -> CGPoint {
    guard let screen = screens.first(where: { $0.contains(p) }) else { return p }
    guard p.y < screen.minY + strip else { return p }
    if abs(p.x - screen.midX) < gap / 2 { return p }
    let above = screens.contains { $0 != screen && p.x >= $0.minX && p.x < $0.maxX && abs($0.maxY - screen.minY) < 1 }
    return above ? p : CGPoint(x: p.x, y: screen.minY + strip)
}

if CommandLine.arguments.contains("--self-test") {
    let main = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    let aboveIt = CGRect(x: 0, y: -1440, width: 2560, height: 1440)
    let beside = CGRect(x: 1800, y: 0, width: 1920, height: 1080)
    var failures = 0
    func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL", what) } }
    expect(guarded(CGPoint(x: 900, y: 2), screens: [main]).y == strip, "held below the strip")
    expect(guarded(CGPoint(x: 900, y: 0), screens: [main]).y == strip, "held at the very top")
    expect(guarded(CGPoint(x: 900, y: 40), screens: [main]).y == 40, "left alone on the bar")
    expect(guarded(CGPoint(x: 900, y: 2), screens: [main, aboveIt]).y == 2, "free to cross to a screen above")
    expect(guarded(CGPoint(x: 900, y: -1438), screens: [main, aboveIt]).y == -1440 + strip, "the upper screen's own top is a wall")
    expect(guarded(CGPoint(x: 2500, y: 3), screens: [main, beside]).y == strip, "a screen beside has its own wall")
    expect(guarded(CGPoint(x: 900, y: 2), screens: [main], gap: 300).y == 2, "the opening lets it through at the centre")
    expect(guarded(CGPoint(x: 1060, y: 2), screens: [main], gap: 300).y == strip, "and nowhere past its edge")
    expect(guarded(CGPoint(x: 2760, y: 2), screens: [main, beside], gap: 300).y == 2, "each screen has its own opening")
    print(failures == 0 ? "topguard: self-test passed" : "topguard: \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}

let gap: CGFloat = {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--gap"), i + 1 < args.count, let w = Double(args[i + 1]), w > 0 else { return 0 }
    return CGFloat(w)
}()

var screens: [CGRect] = []
func readScreens() {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    screens = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
}
readScreens()
CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
    if !flags.contains(.beginConfigurationFlag) { readScreens() }
}, nil)

let moves: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
let mask = moves.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
var tap: CFMachPort?
tap = CGEvent.tapCreate(
    tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
    callback: { _, type, event, _ in
        // macOS switches a tap off if it ever answers too slowly; put it back.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let p = event.location
        let q = guarded(p, screens: screens, gap: gap)
        if q != p { event.location = q }
        return Unmanaged.passUnretained(event)
    }, userInfo: nil)

guard let tap else {
    FileHandle.standardError.write(Data("topguard: no event tap, Accessibility is not granted; the menu bar can still come down\n".utf8))
    exit(1)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
CFRunLoopRun()
