import AppKit
import SwiftUI

/// First run: the steps on the left say in plain words what is happening,
/// the real commands stream on the right, and each step's ring closes as it
/// lands. Nothing runs that you cannot see.
struct OnboardingView: View {
    @Bindable var model: KuroModel
    var finish: () -> Void
    @State private var step: Step = .welcome
    @State private var busy = false

    enum Step: String, CaseIterable, Identifiable {
        case welcome, requirements, source, install, badges, menuBar, start, permissions
        var id: String { rawValue }
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .requirements: "Before you start"
            case .source: "Get Kuro"
            case .install: "Install the parts"
            case .badges: "Your badges"
            case .menuBar: "The menu bar"
            case .start: "Start"
            case .permissions: "Permissions"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider().overlay(Kuro.hairline)
            detail
        }
        .background(Kuro.void)
        .onAppear {
            if let named = Demo.argument("step").flatMap(Step.init(rawValue:)) { step = named }
        }
    }

    // MARK: the rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark().padding(.bottom, 26)
            ForEach(Step.allCases) { item in
                Button {
                    if reachable(item) { withAnimation(Kuro.spring) { step = item } }
                } label: {
                    HStack(spacing: 11) {
                        StateMark(value: mark(item), size: 15)
                        Text(item.title)
                            .font(.system(size: 13, weight: item == step ? .semibold : .regular))
                            .foregroundStyle(item == step ? Kuro.text : Kuro.muted)
                            .opacity(reachable(item) || item == step ? 1 : 0.62)
                        Spacer()
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(item == step ? Kuro.pill : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!reachable(item) || busy)
                .accessibilityValue(item == step ? "Current step" : "")
            }
            Spacer()
            if model.demo != nil { DemoTag() }
        }
        .padding(.horizontal, 14).padding(.top, 40).padding(.bottom, 18)
        .frame(width: 232)
        .background(Kuro.rail)
    }

    private func index(_ s: Step) -> Int { Step.allCases.firstIndex(of: s) ?? 0 }

    private func reachable(_ s: Step) -> Bool { index(s) <= index(step) || done(Step.allCases[max(0, index(s) - 1)]) }

    private func done(_ s: Step) -> Bool {
        switch s {
        case .welcome: index(step) > 0
        case .requirements: model.state.prerequisitesMet
        case .source: model.repo != nil
        case .install: model.state.partsInstalled && model.state.linked
        case .badges, .menuBar: index(step) > index(s)
        case .start: model.state.running.contains(.sketchybar) && model.state.running.contains(.aerospace)
        case .permissions: false
        }
    }

    private func mark(_ s: Step) -> StateMark.Value {
        if busy && s == step { return .working }
        if done(s) { return .done }
        if s == step && s == .requirements && !model.state.prerequisitesMet { return .attention }
        return .waiting
    }

    // MARK: the detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(step.title).font(.system(size: 26, weight: .semibold)).foregroundStyle(Kuro.text)
                    content.frame(maxWidth: 560, alignment: .leading)
                }
                .padding(.horizontal, 40).padding(.top, 44).padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(step)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
            }
            .scrollIndicators(.never)
            if showsConsole {
                ConsoleView(console: model.console)
                    .frame(height: 210)
                    .padding(.horizontal, 28)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            footer
        }
        .animation(Kuro.spring, value: step)
        .animation(Kuro.spring, value: showsConsole)
    }

    private var showsConsole: Bool { [.requirements, .source, .install, .start].contains(step) || !model.console.lines.isEmpty && step == .menuBar }

    private var footer: some View {
        HStack {
            if index(step) > 0 {
                Button("Back") { withAnimation(Kuro.spring) { step = Step.allCases[index(step) - 1] } }
                    .buttonStyle(PillButtonStyle()).disabled(busy)
            }
            Spacer()
            primary
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
    }

    @ViewBuilder private var primary: some View {
        switch step {
        case .welcome:
            Button("Set up Kuro") { advance() }.buttonStyle(ChipButtonStyle()).keyboardShortcut(.defaultAction)
        case .requirements:
            Button("Continue") { advance() }.buttonStyle(ChipButtonStyle())
                .disabled(!model.state.prerequisitesMet).keyboardShortcut(.defaultAction)
        case .source:
            Button("Continue") { advance() }.buttonStyle(ChipButtonStyle())
                .disabled(model.repo == nil || busy).keyboardShortcut(.defaultAction)
        case .install:
            if done(.install) {
                Button("Continue") { advance() }.buttonStyle(ChipButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                Button(model.state.partsInstalled ? "Link the configs" : "Install") {
                    run { _ = await model.install(start: false) }
                }.buttonStyle(ChipButtonStyle()).disabled(busy).keyboardShortcut(.defaultAction)
            }
        case .badges:
            Button("Continue") { run { await model.saveSettings() }; advance() }
                .buttonStyle(ChipButtonStyle()).keyboardShortcut(.defaultAction)
        case .menuBar:
            Button("Continue") { run { await model.saveSettings() }; advance() }
                .buttonStyle(ChipButtonStyle()).keyboardShortcut(.defaultAction)
        case .start:
            if done(.start) {
                Button("Continue") { advance() }.buttonStyle(ChipButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                Button("Start Kuro") { run { _ = await model.install(start: true) } }
                    .buttonStyle(ChipButtonStyle()).disabled(busy).keyboardShortcut(.defaultAction)
            }
        case .permissions:
            Button("Finish") { finish() }.buttonStyle(ChipButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }

    private func advance() {
        guard index(step) + 1 < Step.allCases.count else { return }
        model.console.clear()
        withAnimation(Kuro.spring) { step = Step.allCases[index(step) + 1] }
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task { await work(); busy = false }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: WelcomeStep(repo: model.repo)
        case .requirements: RequirementsStep(model: model, run: run)
        case .source: SourceStep(model: model, run: run)
        case .install: InstallStep(model: model)
        case .badges:
            Text("Each badge sits in one pill on the right of the bar. Switch on the ones you want; you can change this any time.")
                .lede()
            BadgePicker(model: model)
        case .menuBar: MenuBarStep(model: model, run: run)
        case .start: StartStep(model: model)
        case .permissions: PermissionsStep(model: model)
        }
    }
}

extension Text {
    func lede() -> some View {
        font(.system(size: 13.5)).foregroundStyle(Kuro.muted).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 黒 and the name, the way the README sets it.
struct Wordmark: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("黒").font(.system(size: 22, weight: .semibold)).foregroundStyle(Kuro.text)
            Text("Kuro").font(.system(size: 17, weight: .semibold)).foregroundStyle(Kuro.text)
        }
        .padding(.horizontal, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kuro")
    }
}

// MARK: steps

struct WelcomeStep: View {
    let repo: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            BarHero()
            Text("Kuro is a desktop that is mostly not there: AeroSpace tiles the windows, a black bar draws every state it shows, and a thin ring marks the window you are in.")
                .lede()
            Text("This sets it up from nothing. Every command it runs streams beside the step it belongs to, and nothing in your existing setup is deleted: whatever is in the way is moved aside with a date on it.")
                .lede()
            VStack(alignment: .leading, spacing: 8) {
                fact("arrow.down.circle", "Most of the wait is Homebrew downloading the parts.")
                fact("lock.shield", "macOS asks for two or three permissions on the way; the last step says which.")
                fact("arrow.uturn.backward", "Undo is in the README: remove the links and restore the backups.")
            }
        }
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).font(.system(size: 12.5)).foregroundStyle(Kuro.text.opacity(0.9)) }
            icon: { Image(systemName: symbol).foregroundStyle(Kuro.accent).frame(width: 18) }
    }
}

