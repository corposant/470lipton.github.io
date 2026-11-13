import CoreLocation
import AppIntents
import Foundation
import UserNotifications
import os

/// Keeps iOS's pending notifications in line with `NogPlanner`'s plan.
@MainActor
final class NotificationScheduler {
    static let shared = NotificationScheduler()

    nonisolated static let categoryID = "NOG"
    nonisolated static let itemIDKey = "itemID"

    enum Action: String {
        case done = "NOG_DONE"
        case snoozeHour = "NOG_SNOOZE_1H"
        case morning = "NOG_MORNING"
        case extend = "NOG_EXTEND_10"
        case stopDoing = "NOG_STOP"
        case start = "NOG_START"
        case gentler = "NOG_GENTLER"
        case skipToday = "NOG_SKIP_TODAY"
        case later = "NOG_LATER"
        case push = "NOG_PUSH_15"
    }

    /// How far "Push 15 min" on a heads-up moves the start.
    static let pushMinutes = 15

    private let center = UNUserNotificationCenter.current()
    private var running: Task<Void, Never>?
    private(set) var lastPlannedCount = 0

    private var registeredCategories: Set<String> = []
    /// Custom categories seen at the last sync, kept when re-registering without items.
    private var customCategories: Set<String> = []

    /// The default nog category, the Doing one, plus one per custom snooze combination in use.
    /// Without `items` (launch, Settings changes) it keeps the custom ones from the last sync.
    func registerCategories(items: [Item]? = nil) {
        if let items { customCategories = Set(items.map { NogPlanner.category(for: $0.reminder) }) }
        let ids = customCategories.union([Self.categoryID])
        let signature = ids.union(["\(NogSettings.snoozeMinutes)|\(NogSettings.morningMinutes)"])
        guard signature != registeredCategories else { return }
        registeredCategories = signature

        func action(_ action: Action, _ title: String, _ symbol: String,
                    options: UNNotificationActionOptions = []) -> UNNotificationAction {
            UNNotificationAction(identifier: action.rawValue, title: title, options: options,
                                 icon: UNNotificationActionIcon(systemImageName: symbol))
        }
        let done = action(.done, "Done", "checkmark")
        // Starting opens Nog, so the Live Activity and timer start where you can see them.
        let start = action(.start, "Start", "play.fill", options: .foreground)
        let later = UNTextInputNotificationAction(
            identifier: Action.later.rawValue, title: "Later…", options: [],
            icon: UNNotificationActionIcon(systemImageName: "clock"),
            textInputButtonTitle: "Set", textInputPlaceholder: "20m, 4pm, tomorrow")

        var categories: Set<UNNotificationCategory> = []
        for id in ids {
            let custom = NogPlanner.snoozeSettings(fromCategory: id)
            let buttons = NogPlanner.profileButtons(fromCategory: id)
            let snoozeMinutes = custom.snooze ?? NogSettings.snoozeMinutes
            let morningMinutes = custom.morning ?? NogSettings.morningMinutes
            var actions = [done, start,
                           action(.snoozeHour, NogSettings.snoozeLabel(minutes: snoozeMinutes), "zzz")]
            actions.append(buttons.skipToday
                ? action(.skipToday, "Skip today", "forward.end")
                : action(.morning, NogSettings.morningSnoozeLabel(minutes: morningMinutes), "sunrise"))
            if buttons.gentler { actions.append(action(.gentler, "Gentler", "speaker.wave.1")) }
            actions.append(later)
            categories.insert(UNNotificationCategory(identifier: id, actions: actions,
                                                     intentIdentifiers: [], options: []))
        }
        categories.insert(UNNotificationCategory(
            identifier: NogPlanner.categoryHeadsUp,
            actions: [action(.start, "Start now", "play.fill", options: .foreground),
                      action(.push, "Push \(IntervalFormat.amount(Self.pushMinutes))", "clock.arrow.circlepath"),
                      done],
            intentIdentifiers: [], options: []))
        // While you're on it: stop for now (time logged, back tomorrow) or finish it for good.
        categories.insert(UNNotificationCategory(
            identifier: NogPlanner.categoryDoing,
            actions: [action(.stopDoing, "Done for now", "pause.fill"),
                      action(.done, "Complete", "checkmark")],
            intentIdentifiers: [], options: []))
        center.setNotificationCategories(categories)
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func pendingCount() async -> Int {
        await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(NogPlanner.prefix) }.count
    }

    /// Serialized: each sync waits for the previous one so they never interleave.
    func sync(items: [Item]) async {
        let previous = running
        let task = Task {
            await previous?.value
            await self.performSync(items: items)
        }
        running = task
        await task.value
    }

