import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct NogWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DoingLiveActivity()
        NogitivityWidget()
        NogAlarmActivity()
    }
}

/// ▶︎ Doing — Lock Screen, Dynamic Island, StandBy, Apple Watch Smart Stack and CarPlay.
struct DoingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DoingAttributes.self) { context in
            DoingActivityView(context: context)
                .activityBackgroundTint(Color(red: 0.08, green: 0.055, blue: 0.15).opacity(0.72))
                .activitySystemActionForegroundColor(Theme.blue)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("DOING", systemImage: "play.fill")
                        .font(.nogLabel)
                        .tracking(1.5)
                        .foregroundStyle(Theme.blue)
                        .accessibilityLabel("Doing")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DoingTimer(context: context)
                        .font(.nogReadout(20))
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text((context.state.displayTitle ?? "Nog"))
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DoingButtons(itemID: context.attributes.itemID)
                }
            } compactLeading: {
                Image(systemName: "play.fill").foregroundStyle(Theme.blue)
                    .accessibilityLabel("Doing \((context.state.displayTitle ?? "Nog"))")
            } compactTrailing: {
                CompactTimer(context: context)
            } minimal: {
                Image(systemName: context.isStale ? "sparkles" : "timer")
                    .foregroundStyle(context.isStale ? Theme.violet : Theme.blue)
                    .accessibilityLabel(context.isStale
                        ? "Starter done, still on \((context.state.displayTitle ?? "Nog"))"
                        : "Doing \((context.state.displayTitle ?? "Nog"))")
            }
            .keylineTint(Theme.blue)
        }
        // iOS 27: Apple Watch Smart Stack and CarPlay use the small family.
        .supplementalActivityFamilies([.small])
    }
}

private struct DoingActivityView: View {
    @Environment(\.activityFamily) private var activityFamily
    let context: ActivityViewContext<DoingAttributes>

    var body: some View {
        if activityFamily == .small {
            // Apple Watch and the CarPlay dashboard: title, big timer, one tap to finish.
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Label((context.state.displayTitle ?? "Nog"), systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    DoingTimer(context: context)
                        .font(.nogReadout(22))
                }
                Spacer(minLength: 4)
                Button(intent: CompleteItemIntent(itemID: context.attributes.itemID.uuidString)) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .background(Theme.blue.opacity(0.25), in: Circle())
                .accessibilityLabel("Complete")
            }
            .padding(10)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("DOING", systemImage: "play.fill")
                        .font(.nogLabel)
                        .tracking(1.8)
                        .foregroundStyle(Theme.blue)
                        .accessibilityLabel("Doing")
                    Spacer()
                    if context.isStale {
                        Text("KEEP GOING OR STOP · BOTH COUNT")
                            .font(.nogMeta)
                            .foregroundStyle(Theme.violet)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } else if let end = context.state.endsAt {
                        let minutes = Int(end.timeIntervalSince(context.state.startedAt) / 60)
                        Text("\(minutes) MIN START")
                            .font(.nogMeta)
                            .foregroundStyle(Theme.muted)
                            .accessibilityLabel("\(minutes) minute starter timer")
                    }
                }
                HStack(alignment: .center) {
                    Text((context.state.displayTitle ?? "Nog"))
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 12)
                    // Grows with text size (at most 1.6×), shrinks back if the card runs out of room.
                    DoingTimer(context: context)
                        .nogReadout(32)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                }
                if let end = context.state.endsAt, !context.isStale {
                    ProgressView(timerInterval: context.state.startedAt...end, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .tint(Theme.violet)
                    .accessibilityHidden(true) // the timer already says how long is left
                }
                DoingButtons(itemID: context.attributes.itemID)
            }
            .padding()
        }
    }
}

/// Counts down the starter timer (two minutes), then counts up the time logged this session.
/// Open-ended sessions just count up. The flip needs no update from the app: past the end the
/// activity is "stale", and a timer from the start date counts up by itself.
private struct DoingTimer: View {
    let context: ActivityViewContext<DoingAttributes>

    var body: some View {
        if let end = context.state.endsAt {
            if context.isStale {
                Text(context.state.startedAt, style: .timer)
                    .foregroundStyle(Theme.lcd)
                    .accessibilityLabel(Text("Starter done. Logged \(Text(context.state.startedAt, style: .timer)). Keep going or stop."))
            } else {
                Text(timerInterval: context.state.startedAt...end, countsDown: true)
                    .accessibilityLabel(Text("Time left \(Text(timerInterval: context.state.startedAt...end, countsDown: true))"))
            }
        } else {
            Text(context.state.startedAt, style: .timer)
                .accessibilityLabel(Text("Time spent \(Text(context.state.startedAt, style: .timer))"))
        }
    }
}

private struct CompactTimer: View {
    // iOS 27: the Dynamic Island can't grow in landscape.
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth
    let context: ActivityViewContext<DoingAttributes>

    var body: some View {
        if isLimitedInWidth {
            Image(systemName: context.isStale ? "sparkles" : "timer")
                .foregroundStyle(context.isStale ? Theme.violet : Theme.blue)
        } else {
            DoingTimer(context: context)
                .font(.nogReadout(14))
                .frame(maxWidth: 56)
                .foregroundStyle(Theme.blue)
        }
    }
}

private struct DoingButtons: View {
    let itemID: UUID

    var body: some View {
        // Same order as in the app: stop for now, then finish for good.
        HStack(spacing: 8) {
            Button(intent: StopDoingIntent(itemID: itemID.uuidString)) {
                Label("Done for now", systemImage: "pause.fill")
            }
            .buttonStyle(OutlineButtonStyle(tint: Theme.violet))
            .accessibilityHint("Stops for now and logs your time. It comes back tomorrow.")
            Button(intent: CompleteItemIntent(itemID: itemID.uuidString)) {
                Label("Complete", systemImage: "checkmark")
            }
            .buttonStyle(OutlineButtonStyle(tint: Theme.blue))
            .accessibilityHint("Marks it finished")
        }
    }
}
