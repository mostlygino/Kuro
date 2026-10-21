import AppKit
import SwiftUI

/// After setup: the same two panes. Sections on the left, the live state and
/// its controls on the right, and the console under whatever just ran.
struct ManagerView: View {
    @Bindable var model: KuroModel
    var rerunSetup: () -> Void
    @State private var section: Pane = .health

    enum Pane: String, CaseIterable, Identifiable {
        case health, badges, general, keys, updates
        var id: String { rawValue }
        var title: String {
            switch self {
            case .health: "Health"
            case .badges: "Badges"
            case .general: "Menu bar and clock"
            case .keys: "Your keys"
            case .updates: "Updates"
            }
        }
        var symbol: String {
            switch self {
            case .health: "waveform.path.ecg"
            case .badges: "capsule.portrait"
            case .general: "menubar.rectangle"
            case .keys: "keyboard"
            case .updates: "arrow.down.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider().overlay(Kuro.hairline)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(section.title).font(.system(size: 26, weight: .semibold)).foregroundStyle(Kuro.text)
                            Spacer()
                            if model.refreshing { ProgressView().controlSize(.small) }
                        }
                        pane.frame(maxWidth: 600, alignment: .leading)
                    }
                    .padding(.horizontal, 40).padding(.top, 44).padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(section)
                    .transition(.opacity)
                }
                .scrollIndicators(.never)
                if !model.console.lines.isEmpty || model.console.isRunning {
                    ConsoleView(console: model.console)
                        .frame(height: 190)
                        .padding(.horizontal, 28).padding(.bottom, 22)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(Kuro.spring, value: model.console.lines.isEmpty)
        }
        .background(Kuro.void)
        .onAppear { if let named = Demo.argument("section").flatMap(Pane.init(rawValue:)) { section = named } }
        .onChange(of: section) { model.console.clear() }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Wordmark().padding(.bottom, 26)
            ForEach(Pane.allCases) { pane in
                Button { withAnimation(.easeOut(duration: 0.15)) { section = pane } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: pane.symbol).frame(width: 18)
                            .foregroundStyle(pane == section ? Kuro.text : Kuro.muted)
                        Text(pane.title).font(.system(size: 13, weight: pane == section ? .semibold : .regular))
                            .foregroundStyle(pane == section ? Kuro.text : Kuro.muted)
                        Spacer()
                        if pane == .health && !model.state.healthy {
                            StateMark(value: .attention, size: 13)
                        }
                        if pane == .updates && !model.update.incoming.isEmpty {
                            Text("\(model.update.incoming.count)").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Kuro.pill).padding(.horizontal, 6).frame(height: 17)
                                .background(Capsule().fill(Kuro.text))
                                .accessibilityLabel("\(model.update.incoming.count) updates")
                        }
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(pane == section ? Kuro.pill : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if model.demo != nil { DemoTag().padding(.bottom, 8) }
            if let repo = model.repo {
                Text(Places.display(repo)).font(Kuro.mono).foregroundStyle(Kuro.faint).padding(.horizontal, 10)
            }
        }
        .padding(.horizontal, 14).padding(.top, 40).padding(.bottom, 18)
        .frame(width: 232)
        .background(Kuro.rail)
    }

    @ViewBuilder private var pane: some View {
        switch section {
        case .health: HealthPane(model: model, rerunSetup: rerunSetup)
        case .badges: BadgesPane(model: model)
        case .general: GeneralPane(model: model)
        case .keys: KeysPane(model: model)
        case .updates: UpdatesPane(model: model)
        }
    }
}

/// Runs one action at a time from a pane, and greys the rest while it does.
struct ActionButton: View {
    let title: String
    @Bindable var model: KuroModel
    var primary = false
    let action: () async -> Void

    var body: some View {
        let button = Button(title) { Task { await action() } }.disabled(model.console.isRunning)
        if primary { button.buttonStyle(ChipButtonStyle()) } else { button.buttonStyle(PillButtonStyle()) }
    }
}

struct HealthPane: View {
    @Bindable var model: KuroModel
    var rerunSetup: () -> Void

