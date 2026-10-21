// Plays the badges' transitions: when a badge changes state, the frames that
// take it from the old drawing to the new one, then the new still.
//
//   motionwatch
//
// The plugins decide *what* a badge shows and render it as frames; this decides
// *when* each frame is on screen. A plugin cannot do that itself: it is a shell
// script, and a transition is 22 images in 0.6s.
//
// Each badge registers by writing a small file into the registry directory:
//
//   ~/.cache/sketchybar/motion/<item>
//     state=<the badge's state key>
//     still=<the PNG the badge rests on>
//     transition=<directory of frame-NN.png, or empty>
//
// plugins/motion.sh writes these. A new state plays the transition once and
// then puts the still up. Between changes nothing moves and nothing is sent:
// the badges breathed once, all the time, and that was one thing too many on
// a bar whose job is to be glanced at.
//
// Frames go to SketchyBar over the same IPC mediawatch uses, one message per
// tick for every badge that moved, rather than one `sketchybar` process per
// frame.
//
// It also runs property tweens for anything else on the bar, because
// SketchyBar's own `--animate` does nothing on this machine:
//
//   motionwatch tween <item> <property> <from> <to> <start-ms> <ms> <curve> ...
//
// Groups of seven, any number of them. `from` is a value, `-` for wherever the
// property last was, or `=` to set `to` outright at `start-ms`, which is how a
// glyph or a label swaps halfway through a fade. Values are 0xAARRGGBB colours
// or numbers. Curves: linear, out, inout, spring. That form is a client: it
// hands the request to the running motionwatch and exits, and if none is
// running it sets the final values itself, so a caller never has to care.
//
// Usage: swiftc -O -import-objc-header sketchybar_ipc.h motionwatch.swift \
//          sketchybar_ipc.c -o motionwatch

import Foundation

// 60fps, the display's own rate, so a badge moves as smoothly as the window
// behind it. It was 36 until 2026-09-29, and before that 12, which read as a
// stutter rather than as motion; 36 was smooth enough to pass and still looked
// stepped next to the 60fps tweens on the same bar. The renderers draw 36
// frames for their 0.6s. The timer only runs while something is playing.
let framesPerSecond = 60.0
// How often the registry is re-read for new states. A change reaching the
// screen a fifth of a second after its plugin finished is well inside the time
// the plugin itself took.
let registryInterval = 0.2

let registry = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/sketchybar/motion", isDirectory: true)

struct Entry {
    var state = ""
    var still = ""
    var transition: [String] = []
    // Where playback is: negative while the transition plays, counting up to
    // zero, where the still goes up.
    var cursor = 0
    var lastSent = ""

    var isSettled: Bool { cursor >= 0 && lastSent == still }
}

var entries: [String: Entry] = [:]
// The first read after a start finds whatever state each badge was left in, and
// the transition beside it is from before this process existed. Playing it
// would replay an old change on every reload.
var firstRead = true

func frames(in directory: String) -> [String] {
    guard !directory.isEmpty,
          let names = try? FileManager.default.contentsOfDirectory(atPath: directory)
    else { return [] }
    return names.filter { $0.hasPrefix("frame-") && $0.hasSuffix(".png") }
        .sorted()
        .map { directory + "/" + $0 }
}

func parse(_ text: String) -> [String: String] {
    var fields: [String: String] = [:]
    for line in text.split(separator: "\n") {
        guard let eq = line.firstIndex(of: "=") else { continue }
        fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
    }
    return fields
}

// Every registry write is a rename into the directory, which moves the
// directory's modification time; when that has not moved, nothing has changed
// and the files are not read at all. That is most ticks.
var lastRegistryChange: Date?

