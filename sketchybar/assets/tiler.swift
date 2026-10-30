// Kuro's window layouts, on top of AeroSpace: pick one for a screen and every
// window there takes its place in it, the way Shoji does it.
//
//   tiler                  keeps the layouts: follows AeroSpace's events
//   tiler set <layout>     the focused screen's layout, then a pass now
//   tiler pass             one pass over every screen, now
//   tiler --self-test      checks the planner against made-up windows
//
// Layouts: off (AeroSpace as it is), columns, rows, and side (one window on
// the left, the rest stacked on the right). A screen takes so many panes, five
// on an ultrawide, four on a landscape screen and three on a portrait one;
// more windows than that stack in the last pane as an accordion.
//
// What a screen uses is in ~/.config/kuro/layouts, written by `tiler set` and
// the Kuro app, a line a screen by AeroSpace's name for it:
//
//   P34WD-40=columns
//   P34WD-40.panes=5
//   side_width=0.6
//
// A pass leaves a workspace alone until its windows change: rearrange one by
// hand and it stays so until a window opens or closes there, or its layout is
// picked again. Never while the screens are settling (display_settle.sh's and
// aerospace_sync.sh's locks): AeroSpace crashes on commands that land in the
// middle of a monitor change, see aerospace_sync.sh. Agent spaces, F1 to F12,
// are left as AeroSpace has them.
//
// Usage: swiftc -O tiler.swift -o tiler

import AppKit
import Foundation

enum Layout: String, CaseIterable { case off, columns, rows, side }

/// The AeroSpace commands that put these windows, in this order, into the
/// layout. `ids` is the order on screen: left to right (top to bottom for
/// rows). `panes` is how many the screen takes before the rest stack.
func plan(_ ids: [Int], _ layout: Layout, workspace: String, panes: Int, mainWidth: Int?) -> [[String]] {
    guard layout != .off, !ids.isEmpty else { return [] }
    let panes = max(2, panes)
    let ws = workspace
    var commands: [[String]] = [["flatten-workspace-tree", "--workspace", ws]]
    switch layout {
    case .off:
        return []
    case .columns, .rows:
        let columns = layout == .columns
        commands.append(["layout", "--workspace", ws, "--root", columns ? "h_tiles" : "v_tiles"])
        if ids.count > panes {
            // The last pane takes the rest: join the first extra to it, which
            // makes a container across the other way, then move each further
            // one into that container.
            let toward = columns ? "left" : "up"
            commands.append(["join-with", "--window-id", String(ids[panes]), toward])
            for id in ids[(panes + 1)...] { commands.append(["move", "--window-id", String(id), toward]) }
            commands.append(["layout", "--window-id", String(ids[panes - 1]), columns ? "v_accordion" : "h_accordion"])
        }
        commands.append(["balance-sizes", "--workspace", ws])
    case .side:
        commands.append(["layout", "--workspace", ws, "--root", "h_tiles"])
        if ids.count >= 3 {
            commands.append(["join-with", "--window-id", String(ids[2]), "left"])
            for id in ids[3...] { commands.append(["move", "--window-id", String(id), "left"]) }
            if ids.count - 1 > panes - 1 {
                commands.append(["layout", "--window-id", String(ids[1]), "v_accordion"])
            }
        }
        commands.append(["balance-sizes", "--workspace", ws])
        if ids.count >= 2, let width = mainWidth {
            commands.append(["resize", "--window-id", String(ids[0]), "width", String(width)])
        }
    }
    return commands
}

