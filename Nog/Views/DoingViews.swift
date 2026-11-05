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
                Label(suggestion.minutes.map { "Start · \(IntervalFormat.short($0))" } ?? "Start",
                      systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            } else {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Start \(item.title)")
            }
        } primaryAction: {
            store.start(item.id, timebox: suggestion.minutes)
        }
        .modifier(ProminentStyle(enabled: prominent))
    }
}

private struct ProminentStyle: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
        } else {
            content.buttonStyle(.borderless)
        }
    }
}

/// The live "I'm doing this now" card: timer, progress, Done / +10 / Stop.
struct DoingCard: View {
    @Environment(ItemStore.self) private var store
    @Environment(Router.self) private var router
    let item: Item
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle {
                Button {
                    router.path.append(item.id)
                } label: {
                    HStack {
                        Text(item.title).font(.headline)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = context.date
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        timerText(now: now)
                            .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                        Spacer()
                        if let box = item.timeboxMinutes {
                            Text("of \(IntervalFormat.short(box))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let since = item.doingSince, let end = item.timeboxEnd {
                        ProgressView(value: min(1, max(0, now.timeIntervalSince(since) / end.timeIntervalSince(since))))
                            .tint(now >= end ? .red : .orange)
                    }
                    if item.timeSpent >= 60 {
                        Text("\(DurationFormat.short(item.totalTimeSpent(now: now))) total on this")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    store.markDone(item.id)
                } label: {
                    Label("Done", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .tint(.green)
                Button {
                    store.extend(item.id, minutes: 10)
                } label: {
                    Label("+10 min", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .tint(.orange)
                Button {
                    store.stopDoing(item.id)
                } label: {
                    Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly)
                }
                .tint(.gray)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func timerText(now: Date) -> some View {
        if let end = item.timeboxEnd {
            if now >= end {
                Text("Time's up").foregroundStyle(.red)
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