/// The thesis, first: the real bar, both ends of it, as the README shows it.
/// Screenshots of the author's bar, shipped in the app bundle.
struct BarHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(["bar-left", "bar-right"], id: \.self) { name in
                if let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(maxWidth: name == "bar-left" ? 560 : 330, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Kuro.hairline))
                        .frame(maxWidth: .infinity, alignment: name == "bar-left" ? .leading : .trailing)
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown || reduceMotion ? 0 : -6)
                        .animation(.easeOut(duration: 0.5).delay(name == "bar-left" ? 0.05 : 0.2), value: shown)
                }
            }
        }
        .frame(maxWidth: 560)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The Kuro bar: workspaces and Now Playing on the left, badges and the clock on the right")
        .onAppear { shown = true }
    }
}

struct RequirementsStep: View {
    @Bindable var model: KuroModel
    let run: (@escaping () async -> Void) -> Void
    static let brewCommand = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    var body: some View {
        Text("Two things come first, from Apple and from Homebrew, because they need your password and their own installers.")
            .lede()
        VStack(spacing: 0) {
            StatusRow(mark: model.state.macOSMajor >= 26 ? .done : .failed, title: "macOS 26 or later",
                      detail: model.state.macOSMajor >= 26 ? "This Mac runs macOS \(model.state.macOSMajor)." : "Kuro's helpers use macOS 26 APIs.")
            Divider().overlay(Kuro.hairline)
            StatusRow(mark: model.state.installed.contains(.commandLineTools) ? .done : .attention,
                      title: "Command line tools", detail: "Apple's compiler; the bar builds its helpers with it.") {
                if !model.state.installed.contains(.commandLineTools) {
                    Button("Install") { run { await model.installCommandLineTools() } }.buttonStyle(PillButtonStyle())
                }
            }
            Divider().overlay(Kuro.hairline)
            StatusRow(mark: model.state.installed.contains(.homebrew) ? .done : .attention,
                      title: "Homebrew", detail: "Installs AeroSpace, SketchyBar and the rest.") {
                if !model.state.installed.contains(.homebrew) {
                    Button("Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.brewCommand, forType: .string)
                        model.console.note("Copied. Paste it into Terminal, follow its prompts, then press Check again.")
                    }.buttonStyle(PillButtonStyle())
                }
            }
        }
        if !model.state.prerequisitesMet {
            HStack(spacing: 10) {
                Button("Open Terminal") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")) }
                    .buttonStyle(PillButtonStyle())
                Button("Check again") {
                    run {
                        if model.demo != nil { model.state.installed.formUnion([.commandLineTools, .homebrew]) }
                        else { await model.refresh() }
                    }
                }.buttonStyle(PillButtonStyle())
            }
        }
    }
}

