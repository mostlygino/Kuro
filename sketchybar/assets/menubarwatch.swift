import AppKit

// Watches for the macOS auto-hidden menu bar reveal and tells SketchyBar to get
// out of the way, because the bar runs on window layer 3 and the menu bar draws
// on top of it (see sketchybarrc for why it cannot simply outrank it).
//
// macOS reveals the menu bar when the pointer touches the very top edge of a
// screen and keeps it up while the pointer stays inside the menu bar strip.
// Those are two different thresholds, so the same two drive the hysteresis here
// and the bar does not flicker while the pointer sits in the revealed strip.
//
// Polls NSEvent.mouseLocation instead of installing a global event monitor: a
// static read needs no Accessibility or Input Monitoring grant, so this adds no
// TCC surface.

let watchArgs = Array(CommandLine.arguments.dropFirst())

// One-shot query, no watching: prints how far down the built-in panel's notch
// reaches, in points, or 0 when no notched display is attached. That is the
// depth the Now Playing pill has to clear, and it doubles as the "is there a
// notch at all" test. Nothing calls it at present; it is kept because the measurement is fiddly and the pill may move back to the centre.
//
// Lives here because this is already the AppKit-linked binary in the config, so
// the answer costs no extra build step, and it is a measurement rather than a
// match against display names.
//
// The inset is scale-dependent, like the notch's width: 38pt at the 1800x1169
// scaled mode. Reading it per invocation is what keeps the layout correct
// across a scaling change with no config edit.
if watchArgs.contains("--notch-inset") {
    let inset = NSScreen.screens
        .map { $0.safeAreaInsets.top }
        .filter { $0 > 0 }
        .max() ?? 0
    print(Int(inset.rounded()))
    exit(0)
}

let revealScript = watchArgs.first ?? ""

guard !revealScript.isEmpty else {
    FileHandle.standardError.write(
        Data("menubarwatch: usage: menubarwatch <reveal-script>\n".utf8))
    exit(1)
}

let pollInterval = 0.05

// Falls back to the status bar thickness because an external display with the
// menu bar hidden reports no top inset at all, which would collapse the
// hysteresis window to nothing.
func menuBarHeight(of screen: NSScreen) -> CGFloat {
    max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
}

func screenUnderCursor(_ point: NSPoint) -> NSScreen? {
    NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
}

// The strip height travels with the reveal so the frosted pane matches the menu
// bar on whichever screen the pointer is on. The built-in display's strip is
// 38pt because of the notch, an external one is usually 24pt, and the bar height
// is a single global property, so guessing one value would overshoot somewhere.
// Serialised, and each run is waited on. A fast flick across the top edge can
// queue an `on` and an `off` within a few milliseconds, and letting those two
// sketchybar invocations interleave leaves the bar in a half-applied state with
// the geometry of one and the fill of the other.
let revealQueue = DispatchQueue(label: "menubarwatch.reveal")

// Runs the reveal script and blocks until it exits. Not waitUntilExit: that
// polls on a timer and added ~70ms to every reveal.
func runReveal(_ arguments: [String]) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    task.arguments = [revealScript] + arguments
    let done = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in done.signal() }
    try task.run()
    done.wait()
}

func restoreNow() {
    try? runReveal(["off", "0"])
}

// Coalescing, so the queue can never fall behind the pointer. Each run applies
// whatever the current desired state is at the moment it starts, not the state
// that was current when it was queued, and runs that find nothing changed exit
// without spawning anything. Without this a fast flick queues work that takes
// ~150ms per invocation to drain and the bar keeps reacting to stale positions.
struct BarState: Equatable {
    let revealed: Bool
    let strip: Int
}

let stateLock = NSLock()
var desired = BarState(revealed: false, strip: 0)
var applied: BarState? = nil

func notify(revealed: Bool, stripHeight: CGFloat = 0) {
    stateLock.lock()
    desired = BarState(revealed: revealed, strip: Int(stripHeight.rounded()))
    stateLock.unlock()

    revealQueue.async {
        stateLock.lock()
        let want = desired
        let have = applied
        stateLock.unlock()

        guard want != have else { return }

        do {
            try runReveal([want.revealed ? "on" : "off", String(want.strip)])
            stateLock.lock()
            applied = want
            stateLock.unlock()
        } catch {
            FileHandle.standardError.write(
                Data("menubarwatch: cannot run \(revealScript): \(error)\n".utf8))
        }
    }
}

