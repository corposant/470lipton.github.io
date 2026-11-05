import SwiftUI
import UserNotifications
import BackgroundTasks

@main
struct NogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = ItemStore.shared
    @State private var router = Router.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(router)
                .task {
                    await NotificationScheduler.shared.requestAuthorization()
                    await store.syncNow()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await store.syncNow() }
            case .background:
                BackgroundRefresh.schedule()
            default:
                break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationScheduler.shared.registerCategories()
        BackgroundRefresh.register()
        return true
    }

    /// Show nogs even while the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// Done / Snooze / Tomorrow buttons, or a tap on the notification itself.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let idString = response.notification.request.content.userInfo[NotificationScheduler.itemIDKey] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            if let idString, let id = UUID(uuidString: idString) {
                let store = ItemStore.shared
                switch action {
                case NotificationScheduler.Action.done.rawValue:
                    store.markDone(id)
                case NotificationScheduler.Action.snoozeHour.rawValue:
                    store.snooze(id, until: .now.addingTimeInterval(3600))
                case NotificationScheduler.Action.morning.rawValue:
                    store.snooze(id, until: NogSettings.nextMorning())
                case UNNotificationDefaultActionIdentifier:
                    Router.shared.open(id)
                default:
                    break
                }
                await store.syncNow()
            }
            completionHandler()
        }
    }
}

/// Periodically wakes the app (when iOS allows) to top up scheduled nogs.
enum BackgroundRefresh {
    static let identifier = "io.nogapp.nog.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            schedule()
            let work = Task { @MainActor in
                await ItemStore.shared.syncNow()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