struct SourceStep: View {
    @Bindable var model: KuroModel
    let run: (@escaping () async -> Void) -> Void
    @State private var destination = Places.home.appendingPathComponent("Kuro")

    var body: some View {
        if let repo = model.repo {
            Text("Kuro runs from a folder of its own: the bar and AeroSpace read their configs straight from it, so an update is a pull away.")
                .lede()
            StatusRow(mark: .done, title: Places.display(repo), detail: "Your copy of Kuro.") {
                Button("Choose another…") { choose() }.buttonStyle(PillButtonStyle())
            }
        } else {
            Text("Kuro runs from a copy of its repository. It is fetched once from GitHub into a folder you pick, and the bar and AeroSpace read their configs straight from there.")
                .lede()
            StatusRow(mark: .waiting, title: Places.display(destination), detail: "Where the copy goes. Nothing there is overwritten.") {
                Button("Change…") { pickDestination() }.buttonStyle(PillButtonStyle())
            }
            HStack(spacing: 10) {
                Button("Get Kuro") { run { _ = await model.clone(to: destination) } }.buttonStyle(PillButtonStyle())
                    .disabled(FileManager.default.fileExists(atPath: destination.path) && model.demo == nil)
                Button("I already have it…") { choose() }.buttonStyle(PillButtonStyle())
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the folder you cloned Kuro into."
        if panel.runModal() == .OK, let url = panel.url, !model.useRepository(url) {
            model.console.note("\(Places.display(url)) is not a copy of Kuro: there is no install.sh and aerospace.toml in it.")
        }
    }

    private func pickDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "Choose where the Kuro folder goes."
        if panel.runModal() == .OK, let url = panel.url { destination = url.appendingPathComponent("Kuro") }
    }
}

struct InstallStep: View {
    @Bindable var model: KuroModel
    var body: some View {
        Text("Kuro's installer brings in the parts with Homebrew, then links the configs from your copy into place. Anything already at those paths is moved aside first, never deleted.")
            .lede()
        VStack(spacing: 0) {
            ForEach(SystemState.Part.allCases.filter(\.brewInstalls)) { part in
                StatusRow(mark: model.state.installed.contains(part) ? .done : .waiting, title: part.name, detail: part.role)
                Divider().overlay(Kuro.hairline)
            }
            StatusRow(mark: model.state.linked ? .done : .waiting, title: "Configs linked",
                      detail: "~/.config/sketchybar, ~/.aerospace.toml and AeroSpace's login agent.")
        }
    }
}

struct MenuBarStep: View {
    @Bindable var model: KuroModel
    let run: (@escaping () async -> Void) -> Void

