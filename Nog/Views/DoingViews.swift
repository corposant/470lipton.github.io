import SwiftUI

/// ▶︎ Tap for the two-minute start; press and hold for a longer timer. On a nog with sub-nogs it
/// starts the first unfinished one, the small physical step.
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
        let step = stepTitle
        Button {
            if didHold { didHold = false; return }
            store.start(item.id, timebox: suggestion.minutes)
        } label: {
            label(suggestion, step: step)
        }
        .buttonStyle(.borderless)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
            didHold = true
            showPanel = true
        })
            .nogFeedback(.impact(weight: .medium), trigger: showPanel) { _, isShowing in isShowing }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Start \(step ?? item.title)")
            .accessibilityHint((step == nil ? "" : "The first step of \(item.title). ")
                               + "Starts with \(suggestion.label.lowercased()). Hold to choose a longer timer.")
            .accessibilityValue(subItems.map { "\($0.done) of \($0.total) sub-nogs done" } ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.start(item.id, timebox: suggestion.minutes) }
            .accessibilityAction(named: "Choose a longer timer") { showPanel = true }
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

    /// The sub-nog ▶︎ would start instead of this one, if any. Worked out once per body:
    /// every list row has a ▶︎, and each lookup walks the store.
    private var stepTitle: String? {
        let target = store.startTarget(for: item.id)
        return target == item.id ? nil : store.items[target]?.title
    }

    @ViewBuilder
    private func label(_ suggestion: TimeboxSuggestion, step: String?) -> some View {
        if prominent {
            VStack(spacing: 3) {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill").nogFont(12, weight: .bold)
                    Text(suggestion.minutes.map { "START · \(IntervalFormat.amount($0).uppercased())" } ?? "START")
                        .font(.nogTitle(13))
                        .tracking(2)
                }
                if let step {
                    Text(step)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .nogLineLimit(1, accessibilityLines: 3)
                        .padding(.horizontal, 10)
                }
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
                Text("TIMER")
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

            group("Starter")
            row(suggestion.minutes.map(IntervalFormat.amount) ?? "No timer", detail: suggestion.reason, isSelected: true) {
                choose(suggestion.minutes)
            }
            separator
            group("Longer")
            ForEach(NogSettings.timeboxChoices.filter { $0 > (suggestion.minutes ?? 0) }, id: \.self) { minutes in
                row(IntervalFormat.amount(minutes), detail: nil) { choose(minutes) }
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
/// Counts down the starter timer (two minutes), then flips to counting up the time logged.
struct RecessedTimer: View {
    let item: Item
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(isCountdown ? "STARTER" : isOver ? "LOGGING" : "ELAPSED")
                Spacer()
                if isCountdown, let box = item.timeboxMinutes {
                    Text("OF \(clock(TimeInterval(box * 60)))")
                } else if let gap = item.checkInGap(policy: NogSettings.policy) {
                    Text("CHECK-IN \(IntervalFormat.short(gap).uppercased())")
                }
            }
            .font(.nogMicroLabel)
            .tracking(1.8)
            .foregroundStyle(Theme.panelLabel)

            ZStack(alignment: .leading) {
                Text(ghost)
                    .foregroundStyle(Theme.blue.opacity(0.07))
                Text(display)
                    .foregroundStyle(Theme.lcd)
                    .nogGlow(color: (isOver ? Theme.violet : Theme.blue).opacity(0.55), radius: 8)
                    .nogGlow(color: (isOver ? Theme.violet : Theme.blue).opacity(0.9), radius: 1)
            }
            .nogReadout(44)
            .monospacedDigit()

            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.06))
                        Capsule().fill(Theme.synth)
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
        .accessibilityLabel(isCountdown ? "Starter timer, \(spoken) left"
                            : isOver ? "Starter done. \(spoken) logged. Keep going or stop." : "\(spoken) elapsed")
    }

    /// Still in the starter timer (the two minutes).
    private var isCountdown: Bool { item.timeboxEnd.map { now < $0 } ?? false }
    /// Past the starter timer: counting up.
    private var isOver: Bool { item.isCountingUp(now: now) }

    private var seconds: TimeInterval {
        if isCountdown, let end = item.timeboxEnd { return max(0, end.timeIntervalSince(now)) }
        return item.doingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
    }

    private var display: String { clock(seconds) }

    /// "1 minute 20 seconds", for VoiceOver.
    private var spoken: String {
        Duration.seconds(Int(seconds.rounded(isCountdown ? .up : .down)))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    /// Unlit segments matching the digit layout.
    private var ghost: String {
        seconds >= 3600 ? "8:88:88" : "88:88"
    }

    /// The starter timer filling up; full once it's counting up.
    private var fraction: Double? {
        guard let since = item.doingSince, let end = item.timeboxEnd else { return nil }
        if isOver { return 1 }
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
                    // A little "you did it" tap the moment the starter timer flips to counting up.
                    .nogFeedback(.success, trigger: item.isCountingUp(now: context.date)) { old, new in !old && new }
            }
            .contextMenu { CheckInMenu(item: item) }
            .accessibilityHint("Hold to change how often Nog checks in")

            DoingActions(item: item)
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

/// The two ways out of a session. "Done for now" stops it (the time is logged, and the nog comes
/// back tomorrow); "Complete" finishes the nog for good. Same order everywhere: stop, then finish.
struct DoingActions: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: Item

    var body: some View {
        // Stacked at the accessibility text sizes, so neither label truncates.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            Button {
                let logged = store.stopDoing(item.id)
                AccessibilityNotification.Announcement(Self.loggedLine(logged)).post()
            } label: {
                Label("Done for now", systemImage: "pause.fill")
            }
            .buttonStyle(OutlineButtonStyle(tint: Theme.violet))
            .accessibilityHint("Stops for now and logs your time. It comes back tomorrow.")
            Button {
                store.markDone(item.id)
            } label: {
                Label("Complete", systemImage: "checkmark")
            }
            .buttonStyle(OutlineButtonStyle(tint: StatusDial.tint(.done)))
            .accessibilityHint("Marks it finished")
        }
    }

    /// "Logged 7 min. Nice start."
    static func loggedLine(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "Stopped for now. Nice start." : "Logged \(DurationFormat.short(seconds)). Nice start."
    }
}

/// Long press on the timer: how often "still on it?" comes, for this session only.
struct CheckInMenu: View {
    @Environment(ItemStore.self) private var store
    let item: Item

    var body: some View {
        let current = item.checkInGap(policy: NogSettings.policy) ?? 0
        Section("“Still on it?” this session") {
            ForEach(NogSettings.checkInChoices, id: \.self) { minutes in
                Button {
                    store.setCheckIn(item.id, minutes: minutes)
                } label: {
                    if minutes == current {
                        Label(Self.label(minutes), systemImage: "checkmark")
                    } else {
                        Text(Self.label(minutes))
                    }
                }
            }
        }
        if item.checkInMinutes != nil {
            Button("Use my usual (Settings)") { store.setCheckIn(item.id, minutes: nil) }
        }
    }

    static func label(_ minutes: Int) -> String {
        minutes == 0 ? "No check-ins" : "Every \(IntervalFormat.short(minutes))"
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
