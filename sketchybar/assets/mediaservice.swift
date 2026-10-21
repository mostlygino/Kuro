// Which service a browser is playing, and a mark of its own for each one.
//
// A browser's media session says only that the browser is playing: the payload
// has the title, the channel as `artist`, a thumbnail and the browser's bundle
// id, and no URL. So every wide thumbnail from a browser used to be called
// YouTube, and Netflix, Twitch or Disney+ wore the YouTube mark. This asks the
// browser instead. Over AppleScript it lists every tab's title and address,
// finds the tab that is playing by its title (or, when the site keeps its tab
// title to itself as Netflix does, the one streaming tab that is open), and
// reads the service off the host. Once per track, off every queue that
// matters, cached, and only for browsers that can answer: Dia, Arc, Safari and
// the Chrome family. Firefox has no tab scripting and keeps the old guess.
//
// A video app, Apple TV or IINA or VLC, gets its own app icon in the slot,
// breathing like the other marks, instead of the anonymous record dot.
//
// The first lookup asks macOS for permission to talk to the browser, once.

import AppKit
import CoreText

enum WebService: String, CaseIterable {
    case netflix, youtube, youtubeMusic, twitch, disney, prime, appleTV, vimeo
    case soundcloud, spotifyWeb, appleMusicWeb

    /// Music services keep the artist beside the title; video ones treat it as
    /// the channel, which the title usually already carries.
    var isVideo: Bool {
        switch self {
        case .youtubeMusic, .soundcloud, .spotifyWeb, .appleMusicWeb: return false
        default: return true
        }
    }
}

/// The service a URL belongs to, by host.
func webService(forURL raw: String) -> WebService? {
    guard let host = URL(string: raw)?.host?.lowercased() else { return nil }
    func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
    if host == "music.youtube.com" { return .youtubeMusic }
    if on("youtube.com") || on("youtu.be") { return .youtube }
    if on("netflix.com") { return .netflix }
    if on("twitch.tv") { return .twitch }
    if on("disneyplus.com") { return .disney }
    if on("primevideo.com") || (host.contains("amazon.") && raw.contains("/gp/video")) { return .prime }
    if host == "tv.apple.com" { return .appleTV }
    if host == "music.apple.com" { return .appleMusicWeb }
    if on("vimeo.com") { return .vimeo }
    if on("soundcloud.com") { return .soundcloud }
    if host == "open.spotify.com" { return .spotifyWeb }
    return nil
}

/// Picks the playing tab's service from `url\ttitle` lines. The tab whose title
/// holds the track's title wins; failing that, the only tab on a known service.
func serviceFromTabs(_ listing: String, playingTitle: String) -> WebService? {
    let tabs = listing.split(separator: "\n").compactMap { line -> (url: String, title: String)? in
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
    }
    let wanted = playingTitle.lowercased().trimmingCharacters(in: .whitespaces)
    let probe = String(wanted.prefix(28))
    if probe.count >= 3,
       let match = tabs.first(where: { $0.title.lowercased().contains(probe) }),
       let service = webService(forURL: match.url) {
        return service
    }
    let known = Set(tabs.compactMap { webService(forURL: $0.url) })
    return known.count == 1 ? known.first : nil
}

// The tab listing, per scripting dialect. Safari names its tabs `name`; Dia,
// Arc and the Chromium browsers call it `title`.
func tabListingScript(for bundleID: String) -> String? {
    let titleKey: String
    switch bundleID {
    case "com.apple.safari": titleKey = "name"
    case "company.thebrowser.dia", "company.thebrowser.browser", "com.google.chrome",
         "com.brave.browser", "com.microsoft.edgemac", "com.vivaldi.vivaldi":
        titleKey = "title"
    default: return nil
    }
    return """
    tell application id "\(bundleID)"
        set out to ""
        repeat with w in windows
            repeat with t in tabs of w
                set out to out & (URL of t) & tab & (\(titleKey) of t) & linefeed
            end repeat
        end repeat
        return out
    end tell
    """
}

let serviceLock = NSLock()
var serviceAnswers: [String: WebService?] = [:]
var serviceLookupsInFlight: Set<String> = []

func serviceKey(_ bundleID: String, _ title: String) -> String { bundleID + "\u{1f}" + title }

