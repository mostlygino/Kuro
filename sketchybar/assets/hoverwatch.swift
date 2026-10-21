// Runs the bar's popup cards: opens one when its badge is clicked, animates it
// in, and closes it when the badge is clicked again or once the pointer has been
// off the badge and the card for `closeGrace`.
//
// It closed the moment the pointer left the two until 2026-10-12, and in use a
// card shut while you reached for it: the drop from the badge to the card's
// first row crosses a strip that is neither, and a 40ms poll always sees it.
//
//   hoverwatch <item> [<item> ...]   the watcher, started by hover_watch.sh
//   hoverwatch toggle <item>         what a badge's click runs (card_click.sh):
//                                    open that card, or close it if it is open
//
// Cards opened on hover, after a short dwell, until 2026-09-29. Hovering near
// the top of the screen also brings the real menu bar down over the bar, which
// greyed the badges out and shut the card, so a click opens them now. The
// pointer is still watched, for closing and for the OrbStack rows' two buttons,
// and the reason it is read directly is below.
//
// The measurement, with a probe item and the pointer parked motionless on top of
// it, confirmed by a screenshot with the cursor drawn: thirteen `mouse.exited` in
// three seconds and not one `mouse.entered`. Stop `mediawatch` and the noise
// stops with it, so the cause is the Now Playing disc spinning at 24fps. Every
// frame is a `--set`, every `--set` re-evaluates hover, and a pointer that has
// not moved since the last real mouse event resolves as outside. A popup driven
// by those events flickers itself shut in the moment you look at it.
//
// So the pointer is read directly instead, on the same principle menubarwatch
// already runs on: poll `NSEvent` rather than trust an event stream that is not
// telling the truth here.
//
// Cheap by construction. The poll does nothing but one pointer read while the
// cursor is anywhere below the bar, which is almost always. Only when it enters
// the strip does this start asking SketchyBar where its items are, and those
// answers are cached for a second.
//
// Usage: swiftc -O hoverwatch.swift -o hoverwatch

import AppKit
import CoreGraphics
import Foundation

let toggleNotification = Notification.Name("sketchybar.hoverwatch.toggle")

// The click side: hand the item to the running watcher and leave. A separate
// process per click, like `motionwatch tween`, so a click script stays one line.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "toggle" {
    DistributedNotificationCenter.default().postNotificationName(
        toggleNotification, object: nil, userInfo: ["item": CommandLine.arguments[2]],
        deliverImmediately: true)
    exit(0)
}

let targets = Array(CommandLine.arguments.dropFirst())

guard !targets.isEmpty else {
    FileHandle.standardError.write(Data("hoverwatch: usage: hoverwatch <item> ...\n".utf8))
    exit(1)
}

let sketchybar = "/opt/homebrew/bin/sketchybar"

// Hooks live next to the plugins, one per item, named for it. The binary sits in
// assets/, so the sibling directory is two steps away.
let pluginDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("plugins")
let pollInterval: TimeInterval = 0.04
let rectLifetime: TimeInterval = 1.0

// How far below the bar the pointer still counts as "worth looking at". The bar
// is a 66pt band at a 6pt offset and the cards hang another 30 to 110pt under
// it, so anything above this is in play and anything below it cannot be.
let watchedHeight: CGFloat = 220

// How long the pointer may be off the badge and its card before the card shuts.
let closeGrace: TimeInterval = 5
var outsideSince: Date?

func run(_ arguments: [String]) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: sketchybar)
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
    } catch {
        return ""
    }
    // End of stdout is the CLI exiting, so this already waits for sketchybar to
    // have handled the message. No waitUntilExit: it polls on a timer and made
    // every call 70ms instead of 5, which put ~0.5s on each hover card.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Every rectangle an item occupies, one per display it is drawn on.
