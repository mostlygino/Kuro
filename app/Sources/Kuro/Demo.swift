import Foundation

/// `--demo fresh` and `--demo ready`: the app on a made-up Mac, for screenshots
/// and for trying the flow without installing anything. Nothing is run; the
/// console plays what the real commands print. Synthetic, and labelled so in
/// the window.
///
///   Kuro --demo fresh [--step badges]      onboarding, nothing installed
///   Kuro --demo ready [--section keys]     the manager, everything healthy
enum Demo: String {
    case fresh, ready

    static var fromArguments: Demo? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo"), i + 1 < args.count else { return nil }
        return Demo(rawValue: args[i + 1])
    }

    static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--" + name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    var repo: URL? {
        switch self {
        case .fresh: nil
        case .ready: Places.home.appendingPathComponent("src/Kuro")
        }
    }

    var state: SystemState {
        var state = SystemState()
        state.macOSMajor = 26
        switch self {
        case .fresh:
            state.installed = [.commandLineTools]
        case .ready:
            state.installed = Set(SystemState.Part.allCases)
            state.running = Set(SystemState.Service.allCases)
            state.barLinked = true; state.aerospaceLinked = true; state.launchAgent = true
            state.menuBarHides = true
        }
        return state
    }

    var settings: KuroSettings {
        KuroSettings(badges: [.caffeinate, .claude, .tailscale, .wifi, .battery], menuBarOpening: 0, clockURL: "")
    }

    var update: KuroModel.UpdateCheck {
        KuroModel.UpdateCheck(branch: "main", localChanges: [],
                              incoming: ["feat: agent spaces on ctrl-cmd 1..0, no fn key",
                                         "fix: a card stays open until clicked again"],
                              checked: true, failed: nil)
    }

    /// What each command prints, close to the real thing.
    static func output(for executable: String, _ arguments: [String]) -> [String] {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if arguments.first?.hasSuffix("install.sh") == true {
            var lines: [String] = []
            if arguments.contains("--deps") {
                lines += ["==> Installing Homebrew packages",
                          "==> Fetching felixkratz/formulae/sketchybar",
                          "==> Pouring sketchybar--2.24.arm64_tahoe.bottle.tar.gz",
                          "==> Fetching felixkratz/formulae/borders",
                          "==> Pouring borders--1.8.arm64_tahoe.bottle.tar.gz",
                          "==> Installing media-control",
                          "==> Installing Cask aerospace",
                          "==> Installing Cask font-hack-nerd-font"]
            }
            lines += ["==> linked /Users/you/.config/sketchybar",
                      "kuro-apply: applied",
                      "==> linked /Users/you/.config/borders/bordersrc",
                      "==> created sketchybar/local.sh for your own settings",
                      "==> bound Show Notification Center to F19 (the clock presses it)",
                      "==> installed /Users/you/Library/LaunchAgents/sh.kuro.aerospace.plist"]
            if !arguments.contains("--no-start") {
                lines += ["==> Setting the menu bar to hide automatically", "==> Starting SketchyBar"]
            }
            return lines
        }
        switch name {
        case "git" where arguments.first == "clone":
            return ["Cloning into '\(arguments.last ?? "Kuro")'...", "Receiving objects: 100% (214/214), 11.2 MiB | 18 MiB/s"]
        case "git" where arguments.first == "pull":
            return ["Updating 8c07bba..6552177", "Fast-forward", " 12 files changed, 431 insertions(+), 96 deletions(-)"]
        case "zsh" where arguments.first?.hasSuffix("check.sh") == true:
            return ["· shell scripts parse", "· Python compiles, and since.py's self-test",
                    "· Swift helpers compile", "· self-tests", "check: all passed"]
        case "zsh" where arguments.first?.hasSuffix("kuro-apply.sh") == true:
            return [arguments.contains("--check") ? "kuro-apply: fine" : "kuro-apply: applied"]
        case "zsh" where arguments.first?.hasSuffix("kuro.sh") == true:
            let verb = arguments.dropFirst().first ?? "", part = arguments.dropFirst(2).first ?? "all"
            if verb == "menubar" { return ["==> macOS menu bar: \(part == "hide" ? "hidden" : "shown")"] }
            var lines: [String] = []
            if part != "bar" { lines.append("==> windows \(verb)") }
            if part != "windows" { lines += ["==> macOS menu bar: \(verb == "on" ? "hidden" : "shown")", "==> bar \(verb)"] }
            return lines
        case "xcode-select":
            return ["xcode-select: note: install requested for command line developer tools"]
        default:
            return []
        }
    }
}