    /// `shortenTitles`: afterwards, ask Apple Intelligence for any new short parent labels and,
    /// if some arrive, line everything up again with them.
    private func performSync(items: [Item], shortenTitles: Bool = true) async {
        registerCategories(items: items)
        let policy = NogSettings.policy
        // Sub-nogs name their parent: plan with the short labels already worked out. New ones
        // are asked for after the nogs are lined up, because the model can take seconds and a
        // two-minute start's chime (or a nog due now) mustn't wait on it.
        let shortParents = ParentLabelCache.current(for: items)
        let ringing = await AlarmScheduler.shared.sync(items: items, policy: policy, shortParents: shortParents)
        let now = Date.now
        // Places first (they wait for you, not the clock); one slot stays free for the
        // "open Nog to keep nogging" notice.
        let places = NogPlanner.placeNotifications(items: items, places: PlaceBook.shared.places,
                                                   limit: PlaceBook.maxWatched, shortParents: shortParents)
        let plan = NogPlanner.plan(items: items, now: now, budget: NogPlanner.defaultBudget - 1 - places.count,
                                   policy: policy, alarmDates: ringing, shortParents: shortParents)
        var desired: [String: PlannedNotification] = [:]
        for p in plan + places { desired[p.identifier] = p }
        if let pause = NogPlanner.pauseNotice(for: plan, items: items, now: now, policy: policy) {
            desired[pause.identifier] = pause
        }

        let pending = await center.pendingNotificationRequests()
        var pendingIDs = Set(pending.map(\.identifier).filter { $0.hasPrefix(NogPlanner.prefix) })

        // Sound / Time Sensitive / title settings changed: everything already scheduled is out of date.
        let signature = Self.contentSignature
        if UserDefaults.standard.string(forKey: Self.signatureKey) != signature {
            center.removePendingNotificationRequests(withIdentifiers: Array(pendingIDs))
            pendingIDs = []
            UserDefaults.standard.set(signature, forKey: Self.signatureKey)
        }

        let stale = pendingIDs.subtracting(desired.keys)
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(stale))
        }
        for (id, planned) in desired where !pendingIDs.contains(id) {
            do {
                try await center.add(request(for: planned))
            } catch {
                Log.nog.error("failed to schedule \(String(describing: id)): \(String(describing: error))")
            }
        }
        lastPlannedCount = desired.count

        // App icon badge: how many things are nogging right now.
        let nogging = NogSettings.showsBadge
            ? items.filter { $0.isOpen && ($0.reminder?.isActive(at: .now) ?? false) }.count
            : 0
        try? await center.setBadgeCount(nogging)

        if shortenTitles, await ParentLabelCache.refresh(items: items) != shortParents {
            await performSync(items: items, shortenTitles: false)
        }
    }

    private static let signatureKey = "appliedNotificationSignature"

    /// The soft, rising chime at the end of the two-minute start (bundled in Nog/Resources).
    nonisolated static let chimeSound = UNNotificationSoundName(rawValue: "StarterChime.caf")

    /// The two-minute start keeps its rising starter chime; everything else plays the reminder chime.
    static func sound(for planned: PlannedNotification,
                      choice: NotificationChime = .reminder) -> UNNotificationSound {
        if planned.chime { return UNNotificationSound(named: chimeSound) }
        guard let file = choice.fileName else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(rawValue: file))
    }

    private static var contentSignature: String {
        // "v4": Nog's own chimes (Settings › Reminder chime), so nogs scheduled by an older build are replaced.
        "v4|\(NotificationChime.reminder.rawValue)|\(NogSettings.playsSound)|\(NogSettings.timeSensitive)|\(NogSettings.showTitles)"
    }

    func clearDelivered(for itemID: UUID) async {
        let delivered = await center.deliveredNotifications()
        let ids = delivered
            .filter { ($0.request.content.userInfo[Self.itemIDKey] as? String) == itemID.uuidString }
            .map(\.request.identifier)
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }

    private func request(for planned: PlannedNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        if NogSettings.showTitles || planned.category == NogPlanner.categoryPause {
            content.title = planned.title
            content.body = planned.body
        } else {
            // Private: details only after unlocking and opening Nog.
            content.title = "Nog"
            content.body = "Something's nogging you."
        }
        // Hush items never make a sound. Neither they, heads-ups (a gentle "coming up") nor the
        // two-minute chime break through Focus.
        let quiet = planned.silent || planned.isHeadsUp || planned.chime
        if NogSettings.playsSound && !planned.silent {
            content.sound = Self.sound(for: planned)
        }
        content.categoryIdentifier = planned.category
        content.threadIdentifier = planned.itemID.uuidString
        content.userInfo = [Self.itemIDKey: planned.itemID.uuidString]
        // iOS 27: lets people say "Siri, mark that done" about the nog on screen.
        content.appEntityIdentifiers = [EntityIdentifier(for: ReminderEntity.self, identifier: planned.itemID)]
        // Takes effect once the Time Sensitive capability is added (see README).
        content.interruptionLevel = NogSettings.timeSensitive && !quiet ? .timeSensitive : .active

        let trigger: UNNotificationTrigger
        switch planned.trigger {
        case .at(let date):
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        case .every(let seconds):
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, seconds), repeats: true)
        case .daily(let hour, let minute):
            trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: minute), repeats: true)
        case .place(let latitude, let longitude, let radius, let leaving):
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                          radius: radius, identifier: planned.identifier)
            region.notifyOnEntry = !leaving
            region.notifyOnExit = leaving
            trigger = UNLocationNotificationTrigger(region: region, repeats: false)
        }
        return UNNotificationRequest(identifier: planned.identifier, content: content, trigger: trigger)
    }
}
