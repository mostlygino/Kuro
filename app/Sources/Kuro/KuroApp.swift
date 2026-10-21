// Direction: "Watch it install" (chosen 2026-10-20).
// World: Kuro's bar, carried into one window. The void it sits on, its dark
//   pills with a hairline, the white active chip as the one forward action,
//   system status colours always paired with a shape, one purple.
// Structure: two panes everywhere. Left, the steps (setup) or sections
//   (manager); right, plain words, the controls, and the live console of
//   whatever runs, so nothing happens out of sight.
// Signature: each step's ring closes as its command lands, like the bar's
//   battery ring; the badge previews are the bar's own renderers.
// Honesty: permissions inferred from what runs, and said so; `--demo` is
//   labelled as demo in the window.

import AppKit
import SwiftUI

@main
struct KuroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = KuroModel(demo: Demo.fromArguments)
    @AppStorage("setupFinished") private var setupFinished = false
    @State private var forceSetup = false

    var body: some Scene {
        Window("Kuro", id: "main") {
            Group {
                if showsSetup {
                    OnboardingView(model: model) {
                        setupFinished = true
                        forceSetup = false
                        model.console.clear()
                    }
                } else {
                    ManagerView(model: model) {
                        model.console.clear()
                        forceSetup = true
                    }
                }
            }
            .frame(minWidth: 900, idealWidth: 940, minHeight: 640, idealHeight: 680)
            .preferredColorScheme(.dark)
            .tint(Kuro.accent)
            .task { await model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                guard !model.console.isRunning else { return }
                Task { await model.refresh() }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Set Up Again…") { model.console.clear(); forceSetup = true }
            }
        }
    }

    /// Setup shows on first run, when asked for, in `--demo fresh`, and
    /// whenever this Mac plainly is not set up (no copy, nothing linked).
    private var showsSetup: Bool {
        if let demo = model.demo { return demo == .fresh || forceSetup }
        if forceSetup || !setupFinished { return true }
        return model.repo == nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// `--quit-after <seconds>`: for screenshots (docs/make_app_shots.sh).
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let text = Demo.argument("quit-after"), let seconds = Double(text) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
    }
}
