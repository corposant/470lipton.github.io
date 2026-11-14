import AppIntents

// Hands-free Nog: everything here runs without opening the app, so it works by voice
// in CarPlay ("Hey Siri, what's next in Nog?"), on AirPods, and from Shortcuts.

/// Which part of your nogs Siri reads out.
enum NogListChoice: String, AppEnum {
    case now, today, agenda, loose, doing

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Nog List"
    static var caseDisplayRepresentations: [NogListChoice: DisplayRepresentation] = [
        // Plain words first; the in-app names ("Now", "No reminder",
        // "Nogitivity") still work as synonyms.
        .now: DisplayRepresentation(title: "what's next",
                                    synonyms: ["next", "now", "right now", "nogging now", "what's due"]),
        .today: DisplayRepresentation(title: "today",
                                      synonyms: ["today's list", "the rest of today", "my day"]),
        .agenda: DisplayRepresentation(title: "this week",
                                       synonyms: ["agenda", "my agenda", "the week", "schedule", "my schedule", "what's coming up"]),
        .loose: DisplayRepresentation(title: "unscheduled",
                                      synonyms: ["loose nogs", "loose", "no time", "anytime", "someday"]),
        .doing: DisplayRepresentation(title: "what I'm doing",
                                      synonyms: ["what I'm working on", "working on", "current", "Nogitivity"]),
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

/// "What's next in Nog?" / "Read this week in Nog".
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

    @Parameter(title: "Item", requestValueDialog: IntentDialog("Which one is done?"))
    var item: ReminderEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = ItemStore.shared
        guard let existing = store.items[item.id] else { throw NogIntentError.notFound }
        store.markDone(existing.id)
        try await store.flushOrThrow()
        await store.syncNow()
        try await store.flushOrThrow()
        return .result(dialog: IntentDialog(full: "Done: \(existing.title).", supporting: "Done"))
    }
}

/// How long "Silence Nog" lasts.
enum SilenceLengthChoice: String, AppEnum {
    case oneHour, twoHours, fiveHours, twelveHours, untilResumed

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Silence Length"
    static var caseDisplayRepresentations: [SilenceLengthChoice: DisplayRepresentation] = [
        .oneHour: DisplayRepresentation(title: "an hour", synonyms: ["one hour", "1 hour", "a bit", "a while"]),
        .twoHours: DisplayRepresentation(title: "two hours", synonyms: ["2 hours", "a couple of hours", "a couple hours"]),
        .fiveHours: DisplayRepresentation(title: "five hours", synonyms: ["5 hours"]),
        .twelveHours: DisplayRepresentation(title: "twelve hours", synonyms: ["12 hours", "the night", "overnight", "all day"]),
        .untilResumed: DisplayRepresentation(title: "until I turn it back on",
                                             synonyms: ["until I turn it on", "until I say so", "indefinitely"]),
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