func rects(of item: String) -> [CGRect] {
    guard let data = run(["--query", item]).data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let bounds = root["bounding_rects"] as? [String: Any]
    else { return [] }

    return bounds.values.compactMap { entry in
        guard let entry = entry as? [String: Any],
              let origin = entry["origin"] as? [Double],
              let size = entry["size"] as? [Double],
              origin.count == 2, size.count == 2,
              // An item that is not drawn reports itself parked far off-screen.
              origin[0] > -9000
        else { return nil }
        return CGRect(x: origin[0], y: origin[1], width: size[0], height: size[1])
    }
}

func popupMembers(of item: String) -> [String] {
    guard let data = run(["--query", item]).data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let popup = root["popup"] as? [String: Any],
          let items = popup["items"] as? [String]
    else { return [] }
    return items
}

var itemRects: [String: [CGRect]] = [:]
var rectsTakenAt: Date = .distantPast

func refreshItemRects() {
    // Never while a card is open. An item with its popup drawn reports the
    // popup's rectangle rather than its own, so refreshing here would move the
    // hover target out from under the pointer and shut the card the moment it
    // opened. The rectangle taken just before opening is the honest one and it
    // cannot have moved while the pointer is sitting on it.
    guard openTarget == nil else { return }
    guard Date().timeIntervalSince(rectsTakenAt) > rectLifetime else { return }
    for target in targets { itemRects[target] = rects(of: target) }
    rectsTakenAt = Date()
}

var openTarget: String?
// The card's own footprint, measured once when it opens. It cannot be derived
// from the parent: a popup is aligned left, centre or right of it and is as wide
// as its widest member.
var openZone: [CGRect] = []
// Other scripts close cards too: menubar_reveal.sh shuts every one when the real
// menu bar comes down. Nothing tells this process, so it went on believing the
// card was open, and resting on that badge again did nothing, the card being
// "already open", until the pointer went far enough down the screen to reset.
// While the pointer rests on the open badge, ask now and then whether its card
// is really still up.
let verifyEvery: TimeInterval = 0.5
var verifiedAt: Date = .distantPast

func popupIsDrawn(_ item: String) -> Bool {
    guard let data = run(["--query", item]).data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let popup = root["popup"] as? [String: Any]
    // Unanswered (the bar can be busy) counts as still open: a guess that
    // closes a card under the pointer is worse than one more tick of waiting.
    else { return true }
    return (popup["drawing"] as? String) != "off"
}

func measureOpenZone(_ target: String) {
    openZone = (itemRects[target] ?? []) + popupMembers(of: target).flatMap(rects(of:))
}

/// Anything that has to be re-read the moment a card appears rather than on a
/// timer. `plugins/on_open_<item>.sh`, run if it exists and nothing if it does
/// not.
///
/// The transport strip is why this exists. Its play/pause glyph was only ever
/// refreshed by a click, so opening the card by hover showed whatever the last
/// click had left, which is wrong the moment the player is touched from the
/// media keys or from inside the app. SketchyBar's own `media_change` would have
/// been the right signal and it never fires on macOS 26: MediaRemote is locked
/// down, which is the same reason mediawatch exists at all. Measured with a
/// probe item subscribed to it across a play and a pause: no events.
func runOpenHook(_ target: String) {
    let hook = pluginDirectory.appendingPathComponent("on_open_\(target).sh")
    guard FileManager.default.isExecutableFile(atPath: hook.path) else { return }
    // Detached, because a hook that shells out to a player must never hold up
    // the card it belongs to.
    let task = Process()
    task.executableURL = hook
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
}

/// How a card arrives: it drops the last few points from the badge into place
/// while its capsule fades up, the way a system menu settles rather than
/// appearing. The resting values are read from the card itself the first time
/// it opens, so the rc stays the one place they are written.
struct PopupStyle {
    var yOffset: Int
    var fill: String
    var border: String
    var shadow: String
}

let popupDrop = 4
let popupArriveMs = 220
var popupStyles: [String: PopupStyle] = [:]

