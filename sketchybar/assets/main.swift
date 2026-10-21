// Entry point only. Everything it calls lives in mediawatch.swift (the pill) and
// mediatap.swift (the audio tap).
//
// This is a separate file because it has to be: Swift allows top-level
// statements in exactly one file per module, and it must be named main.swift.
// The moment the watcher grew a second source file, keeping the run loop at the
// bottom of mediawatch.swift stopped compiling.

import AppKit
import Dispatch
import Foundation
import ImageIO

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--self-test") {
    exit(Int32(selfTest()))
}

// `mediawatch --marks <dir>`: every shape the Now Playing slot can show, one
// still each, as `<name>.png` in <dir>, drawn by the same code the bar uses.
// For docs/make_states.py. A macOS wallpaper stands in for album art.
if args.first == "--marks", args.count == 2 {
    let dir = URL(fileURLWithPath: args[1], isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var art: CGImage?
    if let src = CGImageSourceCreateWithURL(
        URL(fileURLWithPath: "/System/Library/Desktop Pictures/iMac Blue.heic") as CFURL, nil) {
        art = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 300,
        ] as CFDictionary)
    }
    var shapes: [(String, MediaSource)] = [("music", .music), ("podcast", .podcast), ("silence", .silence)]
    shapes += WebService.allCases.map { ($0.rawValue, MediaSource.service($0)) }
    shapes += [("youtube-guess", .youtube), ("browser", .browser), ("call", .call), ("video", .video)]
    shapes += ["com.apple.TV", "com.apple.QuickTimePlayerX", "com.colliderli.iina", "org.videolan.vlc"]
        .filter { hasAppIcon($0) }.map { ($0, MediaSource.videoApp($0)) }
    for (name, source) in shapes {
        let key = cachePrefix + "marks-" + name
        guard let frames = try? renderDiscFrames(image: art, key: key, source: source),
              let first = frames.first else { continue }
        let still = source == .music || source == .podcast ? first : (frames[safe: slotIconRestFrame / 3] ?? first)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name + ".png"))
        try? FileManager.default.copyItem(at: still, to: dir.appendingPathComponent(name + ".png"))
        try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
        print(name)
    }
    exit(0)
}

// `mediawatch --demo`: the running watcher plays a stand-in track out of silence
// and settles back into it three seconds later, so the two walks can be seen,
// tuned and recorded without starting any audio. Does nothing unless the pill
// is resting in silence.
let demoNotification = Notification.Name("sketchybar.mediawatch.demo")
// `mediawatch --demo call` plays a stand-in Teams meeting instead, to see the
// meeting clock without being in one.
if args.first == "--demo" {
    DistributedNotificationCenter.default().postNotificationName(
        demoNotification, object: nil, userInfo: ["kind": args.dropFirst().first ?? "track"],
        deliverImmediately: true)
    exit(0)
}

