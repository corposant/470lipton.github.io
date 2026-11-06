import SwiftUI
import UserNotifications
import BackgroundTasks

@main
struct NogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = ItemStore.shared
    @State private var router = Router.shared
    @AppStorage(ThemeMode.key) private var themeMode: ThemeMode = .auto

    init() {
        // Futura for navigation titles (falls back to the system font if ever missing).
        let large = UIFont(name: "Futura-Bold", size: 32) ?? .systemFont(ofSize: 30, weight: .bold)
        let inline = UIFont(name: "Futura-Medium", size: 17) ?? .systemFont(ofSize: 16, weight: .semibold)
        let appearance = UINavigationBar.appearance()
        appearance.largeTitleTextAttributes = [.font: large, .kern: 2.5]
        appearance.titleTextAttributes = [.font: inline, .kern: 1.2]
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(router)
                .tint(Theme.blue)
                .preferredColorScheme(themeMode == .auto ? nil : (themeMode == .dark ? .dark : .light))
                .task {
                    await NotificationScheduler.shared.requestAuthorization()
                    await store.connectToICloud()
                    await store.syncNow()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    // iCloud was unavailable earlier (signing in, offline at launch): try again.
                    if StorageMode.current == .iCloud && !store.isUsingICloud {
                        await store.connectToICloud()
                    }
                    await store.reloadFromDisk()
                    await store.syncNow()
                }
            case .background:
                BackgroundRefresh.schedule()
                Task { await store.flush() }
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
                    let minutes = store.items[id].map(NogSettings.snoozeLength(for:)) ?? NogSettings.snoozeMinutes
                    store.snooze(id, until: .now.addingTimeInterval(TimeInterval(minutes * 60)))
                case NotificationScheduler.Action.morning.rawValue:
                    store.snooze(id, until: store.items[id].map { NogSettings.nextMorning(for: $0) } ?? NogSettings.nextMorning())
                case NotificationScheduler.Action.extend.rawValue:
                    store.extend(id, minutes: 10)
                case NotificationScheduler.Action.stopDoing.rawValue:
                    store.stopDoing(id)
                case UNNotificationDefaultActionIdentifier:
                    Router.shared.open(id)
                default:
                    break
                }
                await store.syncNow()
                await store.flush()
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
                await ItemStore.shared.reloadFromDisk()
                await ItemStore.shared.syncNow()
                await ItemStore.shared.flush()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        BGTaskScheduler.shared.submitTaskRequest(request) { error in
            if let error { print("Nog: background refresh not scheduled: \(error)") }
        }
    }
}