// The resting style every card shares, from colors.sh through the environment
// sketchybarrc exports. It used to be read back from each card the first time
// it opened, which learned whatever was on screen at that moment: a card still
// fading in after a restart, or a fade cut short, was cached half-transparent
// and from then on faded in to that, a card with no background.
let restingStyle: PopupStyle? = {
    let env = ProcessInfo.processInfo.environment
    guard let y = env["CARD_Y_OFFSET"].flatMap({ Int($0) }),
          let fill = env["PILL_COLOR"], let border = env["BORDER_COLOR"],
          let shadow = env["SHADOW_COLOR"]
    else { return nil }
    return PopupStyle(yOffset: y, fill: fill, border: border, shadow: shadow)
}()

func popupStyle(of item: String) -> PopupStyle? {
    if let restingStyle { return restingStyle }
    if let known = popupStyles[item] { return known }
    guard let data = run(["--query", item]).data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let popup = root["popup"] as? [String: Any],
          let yOffset = popup["y_offset"] as? Int,
          let background = popup["background"] as? [String: Any],
          let fill = background["color"] as? String,
          let border = background["border_color"] as? String,
          let shadow = (background["shadow"] as? [String: Any])?["color"] as? String
    else { return nil }
    let style = PopupStyle(yOffset: yOffset, fill: fill, border: border, shadow: shadow)
    popupStyles[item] = style
    return style
}

/// The colour with its alpha byte cleared, so a fade changes nothing else.
func clear(_ color: String) -> String {
    color.count == 10 ? "0x00" + color.dropFirst(4) : color
}

let motionPidFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/sketchybar/motion/.pid")

func motionwatchRunning() -> Bool {
    guard let text = try? String(contentsOf: motionPidFile, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return false }
    return kill(pid, 0) == 0
}

func open(_ target: String) {
    var arguments: [String] = []
    for other in targets where other != target {
        arguments += ["--set", other, "popup.drawing=off"]
    }
    // Without motionwatch there is nothing to animate with, and the card opens
    // at rest exactly as it did before.
    let style = motionwatchRunning() ? popupStyle(of: target) : nil
    if let style {
        // The starting point goes in the same message that opens the card, so
        // it never shows one frame at rest before the animation begins.
        arguments += ["--set", target,
                      "popup.y_offset=\(style.yOffset - popupDrop)",
                      "popup.background.color=\(clear(style.fill))",
                      "popup.background.border_color=\(clear(style.border))",
                      "popup.background.shadow.color=\(clear(style.shadow))"]
    }
    arguments += ["--set", target, "popup.drawing=on"]
    _ = run(arguments)
    if let style {
        let ms = String(popupArriveMs)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("sketchybar.motionwatch.tween"), object: nil,
            userInfo: ["args": [
                target, "popup.y_offset", String(style.yOffset - popupDrop), String(style.yOffset), "0", ms, "out",
                target, "popup.background.color", clear(style.fill), style.fill, "0", ms, "out",
                target, "popup.background.border_color", clear(style.border), style.border, "0", ms, "out",
                target, "popup.background.shadow.color", clear(style.shadow), style.shadow, "0", ms, "out",
            ]],
            deliverImmediately: true)
    }
    openTarget = target
    outsideSince = nil
    runOpenHook(target)
    // Measured only once the card has settled. Measuring is a query per card row,
    // and firing those at SketchyBar while it draws the arrival tween is what made
    // the animation stutter. Until then the badge alone counts, which is where
    // the pointer is; the tick measures early anyway if the pointer leaves it.
    openZone = itemRects[target] ?? []
    let settle = style != nil ? Double(popupArriveMs + 40) / 1000 : 0
    DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
        if openTarget == target { measureOpenZone(target) }
    }
}

/// Where the pointer is while a card is open, for click scripts. SketchyBar
/// tells a click_script which button was pressed and nothing about where, so a
/// row with two things to click, the OrbStack rows' name and state, reads this
/// to tell them apart. Written only while a card is open, and only when it moved.
let pointerFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/sketchybar/hover/pointer")
var lastRecorded: CGPoint?

