import SwiftUI

/// ▶︎ Tap to start with the suggested timebox; press and hold for the timebox panel.
struct StartButton: View {
    @Environment(ItemStore.self) private var store
    let item: Item
    var prominent = false
    /// Sub-item progress, drawn as a ring around the small ▶︎ (nil = no sub-items).
    var subItems: (done: Int, total: Int)? = nil
    @State private var showPanel = false
    /// Set by a hold, so the button's tap (which fires on release) doesn't also start it.
    @State private var didHold = false

    var body: some View {
        let suggestion = store.suggestedTimebox(for: item.id)
        Button {
            if didHold { didHold = false; return }
            store.start(item.id, timebox: suggestion.minutes)
        } label: {
            label(suggestion)
        }
        .buttonStyle(.borderless)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
            didHold = true
            showPanel = true
        })
            .nogFeedback(.impact(weight: .medium), trigger: showPanel) { _, isShowing in isShowing }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Start \(item.title)")
            .accessibilityHint("Starts with \(suggestion.label.lowercased()). Hold to choose a timebox.")
            .accessibilityValue(subItems.map { "\($0.done) of \($0.total) sub-nogs done" } ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.start(item.id, timebox: suggestion.minutes) }
            .accessibilityAction(named: "Choose timebox") { showPanel = true }
            .popover(isPresented: $showPanel) {
                TimeboxPanel(suggestion: suggestion) { minutes in
                    showPanel = false
                    store.start(item.id, timebox: minutes)
                } close: {
                    showPanel = false
                }
                .presentationCompactAdaptation(.popover)
                .presentationBackground(.clear)
            }
    }

    @ViewBuilder
    private func label(_ suggestion: TimeboxSuggestion) -> some View {
        if prominent {
            HStack(spacing: 10) {
                Image(systemName: "play.fill").nogFont(12, weight: .bold)
                Text(suggestion.minutes.map { "START · \(IntervalFormat.amount($0).uppercased())" } ?? "START")
                    .font(.nogTitle(13))
                    .tracking(2)
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.synth, lineWidth: 1.5))
            .nogGlow(color: Theme.violet.opacity(0.18), radius: 14)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            CircleOutlineIcon(systemName: "play.fill", size: 32,
                              progress: subItems.flatMap { $0.total > 0 ? Double($0.done) / Double($0.total) : nil })
        }
    }
}

/// Aperture-style floating panel: translucent black, thin light edge, small title bar,
/// the suggestion highlighted in pro-app blue.
struct TimeboxPanel: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let suggestion: TimeboxSuggestion
    let choose: (Int?) -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            ZStack {
                Text("TIMEBOX")
                    .font(.nogLabel)
                    .tracking(2.2)
                    .foregroundStyle(Color(white: 0.78))
                HStack {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .nogFont(8, weight: .heavy)
                            .foregroundStyle(Color(white: 0.15))
                            .nogFrame(width: 15, height: 15)
                            .background(Color(white: 0.62), in: Circle())
                            // The dot stays small, but the tap area is a comfortable 44 pt.
                            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                    Spacer()
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) }

            group("Suggested")
            row(suggestion.minutes.map(IntervalFormat.amount) ?? "No timer", detail: suggestion.reason, isSelected: true) {
                choose(suggestion.minutes)
            }
            separator
            group("Choose")
            ForEach(NogSettings.timeboxChoices, id: \.self) { minutes in
                row(IntervalFormat.amount(minutes),
                    detail: minutes == NogSettings.timeboxMinutes ? "default" : nil) { choose(minutes) }
            }
            separator
            row("No timer", detail: "count up") { choose(nil) }
                .padding(.bottom, 4)
        }
        // Fixed width normally; at the accessibility text sizes it takes the room it needs.
        .frame(width: typeSize.isAccessibilitySize ? nil : 290)
        .background(Color(red: 0.055, green: 0.06, blue: 0.07).opacity(0.86))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private func group(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.nogMicroLabel)
            .tracking(2)
            .foregroundStyle(Color(white: 0.62))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, 3)
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.vertical, 3)
    }

    private func row(_ title: String, detail: String?, isSelected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.subheadline)
                Spacer(minLength: 10)
                if let detail {
                    Text(detail).font(.nogMeta).nogLineLimit()
                        .foregroundStyle(isSelected ? Color(white: 0.92) : Color(white: 0.66))
                }
            }
            .foregroundStyle(isSelected ? .white : Color(white: 0.88))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background {
                if isSelected {
                    LinearGradient(colors: [Color(red: 0.25, green: 0.50, blue: 0.84), Color(red: 0.17, green: 0.37, blue: 0.70)],
                                   startPoint: .top, endPoint: .bottom)
                        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.25)).frame(height: 1) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Logic-transport-style readout: an inset display with faint "88:88" ghost segments