    var body: some View {
        PowerBlock(model: model)
        Text(model.state.healthy ? "Everything Kuro needs is installed, linked and running."
                                 : "Something Kuro needs is not running or not in place. Each line says what, and how to bring it back.")
            .lede()
        Block(title: "Running") {
            VStack(spacing: 0) {
                ForEach(SystemState.Service.allCases) { service in
                    StatusRow(mark: model.state.running.contains(service) ? .done : .attention, title: service.name,
                              detail: detail(service))
                    Divider().overlay(Kuro.hairline)
                }
            }
        }
        Block(title: "In place") {
            VStack(spacing: 0) {
                StatusRow(mark: model.state.partsInstalled ? .done : .attention, title: "Parts installed",
                          detail: missingParts)
                Divider().overlay(Kuro.hairline)
                StatusRow(mark: model.state.linked ? .done : .attention, title: "Configs linked",
                          detail: "~/.config/sketchybar, ~/.aerospace.toml, AeroSpace's login agent")
                Divider().overlay(Kuro.hairline)
                StatusRow(mark: model.state.menuBarHides ? .done : .attention, title: "Menu bar hides itself",
                          detail: model.state.menuBarHides ? "The bar has the top of the screen." : "The macOS menu bar will cover the bar.")
            }
        }
        HStack(spacing: 10) {
            ActionButton(title: "Reload the bar", model: model) { await model.reloadBar() }
            ActionButton(title: "Restart the bar", model: model) { await model.restartBar() }
            ActionButton(title: "Restart AeroSpace", model: model) { await model.restartAeroSpace() }
        }
        HStack(spacing: 10) {
            ActionButton(title: "Run the checks", model: model) { await model.runChecks() }
            if !model.state.linked || !model.state.partsInstalled {
                ActionButton(title: "Repair", model: model, primary: true) { _ = await model.install(start: true) }
            }
            Button("Set up again…") { rerunSetup() }.buttonStyle(PillButtonStyle())
        }
    }

    private var missingParts: String {
        let missing = SystemState.Part.allCases.filter { !model.state.installed.contains($0) }.map(\.name)
        return missing.isEmpty ? "AeroSpace, SketchyBar, JankyBorders, media-control, the font"
                               : "Missing: " + missing.joined(separator: ", ")
    }

    private func detail(_ service: SystemState.Service) -> String {
        let on = model.state.running.contains(service)
        switch service {
        case .aerospace: return on ? "Tiling, started by its login agent" : "Not running: Restart AeroSpace"
        case .sketchybar: return on ? "Drawing the bar" : "Not running: Restart the bar"
        case .borders: return on ? "The ring round the focused window" : "Not running: Restart the bar starts it again"
        case .topguard: return on ? "Holding the menu bar back, so SketchyBar has Accessibility" : "Needs Accessibility for SketchyBar"
        case .mediawatch: return on ? "Reading Now Playing" : "Starts with the bar; check System Audio Recording"
        }
    }
}

