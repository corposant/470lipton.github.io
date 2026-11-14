import ActivityKit
import Foundation

/// Keeps one Live Activity running for each item you're doing.
@MainActor
final class DoingActivities {
    static let shared = DoingActivities()
    private var running: Task<Void, Never>?

    func reconcile(_ items: [Item]) {
        let previous = running
        running = Task {
            await previous?.value
            await self.performReconcile(items)
        }
    }

    private func performReconcile(_ items: [Item]) async {
        var doing: [UUID: Item] = [:]
        if NogSettings.liveActivityEnabled {
            for item in items where item.isDoing && item.doingSince != nil { doing[item.id] = item }
        }

        var live = Set<UUID>()
        for activity in Activity<DoingAttributes>.activities {
            let id = activity.attributes.itemID
            if let item = doing[id], !live.contains(id) {
                live.insert(id)
                let content = Self.content(for: item)
                if activity.content.state != content.state {
                    await activity.update(content)
                }
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for (id, item) in doing where !live.contains(id) {
            do {
                _ = try Activity.request(attributes: DoingAttributes(itemID: id, title: "Nog"),
                                         content: Self.content(for: item))
            } catch {
                print("Nog: couldn't start Live Activity: \(error)")
            }
        }
    }

    static func content(for item: Item) -> ActivityContent<DoingAttributes.ContentState> {
        let state = DoingAttributes.ContentState(
            startedAt: item.doingSince ?? .now,
            endsAt: item.timeboxEnd,
            priorSeconds: item.timeSpent,
            isUrgent: item.reminder?.alarm ?? false,
            displayTitle: PresentationPrivacy.title(item.title, visible: NogSettings.showTitles))
        // Past the starter timer the activity goes "stale", which the view shows as counting up.
        return ActivityContent(state: state, staleDate: item.timeboxEnd, relevanceScore: 100)
    }
}