// Returns whether anything now has frames to play.
func readRegistry() -> Bool {
    let fm = FileManager.default
    try? fm.createDirectory(at: registry, withIntermediateDirectories: true)
    let changed = (try? fm.attributesOfItem(atPath: registry.path))?[.modificationDate] as? Date
    if let changed, changed == lastRegistryChange { return false }
    lastRegistryChange = changed
    let names = (try? fm.contentsOfDirectory(atPath: registry.path)) ?? []
    let present = Set(names.filter { !$0.hasPrefix(".") })

    // A badge whose file is gone is no longer animated. Its still stays on the
    // bar, which is the plugin's to replace.
    for gone in Set(entries.keys).subtracting(present) { entries[gone] = nil }

    for item in present {
        let path = registry.appendingPathComponent(item).path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        let fields = parse(text)
        let state = fields["state"] ?? ""
        if entries[item]?.state == state { continue }

        guard let still = fields["still"], !still.isEmpty else { continue }
        let transition = firstRead ? [] : frames(in: fields["transition"] ?? "")
        var entry = entries[item] ?? Entry()
        entry.state = state
        entry.still = still
        entry.transition = transition
        entry.cursor = -transition.count
        entries[item] = entry
    }
    firstRead = false
    return entries.values.contains { !$0.isSettled }
}

func encode(_ args: [String]) -> [UInt8] {
    var buffer: [UInt8] = []
    for arg in args {
        buffer.append(contentsOf: arg.utf8)
        buffer.append(0)
    }
    return buffer
}

func send(_ args: [String]) {
    let buffer = encode(args)
    guard !buffer.isEmpty else { return }
    buffer.withUnsafeBufferPointer { raw in
        guard let base = raw.baseAddress else { return }
        base.withMemoryRebound(to: CChar.self, capacity: raw.count) {
            _ = sketchybar_send_args($0, UInt32(raw.count))
        }
    }
}

// Advances every badge one frame. Returns whether anything is still playing.
func tick(sending: Bool = true) -> Bool {
    var args: [String] = []
    for item in entries.keys.sorted() {
        guard var entry = entries[item], !entry.isSettled else { continue }
        let frame: String
        if entry.cursor < 0 {
            frame = entry.transition[entry.transition.count + entry.cursor]
            entry.cursor += 1
        } else {
            frame = entry.still
        }
        if frame != entry.lastSent {
            args += ["--set", item, "background.image=\(frame)"]
            entry.lastSent = frame
        }
        entries[item] = entry
    }
    if sending, !args.isEmpty { send(args) }
    return entries.values.contains { !$0.isSettled }
}

// MARK: property tweens

let tweenNotification = Notification.Name("sketchybar.motionwatch.tween")
let tweenFramesPerSecond = 60.0
let pidFile = registry.appendingPathComponent(".pid")

enum TweenValue: Equatable {
    case color(r: Double, g: Double, b: Double, a: Double)
    case number(Double, integer: Bool)
    case text(String)

    init(_ raw: String) {
        let hex = raw.lowercased()
        if hex.hasPrefix("0x"), hex.count == 10, let v = UInt32(hex.dropFirst(2), radix: 16) {
            self = .color(r: Double((v >> 16) & 0xff), g: Double((v >> 8) & 0xff),
                          b: Double(v & 0xff), a: Double((v >> 24) & 0xff))
        } else if let n = Double(raw) {
            self = .number(n, integer: !raw.contains("."))
        } else {
            self = .text(raw)
        }
    }

    var string: String {
        switch self {
        case let .color(r, g, b, a):
            let byte = { (x: Double) in UInt32(min(255, max(0, x.rounded()))) }
            return String(format: "0x%02x%02x%02x%02x", byte(a), byte(r), byte(g), byte(b))
        case let .number(n, integer):
            return integer ? String(Int(n.rounded())) : String(format: "%.3f", n)
        case let .text(t):
            return t
        }
    }

    // Colours blend per channel and numbers linearly. Text cannot blend, so it
    // switches at the end.
    func mixed(to other: TweenValue, _ t: Double) -> TweenValue {
        switch (self, other) {
        case let (.color(r0, g0, b0, a0), .color(r1, g1, b1, a1)):
            return .color(r: r0 + (r1 - r0) * t, g: g0 + (g1 - g0) * t,
                          b: b0 + (b1 - b0) * t, a: a0 + (a1 - a0) * t)
        case let (.number(n0, i0), .number(n1, i1)):
            return .number(n0 + (n1 - n0) * t, integer: i0 && i1)
        default:
            return t >= 1 ? other : self
        }
    }
}