if CommandLine.arguments.contains("--self-test") {
    var failures = 0
    func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL", what) } }
    let one = plan([1], .columns, workspace: "1", panes: 4, mainWidth: nil)
    expect(one.first == ["flatten-workspace-tree", "--workspace", "1"], "a pass starts flat")
    expect(one.contains(["layout", "--workspace", "1", "--root", "h_tiles"]), "columns are h_tiles")
    expect(!one.contains { $0.first == "join-with" }, "no stack under the limit")
    let six = plan([1, 2, 3, 4, 5, 6], .columns, workspace: "2", panes: 4, mainWidth: nil)
    expect(six.contains(["join-with", "--window-id", "5", "left"]), "the first extra joins the last pane")
    expect(six.contains(["move", "--window-id", "6", "left"]), "the next extra moves into it")
    expect(six.contains(["layout", "--window-id", "4", "v_accordion"]), "the last pane is an accordion")
    let rows = plan([1, 2, 3, 4], .rows, workspace: "3", panes: 3, mainWidth: nil)
    expect(rows.contains(["layout", "--workspace", "3", "--root", "v_tiles"]), "rows are v_tiles")
    expect(rows.contains(["join-with", "--window-id", "4", "up"]), "rows stack upward")
    let side = plan([7, 8, 9, 10], .side, workspace: "4", panes: 4, mainWidth: 1200)
    expect(side.contains(["join-with", "--window-id", "9", "left"]), "the stack starts with the second and third")
    expect(side.contains(["move", "--window-id", "10", "left"]), "the rest join the stack")
    expect(!side.contains { $0.contains("v_accordion") }, "three in the stack still tile")
    expect(side.last == ["resize", "--window-id", "7", "width", "1200"], "the main window last, to its width")
    expect(plan([1, 2], .side, workspace: "5", panes: 4, mainWidth: 900).contains { $0.first == "resize" }, "two windows side by side")
    expect(plan([1, 2], .off, workspace: "6", panes: 4, mainWidth: nil).isEmpty, "off does nothing")
    print(failures == 0 ? "tiler: self-test passed" : "tiler: \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}

// ── Talking to AeroSpace, one command at a time.

let aerospace = "/opt/homebrew/bin/aerospace"

@discardableResult
func run(_ arguments: [String], timeout: TimeInterval = 4) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: aerospace)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let deadline = DispatchTime.now() + timeout
    DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}

func lines(_ arguments: [String]) -> [String] {
    (run(arguments) ?? "").split(separator: "\n").map(String.init)
}

// ── The settings file.

let home = FileManager.default.homeDirectoryForCurrentUser
let layoutsFile = home.appendingPathComponent(".config/kuro/layouts")
let appliedFile = home.appendingPathComponent(".cache/kuro/tiler-applied")

struct Settings {
    var layouts: [String: Layout] = [:]
    var panes: [String: Int] = [:]
    var sideWidth = 0.6

    static func load() -> Settings {
        var settings = Settings()
        let text = (try? String(contentsOf: layoutsFile, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            // The last `=`: a screen's name can hold one, a value never does.
            guard let equals = line.lastIndex(of: "=") else { continue }
            let key = String(line[..<equals]), value = String(line[line.index(after: equals)...])
            if key == "side_width", let width = Double(value), (0.3...0.8).contains(width) {
                settings.sideWidth = width
            } else if key.hasSuffix(".panes"), let n = Int(value), (2...8).contains(n) {
                settings.panes[String(key.dropLast(6))] = n
            } else if let layout = Layout(rawValue: value) {
                settings.layouts[key] = layout
            }
        }
        return settings
    }

    /// One screen's layout, written back with every other line kept.
    static func set(_ layout: Layout, for screen: String) {
        var kept = ((try? String(contentsOf: layoutsFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix(screen + "=") && !$0.hasPrefix("#") }
        kept.append("\(screen)=\(layout.rawValue)")
        let text = "# Written by Kuro's tiler and the Kuro app: a layout a screen.\n" + kept.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: layoutsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: layoutsFile, atomically: true, encoding: .utf8)
    }
}

/// What each workspace was last laid out as, so a pass can leave it alone
/// until its windows change. Shared between the daemon and `tiler set`.
func loadApplied() -> [String: String] {
    var applied: [String: String] = [:]
    for line in ((try? String(contentsOf: appliedFile, encoding: .utf8)) ?? "").split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1)
        if parts.count == 2 { applied[String(parts[0])] = String(parts[1]) }
    }
    return applied
}

func saveApplied(_ applied: [String: String]) {
    let text = applied.map { "\($0.key)\t\($0.value)" }.sorted().joined(separator: "\n") + "\n"
    try? FileManager.default.createDirectory(at: appliedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: appliedFile, atomically: true, encoding: .utf8)
}

// ── A pass.

/// A screen as AeroSpace names it, with its size from AppKit.
struct Screen {
    let name: String
    let width: Double
    let height: Double
    /// Five on an ultrawide, three on a portrait screen, four otherwise.
    var defaultPanes: Int { width / height >= 2 ? 5 : (height > width ? 3 : 4) }
}

func screen(appkitIndex: String, name: String) -> Screen? {
    guard let index = Int(appkitIndex), index >= 1, index <= NSScreen.screens.count else { return nil }
    let frame = NSScreen.screens[index - 1].visibleFrame
    return Screen(name: name, width: frame.width, height: frame.height)
}

