import AppKit
import Foundation
import Observation

/// What is true on this Mac right now, read rather than assumed.
struct SystemState: Equatable {
    enum Part: String, CaseIterable, Identifiable {
        case commandLineTools, homebrew, aerospace, sketchybar, borders, mediaControl, font
        var id: String { rawValue }
        var name: String {
            switch self {
            case .commandLineTools: "Command line tools"
            case .homebrew: "Homebrew"
            case .aerospace: "AeroSpace"
            case .sketchybar: "SketchyBar"
            case .borders: "JankyBorders"
            case .mediaControl: "media-control"
            case .font: "Hack Nerd Font"
            }
        }
        var role: String {
            switch self {
            case .commandLineTools: "compiles the bar's Swift helpers"
            case .homebrew: "installs everything else"
            case .aerospace: "tiles the windows"
            case .sketchybar: "draws the bar"
            case .borders: "the thin ring round the focused window"
            case .mediaControl: "reads Now Playing"
            case .font: "the bar's icons"
            }
        }
        /// Installed by `install.sh --deps`, as opposed to by hand first.
        var brewInstalls: Bool { ![.commandLineTools, .homebrew].contains(self) }
    }

    enum Service: String, CaseIterable, Identifiable {
        case aerospace = "AeroSpace", sketchybar, borders, topguard, mediawatch
        var id: String { rawValue }
        var name: String {
            switch self {
            case .aerospace: "AeroSpace"
            case .sketchybar: "SketchyBar"
            case .borders: "JankyBorders"
            case .topguard: "Top-edge guard"
            case .mediawatch: "Now Playing watcher"
            }
        }
    }

    var installed: Set<Part> = []
    var running: Set<Service> = []
    var barLinked = false
    var aerospaceLinked = false
    var launchAgent = false
    var menuBarHides = false
    var agentOpen = false
    var macOSMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

    var prerequisitesMet: Bool { installed.contains(.commandLineTools) && installed.contains(.homebrew) }
    var partsInstalled: Bool { Part.allCases.allSatisfy(installed.contains) }
    var linked: Bool { barLinked && aerospaceLinked && launchAgent }
    var healthy: Bool { partsInstalled && linked && [.aerospace, .sketchybar, .borders].allSatisfy(running.contains) }

    static func read() async -> SystemState {
        var state = SystemState()
        let fm = FileManager.default
        if fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/swiftc")
            || fm.fileExists(atPath: "/Applications/Xcode.app") { state.installed.insert(.commandLineTools) }
        if Shell.which("brew") != nil { state.installed.insert(.homebrew) }
        if fm.fileExists(atPath: "/Applications/AeroSpace.app") || Shell.which("aerospace") != nil {
            state.installed.insert(.aerospace)
        }
        if Shell.which("sketchybar") != nil { state.installed.insert(.sketchybar) }
        if Shell.which("borders") != nil { state.installed.insert(.borders) }
        if Shell.which("media-control") != nil { state.installed.insert(.mediaControl) }
        let families = NSFontManager.shared.availableFontFamilies
        if families.contains(where: { $0.hasPrefix("Hack Nerd Font") }) { state.installed.insert(.font) }

        for service in Service.allCases where await Shell.running(service.rawValue) {
            state.running.insert(service)
        }
        if let repo = Places.findRepository() {
            state.barLinked = Places.links(Places.barLink, to: repo.appendingPathComponent("sketchybar"))
        }
        state.aerospaceLinked = Places.links(Places.aerospaceLink, to: Places.aerospaceBuilt)
        state.launchAgent = fm.fileExists(atPath: Places.launchAgent.path)
        // The global domain is read whole: a suite named after it reads nothing.
        state.menuBarHides = (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["_HIHideMenuBar"]
            as? NSNumber)?.boolValue ?? false
        state.agentOpen = fm.fileExists(atPath: Places.agentOpen.path)
        return state
    }
}

/// The app's one source of truth: the checkout, the Mac's state, the
/// settings, and every action, each run through the console.
@MainActor @Observable
final class KuroModel {
    let demo: Demo?
    let console = Console()
    var state = SystemState()
    var settings = KuroSettings.load()
    var savedSettings = KuroSettings.load()
    var repo: URL? = Places.findRepository()
    var refreshing = false

