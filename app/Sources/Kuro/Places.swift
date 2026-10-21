import Foundation

/// Where Kuro's pieces live on this Mac.
enum Places {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let config = home.appendingPathComponent(".config")
    static let kuro = config.appendingPathComponent("kuro")
    static let settings = kuro.appendingPathComponent("settings")
    static let localBindings = kuro.appendingPathComponent("aerospace.local.toml")
    static let barLink = config.appendingPathComponent("sketchybar")
    static let aerospaceLink = home.appendingPathComponent(".aerospace.toml")
    static let aerospaceBuilt = kuro.appendingPathComponent("aerospace.toml")
    static let launchAgent = home.appendingPathComponent("Library/LaunchAgents/sh.kuro.aerospace.plist")
    static let agentOpen = home.appendingPathComponent(".local/bin/open")
    static let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.mostlygino.kuro")

    static let cloneURL = "https://github.com/mostlygino/Kuro.git"
    static let repoDefaultsKey = "repositoryPath"

    /// The checkout this Mac runs, found the way the bar finds itself: the
    /// config link points into it. Failing that, the one chosen before, the
    /// folder this app was built in, and the usual places.
    static func findRepository() -> URL? {
        var candidates: [URL] = []
        let linked = barLink.resolvingSymlinksInPath()
        if linked.path != barLink.path { candidates.append(linked.deletingLastPathComponent()) }
        if let saved = UserDefaults.standard.string(forKey: repoDefaultsKey) {
            candidates.append(URL(fileURLWithPath: saved))
        }
        // build/Kuro.app inside a checkout.
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent())
        for name in ["Kuro", "src/Kuro", "Developer/Kuro", "Code/Kuro", "Projects/Kuro"] {
            candidates.append(home.appendingPathComponent(name))
        }
        return candidates.first(where: isRepository)
    }

    static func isRepository(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("install.sh").path)
            && fm.fileExists(atPath: url.appendingPathComponent("aerospace.toml").path)
            && fm.fileExists(atPath: url.appendingPathComponent("sketchybar/sketchybarrc").path)
    }

    /// `~/src/Kuro` rather than `/Users/name/src/Kuro`, for showing.
    static func display(_ url: URL) -> String {
        let path = url.path
        return path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path
    }

    static func links(_ link: URL, to target: URL) -> Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return false
        }
        return URL(fileURLWithPath: destination).standardizedFileURL.path == target.standardizedFileURL.path
    }
}
