import Foundation

/// `~/.config/kuro/settings`, the file the bar reads (sketchybar/colors.sh).
/// The bar only accepts known keys with values of the right shape, and this
/// writes nothing it would refuse, so a setting never silently does nothing.
struct KuroSettings: Equatable {
    var badges: Set<Badge.ID>
    var menuBarOpening: Int
    var clockURL: String

    static let fileHeader = """
    # Written by the Kuro app. The bar reads these lines (sketchybar/colors.sh)
    # and ignores anything it does not know; sketchybar/local.sh still wins.
    """

    /// What a new bar starts with, the same defaults colors.sh falls back to.
    static var defaults: KuroSettings {
        var badges: Set<Badge.ID> = [.caffeinate, .tailscale, .wifi, .battery]
        if Badge.vitals.isAvailable { badges.insert(.vitals) }
        if Badge.orbstack.isAvailable { badges.insert(.orbstack) }
        return KuroSettings(badges: badges, menuBarOpening: 0, clockURL: "")
    }

    static func load() -> KuroSettings {
        var settings = defaults
        guard let text = try? String(contentsOf: Places.settings, encoding: .utf8) else { return settings }
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals], value = String(line[line.index(after: equals)...])
            switch key {
            case "badges":
                settings.badges = Set(value.split(separator: " ").compactMap { Badge.ID(rawValue: String($0)) })
            case "menubar_reveal_width":
                if let width = Int(value), (0...9999).contains(width) { settings.menuBarOpening = width }
            case "clock_url":
                if Self.isValidURL(value) { settings.clockURL = value }
            default:
                continue
            }
        }
        return settings
    }

    /// The clock link may only be https and only these characters: the bar
    /// puts it inside a command, so anything that could end a quote is out.
    static func isValidURL(_ value: String) -> Bool {
        value.range(of: #"^https://[A-Za-z0-9._~:/?#=&%+-]+$"#, options: .regularExpression) != nil
    }

    var fileText: String {
        var lines = [Self.fileHeader]
        let ordered = Badge.all.map(\.id).filter(badges.contains).map(\.rawValue)
        lines.append("badges=" + ordered.joined(separator: " "))
        lines.append("menubar_reveal_width=\(max(0, min(9999, menuBarOpening)))")
        if Self.isValidURL(clockURL) { lines.append("clock_url=" + clockURL) }
        return lines.joined(separator: "\n") + "\n"
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Places.kuro, withIntermediateDirectories: true)
        try fileText.write(to: Places.settings, atomically: true, encoding: .utf8)
    }
}