func curveValue(_ name: String, _ t: Double) -> Double {
    let c = min(1, max(0, t))
    switch name {
    case "out": return 1 - pow(1 - c, 3)
    case "inout": return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
    // Damped, about 6% past the target, settled by the end.
    case "spring": return c >= 1 ? 1 : 1 - exp(-6.5 * c) * cos(2.4 * .pi * c)
    default: return c
    }
}

struct Tween {
    var item: String
    var property: String
    // nil until the tween starts. `-` is resolved then, against wherever the
    // property is by that moment, which may be the end of an earlier segment.
    var from: TweenValue?
    var fromLast: Bool
    var to: TweenValue
    var start: Double
    var duration: Double
    var curve: String
    var key: String { item + "\u{1}" + property }
}

var tweens: [Tween] = []
// Where each tweened property was last put, so `-` carries on from it and an
// interrupted tween starts the next one from where it actually is.
var lastValues: [String: TweenValue] = [:]

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func parseTweens(_ args: [String], at base: Double) -> [Tween]? {
    guard !args.isEmpty, args.count % 7 == 0 else { return nil }
    return stride(from: 0, to: args.count, by: 7).compactMap { i in
        guard let startMs = Double(args[i + 4]), let ms = Double(args[i + 5]) else { return nil }
        let from = args[i + 2]
        let isSet = from == "="
        return Tween(
            item: args[i], property: args[i + 1],
            from: isSet || from == "-" ? nil : TweenValue(from),
            fromLast: from == "-",
            to: TweenValue(args[i + 3]),
            start: base + startMs / 1000, duration: isSet ? 0 : ms / 1000,
            curve: args[i + 6])
    }
}

// A new request for a property replaces whatever was still queued for it, so
// the latest intent wins and nothing from an older one lands afterwards.
func addTweens(_ incoming: [Tween]) {
    let keys = Set(incoming.map(\.key))
    tweens.removeAll { keys.contains($0.key) }
    tweens += incoming
}

// Advances every started tween. Returns whether any remain.
func tweenTick(at time: Double, sending: Bool = true) -> Bool {
    var args: [String] = []
    var remaining: [Tween] = []
    for var tween in tweens {
        guard time >= tween.start else { remaining.append(tween); continue }
        if tween.from == nil {
            // Nothing known to start from means nothing to animate: land it.
            tween.from = tween.fromLast ? (lastValues[tween.key] ?? tween.to) : tween.to
        }
        let progress = tween.duration <= 0 ? 1 : (time - tween.start) / tween.duration
        let value = tween.from!.mixed(to: tween.to, curveValue(tween.curve, progress))
        if lastValues[tween.key] != value || progress >= 1 {
            args += ["--set", tween.item, "\(tween.property)=\(value.string)"]
            lastValues[tween.key] = value
        }
        if progress < 1 { remaining.append(tween) }
    }
    tweens = remaining
    if sending, !args.isEmpty { send(args) }
    return !tweens.isEmpty
}

func serverRunning() -> Bool {
    guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return false }
    return kill(pid, 0) == 0
}

// `motionwatch tween ...`: hand the request over and exit, or with no server,
// land the final values here.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "tween" {
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard let parsed = parseTweens(args, at: 0) else {
        FileHandle.standardError.write(Data("motionwatch tween: expected groups of 7 arguments\n".utf8))
        exit(2)
    }
    if serverRunning() {
        DistributedNotificationCenter.default().postNotificationName(
            tweenNotification, object: nil, userInfo: ["args": args], deliverImmediately: true)
    } else {
        // The last segment per property is where it ends up.
        var final: [String: Tween] = [:]
        var order: [String] = []
        for tween in parsed {
            if final[tween.key] == nil { order.append(tween.key) }
            if (final[tween.key]?.start ?? -1) <= tween.start { final[tween.key] = tween }
        }
        send(order.flatMap { key -> [String] in
            let t = final[key]!
            return ["--set", t.item, "\(t.property)=\(t.to.string)"]
        })
    }
    exit(0)
}

