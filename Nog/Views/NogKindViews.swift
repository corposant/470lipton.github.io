import SwiftUI

extension NogKind {
    /// Note grey, Nog pink, Alarm amber: told apart by lightness and icon, not hue alone.
    var tint: Color {
        switch self {
        case .note: Theme.muted
        case .nog: Theme.pink
        case .alarm: Color(light: 0xC77800, dark: 0xFFB65C)
        }
    }
}

/// A small "Nog" / "Alarm" pill for rows.
struct KindBadge: View {
    let kind: NogKind

    var body: some View {
        Label(kind.label, systemImage: kind.systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(kind.tint)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .overlay(Capsule().strokeBorder(kind.tint.opacity(0.55), lineWidth: 1))
            .accessibilityLabel(kind.label)
    }
}

/// Three cards: Note · Nog · Alarm.
struct KindPicker: View {
    let selected: NogKind
    let pick: (NogKind) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(NogKind.allCases) { kind in
                let isOn = kind == selected
                Button {
                    pick(kind)
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: kind.systemImage).font(.system(size: 18, weight: .medium))
                        Text(kind.label).font(.nogTitle(14))
                    }
                    .foregroundStyle(isOn ? kind.tint : Color.primary.opacity(0.75))
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(isOn ? kind.tint.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isOn ? kind.tint : Theme.edgeStrong, lineWidth: isOn ? 1.5 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.borderless)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// "What's the difference?": what a Nog and an Alarm will actually do, before you pick.
struct NogKindSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    card(.nog, note: "the default") {
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 8).fill(Theme.synth).frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("Call the plumber").font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("now").font(.caption).foregroundStyle(Theme.muted)
                                }
                                Text("Nogging every 8 min until done").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityHidden(true)
                        Text("9:00 · 9:08 · 9:16 · 9:24 … until you nog it")
                            .font(.nogReadout(12))
                            .foregroundStyle(NogKind.nog.tint)
                        bullets([
                            "A notification with a sound, like a message.",
                            "Silent switch on: it buzzes, no sound.",
                            "In a Focus: stays quiet unless Nog is allowed through.",
                        ])
                    }
                    card(.alarm, note: "for things you can't miss") {
                        VStack(spacing: 6) {
                            Text("9:00").font(.nogReadout(34)).foregroundStyle(Color(red: 1, green: 0.89, blue: 0.74))
                            Text("Call the plumber").font(.footnote)
                            HStack(spacing: 8) {
                                Text("Stop").padding(.horizontal, 18).frame(height: 30)
                                    .background(.white.opacity(0.14), in: Capsule())
                                Text("Nogged").fontWeight(.semibold).foregroundStyle(.black)
                                    .padding(.horizontal, 18).frame(height: 30)
                                    .background(ProgressRing.complete, in: Capsule())
                            }
                            .font(.footnote)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(LinearGradient(colors: [Color(red: 0.16, green: 0.13, blue: 0.09), Theme.base],
                                                   startPoint: .top, endPoint: .bottom),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityHidden(true)
                        bullets([
                            "Rings full screen like the Clock app until you stop it.",
                            "Rings even on Silent and in a Focus.",
                            "Stop quiets this ring; it rings again on schedule. Nogged ends it.",
                        ])
                    }
                    Label("Ignoring a Nog? It can turn into an Alarm: Relentless does after 3 unanswered nogs, or set it for everything in Settings → Nogs & alerts.",
                          systemImage: "chart.line.uptrend.xyaxis")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .nogPanel(cornerRadius: 14)
                }
                .padding()
            }
            .background { NogBackground() }
            .navigationTitle("How should it get you?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Got it") { dismiss() } }
            }
        }
    }

    private func card<Content: View>(_ kind: NogKind, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(kind.label, systemImage: kind.systemImage)
                    .font(.nogTitle(17))
                    .foregroundStyle(kind.tint)
                Spacer()
                Text(note).font(.caption).foregroundStyle(Theme.muted)
            }
            content()
        }
        .padding(14)
        .background(kind.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(kind.tint.opacity(0.55), lineWidth: 1))
    }

    private func bullets(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(Theme.muted)
                    Text(line)
                }
            }
        }
        .font(.subheadline)
    }
}