func recordPointer(_ pointer: CGPoint) {
    guard pointer != lastRecorded else { return }
    lastRecorded = pointer
    try? FileManager.default.createDirectory(
        at: pointerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? "\(pointer.x) \(pointer.y)\n".write(to: pointerFile, atomically: true, encoding: .utf8)
}

func closeAll() {
    var arguments: [String] = []
    for target in targets { arguments += ["--set", target, "popup.drawing=off"] }
    _ = run(arguments)
    openTarget = nil
    openZone = []
    outsideSince = nil
}

/// Whether the pointer is on the open card's badge or on the card itself.
func isInside(_ current: String, _ pointer: CGPoint) -> Bool {
    let hovered = targets.first { target in
        (itemRects[target] ?? []).contains { $0.contains(pointer) }
    }

    if ProcessInfo.processInfo.environment["HOVERWATCH_DEBUG"] != nil {
        FileHandle.standardError.write(
            Data("pointer \(pointer) over \(hovered ?? "none") card \(current)\n".utf8))
    }

    if hovered == current {
        if Date().timeIntervalSince(verifiedAt) >= verifyEvery {
            verifiedAt = Date()
            // Closed behind this process's back: forget it, so the next click
            // opens it rather than closing a card that is not there.
            if !popupIsDrawn(current) {
                openTarget = nil
                openZone = []
            }
        }
        return true
    }

    // Reaching for a button means leaving the item the card belongs to, so the
    // card's own rectangle has to count as still being here. Measured late if it
    // came up empty: a popup laid out in the same frame it was opened sometimes
    // reports nothing yet.
    if openZone.count <= (itemRects[current] ?? []).count { measureOpenZone(current) }
    return openZone.contains(where: { $0.contains(pointer) })
}

let timer = Timer(timeInterval: pollInterval, repeats: true) { _ in
    // With no card up there is nothing to do: nothing opens from here any more,
    // so a tick is one property read.
    guard let current = openTarget, let pointer = CGEvent(source: nil)?.location else { return }

    // An open card can reach further down than the band, the OrbStack card
    // with a row per project in particular, so the band follows its bottom edge.
    // Below it the pointer cannot be on the card, and nothing is asked.
    let limit = max(watchedHeight, openZone.map(\.maxY).max() ?? 0)
    if pointer.y <= limit {
        recordPointer(pointer)
        if isInside(current, pointer) {
            outsideSince = nil
            return
        }
    }

    let since = outsideSince ?? Date()
    outsideSince = since
    if Date().timeIntervalSince(since) >= closeGrace { closeAll() }
}

RunLoop.main.add(timer, forMode: .common)

// A badge was clicked. Its card again closes it; any other opens that one in
// its place. Rectangles are taken fresh, because none are taken while a card is
// open and the badges may have moved since.
DistributedNotificationCenter.default().addObserver(
    forName: toggleNotification, object: nil, queue: .main
) { note in
    guard let item = note.userInfo?["item"] as? String, targets.contains(item) else { return }
    if openTarget == item, popupIsDrawn(item) {
        closeAll()
        return
    }
    if openTarget != nil { closeAll() }
    rectsTakenAt = .distantPast
    refreshItemRects()
    open(item)
}

// Put every card back at rest on start, so one left half-faded by the last
// instance (killed mid-arrival on a reload) is whole again.
if let style = restingStyle {
    var reset: [String] = []
    for target in targets {
        reset += ["--set", target, "popup.y_offset=\(style.yOffset)",
                  "popup.background.color=\(style.fill)",
                  "popup.background.border_color=\(style.border)",
                  "popup.background.shadow.color=\(style.shadow)"]
    }
    _ = run(reset)
}

// Leaving a card stuck open would outlast this process, so shut them on the way
// out however that happens.
for signal in [SIGTERM, SIGINT] {
    let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
    source.setEventHandler { closeAll(); exit(0) }
    source.resume()
    Foundation.signal(signal, SIG_IGN)
}

RunLoop.main.run()
