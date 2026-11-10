import AppIntents

/// "Hey Siri, Nog me" (or "Capture in Nog") → Siri asks what → item saved with the default nog.
/// Also usable from Shortcuts and the Action Button without opening the app.
struct CaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture"
    static var description = IntentDescription("Capture something and start nogging about it.")
    static var openAppWhenRun = false

    @Parameter(title: "What", requestValueDialog: IntentDialog("What do you want to capture?"))
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let item = ItemStore.shared.capture(text) else {
            return .result(dialog: "There was nothing to capture.")
        }
        await ItemStore.shared.syncNow()
        await ItemStore.shared.flush()
        return .result(dialog: "Got it: \(item.title)")
    }
}

/// Opens the app straight into the capture field (good for the Action Button).
struct OpenCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick Capture"
    static var description = IntentDescription("Open Nog ready to type.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Router.shared.focusCapture()
        return .result()
    }
}

/// "Start <item> in Nog" → ▶︎ with the suggested timebox. Runs without opening the app
/// (a LiveActivityIntent may start the timer from the background), so it works by voice
/// in CarPlay, where the timer then shows on the dashboard.
struct StartItemIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start Working On"
    static var description = IntentDescription("Start doing a Nog item, with a timer on your Lock Screen and CarPlay.")
    static var openAppWhenRun = false

    @Parameter(title: "Item")
    var item: ReminderEntity

    @Parameter(title: "Minutes", description: "Leave empty to use Nog's suggestion.")
    var minutes: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = ItemStore.shared
        guard let existing = store.items[item.id] else { throw NogIntentError.notFound }
        let timebox = minutes ?? store.suggestedTimebox(for: existing.id).minutes
        store.start(existing.id, timebox: timebox)
        await store.syncNow()
        await store.flush()
        let length = timebox.map { "for \(IntervalFormat.amount($0))" } ?? "with no time limit"
        return .result(dialog: IntentDialog(full: "Started \(existing.title) \(length). Go!", supporting: "Started"))
    }
}

struct NogShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureIntent(),
                    phrases: ["Capture in \(.applicationName)", "\(.applicationName) me", "\(.applicationName) this",
                              "Add to \(.applicationName)", "New \(.applicationName)"],
                    shortTitle: "Capture",
                    systemImageName: "plus.circle")
        AppShortcut(intent: ReadNogsIntent(),
                    phrases: ["What's nogging in \(.applicationName)", "Read my \(.applicationName)",
                              "Read \(\.$list) in \(.applicationName)", "What's on my \(.applicationName)"],
                    shortTitle: "Read My Nogs",
                    systemImageName: "text.bubble")
        AppShortcut(intent: MarkNoggedIntent(),
                    phrases: ["Mark \(\.$item) done in \(.applicationName)", "\(.applicationName) \(\.$item) done",
                              "I nogged \(\.$item) in \(.applicationName)"],
                    shortTitle: "Mark Done",
                    systemImageName: "checkmark.circle")
        AppShortcut(intent: StartItemIntent(),
                    phrases: ["Start \(\.$item) in \(.applicationName)", "\(.applicationName) start \(\.$item)"],
                    shortTitle: "Start",
                    systemImageName: "play.circle")
        AppShortcut(intent: SilenceNogsIntent(),
                    phrases: ["Silence \(.applicationName)", "Silence \(.applicationName) for \(\.$length)",
                              "Quiet \(.applicationName)"],
                    shortTitle: "Silence",
                    systemImageName: "bell.slash")
        AppShortcut(intent: ResumeNogsIntent(),
                    phrases: ["Resume \(.applicationName)", "Unsilence \(.applicationName)"],
                    shortTitle: "Resume",
                    systemImageName: "bell")
        AppShortcut(intent: OpenCaptureIntent(),
                    phrases: ["Open \(.applicationName) capture"],
                    shortTitle: "Quick Capture",
                    systemImageName: "square.and.pencil")
    }
}
