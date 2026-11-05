import AppIntents

/// "Hey Siri, capture in Nog" → Siri asks what → item saved with the default nag.
/// Also usable from Shortcuts and the Action Button without opening the app.
struct CaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture"
    static var description = IntentDescription("Capture something and start nagging about it.")
    static var openAppWhenRun = false

    @Parameter(title: "What", requestValueDialog: IntentDialog("What do you want to capture?"))
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let item = ItemStore.shared.capture(text) else {
            return .result(dialog: "There was nothing to capture.")
        }
        await ItemStore.shared.syncNow()
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

struct NagShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureIntent(),
                    phrases: ["Capture in \(.applicationName)", "Nag me with \(.applicationName)"],
                    shortTitle: "Capture",
                    systemImageName: "plus.circle")
        AppShortcut(intent: OpenCaptureIntent(),
                    phrases: ["Open \(.applicationName) capture"],
                    shortTitle: "Quick Capture",
                    systemImageName: "square.and.pencil")
    }
}