    init(demo: Demo?) {
        self.demo = demo
        if let demo {
            state = demo.state
            settings = demo.settings
            savedSettings = demo.settings
            repo = demo.repo
            console.script = { [weak self] exe, args in
                let output = Demo.output(for: exe, args)
                Task { @MainActor in self?.demoAdvance(exe, args) }
                return output
            }
        }
    }

    func refresh() async {
        guard demo == nil else { return }
        refreshing = true
        state = await SystemState.read()
        repo = Places.findRepository()
        refreshing = false
    }

    // MARK: actions, all through the console

    private func script(_ name: String) -> String? {
        repo.map { $0.appendingPathComponent(name).path }
    }

    func installCommandLineTools() async {
        await console.run("/usr/bin/xcode-select", ["--install"], title: "xcode-select --install")
        console.note("macOS opens its own installer for the command line tools. Come back when it has finished.")
    }

    func clone(to destination: URL) async -> Bool {
        let ok = await console.run("/usr/bin/git", ["clone", "--depth", "1", Places.cloneURL, destination.path],
                                   title: "git clone \(Places.cloneURL) \(Places.display(destination))")
        if ok || demo != nil {
            UserDefaults.standard.set(destination.path, forKey: Places.repoDefaultsKey)
            repo = demo != nil ? destination : (Places.isRepository(destination) ? destination : nil)
        }
        return ok
    }

    func useRepository(_ url: URL) -> Bool {
        guard Places.isRepository(url) else { return false }
        UserDefaults.standard.set(url.path, forKey: Places.repoDefaultsKey)
        repo = url
        return true
    }

    /// `install.sh`: installs the parts when some are missing, links the
    /// configs, and starts everything when asked to.
    func install(start: Bool) async -> Bool {
        guard let installer = script("install.sh") else { return false }
        var arguments = [installer]
        if !state.partsInstalled { arguments.append("--deps") }
        if !start { arguments.append("--no-start") }
        if start && !state.menuBarHides { arguments.append("--hide-menubar") }
        let ok = await console.run("/bin/zsh", arguments, in: repo,
                                   title: (["./install.sh"] + arguments.dropFirst()).joined(separator: " "))
        await refresh()
        return ok
    }

    func saveSettings() async {
        guard settings != savedSettings else { return }
        if demo == nil {
            do { try settings.save() } catch {
                console.note("Could not write \(Places.display(Places.settings)): \(error.localizedDescription)")
                return
            }
        }
        savedSettings = settings
        await reloadBar()
    }

    func reloadBar() async {
        guard demo != nil || state.running.contains(.sketchybar) else { return }
        await console.run(Shell.which("sketchybar") ?? "/opt/homebrew/bin/sketchybar", ["--reload"],
                          title: "sketchybar --reload")
    }

    func restartBar() async {
        await console.run(Shell.which("brew") ?? "/opt/homebrew/bin/brew", ["services", "restart", "sketchybar"],
                          title: "brew services restart sketchybar")
        await refresh()
    }

