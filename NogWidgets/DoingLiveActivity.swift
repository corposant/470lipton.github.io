import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct NogWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DoingLiveActivity()
        NogitivityWidget()
    }
}

/// ▶︎ Doing — Lock Screen, Dynamic Island, StandBy, Apple Watch Smart Stack and CarPlay.
struct DoingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DoingAttributes.self) { context in
            DoingActivityView(context: context)
                .activityBackgroundTint(Color(red: 0.11, green: 0.11, blue: 0.15).opacity(0.72))
                .activitySystemActionForegroundColor(Theme.blue)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("DOING", systemImage: "play.fill")
                        .font(.nogLabel)
                        .tracking(1.5)
                        .foregroundStyle(Theme.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DoingTimer(context: context)
                        .font(.nogReadout(20))
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
                Image(systemName: "play.fill").foregroundStyle(Theme.blue)
            } compactTrailing: {
                CompactTimer(context: context)
            } minimal: {
                Image(systemName: context.isStale ? "bell" : "timer")
                    .foregroundStyle(context.isStale ? Theme.pink : Theme.blue)
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
                    Label(context.attributes.title, systemImage: "play.fill")
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
                .accessibilityLabel("Done")
            }
            .padding(10)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("NOGITIVITY", systemImage: "play.fill")
                        .font(.nogLabel)
                        .tracking(1.8)
                        .foregroundStyle(Theme.blue)
                    Spacer()
                    if let end = context.state.endsAt {
                        Text("\(Int(end.timeIntervalSince(context.state.startedAt) / 60)) MIN BOX")
                            .font(.nogMeta)
                            .foregroundStyle(Theme.muted)
                    }
                }
                HStack(alignment: .center) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 12)
                    DoingTimer(context: context)
                        .font(.nogReadout(32))
                        .multilineTextAlignment(.trailing)
                }
                if let end = context.state.endsAt, !context.isStale {
                    ProgressView(timerInterval: context.state.startedAt...end, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .tint(Theme.violet)
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
                Text("TIME'S UP").foregroundStyle(Theme.pink)
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
            Image(systemName: context.isStale ? "bell" : "timer")
                .foregroundStyle(context.isStale ? Theme.pink : Theme.blue)
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
        HStack(spacing: 8) {
            Button(intent: CompleteItemIntent(itemID: itemID.uuidString)) {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(OutlineButtonStyle(tint: Theme.blue))
            Button(intent: ExtendTimeboxIntent(itemID: itemID.uuidString, minutes: 10)) {
                Text("+10 min")
            }
            .buttonStyle(OutlineButtonStyle(tint: Theme.pink))
            Button(intent: StopDoingIntent(itemID: itemID.uuidString)) {
                Image(systemName: "stop.fill").font(.caption)
            }
            .buttonStyle(OutlineButtonStyle(tint: Theme.muted, expands: false))
        }
    }
}
