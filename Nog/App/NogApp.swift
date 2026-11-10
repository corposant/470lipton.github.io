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
                // Tapping a widget: nog://item/<id> opens that item, nog://capture the capture box.
                .onOpenURL { url in
                    guard url.scheme == "nog" else { return }
                    if url.host() == "item", let id = UUID(uuidString: url.lastPathComponent) {
                        router.open(id)
                    } else if url.host() == "capture" {
                        router.focusCapture()
                    }
                }
                .task {
                    await NotificationScheduler.shared.requestAuthorization()
                    // Launch also makes the scene active, which refreshes too; the two share one run.
                    await store.refresh()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                store.pauseWatching(false)
                Task { await store.refresh() }
                QuickActions.update()
            case .background:
                // Keep the app icon's menu current ("Resume nogs", or silence that has run out).
                QuickActions.update()
                BackgroundRefresh.schedule()
                store.pauseWatching(true)
                Task {
                    await store.syncIfPending()
                    await store.flush()
                }
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
        QuickActions.update()
        return true
    }

    /// Hooks up the scene delegate that receives app-icon quick actions, and runs one that
    /// launched the app from cold.
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let shortcut = options.shortcutItem { QuickActions.handle(shortcut) }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
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
