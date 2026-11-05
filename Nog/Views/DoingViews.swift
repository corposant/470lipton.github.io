import SwiftUI

/// ▶︎ Tap to start with the suggested timebox; press and hold to choose.
struct StartButton: View {
    @Environment(ItemStore.self) private var store
    let item: Item
    var prominent = false

    var body: some View {
        let suggestion = store.suggestedTimebox(for: item.id)
        Menu {
            Section("Suggested") {
                Button {
                    store.start(item.id, timebox: suggestion.minutes)
                } label: {
                    Label(suggestion.label, systemImage: "wand.and.stars")
                }
            }
            Section("Timebox") {
                ForEach(NogSettings.timeboxChoices, id: \.self) { minutes in
                    Button(IntervalFormat.short(minutes)) { store.start(item.id, timebox: minutes) }
                }
                Button {
                    store.start(item.id, timebox: nil)
                } label: {
                    Label("No timer (count up)", systemImage: "stopwatch")
                }
            }
        } label: {
            if prominent {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                    Text(suggestion.minutes.map { "START · \(IntervalFormat.short($0).uppercased())" } ?? "START")
                        .font(.nogTitle(13))
                        .tracking(2)
                }
                .foregroundStyle(.primary)
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.synth, lineWidth: 1.5))
                .shadow(color: Theme.violet.opacity(0.18), radius: 14)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                CircleOutlineIcon(systemName: "play.fill")
                    .accessibilityLabel("Start \(item.title)")
            }
        } primaryAction: {
            store.start(item.id, timebox: suggestion.minutes)
        }
        .buttonStyle(.borderless)
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
                    router.path.append(item.id)
                } label: {
                    HStack {
                        Text(item.title).font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            Text(metaLine)
                .font(.nogMeta)
                .tracking(0.6)
                .foregroundStyle(Theme.muted)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = context.date
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        timerText(now: now)
                            .font(.nogReadout(44))
                            .shadow(color: Theme.blue.opacity(0.35), radius: 14)
                        Text(item.timeboxEnd.map { $0 > now ? "remaining" : "" } ?? "elapsed")
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                    }
                    if let since = item.doingSince, let end = item.timeboxEnd {
                        GeometryReader { geo in
                            let fraction = min(1, max(0, now.timeIntervalSince(since) / end.timeIntervalSince(since)))
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.edge)
                                Capsule().fill(now >= end ? AnyShapeStyle(Theme.pink) : AnyShapeStyle(Theme.synth))
                                    .frame(width: geo.size.width * fraction)
                            }
                        }
                        .frame(height: 3)
                    }
                }
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
        if let box = item.timeboxMinutes { parts.append("TIMEBOX \(IntervalFormat.short(box).uppercased())") }
        else { parts.append("OPEN-ENDED") }
        if item.timeSpent >= 60 { parts.append("\(DurationFormat.short(item.timeSpent).uppercased()) BEFORE") }
        parts += item.tags.prefix(2).map { "#\($0.uppercased())" }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func timerText(now: Date) -> some View {
        if let end = item.timeboxEnd {
            if now >= end {
                Text("TIME'S UP").foregroundStyle(Theme.pink)
            } else {
                Text(clock(end.timeIntervalSince(now)))
            }
        } else if let since = item.doingSince {
            Text(clock(now.timeIntervalSince(since)))
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
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