/// The cached answer for this track: a service, `.some(nil)` for "asked, none",
/// or nil when it has not been asked yet.
func knownService(bundleID: String, title: String) -> WebService?? {
    serviceLock.lock()
    defer { serviceLock.unlock() }
    return serviceAnswers[serviceKey(bundleID, title)]
}

/// Asks the browser, off every queue that matters, and hands the answer back on
/// applyQueue. Bounded to two seconds: a browser that hangs, or a permission
/// prompt nobody answers, must not stall anything.
func lookUpService(bundleID: String, title: String, then finish: @escaping (WebService?) -> Void) {
    let key = serviceKey(bundleID, title)
    serviceLock.lock()
    let claimed = serviceAnswers[key] == nil && !serviceLookupsInFlight.contains(key)
    if claimed { serviceLookupsInFlight.insert(key) }
    serviceLock.unlock()
    guard claimed, let script = tabListingScript(for: bundleID) else { return }
    DispatchQueue.global(qos: .utility).async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        var listing = ""
        if (try? task.run()) != nil {
            let deadline = DispatchTime.now() + 2
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                listing = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                done.signal()
            }
            if done.wait(timeout: deadline) == .timedOut { task.terminate() }
        }
        let service = serviceFromTabs(listing, playingTitle: title)
        serviceLock.lock()
        serviceLookupsInFlight.remove(key)
        if serviceAnswers.count > 64 { serviceAnswers.removeAll() }
        serviceAnswers[key] = .some(service)
        serviceLock.unlock()
        applyQueue.async { finish(service) }
    }
}

// MARK: - Marks

/// A mark drawn as a letter or two in a heavy face, for the services whose
/// identity is a wordmark rather than a picture.
struct GlyphMark {
    let text: String
    let font: String
    let color: CGColor
    let scale: CGFloat       // of the slot's height
}

func glyphMark(for service: WebService) -> GlyphMark? {
    switch service {
    case .netflix:
        return GlyphMark(text: "N", font: "AvenirNextCondensed-Heavy",
                         color: CGColor(srgbRed: 0.898, green: 0.035, blue: 0.078, alpha: 1), scale: 0.82)
    case .disney:
        return GlyphMark(text: "D+", font: "AvenirNext-Heavy",
                         color: CGColor(srgbRed: 0.24, green: 0.55, blue: 1, alpha: 1), scale: 0.58)
    case .vimeo:
        return GlyphMark(text: "v", font: "AvenirNext-Heavy",
                         color: CGColor(srgbRed: 0.10, green: 0.72, blue: 0.92, alpha: 1), scale: 0.78)
    default:
        return nil
    }
}

/// The SF Symbol marks, for services with no wordmark or whose shape is one.
func symbolMark(for service: WebService) -> SlotIcon? {
    func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    let white = rgb(1, 1, 1)
    switch service {
    case .youtube:
        return SlotIcon(symbol: "play.rectangle.fill", palette: [white, rgb(1, 0, 0.2)], motion: .breathe)
    case .youtubeMusic:
        return SlotIcon(symbol: "play.circle.fill", palette: [white, rgb(1, 0, 0.2)], motion: .breathe)
    case .twitch:
        return SlotIcon(symbol: "bubble.left.fill", palette: [rgb(0.57, 0.27, 1)], motion: .breathe)
    case .prime:
        return SlotIcon(symbol: "play.tv.fill", palette: [rgb(0, 0.66, 0.88)], motion: .breathe)
    case .soundcloud:
        return SlotIcon(symbol: "cloud.fill", palette: [rgb(1, 0.33, 0)], motion: .breathe)
    case .spotifyWeb:
        return SlotIcon(symbol: "music.note", palette: [rgb(0.11, 0.73, 0.33)], motion: .breathe)
    case .appleMusicWeb:
        return SlotIcon(symbol: "music.note", palette: [rgb(0.98, 0.18, 0.28)], motion: .breathe)
    // Apple TV on the web wears the Apple TV app's own icon: its symbol comes
    // out as a blank tile in one colour.
    case .netflix, .disney, .vimeo, .appleTV:
        return nil
    }
}

/// The app whose icon stands in for a service, when it has no drawn mark.
func standInApp(for service: WebService) -> String? {
    service == .appleTV ? "com.apple.TV" : nil
}