    func restartAeroSpace() async {
        let uid = getuid()
        if state.launchAgent || demo != nil {
            await console.run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/sh.kuro.aerospace"],
                              title: "launchctl kickstart -k gui/\(uid)/sh.kuro.aerospace")
        } else {
            await console.run("/usr/bin/open", ["-a", "AeroSpace"], title: "open -a AeroSpace")
        }
        try? await Task.sleep(for: .seconds(1))
        await refresh()
    }

    func runChecks() async {
        guard let checks = script("scripts/check.sh") else { return }
        await console.run("/bin/zsh", [checks], in: repo, title: "scripts/check.sh")
    }

    func applyBindings(check: Bool) async -> Bool {
        guard let apply = script("scripts/kuro-apply.sh") else { return false }
        return await console.run("/bin/zsh", check ? [apply, "--check"] : [apply], in: repo,
                                 title: "scripts/kuro-apply.sh" + (check ? " --check" : ""))
    }

    func setMenuBarHides(_ hides: Bool) async {
        guard let kuro = script("scripts/kuro.sh") else { return }
        await console.run("/bin/zsh", [kuro, "menubar", hides ? "hide" : "show"], in: repo,
                          title: "scripts/kuro.sh menubar \(hides ? "hide" : "show")")
        if demo != nil { state.menuBarHides = hides } else { await refresh() }
    }

    /// The parts that switch on and off (scripts/kuro.sh).
    enum Power: String { case all, bar, windows }

    func isOn(_ part: Power) -> Bool {
        switch part {
        case .bar: state.running.contains(.sketchybar)
        case .windows: state.running.contains(.aerospace)
        case .all: isOn(.bar) && isOn(.windows)
        }
    }

    func setPower(_ part: Power, on: Bool) async {
        guard let kuro = script("scripts/kuro.sh") else { return }
        await console.run("/bin/zsh", [kuro, on ? "on" : "off", part.rawValue], in: repo,
                          title: "scripts/kuro.sh \(on ? "on" : "off") \(part.rawValue)")
        if demo != nil {
            let services: [SystemState.Service] = switch part {
            case .bar: [.sketchybar, .topguard, .mediawatch]
            case .windows: [.aerospace, .borders]
            case .all: SystemState.Service.allCases
            }
            if on { state.running.formUnion(services) } else { state.running.subtract(services) }
            if part != .windows { state.menuBarHides = on }
        } else {
            try? await Task.sleep(for: .milliseconds(600))
            await refresh()
        }
    }

    /// The agents' `open` (sketchybar/plugins/agent_open.sh). Only ever adds
    /// or removes its own link: a ~/.local/bin/open that is something else is
    /// left alone and said so.
    func setAgentOpen(_ on: Bool) async {
        guard let repo else { return }
        let shim = repo.appendingPathComponent("sketchybar/plugins/agent_open.sh")
        let fm = FileManager.default
        if demo != nil { state.agentOpen = on; console.note(on ? "Linked ~/.local/bin/open" : "Removed ~/.local/bin/open"); return }
        if on {
            if fm.fileExists(atPath: Places.agentOpen.path) && !Places.links(Places.agentOpen, to: shim) {
                console.note("~/.local/bin/open is already something else, so it was left as it is.")
                return
            }
            try? fm.createDirectory(at: Places.agentOpen.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try fm.createSymbolicLink(at: Places.agentOpen, withDestinationURL: shim); console.note("Linked ~/.local/bin/open") }
            catch { console.note("Could not link ~/.local/bin/open: \(error.localizedDescription)") }
        } else if Places.links(Places.agentOpen, to: shim) {
            try? fm.removeItem(at: Places.agentOpen)
            console.note("Removed ~/.local/bin/open")
        }
        await refresh()
    }

    // MARK: updates

    struct UpdateCheck: Equatable {
        var branch = ""
        var localChanges: [String] = []
        var incoming: [String] = []
        var checked = false
        var failed: String?
    }
    var update = UpdateCheck()

    func checkForUpdates() async {
        if let demo { update = demo.update; return }
        guard let repo else { return }
        var check = UpdateCheck()
        let git = "/usr/bin/git"
        check.branch = (await Shell.capture(git, ["rev-parse", "--abbrev-ref", "HEAD"], in: repo)).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        check.localChanges = (await Shell.capture(git, ["status", "--porcelain", "--untracked-files=no"], in: repo)).output
            .split(separator: "\n").map { String($0) }
        let fetch = await Shell.capture(git, ["fetch", "--quiet", "origin"], in: repo, timeout: 60)
        if !fetch.ok { check.failed = fetch.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        check.incoming = (await Shell.capture(git, ["log", "--format=%s", "HEAD..@{u}"], in: repo)).output
            .split(separator: "\n").map { String($0) }
        check.checked = true
        update = check
    }

    /// Pull, then everything that follows from new code: the AeroSpace config
    /// rebuilt, the bar reloaded, this app rebuilt into ~/Applications.
    func applyUpdate() async -> Bool {
        guard let repo else { return false }
        guard await console.run("/usr/bin/git", ["pull", "--ff-only"], in: repo, title: "git pull --ff-only") else {
            return false
        }
        _ = await applyBindings(check: false)
        await reloadBar()
        if let build = script("scripts/build-app.sh") {
            await console.run("/bin/zsh", [build, "--install"], in: repo, title: "scripts/build-app.sh --install")
        }
        await checkForUpdates()
        return true
    }

    func openSettingsPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: demo

    private func demoAdvance(_ executable: String, _ arguments: [String]) {
        guard demo != nil else { return }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if name == "xcode-select" { state.installed.insert(.commandLineTools) }
        if arguments.first?.hasSuffix("install.sh") == true {
            state.installed.formUnion(SystemState.Part.allCases)
            state.barLinked = true; state.aerospaceLinked = true; state.launchAgent = true
            if !arguments.contains("--no-start") {
                state.running.formUnion(SystemState.Service.allCases)
                state.menuBarHides = true
            }
        }
    }
}