var revealed = false

// macOS reveals the menu bar once the cursor is within 4pt of the top edge
// (measured: 4pt reveals, 5pt does not), not only at the edge itself.
let revealZone: CGFloat = 4

// Reveal gate: the menu bar may only be opened from a centred band of the top
// edge (MENUBAR_REVEAL_BAND of the screen width, default a third). Once it is
// open the pointer can slide along it to either side, because the gate stands
// down while `revealed` is set.
//
// An Accessibility event tap rewrites any move that would put the cursor in the
// reveal zone outside the band to a ceiling 8pt under the edge, and warps the
// cursor there. The ceiling has to sit clear of the zone: holding it at 3pt
// still revealed. Only plain moves are tapped, so drags reach the top as before.
// Synthetic warps never trigger the reveal, so the gate is tested by posting
// HID mouseMoved events and screenshotting the menu bar.
let revealBand: CGFloat = {
    let raw = ProcessInfo.processInfo.environment["MENUBAR_REVEAL_BAND"].flatMap(Double.init) ?? 0.33
    return CGFloat(min(max(raw, 0), 1))
}()
let gateCeiling: CGFloat = 8

func gatedCeiling(_ cg: CGPoint) -> CGPoint? {
    guard !revealed else { return nil }
    // CG coordinates run top-down from the primary display's top-left corner.
    let primaryHeight = NSScreen.screens[0].frame.height
    let point = NSPoint(x: cg.x, y: primaryHeight - cg.y)
    guard let screen = screenUnderCursor(point) else { return nil }
    let frame = screen.frame
    guard point.y > frame.maxY - revealZone - 1 else { return nil }
    guard abs(point.x - frame.midX) > frame.width * revealBand / 2 else { return nil }

    // A display stacked above makes this edge a crossing, not the menu bar.
    let above = NSPoint(x: point.x, y: frame.maxY + 1)
    if NSScreen.screens.contains(where: { $0 != screen && NSMouseInRect(above, $0.frame, false) }) {
        return nil
    }
    return CGPoint(x: cg.x, y: primaryHeight - (frame.maxY - gateCeiling))
}

var gateTap: CFMachPort? = nil
gateTap = CGEvent.tapCreate(
    tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
    eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
    callback: { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = gateTap { CGEvent.tapEnable(tap: tap, enable: true) }
        } else if let held = gatedCeiling(event.location) {
            event.location = held
            CGWarpMouseCursorPosition(held)
        }
        return Unmanaged.passUnretained(event)
    }, userInfo: nil)

if let tap = gateTap {
    // A warp otherwise freezes the pointer for 250ms.
    CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
} else {
    FileHandle.standardError.write(Data(
        "menubarwatch: no Accessibility grant, menu bar reveals from the whole top edge\n".utf8))
}

let timer = Timer(timeInterval: pollInterval, repeats: true) { _ in
    let point = NSEvent.mouseLocation
    guard let screen = screenUnderCursor(point) else { return }

    let top = screen.frame.maxY
    let strip = menuBarHeight(of: screen)
    let nowRevealed: Bool
    if revealed {
        nowRevealed = point.y >= top - strip
    } else {
        nowRevealed = point.y > top - revealZone - 1
    }

    if nowRevealed != revealed {
        revealed = nowRevealed
        notify(revealed: revealed, stripHeight: strip)
    }

}

RunLoop.main.add(timer, forMode: .common)

// Leaving the bar stuck in its receded state would be worse than crashing, so
// restore it on the way out no matter which signal arrives. The sources are
// retained deliberately; ARC would otherwise tear them down immediately.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        // Synchronous: notify() is queued and asynchronous, so exiting straight
        // after it would kill the process before the restore ever ran.
        if revealed { revealQueue.sync { restoreNow() } }
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

// An application event loop rather than a bare run loop. Without one, NSScreen
// never refreshes: the layout read at start is the layout forever, and after a
// lid opens or closes both the reveal and the cursor gate above were working
// from displays that no longer existed, which revealed the bar at the wrong
// moments (pills gone, cards shut) and held the cursor in odd places. With
// the app running, AppKit tracks the displays itself.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// And when they change, start from rest: a reveal in progress was measured
// against the old layout, so it is undone rather than trusted.
NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
) { _ in
    if revealed {
        revealed = false
        notify(revealed: false, stripHeight: 0)
    }
}

app.run()