    var body: some View {
        Text("The bar sits where the macOS menu bar is, so the menu bar is set to hide itself, and Kuro keeps it from sliding down whenever the pointer touches the top of the screen.")
            .lede()
        Block(title: "Bring the menu bar back from the middle",
              detail: "An opening at the top centre of each screen where resting the pointer still shows the macOS menu bar. Everywhere else it stays away.") {
            Picker("Opening", selection: $model.settings.menuBarOpening) {
                Text("None").tag(0)
                Text("Narrow").tag(300)
                Text("Wide").tag(600)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 280)
        }
        Block(title: "The clock's calendar", detail: "The clock card has an Open row. It opens Calendar unless you give it a web calendar.") {
            ClockField(model: model)
        }
    }
}

struct ClockField: View {
    @Bindable var model: KuroModel
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("https://… (leave empty for Calendar)", text: $model.settings.clockURL)
                .textFieldStyle(.roundedBorder).frame(width: 360)
                .font(.system(size: 12.5))
            if !model.settings.clockURL.isEmpty && !KuroSettings.isValidURL(model.settings.clockURL) {
                Label("Only an https link, without spaces or quotes. The bar would refuse anything else.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5)).foregroundStyle(Kuro.amber)
            }
        }
    }
}

struct StartStep: View {
    @Bindable var model: KuroModel
    var body: some View {
        Text("Starting hands AeroSpace to a login agent that brings it back if it ever stops, and starts the bar. The first start takes about twenty seconds while the bar compiles its helpers.")
            .lede()
        VStack(spacing: 0) {
            ForEach([SystemState.Service.aerospace, .sketchybar, .borders]) { service in
                StatusRow(mark: model.state.running.contains(service) ? .done : .waiting,
                          title: service.name, detail: model.state.running.contains(service) ? "Running" : "Not running yet")
                Divider().overlay(Kuro.hairline)
            }
            StatusRow(mark: model.state.menuBarHides ? .done : .waiting, title: "Menu bar hides itself",
                      detail: "So the bar has the top of the screen.")
        }
    }
}

struct PermissionsStep: View {
    @Bindable var model: KuroModel
    var body: some View {
        Text("macOS asks for these itself, once each. Kuro cannot read another app's permissions, so where it says so, it is going by what is running.")
            .lede()
        VStack(spacing: 0) {
            StatusRow(mark: model.state.running.contains(.aerospace) ? .done : .attention, title: "AeroSpace · Accessibility",
                      detail: model.state.running.contains(.aerospace) ? "Running, so it has it." : "AeroSpace asks when it first starts.") {
                Button("Open Settings") { model.openSettingsPane("Privacy_Accessibility") }.buttonStyle(PillButtonStyle())
            }
            Divider().overlay(Kuro.hairline)
            StatusRow(mark: model.state.running.contains(.topguard) ? .done : .attention, title: "SketchyBar · Accessibility",
                      detail: model.state.running.contains(.topguard) ? "The top-edge guard is running, which it cannot without it."
                                                                     : "Keeps the menu bar from sliding over the bar.") {
                Button("Open Settings") { model.openSettingsPane("Privacy_Accessibility") }.buttonStyle(PillButtonStyle())
            }
            Divider().overlay(Kuro.hairline)
            StatusRow(mark: .waiting, title: "Now Playing · System Audio Recording",
                      detail: "For the live waveform on podcasts; macOS asks the first time one plays.") {
                Button("Open Settings") { model.openSettingsPane("Privacy_ScreenCapture") }.buttonStyle(PillButtonStyle())
            }
            Divider().overlay(Kuro.hairline)
            StatusRow(mark: .waiting, title: "Wi-Fi badge · Location",
                      detail: "macOS counts a network's name as location; it asks once.") {
                Button("Open Settings") { model.openSettingsPane("Privacy_LocationServices") }.buttonStyle(PillButtonStyle())
            }
        }
    }
}
