import AppIntents

/// Opens the app straight into the New Nog capture field. Used by the Action Button,
/// Shortcuts, and the New Nog control (Lock Screen, Control Center, Action Button).
///
/// It lives in Shared because a control's intent has to be compiled into both the
/// widget extension and the app. With openAppWhenRun, the system always runs
/// perform() in the app, so the extension's copy never touches the store.
struct OpenCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick Capture"
    static var description = IntentDescription("Open Nog ready to type.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        Router.shared.focusCapture()
        #endif
        return .result()
    }
}
