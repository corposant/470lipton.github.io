import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct NogWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DoingLiveActivity()
    }
}

/// ▶︎ Doing — Lock Screen, Dynamic Island, StandBy, Apple Watch Smart Stack and CarPlay.
struct DoingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DoingAttributes.self) { context in
            DoingActivityView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.orange)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Doing", systemImage: "play.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DoingTimer(context: context)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DoingButtons(itemID: context.attributes.itemID)
                }
            } compactLeading: {
                Image(systemName: "play.circle.fill").foregroundStyle(.orange)
            } compactTrailing: {
                CompactTimer(context: context)
            } minimal: {
                Image(systemName: context.isStale ? "bell.badge.fill" : "timer")
                    .foregroundStyle(.orange)
            }
            .keylineTint(.orange)
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
            VStack(alignment: .leading, spacing: 4) {
                Label(context.attributes.title, systemImage: "play.circle.fill")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                DoingTimer(context: context)
                    .font(.title2.monospacedDigit().weight(.bold))
            }
            .padding(10)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Doing", systemImage: "play.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Spacer()
                    if context.state.priorSeconds >= 60 {
                        Text("\(Int(context.state.priorSeconds / 60)) min before")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .center) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 12)
                    DoingTimer(context: context)
                        .font(.system(size: 34, weight: .semibold).monospacedDigit())
                        .multilineTextAlignment(.trailing)
                }
                if let end = context.state.endsAt, !context.isStale {
                    ProgressView(timerInterval: context.state.startedAt...end, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .tint(.orange)
                }
                DoingButtons(itemID: context.attributes.itemID)
            }
            .padding()
        }
    }
}

/// Counts down a timebox, or up when open-ended. "Time's up" once past the end.
private struct DoingTimer: View {
    let context: ActivityViewContext<DoingAttributes>

    var body: some View {
        if let end = context.state.endsAt {
            if context.isStale {
                Text("Time's up").foregroundStyle(.orange)
            } else {
                Text(timerInterval: context.state.startedAt...end, countsDown: true)
            }
        } else {
            Text(context.state.startedAt, style: .timer)
        }
    }
}

private struct CompactTimer: View {
    // iOS 27: the Dynamic Island can't grow in landscape.
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth
    let context: ActivityViewContext<DoingAttributes>

    var body: some View {
        if isLimitedInWidth || context.isStale {
            Image(systemName: context.isStale ? "bell.badge.fill" : "timer")
                .foregroundStyle(.orange)
        } else {
            DoingTimer(context: context)
                .monospacedDigit()
                .frame(maxWidth: 56)
                .foregroundStyle(.orange)
        }
    }
}

private struct DoingButtons: View {
    let itemID: UUID

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: CompleteItemIntent(itemID: itemID.uuidString)) {
                Label("Done", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .tint(.green)
            Button(intent: ExtendTimeboxIntent(itemID: itemID.uuidString, minutes: 10)) {
                Label("+10 min", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .tint(.orange)
            Button(intent: StopDoingIntent(itemID: itemID.uuidString)) {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
            }
            .tint(.gray)
        }
        .buttonStyle(.borderedProminent)
        .font(.subheadline.weight(.semibold))
    }
}