/// Where each window is on screen right now, by its id: the order to keep.
func frames() -> [Int: CGRect] {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    var out: [Int: CGRect] = [:]
    for window in list {
        guard let id = window[kCGWindowNumber as String] as? Int,
              let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"]
        else { continue }
        out[id] = CGRect(x: x, y: y, width: w, height: h)
    }
    return out
}

func settling() -> Bool {
    let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/"
    let base = tmp.hasSuffix("/") ? tmp : tmp + "/"
    return ["sketchybar-display-settle.lock", "sketchybar-aerospace-sync.lock"]
        .contains { FileManager.default.fileExists(atPath: base + $0) }
}

/// Lays out every visible workspace whose windows or layout changed since the
/// last pass, or `force`d ones (`tiler set`) whatever they were.
func pass(force: Set<String> = []) {
    if settling() { return }
    let settings = Settings.load()
    var applied = loadApplied()
    let onScreen = frames()
    let format = "%{workspace}|%{monitor-name}|%{monitor-appkit-nsscreen-screens-id}"
    for line in lines(["list-workspaces", "--monitor", "all", "--visible", "--format", format]) {
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 3, !f[0].hasPrefix("F") || Int(f[0].dropFirst()) == nil,
              let screen = screen(appkitIndex: f[2], name: f[1]) else { continue }
        let ws = f[0]
        let layout = settings.layouts[screen.name] ?? .off
        let windows = lines(["list-windows", "--workspace", ws, "--format", "%{window-id}|%{window-layout}|%{window-is-fullscreen}"])
            .map { $0.split(separator: "|").map(String.init) }
        if windows.contains(where: { $0.count == 3 && $0[2] == "true" }) { continue }
        let tiled = windows.filter { $0.count == 3 && $0[1] != "floating" }.compactMap { Int($0[0]) }
        let panes = settings.panes[screen.name] ?? screen.defaultPanes
        let signature = "\(layout.rawValue) \(panes) \(settings.sideWidth) " + tiled.sorted().map(String.init).joined(separator: ",")
        guard force.contains(ws) || applied[ws] != signature else { continue }
        applied[ws] = signature
        guard layout != .off else { continue }
        let order = tiled.sorted { a, b in
            let fa = onScreen[a] ?? .zero, fb = onScreen[b] ?? .zero
            if layout == .rows { return (fa.minY, fa.minX, a) < (fb.minY, fb.minX, b) }
            return (fa.minX, fa.minY, a) < (fb.minX, fb.minY, b)
        }
        let mainWidth = Int(screen.width * settings.sideWidth)
        for command in plan(order, layout, workspace: ws, panes: panes, mainWidth: mainWidth) { run(command) }
    }
    saveApplied(applied)
}

// ── The commands.

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "set":
    guard arguments.count == 2, let layout = Layout(rawValue: arguments[1]) else {
        FileHandle.standardError.write(Data("tiler: set off|columns|rows|side\n".utf8)); exit(2)
    }
    guard let line = lines(["list-workspaces", "--focused", "--format", "%{workspace}|%{monitor-name}"]).first else { exit(1) }
    let f = line.split(separator: "|", maxSplits: 1).map(String.init)
    guard f.count == 2 else { exit(1) }
    Settings.set(layout, for: f[1])
    pass(force: [f[0]])
    exit(0)
case "pass":
    pass()
    exit(0)
case nil:
    break
default:
    FileHandle.standardError.write(Data("tiler: set <layout> | pass | --self-test\n".utf8)); exit(2)
}

// The daemon: a pass after AeroSpace's events, the burst a new app sends
// counted as one. AeroSpace restarting ends the stream; then this waits for it
// and subscribes again, and goes when it does not come back.
let queue = DispatchQueue(label: "tiler")
var pending: DispatchWorkItem?
func soon(_ delay: Double = 0.4) {
    queue.async {
        pending?.cancel()
        let work = DispatchWorkItem {
            pass()
            // The screens were settling: look again once they are done.
            if settling() { soon(1.5) }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var heard = false
    func yes() { lock.lock(); heard = true; lock.unlock() }
    var any: Bool { lock.lock(); defer { lock.unlock() }; return heard }
}

var missing = 0
while missing < 30 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: aerospace)
    process.arguments = ["subscribe", "window-detected", "focus-changed", "focused-workspace-changed", "focused-monitor-changed"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let heard = Collected()
    if (try? process.run()) != nil {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil } else { heard.yes(); soon() }
        }
        process.waitUntilExit()
    }
    // A stream that said nothing is AeroSpace not running.
    missing = heard.any ? 0 : missing + 1
    Thread.sleep(forTimeInterval: 2)
}
