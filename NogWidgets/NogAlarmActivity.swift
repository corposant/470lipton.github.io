import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

/// Required if countdown alarms are added. Fixed alarms currently use the
/// system alert UI; this view renders AlarmKit's live countdown/paused state.
struct NogAlarmActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<NogAlarmMetadata>.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Label { Text(context.attributes.presentation.alert.title) } icon: {
                    Image(systemName: "alarm.fill")
                }
                NogAlarmStateView(state: context.state)
            }
            .font(.headline)
            .padding()
            .activityBackgroundTint(context.attributes.tintColor.opacity(0.15))
            .activitySystemActionForegroundColor(context.attributes.tintColor)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "alarm.fill").foregroundStyle(context.attributes.tintColor)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    NogAlarmStateView(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.presentation.alert.title)
                        .font(.headline).lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: "alarm.fill").foregroundStyle(context.attributes.tintColor)
            } compactTrailing: {
                NogAlarmStateView(state: context.state).frame(maxWidth: 64)
            } minimal: {
                Image(systemName: "alarm.fill").foregroundStyle(context.attributes.tintColor)
            }
            .keylineTint(context.attributes.tintColor)
        }
    }
}

private struct NogAlarmStateView: View {
    let state: AlarmPresentationState

    var body: some View {
        switch state.mode {
        case .countdown(let countdown):
            Text(timerInterval: countdown.startDate...max(countdown.startDate, countdown.fireDate),
                 countsDown: true)
                .monospacedDigit()
                .accessibilityLabel("Time remaining")
        case .paused:
            Text("Paused")
        case .alert:
            Text("Ringing")
        @unknown default:
            Text("Alarm")
        }
    }
}
