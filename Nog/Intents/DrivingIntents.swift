import AppIntents

// Hands-free Nog: everything here runs without opening the app, so it works by voice
// in CarPlay ("Hey Siri, what's nogging in Nog?"), on AirPods, and from Shortcuts.

/// Which part of your nogs Siri reads out.
enum NogListChoice: String, AppEnum {
    case now, today, agenda, loose, doing

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Nog List"
    static var caseDisplayRepresentations: [NogListChoice: DisplayRepresentation] = [
        .now: "Nogging now",
        .today: "Today",
        .agenda: "Agenda",
        .loose: "Loose nogs",
        .doing: "Nogitivity",
    ]

    var section: NogBriefing.Section {
        switch self {
        case .now: .now
        case .today: .today
        case .agenda: .agenda
        case .loose: .loose
        case .doing: .doing
        }
    }
}

/// "What's nogging in Nog?" / "Read my agenda in Nog".
struct ReadNogsIntent: AppIntent {
    static var title: LocalizedStringResource = "Read My Nogs"
    static var description = IntentDescription("Hear what's nogging, what's left today, your agenda, loose nogs, or what you're working on.")
    static var openAppWhenRun = false

    @Parameter(title: "List", default: .now)
    var list: NogListChoice

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = NogBriefing.text(for: list.section, items: Array(ItemStore.shared.items.values),
                                    now: .now, policy: NogSettings.policy)
        return .result(dialog: "\(text)")
    }
}

/// "Mark <item> done in Nog".
struct MarkNoggedIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark Done"
    static var description = IntentDescription("Mark a Nog item as done. It stops nogging you.")
    static var openAppWhenRun = false

    @Parameter(title: "Item")
    var item: ReminderEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = ItemStore.shared
        guard let existing = store.items[item.id] else { throw NogIntentError.notFound }
        store.markDone(existing.id)
        await store.syncNow()
        await store.flush()
        return .result(dialog: IntentDialog(full: "Done: \(existing.title).", supporting: "Done"))
    }
}

/// How long "Silence Nog" lasts.
enum SilenceLengthChoice: String, AppEnum {
    case oneHour, twoHours, fiveHours, twelveHours, untilResumed

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Silence Length"
    static var caseDisplayRepresentations: [SilenceLengthChoice: DisplayRepresentation] = [
        .oneHour: "an hour",
        .twoHours: "two hours",
        .fiveHours: "five hours",
        .twelveHours: "twelve hours",
        .untilResumed: "until I turn it back on",
    ]

    var minutes: Int? {
        switch self {
        case .oneHour: 60
        case .twoHours: 120
        case .fiveHours: 300
        case .twelveHours: 720
        case .untilResumed: nil
        }
    }
}

/// "Silence Nog for an hour" — handy for a drive.
struct SilenceNogsIntent: AppIntent {
    static var title: LocalizedStringResource = "Silence Nogs"
    static var description = IntentDescription("Hold every nog and alarm for a while. Anything due comes once silence ends.")
    static var openAppWhenRun = false

    @Parameter(title: "For", default: .oneHour)
    var length: SilenceLengthChoice

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        Silence.silence(for: length.minutes)
        await ItemStore.shared.syncNow()
        let until = NogSettings.silencedUntil.map { NogSettings.silenceLabel($0) } ?? "Silenced"
        return .result(dialog: "\(until).")
    }
}

/// "Resume Nog".
struct ResumeNogsIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Nogs"
    static var description = IntentDescription("Turn nogs and alarms back on.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        Silence.resume()
        await ItemStore.shared.syncNow()
        return .result(dialog: "Nogs are back on.")
    }
}