/// Kuro on and off: all of it, or the bar and the windows apart. Off stays
/// off across a restart; the macOS menu bar comes back with the bar's going.
struct PowerBlock: View {
    @Bindable var model: KuroModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(model.isOn(.all) ? Kuro.text : Kuro.pill)
                    Image(systemName: "power").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(model.isOn(.all) ? Kuro.pill : Kuro.muted)
                }
                .frame(width: 34, height: 34)
                .overlay(Circle().strokeBorder(Kuro.hairline))
                .animation(Kuro.spring, value: model.isOn(.all))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kuro").font(.system(size: 15, weight: .semibold)).foregroundStyle(Kuro.text)
                    Text(summary).font(.system(size: 12)).foregroundStyle(Kuro.muted)
                }
                Spacer()
                toggle(.all, label: "Kuro")
            }
            .padding(.vertical, 12)
            Divider().overlay(Kuro.hairline)
            row(.bar, title: "The bar", detail: model.isOn(.bar) ? "SketchyBar, with the macOS menu bar hidden"
                                                                 : "Off: the macOS menu bar is back")
            Divider().overlay(Kuro.hairline)
            row(.windows, title: "Windows", detail: model.isOn(.windows) ? "AeroSpace tiling, and the ring round the focused window"
                                                                         : "Off: windows stay where they are, untiled")
        }
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Kuro.rail))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Kuro.hairline))
    }

    private var summary: String {
        switch (model.isOn(.bar), model.isOn(.windows)) {
        case (true, true): "On. Off stays off, even across a restart."
        case (false, false): "Off. The Mac looks the way macOS does."
        case (true, false): "The bar is on; windows are not tiled."
        case (false, true): "Windows are tiled; the bar is off."
        }
    }

    private func row(_ part: KuroModel.Power, title: String, detail: String) -> some View {
        StatusRow(mark: model.isOn(part) ? .done : .off, title: title, detail: detail) {
            toggle(part, label: title)
        }
        .padding(.vertical, 3)
    }

    private func toggle(_ part: KuroModel.Power, label: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { model.isOn(part) },
            set: { on in Task { await model.setPower(part, on: on) } }))
            .labelsHidden().toggleStyle(.switch).tint(Kuro.accent)
            .disabled(model.console.isRunning || model.repo == nil)
    }
}

struct BadgesPane: View {
    @Bindable var model: KuroModel
    var body: some View {
        Text("Left to right as they sit in the bar's pill. A badge that is off is never built: no item, no script, nothing read.")
            .lede()
        BadgePicker(model: model)
        SaveBar(model: model)
    }
}

struct GeneralPane: View {
    @Bindable var model: KuroModel
    var body: some View {
        Block(title: "Hide the macOS menu bar", detail: "The bar takes its place. Off, the macOS menu bar covers the bar.") {
            Toggle("Hide the macOS menu bar", isOn: Binding(
                get: { model.state.menuBarHides },
                set: { hides in Task { await model.setMenuBarHides(hides) } }))
                .labelsHidden().toggleStyle(.switch).tint(Kuro.accent).disabled(model.console.isRunning)
        }
        Block(title: "Bring the menu bar back from the middle",
              detail: "Resting the pointer at the top centre of a screen shows the macOS menu bar; everywhere else it stays away.") {
            Picker("Opening", selection: $model.settings.menuBarOpening) {
                Text("None").tag(0); Text("Narrow").tag(300); Text("Wide").tag(600)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 280)
        }
        Block(title: "The clock's calendar", detail: "What the Open row in the clock card opens. Empty is Calendar.") {
            ClockField(model: model)
        }
        Block(title: "Agent spaces for coding agents",
              detail: "Apps that Claude Code, Codex or Zeron start with open go to a hidden workspace, F1 to F12, instead of landing on yours; ⌃⌘1 to 0 looks in. Installs ~/.local/bin/open, which stays the system's open for everything else.") {
            Toggle("Agent spaces", isOn: Binding(
                get: { model.state.agentOpen },
                set: { on in Task { await model.setAgentOpen(on) } }))
                .labelsHidden().toggleStyle(.switch).tint(Kuro.accent)
        }
        SaveBar(model: model)
    }
}