/// behind softly glowing digits, its labels and progress bar inside the glass.
struct RecessedTimer: View {
    let item: Item
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(isCountdown ? "REMAINING" : "ELAPSED")
                Spacer()
                if let box = item.timeboxMinutes { Text("BOX \(clock(TimeInterval(box * 60)))") }
            }
            .font(.nogMicroLabel)
            .tracking(1.8)
            .foregroundStyle(Theme.panelLabel)

            ZStack(alignment: .leading) {
                Text(ghost)
                    .foregroundStyle(Theme.blue.opacity(0.07))
                Text(display)
                    .foregroundStyle(isOver ? Theme.pink : Theme.lcd)
                    .nogGlow(color: (isOver ? Theme.pink : Theme.blue).opacity(0.55), radius: 8)
                    .nogGlow(color: (isOver ? Theme.pink : Theme.blue).opacity(0.9), radius: 1)
            }
            .nogReadout(44)
            .monospacedDigit()

            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.06))
                        Capsule().fill(isOver ? AnyShapeStyle(Theme.pink) : AnyShapeStyle(Theme.synth))
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 3)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.027, green: 0.03, blue: 0.043),
                                              Color(red: 0.05, green: 0.06, blue: 0.08)],
                                     startPoint: .top, endPoint: .bottom))
                // Inset: dark lip at the top, faint light catch at the bottom.
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.black.opacity(0.95), .white.opacity(0.09)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1.5))
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 8)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(isCountdown ? "Remaining" : "Elapsed") \(display)")
    }

    private var isCountdown: Bool { item.timeboxEnd != nil }
    private var isOver: Bool { item.timeboxEnd.map { now >= $0 } ?? false }

    private var seconds: TimeInterval {
        if let end = item.timeboxEnd { return max(0, end.timeIntervalSince(now)) }
        return item.doingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
    }

    private var display: String { isOver ? "TIME'S UP" : clock(seconds) }

    /// Unlit segments matching the digit layout.
    private var ghost: String {
        if isOver { return "" }
        return seconds >= 3600 ? "8:88:88" : "88:88"
    }

    private var fraction: Double? {
        guard let since = item.doingSince, let end = item.timeboxEnd else { return nil }
        return min(1, max(0, now.timeIntervalSince(since) / end.timeIntervalSince(since)))
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// The live "I'm doing this now" card: timer, progress, Done / +10 / Stop.
struct DoingCard: View {
    @Environment(ItemStore.self) private var store
    @Environment(Router.self) private var router
    let item: Item
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsTitle {
                Button {
                    router.push(item.id)
                } label: {
                    HStack {
                        Text(item.title).font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            if !metaLine.isEmpty {
                Text(metaLine)
                    .font(.nogMeta)
                    .tracking(0.6)
                    .foregroundStyle(Theme.muted)
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                RecessedTimer(item: item, now: context.date)
            }

            HStack(spacing: 8) {
                Button {
                    store.markDone(item.id)
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(OutlineButtonStyle(tint: Theme.blue))
                Button {
                    store.extend(item.id, minutes: 10)
                } label: {
                    Text("+10 min")
                }
                .buttonStyle(OutlineButtonStyle(tint: Theme.pink))
                Button {
                    store.stopDoing(item.id)
                } label: {
                    Image(systemName: "stop.fill").font(.caption)
                }
                .buttonStyle(OutlineButtonStyle(tint: Theme.muted, expands: false))
                .accessibilityLabel("Stop")
            }
            .padding(.top, 4)
        }
        .padding(16)
        .nogPanel()
        .overlay { CornerBrackets().stroke(Theme.blue.opacity(0.9), lineWidth: 1.5) }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.blue.opacity(0.35), lineWidth: 1)
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if item.timeboxMinutes == nil { parts.append("OPEN-ENDED") }
        if item.timeSpent >= 60 { parts.append("\(DurationFormat.short(item.timeSpent).uppercased()) BEFORE") }
        parts += item.tags.prefix(2).map { "#\($0.uppercased())" }
        return parts.joined(separator: " · ")
    }

}

/// HUD-style corner ticks (top-left and bottom-right).
struct CornerBrackets: Shape {
    var inset: CGFloat = 7
    var length: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = rect.insetBy(dx: inset, dy: inset)
        p.move(to: CGPoint(x: r.minX, y: r.minY + length))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + length, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - length, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - length))
        return p
    }
}
