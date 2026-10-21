import SwiftUI

/// The bar's world, carried into a window: the void it sits on, its pills,
/// the white active chip, the hairline border, the system status colours,
/// one purple. Values are colors.sh's.
enum Kuro {
    static let void = Color(red: 0.039, green: 0.039, blue: 0.043)          // the desktop under the bar
    static let rail = Color(red: 0.067, green: 0.067, blue: 0.075)          // the step and section list
    static let pill = Color(red: 0.110, green: 0.110, blue: 0.118)          // 0x1c1c1e
    static let inset = Color(red: 0.027, green: 0.027, blue: 0.031)         // the console well
    static let hairline = Color.white.opacity(0.13)                          // 0x59ffffff, quieter in a window
    static let text = Color(red: 0.961, green: 0.961, blue: 0.969)          // 0xf5f5f7
    static let muted = Color(red: 0.557, green: 0.557, blue: 0.576)         // 0x8e8e93
    static let faint = Color(red: 0.282, green: 0.282, blue: 0.290)         // 0x48484a, empty workspace
    static let accent = Color(red: 0.749, green: 0.353, blue: 0.949)        // 0xbf5af2
    static let green = Color(red: 0.196, green: 0.843, blue: 0.294)         // 0x32d74b
    static let amber = Color(red: 1.0, green: 0.624, blue: 0.039)           // 0xff9f0a
    static let red = Color(red: 1.0, green: 0.271, blue: 0.227)             // 0xff453a

    static let mono = Font.system(size: 11.5, design: .monospaced)
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
}

/// The white capsule: the bar's active workspace chip, as the one action that
/// moves you forward.
struct ChipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Kuro.pill)
            .padding(.horizontal, 18).frame(height: 30)
            .background(Capsule().fill(Kuro.text.opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.28)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A pill with a hairline, the bar's own chrome, for everything else.
struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(enabled ? Kuro.text : Kuro.muted.opacity(0.6))
            .padding(.horizontal, 14).frame(height: 28)
            .background(Capsule().fill(configuration.isPressed ? Kuro.pill.opacity(0.6) : Kuro.pill))
            .overlay(Capsule().strokeBorder(Kuro.hairline))
    }
}

/// A part's state, in shape as well as colour: a drawn ring that closes when
/// it is done, the way the bar's battery ring fills. Never colour alone.
struct StateMark: View {
    enum Value: Equatable { case done, working, waiting, attention, failed, off }
    let value: Value
    var size: CGFloat = 16
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(Kuro.faint, lineWidth: 1.5)
            switch value {
            case .done:
                Circle().fill(Kuro.green)
                Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .heavy)).foregroundStyle(Kuro.void)
            case .working:
                Circle().trim(from: 0, to: 0.28)
                    .stroke(Kuro.text, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .padding(0.75)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true } }
            case .attention:
                Circle().fill(Kuro.amber)
                Image(systemName: "exclamationmark").font(.system(size: size * 0.52, weight: .heavy)).foregroundStyle(Kuro.void)
            case .failed:
                Circle().fill(Kuro.red)
                Image(systemName: "xmark").font(.system(size: size * 0.45, weight: .heavy)).foregroundStyle(Kuro.void)
            case .waiting, .off:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .animation(Kuro.spring, value: value)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private var label: String {
        switch value {
        case .done: "Done"
        case .working: "In progress"
        case .waiting: "Not yet"
        case .attention: "Needs you"
        case .failed: "Failed"
        case .off: "Off"
        }
    }
}

/// The live console: every command as it runs, in the bar's monospace well.
struct ConsoleView: View {
    let console: Console
    var emptyText = "Nothing has run yet. What Kuro runs appears here, line by line."

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if console.lines.isEmpty {
                        Text(emptyText).font(Kuro.mono).foregroundStyle(Kuro.faint)
                    }
                    ForEach(console.lines) { line in
                        row(line).id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .textSelection(.enabled)
            }
            .onChange(of: console.lines.count) {
                if let last = console.lines.last { withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Kuro.inset))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Kuro.hairline))
        .accessibilityLabel("Command output")
    }

    @ViewBuilder private func row(_ line: Console.Line) -> some View {
        switch line.kind {
        case .command:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("$").foregroundStyle(Kuro.accent)
                Text(line.text).foregroundStyle(Kuro.text)
            }.font(Kuro.mono.weight(.semibold)).padding(.top, 6)
        case .output:
            Text(line.text).font(Kuro.mono).foregroundStyle(Kuro.muted)
        case .success:
            Label(line.text, systemImage: "checkmark").font(Kuro.mono.weight(.semibold)).foregroundStyle(Kuro.green)
        case .failure:
            Label(line.text, systemImage: "xmark").font(Kuro.mono.weight(.semibold)).foregroundStyle(Kuro.red)
        case .note:
            Text(line.text).font(Kuro.mono).foregroundStyle(Kuro.text.opacity(0.85))
        }
    }
}

/// A titled block of the detail pane.
struct Block<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Kuro.text)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Kuro.muted).fixedSize(horizontal: false, vertical: true) }
            }
            content
        }
    }
}

/// One line of a status list: mark, name, what it is for, an action.
struct StatusRow<Trailing: View>: View {
    let mark: StateMark.Value
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            StateMark(value: mark)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Kuro.text)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Kuro.muted)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

extension StatusRow where Trailing == EmptyView {
    init(mark: StateMark.Value, title: String, detail: String) {
        self.init(mark: mark, title: title, detail: detail) { EmptyView() }
    }
}

/// The synthetic-data label for `--demo`, so a screenshot never passes for a real Mac.
struct DemoTag: View {
    var body: some View {
        Text("Demo · nothing is installed or run")
            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Kuro.accent)
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(Kuro.accent.opacity(0.14)))
    }
}