/// Settings changes are held until saved, then the bar reloads once.
struct SaveBar: View {
    @Bindable var model: KuroModel
    var body: some View {
        let changed = model.settings != model.savedSettings
        HStack(spacing: 10) {
            ActionButton(title: "Save and reload the bar", model: model, primary: true) { await model.saveSettings() }
                .disabled(!changed || (!model.settings.clockURL.isEmpty && !KuroSettings.isValidURL(model.settings.clockURL)))
            if changed {
                Button("Revert") { withAnimation(Kuro.spring) { model.settings = model.savedSettings } }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .padding(.top, 4)
    }
}

struct KeysPane: View {
    @Bindable var model: KuroModel
    @State private var text = ""
    @State private var loaded = ""

    var body: some View {
        Text("Your own AeroSpace bindings and modes, kept out of Kuro's repository so an update never touches them. Plain bindings join the main mode; [tables] are added as they are. Each change is checked by AeroSpace before it applies, and rolled back if it is refused.")
            .lede()
        TextEditor(text: $text)
            .font(.system(size: 12.5, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(minHeight: 220)
            .background(RoundedRectangle(cornerRadius: 12).fill(Kuro.inset))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Kuro.hairline))
            .accessibilityLabel("Your AeroSpace bindings")
        HStack(spacing: 10) {
            ActionButton(title: "Check", model: model) { await save(apply: false) }
            ActionButton(title: "Apply", model: model, primary: true) { await save(apply: true) }
                .disabled(text == loaded && model.console.lines.isEmpty == false)
            Spacer()
            Button("Kuro's keys") { openReference() }.buttonStyle(PillButtonStyle())
        }
        .onAppear(perform: load)
    }

    private static let starter = """
    # Your own AeroSpace bindings. Plain lines join the main mode, for example:
    # cmd-shift-g = 'exec-and-forget open -a Ghostty'
    #
    # Tables are added at the end as they are:
    # [mode.mine.binding]

    """

    private func load() {
        if model.demo != nil {
            text = Self.starter + "cmd-shift-g = 'exec-and-forget open -a Ghostty'\n"
        } else {
            text = (try? String(contentsOf: Places.localBindings, encoding: .utf8)) ?? Self.starter
        }
        loaded = text
    }

    /// Writes the file, then has AeroSpace check (and with Apply, load) the
    /// merged config; a refused one leaves the last good config running.
    private func save(apply: Bool) async {
        if model.demo == nil {
            do {
                try FileManager.default.createDirectory(at: Places.kuro, withIntermediateDirectories: true)
                let previous = try? String(contentsOf: Places.localBindings, encoding: .utf8)
                try text.write(to: Places.localBindings, atomically: true, encoding: .utf8)
                let ok = await model.applyBindings(check: !apply)
                if !apply || !ok, let previous { try previous.write(to: Places.localBindings, atomically: true, encoding: .utf8) }
                if apply && ok { loaded = text }
            } catch {
                model.console.note("Could not write \(Places.display(Places.localBindings)): \(error.localizedDescription)")
            }
        } else {
            _ = await model.applyBindings(check: !apply)
            if apply { loaded = text }
        }
    }

    private func openReference() {
        guard let repo = model.repo else { return }
        NSWorkspace.shared.open(repo.appendingPathComponent("docs/keys.html"))
    }
}

struct UpdatesPane: View {
    @Bindable var model: KuroModel

    var body: some View {
        let update = model.update
        Text("Kuro updates from its GitHub repository into your copy. Your settings, your keys and local.sh live outside it, so a pull never changes them.")
            .lede()
        if let repo = model.repo {
            StatusRow(mark: update.failed == nil ? (update.checked ? .done : .waiting) : .attention,
                      title: Places.display(repo),
                      detail: update.branch.isEmpty ? "Your copy of Kuro" : "Your copy of Kuro, on \(update.branch)")
        }
        Block(title: update.checked ? (update.incoming.isEmpty ? "Up to date" : "\(update.incoming.count) new on \(update.branch)") : "Not checked yet") {
            if let failed = update.failed {
                Label("Could not reach GitHub: \(failed)", systemImage: "wifi.exclamationmark")
                    .font(.system(size: 12)).foregroundStyle(Kuro.amber)
            }
            if !update.incoming.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(update.incoming, id: \.self) { subject in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Kuro.accent).frame(width: 5, height: 5).offset(y: -2)
                            Text(subject).font(.system(size: 12.5)).foregroundStyle(Kuro.text)
                        }
                    }
                }
            }
            if !update.localChanges.isEmpty {
                Label("Your copy has changes of its own (\(update.localChanges.count) files). Commit or set them aside before updating; Kuro will not overwrite them.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Kuro.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack(spacing: 10) {
            ActionButton(title: "Check for updates", model: model) { await model.checkForUpdates() }
            if !update.incoming.isEmpty {
                ActionButton(title: "Update", model: model, primary: true) { _ = await model.applyUpdate() }
                    .disabled(!update.localChanges.isEmpty)
            }
        }
        .task { if !update.checked { await model.checkForUpdates() } }
    }
}