// Self-check: `motionwatch --self-test` exercises the playback order without a
// bar to draw on.
if CommandLine.arguments.contains("--self-test") {
    var failures = 0
    func expect(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; FileHandle.standardError.write(Data("fail: \(what)\n".utf8)) }
    }
    let fields = parse("state=84-0xffd97757\nstill=/a.png\ntransition=/b\n")
    expect(fields["still"] == "/a.png" && fields["transition"] == "/b" && fields["state"] == "84-0xffd97757",
           "registry fields parse")
    entries = ["probe": Entry(state: "1", still: "S", transition: ["T0", "T1"], cursor: -2)]
    var played: [String] = []
    var busy = true
    for _ in 0..<5 where busy {
        busy = tick(sending: false)
        played.append(entries["probe"]!.lastSent)
    }
    expect(played == ["T0", "T1", "S"], "transition plays once, then the still, then nothing")
    expect(!busy, "settled once the still is up")

    tweens = parseTweens(["x", "label.color", "0x00ffffff", "0xffffffff", "0", "100", "linear",
                          "x", "label", "=", "B", "50", "0", "linear"], at: 0)!
    _ = tweenTick(at: 0.05, sending: false)
    expect(lastValues["x\u{1}label.color"]?.string == "0x80ffffff", "colour halfway at half time")
    expect(lastValues["x\u{1}label"] == TweenValue("B"), "a set lands at its start")
    let more = tweenTick(at: 0.2, sending: false)
    expect(lastValues["x\u{1}label.color"] == TweenValue("0xffffffff") && !more, "lands on the target")
    addTweens(parseTweens(["x", "label.color", "-", "0x00ffffff", "0", "100", "out"], at: 1)!)
    _ = tweenTick(at: 1, sending: false)
    expect(lastValues["x\u{1}label.color"] == TweenValue("0xffffffff"), "`-` starts where it was")
    expect(TweenValue("12").mixed(to: TweenValue("-20"), 0.5).string == "-4", "integers stay integers")
    exit(failures == 0 ? 0 : 1)
}

// The frame timer runs only while a transition plays, so a bar with nothing
// changing costs one directory read every fifth of a second and nothing else.
let frameTimer = DispatchSource.makeTimerSource(queue: .main)
var framesRunning = false
frameTimer.schedule(deadline: .now(), repeating: 1 / framesPerSecond)
frameTimer.setEventHandler {
    if !tick() {
        frameTimer.suspend()
        framesRunning = false
    }
}

// Property tweens run on their own 60fps timer, again only while one is live.
let tweenTimer = DispatchSource.makeTimerSource(queue: .main)
var tweensRunning = false
tweenTimer.schedule(deadline: .now(), repeating: 1 / tweenFramesPerSecond)
tweenTimer.setEventHandler {
    if !tweenTick(at: now()) {
        tweenTimer.suspend()
        tweensRunning = false
    }
}
DistributedNotificationCenter.default().addObserver(
    forName: tweenNotification, object: nil, queue: .main
) { note in
    guard let args = note.userInfo?["args"] as? [String],
          let parsed = parseTweens(args, at: now()) else { return }
    addTweens(parsed)
    if !tweensRunning {
        tweensRunning = true
        tweenTimer.resume()
    }
}
try? FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
try? String(getpid()).write(to: pidFile, atomically: true, encoding: .utf8)

let registryTimer = DispatchSource.makeTimerSource(queue: .main)
registryTimer.schedule(deadline: .now(), repeating: registryInterval)
registryTimer.setEventHandler {
    if readRegistry(), !framesRunning {
        framesRunning = true
        frameTimer.resume()
    }
}
registryTimer.resume()

// A run loop rather than dispatchMain, because distributed notifications are
// delivered through one.
RunLoop.main.run()