// `mediawatch --refit`: the workspace pill changed width, so tell the running
// watcher to re-fit the title to its new room, and leave. See mediafit.swift.
if args.first == "--refit" {
    DistributedNotificationCenter.default().postNotificationName(
        refitNotification, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

// Tuning aid for the noise lists. `mediawatch --clean "Song (feat. X)"` prints
// what the bar would show, so a title that cleans up wrong can be checked and
// the lists adjusted without waiting for that track to come round again.
if args.first == "--clean" {
    let input = args.dropFirst().joined(separator: " ")
    print(cleanTitle(sanitizeLabel(input)))
    exit(0)
}

// Measurement aid for the live waveform. `mediawatch --levels [bars] [seconds]`
// taps Spotify and prints what the bars would be doing, plus how much they move
// between frames. Smoothness is a number here, not an opinion: the mean absolute
// frame-to-frame delta is what reads as jitter, and tuning the attack, the rate
// or the band folding without measuring it first is guessing.
//
// Run from inside the app bundle, so it carries the same signing identity and
// therefore the same System Audio Recording grant as the watcher itself.
if args.first == "--levels" {
    let rest = args.dropFirst().compactMap { Int($0) }
    let bars = rest.first ?? 6
    let seconds = rest.count > 1 ? rest[1] : 6
    guard let pid = NSRunningApplication
        .runningApplications(withBundleIdentifier: spotifyBundleID)
        .first?.processIdentifier
    else {
        print("spotify is not running")
        exit(1)
    }
    guard spectrumTap.start(pid: pid) else {
        print("tap did not start: System Audio Recording is probably not granted")
        exit(1)
    }
    // Raw, unsmoothed bands as CSV so the smoothing chain and the frame rate can
    // be simulated offline against the same recording, instead of rebuilding and
    // re-listening once per candidate.
    FileHandle.standardError.write(
        "tapping pid \(pid) at \(Int(spectrumTap.sampleRate))Hz, \(bars) bars, \(seconds)s\n"
            .data(using: .utf8)!)
    let started = Date()
    let deadline = started.addingTimeInterval(TimeInterval(seconds))
    while Date() < deadline {
        if let raw = spectrumTap.levels(bands: bars) {
            let stamp = Date().timeIntervalSince(started)
            print(
                String(format: "%.4f,", stamp)
                    + raw.map { String(format: "%.5f", Double($0)) }.joined(separator: ","))
        }
        Thread.sleep(forTimeInterval: 0.004)
    }
    spectrumTap.stop()
    exit(0)
}

// `mediawatch --smoothcheck` runs the real smoothing chain against live audio at
// the real tick rate and reports the achieved rate plus how far a bar moves
// between frames. That per-frame movement is what reads as jitter, so this is the
// number the smoothness change has to move, and it includes the render cost
// because the loop does the same work the timer does.
if args.first == "--smoothcheck" {
    let rest = args.dropFirst().compactMap { Int($0) }
    let bars = rest.first ?? 6
    let seconds = rest.count > 1 ? rest[1] : 8
    guard let pid = NSRunningApplication
        .runningApplications(withBundleIdentifier: spotifyBundleID)
        .first?.processIdentifier
    else {
        print("spotify is not running")
        exit(1)
    }
    guard spectrumTap.start(pid: pid) else {
        print("tap did not start: System Audio Recording is probably not granted")
        exit(1)
    }
    var previous: [CGFloat]?
    var deltas: [CGFloat] = []
    var stamps: [TimeInterval] = []
    let deadline = Date().addingTimeInterval(TimeInterval(seconds))
    while Date() < deadline {
        let tickBegan = ProcessInfo.processInfo.systemUptime
        if let now = smoothedAudioLevels(bars: bars) {
            // Render too, so the measured rate is what the timer can actually hold.
            _ = liveWaveURL(
                width: discPixelSize, levels: now, amplitude: 1, opacity: 1,
                sideMargin: discWaveSideMargin, envelopeFloor: discWaveEnvelopeFloor)
            stamps.append(tickBegan)
            if let previous {
                deltas.append(
                    zip(previous, now).map { abs($0 - $1) }.reduce(0, +) / CGFloat(bars))
            }
            previous = now
        }
        let spent = ProcessInfo.processInfo.systemUptime - tickBegan
        if spent < liveInterval { Thread.sleep(forTimeInterval: liveInterval - spent) }
    }
    spectrumTap.stop()
    guard deltas.count > 1, let first = stamps.first, let last = stamps.last else {
        print("no audio arrived, so nothing to measure")
        exit(1)
    }
    let rate = Double(stamps.count - 1) / (last - first)
    let mean = deltas.reduce(0, +) / CGFloat(deltas.count)
    print(String(
        format: "achieved %.1f fps over %d frames", rate, stamps.count))
    print(String(
        format: "mean move %.4f (%.2fpx per frame)  worst %.4f (%.2fpx)",
        Double(mean), Double(mean) * 20,
        Double(deltas.max() ?? 0), Double(deltas.max() ?? 0) * 20))
    exit(0)
}

initialiseCacheOrder()

var sources: [DispatchSourceSignal] = []

// Terminating deliberately does NOT go on applyQueue. It used to, and then a call that blocked applyQueue made the watcher
// unkillable by TERM: the handler was queued behind the block, so `pkill -TERM`
// did nothing and the plugin's restart quietly kept talking to the stuck
// process. Exit needs no ordering against commit. It needs to happen.
let exitQueue = DispatchQueue(label: "mediawatch.exit")
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: exitQueue)
    source.setEventHandler {
        stopSpin()
        stopWaveform()
        // Explicitly, and before exit. The tap is a HAL object and a recording
        // state, not just memory: leaving it to process teardown is how you end
        // up with an aggregate device nobody owns and an indicator that stays on.
        spectrumTap.stop()
        cancelTransition()
        exit(0)
    }
    source.resume()
    sources.append(source)
}

// Re-fit on request: forget the measured room and re-apply what is showing,
// unless a transition is running, which lands its own layout when it ends.
DistributedNotificationCenter.default().addObserver(
    forName: refitNotification, object: nil, queue: nil
) { _ in
    applyQueue.async {
        cachedRoom = nil
        guard let state = lastApplied, playerDrawn, transitionTimer == nil,
              state.displayMode != .spotifyDJ else { return }
        applyTrackVisible(state, discDrawing: true)
    }
}

DistributedNotificationCenter.default().addObserver(
    forName: demoNotification, object: nil, queue: nil
) { note in
    let kind = note.userInfo?["kind"] as? String ?? "track"
    applyQueue.async {
        guard lastApplied == silenceState, playerDrawn, transitionTimer == nil else { return }
        if kind == "call" {
            let call = NowPlaying(
                title: "Daily stand-up", artist: "", playing: true,
                artworkKey: discCacheKey(artworkHash: "", source: .call),
                displayMode: .track, source: .call, bundleID: "com.microsoft.teams2.modulehost")
            currentArtwork = nil
            showTrack(call)
            applyQueue.asyncAfter(deadline: .now() + 7) {
                if lastApplied == call { enterSilence() }
            }
            return
        }
        // A macOS wallpaper stands in for album art, as it does for --marks.
        var art: CGImage?
        if let src = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: "/System/Library/Desktop Pictures/iMac Blue.heic") as CFURL, nil) {
            art = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 300,
            ] as CFDictionary)
        }
        let demo = NowPlaying(
            title: "Everything In Its Right Place", artist: "Radiohead", playing: true,
            artworkKey: discCacheKey(artworkHash: cachePrefix + "demo", source: .music),
            displayMode: .track, source: .music, bundleID: "")
        currentArtwork = art
        showTrack(demo)
        applyQueue.asyncAfter(deadline: .now() + 3.5) {
            if lastApplied == demo { enterSilence() }
        }
    }
}

DispatchQueue.global(qos: .utility).async { startStream() }

// Meetings, which never reach Now Playing: see mediacall.swift.
applyQueue.async { watchCalls() }

// media-control says nothing at all when no app holds a Now Playing session, so
// a bar started in silence would otherwise wait for the first song to show the
// pill. Anything that did arrive in the meantime has set lastApplied.
applyQueue.asyncAfter(deadline: .now() + 2) {
    if lastApplied == nil { enterSilence() }
}
RunLoop.main.run()
