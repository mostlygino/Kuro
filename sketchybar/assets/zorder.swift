// Says whether SketchyBar's windows are still stacked the right way round: a
// pill's background below the badges it holds.
//
//   zorder              exit 0 when they are, 1 when a pill sits over its items
//   zorder --self-test  checks the rule against made-up windows
//
// SketchyBar draws every item and every bracket in a window of its own, all on
// one level, so which is in front is the order they were last put there. After
// the screens change it can come out wrong: on 2026-09-29 the badge pill's
// window was found above its five badges, and its 85% fill dimmed them to a
// third of their colour, as if the whole pill were greyed out. The images were
// right; the pill was in front. A reload puts the order back, and
// plugins/display_settle.sh runs this after every display change and wake to
// know when one is needed.
//
// The rule needs no names: a SketchyBar window that encloses another one must
// be behind it. Brackets enclose their members, the bar encloses everything,
// and nothing else encloses anything.
//
// Usage: swiftc -O zorder.swift -o zorder

import CoreGraphics
import Foundation

/// Windows front to back. True when every window that encloses a smaller one
/// is behind it.
func stackedRight(_ frontToBack: [CGRect]) -> Bool {
    for (i, front) in frontToBack.enumerated() {
        for back in frontToBack[(i + 1)...]
        where back.width < front.width && front.insetBy(dx: -1, dy: -1).contains(back) {
            return false
        }
    }
    return true
}

if CommandLine.arguments.contains("--self-test") {
    let pill = CGRect(x: 1548, y: 6, width: 174, height: 66)
    let badge = CGRect(x: 1556, y: 6, width: 18, height: 66)
    let bar = CGRect(x: 10, y: 6, width: 1780, height: 66)
    let clock = CGRect(x: 1739, y: 6, width: 50, height: 66)
    var failures = 0
    func expect(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL", what) }
    }
    expect(stackedRight([badge, clock, pill, bar]), "badges in front of their pill")
    expect(!stackedRight([pill, badge, clock, bar]), "a pill in front of its badges")
    expect(!stackedRight([badge, bar, pill]), "the bar in front of a pill")
    expect(stackedRight([clock, badge]), "windows side by side")
    print(failures == 0 ? "zorder: self-test passed" : "zorder: \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}

let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
let rects = windows.compactMap { window -> CGRect? in
    guard (window[kCGWindowOwnerName as String] as? String) == "sketchybar",
          let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
          let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"],
          x > -9000, w > 1
    else { return nil }
    return CGRect(x: x, y: y, width: w, height: h)
}
exit(stackedRight(rects) ? 0 : 1)
