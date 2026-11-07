import Foundation

/// How an item gets your attention. One name, colour and icon everywhere:
/// Capture, Agenda, the item page.
enum NogKind: String, CaseIterable, Identifiable {
    /// No reminder at all.
    case note
    /// Notifications, repeating until done.
    case nog
    /// Rings like the Clock app (AlarmKit), through Silent and Focus.
    case alarm

    var id: String { rawValue }

    var label: String {
        switch self {
        case .note: "Note"
        case .nog: "Nog"
        case .alarm: "Alarm"
        }
    }

    var systemImage: String {
        switch self {
        case .note: "lightbulb"
        case .nog: "bell"
        case .alarm: "alarm"
        }
    }

    static func of(_ reminder: Reminder?) -> NogKind {
        guard let reminder else { return .note }
        return reminder.alarm ? .alarm : .nog
    }

    /// What will happen, in a sentence, for this reminder.
    static func promise(for reminder: Reminder?, now: Date = .now) -> String {
        guard let r = reminder else { return "Never nogs. It waits in Loose nogs on the Nogs tab." }
        let time = DayFormat.label(r.start) == "Today"
            ? r.start.formatted(date: .omitted, time: .shortened)
            : "\(DayFormat.label(r.start)) \(r.start.formatted(date: .omitted, time: .shortened))"
        let then = r.repeatSummary.map { ", then \($0) until you nog it" } ?? ", once"
        if r.alarm {
            return "Rings at \(time) like the Clock app, even on Silent and in Focus\(then)."
        }
        return "A notification at \(time)\(then). Quiet on Silent and in Focus."
    }
}

/// A capture being put together: the typed text, plus whatever was picked in the
/// option tray (which wins over what the text says).
struct CaptureDraft: Equatable {
    var text = ""
    var subItems: [String] = []
    /// Picked start time (nil: from the text, or the default delay).
    var when: Date?
    /// Picked Note / Nog / Alarm (nil: from the text).
    var kind: NogKind?
    /// Picked rhythm (nil: from the text, or the default).
    var profile: NogProfile?
    /// Tags added in the tray, on top of #tags typed in the text.
    var extraTags: [String] = []
    var parentID: UUID?

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The text as parsed, with the tray's choices applied on top.
    func resolved(defaults: CaptureDefaults, now: Date, calendar: Calendar = .current) -> CaptureResult {
        var result = CaptureParser.parse(text, defaults: defaults, now: now, calendar: calendar)
        let kind = self.kind ?? NogKind.of(result.reminder)
        if kind == .note {
            result.reminder = nil
        } else {
            var r = result.reminder ?? Reminder(
                start: now.addingTimeInterval(TimeInterval(defaults.firstDelayMinutes * 60)),
                repeatMinutes: defaults.repeatMinutes, curve: defaults.curve, escalateAfter: defaults.escalateAfter)
            if let profile { r = profile.apply(to: r) }
            if let when { r.start = when }
            r.alarm = kind == .alarm
            result.reminder = r
        }
        for tag in extraTags where !result.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            result.tags.append(tag)
        }
        return result
    }

    /// True when the rhythm was picked here or typed in the text, so a parent's shouldn't replace it.
    func choseOwnRhythm(defaults: CaptureDefaults, now: Date) -> Bool {
        if kind != nil || profile != nil { return true }
        let typed = CaptureParser.parse(text, defaults: defaults, now: now).reminder
        return CaptureDefaults.differs(typed, from: defaults)
    }
}

extension CaptureDefaults {
    /// Whether a parsed reminder's rhythm is something other than these defaults.
    static func differs(_ reminder: Reminder?, from defaults: CaptureDefaults) -> Bool {
        guard let r = reminder else { return false }
        return r.repeatMinutes != defaults.repeatMinutes || r.curve != defaults.curve
            || r.escalateAfter != defaults.escalateAfter
    }
}
