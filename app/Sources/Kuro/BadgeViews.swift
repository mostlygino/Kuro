import SwiftUI

/// A badge as the bar draws it, on a piece of the bar's pill, cycling slowly
/// through its states: the preview is the bar's own renderer, not a picture of it.
struct BadgeMark: View {
    let badge: Badge
    let repo: URL?
    var on = true
    @State private var images: [NSImage] = []
    @State private var index = 0
    @State private var drawing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Capsule().fill(Kuro.pill).overlay(Capsule().strokeBorder(Kuro.hairline))
            if let image = images.isEmpty ? nil : images[index % images.count] {
                Image(nsImage: image)
                    .interpolation(.high)
                    .id(index)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            } else if drawing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "circle.dotted").foregroundStyle(Kuro.faint)
            }
        }
        .frame(width: 54, height: 34)
        .saturation(on ? 1 : 0)
        .opacity(on ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.25), value: on)
        .accessibilityHidden(true)
        .task(id: repo) {
            // Before Kuro is on the Mac there is no renderer to ask; the app's
            // own checkout, when it was built in one, stands in.
            let source = repo ?? Places.findRepository()
            var drawn: [NSImage] = []
            for state in badge.states {
                if let image = await Renderer.shared.image(for: state, repo: source) { drawn.append(image) }
            }
            images = drawn
            drawing = false
        }
        .task(id: images.count) {
            guard images.count > 1, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.4))
                withAnimation(.easeInOut(duration: 0.35)) { index += 1 }
            }
        }
    }
}

/// The badge chooser: each badge with its preview, what it does, and what it
/// reads, if anything of yours.
struct BadgePicker: View {
    @Bindable var model: KuroModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Badge.all) { badge in
                row(badge)
                if badge.id != Badge.all.last?.id { Divider().overlay(Kuro.hairline) }
            }
        }
    }

    private func row(_ badge: Badge) -> some View {
        let available = badge.isAvailable || model.demo != nil
        let binding = Binding(
            get: { model.settings.badges.contains(badge.id) },
            set: { on in
                withAnimation(Kuro.spring) {
                    if on { model.settings.badges.insert(badge.id) } else { model.settings.badges.remove(badge.id) }
                }
            })
        return HStack(alignment: .center, spacing: 14) {
            BadgeMark(badge: badge, repo: model.repo, on: binding.wrappedValue && available)
            VStack(alignment: .leading, spacing: 3) {
                Text(badge.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Kuro.text)
                Text(badge.summary).font(.system(size: 12)).foregroundStyle(Kuro.muted)
                if let privacy = badge.privacy, binding.wrappedValue {
                    Label(privacy, systemImage: "key")
                        .font(.system(size: 11.5)).foregroundStyle(Kuro.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let needs = badge.needs, !available {
                    Text("Needs \(needs.name), which is not installed.")
                        .font(.system(size: 11.5)).foregroundStyle(Kuro.muted)
                }
            }
            Spacer(minLength: 12)
            Toggle(badge.name, isOn: binding).labelsHidden().toggleStyle(.switch).tint(Kuro.accent)
                .disabled(!available)
        }
        .padding(.vertical, 10)
    }
}
