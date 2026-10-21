import AppKit
import Foundation

/// The badges the bar can carry, left to right as they sit in its pill.
struct Badge: Identifiable, Hashable {
    enum ID: String, CaseIterable { case orbstack, caffeinate, vitals, claude, tailscale, wifi, battery }

    let id: ID
    let name: String
    let summary: String
    /// Said before switching it on, when it reads something of yours.
    let privacy: String?
    /// An app it needs, by bundle path, and that app's name.
    let needs: (path: String, name: String)?
    /// The states the preview cycles through: renderer, arguments, caption.
    let states: [(renderer: String, arguments: [String], caption: String)]

    static func == (a: Badge, b: Badge) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var isAvailable: Bool {
        guard let needs else { return true }
        return FileManager.default.fileExists(atPath: needs.path)
    }

    static let green = "0xff32d74b", amber = "0xffff9f0a", red = "0xffff453a", grey = "0xff8e8e93"
    static let orange = "0xffd97757", purple = "0xffbf5af2", blue = "0xff64d2ff"

    static let orbstack = Badge(
        id: .orbstack, name: "OrbStack", summary: "An orb that lights up while containers or machines run.",
        privacy: nil, needs: ("/Applications/OrbStack.app", "OrbStack"),
        states: [("orbmark", ["--color", purple], "running"), ("orbmark", ["--color", grey], "idle")])
    static let caffeinate = Badge(
        id: .caffeinate, name: "Keep awake", summary: "A capsule: click to keep the Mac and its screen awake.",
        privacy: nil, needs: nil,
        states: [("capsulemark", ["--state", "on"], "on"), ("capsulemark", ["--state", "off"], "off")])
    static let vitals = Badge(
        id: .vitals, name: "Vitals", summary: "A pixel ghost whose colour is how hard the Mac is working.",
        privacy: nil, needs: ("/Applications/Vitals.app", "Vitals"),
        states: [("vitalsmark", ["--level", "1", "--tone", "calm"], "light"),
                 ("vitalsmark", ["--level", "3", "--tone", "calm"], "heavy"),
                 ("vitalsmark", ["--level", "0", "--tone", "dead"], "not running")])
    static let claude = Badge(
        id: .claude, name: "Claude usage", summary: "A burst whose rays go out as your Claude Code session is spent.",
        privacy: "Reads Claude Code's login from your keychain to ask Anthropic how much of the session is used. macOS asks the first time.",
        needs: nil,
        states: [("usagemark", ["--percent", "100", "--color", orange], "fresh"),
                 ("usagemark", ["--percent", "50", "--color", orange], "half spent"),
                 ("usagemark", ["--percent", "8", "--color", red], "nearly out")])
    static let tailscale = Badge(
        id: .tailscale, name: "Tailscale", summary: "A drawn shield, green when the tailnet is connected.",
        privacy: nil, needs: nil,
        states: [("vpnmark", ["--state", "up"], "connected"), ("vpnmark", ["--state", "down"], "off")])
    static let wifi = Badge(
        id: .wifi, name: "Wi-Fi", summary: "Four dots, lit as far as the signal reaches; a port on a cable.",
        privacy: "Shows the network's name, which macOS treats as location: it asks once.",
        needs: nil,
        states: [("wifimark", ["--dots", "4", "--color", purple], "excellent"),
                 ("wifimark", ["--dots", "2", "--color", "0xffff6ac1"], "fair"),
                 ("wifimark", ["--ethernet", "--color", purple], "cable")])
    static let battery = Badge(
        id: .battery, name: "Battery", summary: "A ring in green, amber or red, with a bolt while charging.",
        privacy: nil, needs: nil,
        states: [("batterymark", ["--percent", "84", "--color", green], "on battery"),
                 ("batterymark", ["--percent", "62", "--color", green, "--charging"], "charging"),
                 ("batterymark", ["--percent", "9", "--color", red], "critical")])

    static let all: [Badge] = [orbstack, caffeinate, vitals, claude, tailscale, wifi, battery]
}

/// Draws badge previews with the bar's own renderers, so what the app shows
/// is exactly what the bar will. Each renderer is a single Swift file in the
/// checkout; built once into the app's cache if the bar has not built it yet.
actor Renderer {
    static let shared = Renderer()
    private var images: [String: NSImage] = [:]

    func image(for state: (renderer: String, arguments: [String], caption: String), repo: URL?) async -> NSImage? {
        let key = ([state.renderer] + state.arguments).joined(separator: " ")
        if let cached = images[key] { return cached }
        guard let repo, let binary = await binary(state.renderer, repo: repo) else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: Places.cache, withIntermediateDirectories: true)
        let out = Places.cache.appendingPathComponent("preview-\(abs(key.hashValue)).png")
        let result = await Shell.capture(binary, state.arguments + ["--out", out.path], timeout: 15)
        guard result.ok, let image = NSImage(contentsOf: out) else { return nil }
        // Drawn at two pixels per point (2.25 for the burst); shown at point size.
        if let rep = image.representations.first {
            let scale: CGFloat = state.renderer == "usagemark" ? 2.25 : 2
            image.size = NSSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
        }
        images[key] = image
        return image
    }

    private func binary(_ name: String, repo: URL) async -> String? {
        let fm = FileManager.default
        let source = repo.appendingPathComponent("sketchybar/assets/\(name).swift")
        let built = repo.appendingPathComponent("sketchybar/assets/\(name)")
        if fm.isExecutableFile(atPath: built.path), modified(built) >= modified(source) { return built.path }
        let cached = Places.cache.appendingPathComponent("bin/\(name)")
        if fm.isExecutableFile(atPath: cached.path), modified(cached) >= modified(source) { return cached.path }
        guard fm.fileExists(atPath: source.path) else { return nil }
        try? fm.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = await Shell.capture("/usr/bin/xcrun", ["swiftc", "-O", source.path, "-o", cached.path], timeout: 180)
        return result.ok ? cached.path : nil
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