/// The breath every mark in the slot shares: a slow swell of size and light.
func breath(_ phase: CGFloat) -> (alpha: CGFloat, grow: CGFloat) {
    let swell = pow((cos(phase * 2 * .pi) + 1) / 2, 0.65)
    return (slotIconAlphaFloor + (1 - slotIconAlphaFloor) * swell,
            slotIconScaleFloor + (1 - slotIconScaleFloor) * swell)
}

func drawGlyphMark(_ mark: GlyphMark, into ctx: CGContext, size: Int, phase: CGFloat) {
    let canvas = CGFloat(size)
    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    let (alpha, grow) = breath(phase)
    let font = CTFontCreateWithName(mark.font as CFString, canvas * mark.scale * grow, nil)
    let attributed = NSAttributedString(string: mark.text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): mark.color.copy(alpha: alpha) ?? mark.color,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.textPosition = CGPoint(x: (canvas - bounds.width) / 2 - bounds.minX,
                               y: (canvas - bounds.height) / 2 - bounds.minY)
    CTLineDraw(line, ctx)
}

/// A video app's own icon, breathing, for the slot.
func drawAppIcon(_ icon: CGImage, into ctx: CGContext, size: Int, phase: CGFloat) {
    let canvas = CGFloat(size)
    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    let (alpha, grow) = breath(phase)
    let side = canvas * 0.92 * grow
    ctx.setAlpha(alpha)
    ctx.interpolationQuality = .high
    ctx.draw(icon, in: CGRect(x: (canvas - side) / 2, y: (canvas - side) / 2, width: side, height: side))
}

func appIconImage(bundleID: String, pixels: Int) -> CGImage? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    let image = NSWorkspace.shared.icon(forFile: url.path)
    var rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

/// Frames for a mark drawn by `draw`, cached under `key` like the other slots.
func renderMarkFrames(key: String, draw: (CGContext, Int, CGFloat) -> Void) throws -> [URL] {
    let root = try cacheRoot().appendingPathComponent(key, isDirectory: true)
    let fm = FileManager.default
    let urls = (0..<slotIconFrameCount).map {
        root.appendingPathComponent(String(format: "frame-%03d.png", $0))
    }
    if urls.allSatisfy({ fm.fileExists(atPath: $0.path) }) {
        touchCache(key)
        pruneCache()
        return urls
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let side = slotPixelSize * slotIconPixelScale
    for (index, url) in urls.enumerated() {
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw NSError(domain: "mediawatch.mark", code: 1) }
        draw(ctx, side, CGFloat(index) / CGFloat(slotIconFrameCount))
        guard let image = ctx.makeImage(), let data = pngData(from: image) else {
            throw NSError(domain: "mediawatch.mark", code: 2)
        }
        try writeFrame(data, to: url)
    }
    touchCache(key)
    pruneCache()
    return urls
}

/// Checks the service rules, for the self-test.
func serviceSelfTest(_ expect: (Bool, String) -> Void) {
    expect(webService(forURL: "https://www.netflix.com/watch/81234") == .netflix, "netflix by host")
    expect(webService(forURL: "https://music.youtube.com/watch?v=x") == .youtubeMusic, "youtube music before youtube")
    expect(webService(forURL: "https://m.youtube.com/watch?v=x") == .youtube, "youtube on a subdomain")
    expect(webService(forURL: "https://www.amazon.de/gp/video/detail/x") == .prime, "prime on amazon")
    expect(webService(forURL: "https://example.com") == nil, "unknown hosts are nothing")
    let tabs = "https://www.youtube.com/watch?v=a\tLofi Girl - YouTube\nhttps://www.netflix.com/watch/1\tNetflix\n"
    expect(serviceFromTabs(tabs, playingTitle: "Lofi Girl") == .youtube, "the tab with the title wins")
    expect(serviceFromTabs("https://www.netflix.com/watch/1\tNetflix\nhttps://a.com\tA\n",
                           playingTitle: "Stranger Things") == .netflix,
           "the one streaming tab when no title matches")
    expect(serviceFromTabs(tabs, playingTitle: "Something else") == nil, "two services and no match is no answer")
    expect(WebService.allCases.allSatisfy {
        glyphMark(for: $0) != nil || symbolMark(for: $0) != nil || standInApp(for: $0) != nil
    }, "every service has a mark")
}
