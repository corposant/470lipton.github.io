import AppIntents

/// "Hey Siri, take a Nog" (or "Capture in Nog") → Siri asks what → item saved with the default nog.
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

    @Parameter(title: "Item", requestValueDialog: IntentDialog("Which one do you want to start?"))
    var item: ReminderEntity

    @Parameter(title: "Minutes", description: "Leave empty for the two-minute start.")
    var minutes: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = ItemStore.shared
        guard let existing = store.items[item.id] else { throw NogIntentError.notFound }
        let timebox = minutes ?? store.suggestedTimebox(for: existing.id).minutes
        // A nog with sub-nogs starts its first unfinished one: say which.
        let target = store.items[store.startTarget(for: existing.id)] ?? existing
        // Its step is already under way: Start leaves that timer alone, so don't claim otherwise.
        if target.id != existing.id, target.isDoing {
            return .result(dialog: IntentDialog(full: "You're already on \(target.title).", supporting: "Already started"))
        }
        store.start(existing.id, timebox: timebox)
        await store.syncNow()
        await store.flush()
        let length = timebox.map { "for \(IntervalFormat.amount($0))" } ?? "with no time limit"
        return .result(dialog: IntentDialog(full: "Started \(target.title) \(length). Just that, then you can stop.",
                                            supporting: "Started"))
    }
}

/// Every phrase says "Nog" once, usually at the end, in plain words. The made-up
/// verbs ("Nog me", "I nogged…") stay for people who already use them, but each
/// action also has ordinary phrasing and a version without an item name, where
/// Siri asks which one.
struct NogShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureIntent(),
                    phrases: ["Take a \(.applicationName)", "Take a new \(.applicationName)",
                              "Add to \(.applicationName)", "Add something to \(.applicationName)",
                              "Capture in \(.applicationName)", "Capture something in \(.applicationName)",
                              "Take a note in \(.applicationName)", "Jot something down in \(.applicationName)",
                              "New \(.applicationName)", "\(.applicationName) this", "\(.applicationName) me"],
                    shortTitle: "Take a Nog",
                    systemImageName: "plus.circle")
        AppShortcut(intent: ReadNogsIntent(),
                    phrases: ["Read my \(.applicationName)", "What's next in \(.applicationName)",
                              "What's on my \(.applicationName)", "What's on in \(.applicationName)",
                              "Read \(\.$list) in \(.applicationName)", "Read \(\.$list) from \(.applicationName)",
                              "What's \(\.$list) in \(.applicationName)", "What's nogging in \(.applicationName)"],
                    shortTitle: "Read My Nogs",
                    systemImageName: "text.bubble")
        AppShortcut(intent: MarkNoggedIntent(),
                    phrases: ["Mark done in \(.applicationName)", "I'm done in \(.applicationName)",
                              "Finish something in \(.applicationName)",
                              "Mark \(\.$item) done in \(.applicationName)", "Finish \(\.$item) in \(.applicationName)",
                              "I finished \(\.$item) in \(.applicationName)", "Done with \(\.$item) in \(.applicationName)",
                              "\(.applicationName) \(\.$item) done", "I nogged \(\.$item) in \(.applicationName)"],
                    shortTitle: "Mark Done",
                    systemImageName: "checkmark.circle")
        AppShortcut(intent: StartItemIntent(),
                    phrases: ["Start in \(.applicationName)", "Start something in \(.applicationName)",
                              "Start \(\.$item) in \(.applicationName)", "Work on \(\.$item) in \(.applicationName)",
                              "Begin \(\.$item) in \(.applicationName)", "\(.applicationName) start \(\.$item)"],
                    shortTitle: "Start",
                    systemImageName: "play.circle")
        AppShortcut(intent: SilenceNogsIntent(),
                    phrases: ["Silence \(.applicationName)", "Quiet \(.applicationName)",
                              "Pause \(.applicationName)", "Mute \(.applicationName)",
                              "Silence \(.applicationName) for \(\.$length)", "Pause \(.applicationName) for \(\.$length)",
                              "Mute \(.applicationName) for \(\.$length)"],
                    shortTitle: "Silence",
                    systemImageName: "bell.slash")
        AppShortcut(intent: ResumeNogsIntent(),
                    phrases: ["Resume \(.applicationName)", "Unsilence \(.applicationName)",
                              "Unmute \(.applicationName)", "Turn \(.applicationName) back on"],
                    shortTitle: "Resume",
                    systemImageName: "bell")
        AppShortcut(intent: OpenCaptureIntent(),
                    phrases: ["Open \(.applicationName) capture", "Type in \(.applicationName)",
                              "Open \(.applicationName) to type"],
                    shortTitle: "Quick Capture",
                    systemImageName: "square.and.pencil")
    }
}
