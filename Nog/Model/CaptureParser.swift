import Foundation

struct CaptureDefaults: Equatable {
    var firstDelayMinutes: Int
    var repeatMinutes: Int?
    var curve: RepeatCurve = .steady
    var escalateAfter: Int? = nil
    /// Hush: no sound, no Time Sensitive.
    var silent = false
}

struct CaptureResult: Equatable {
    var title: String
    var reminder: Reminder?
    var tags: [String]
    var estimateMinutes: Int? = nil
}

/// Turns a quick-capture line into an item. Everything gets the default nog
/// unless you say otherwise with a few optional tokens anywhere in the text:
///
///   `!8m` `!2h` `!1d`   repeat every 8 minutes / 2 hours / 1 day
///   `!once` `!norepeat` remind once, don't repeat
///   `!log`              logarithmic: gaps double each time (8, 16, 32…), capped at daily
///   `!alarm`            ring like a real alarm (through Silent and Focus)
///   `!hush` `!whisper` `!daily` `!easing` `!steady` `!building` `!hyperfocus` `!unhinged`
///                       use a nog profile (or just its first three letters: `!hus` `!unh`…;
///                       `!gentle` = Whisper, `!break` = Hyperfocus)
///   `!off` / `!idea`    no reminder at all
///   `@30m` `@2h` `@1d`  start nogging in 30 minutes / 2 hours / 1 day
///   `@now`              start now
///   `#tag`              add a tag
///   `~30m` `~2h`        how long it'll take (the ▶︎ timebox)
///
/// …and plain English, via `NaturalDateParser`: "lunch next Tues",
/// "call mom tomorrow at 3", "pills every 4 hours", "stretch in 20 min".
enum CaptureParser {
    static func parse(_ text: String, defaults: CaptureDefaults, now: Date,
                      calendar: Calendar = .current) -> CaptureResult {
        var words: [String] = []
        var tags: [String] = []
        var noReminder = false
        var once = false
        var curveOverride: RepeatCurve?
        var alarm = false
        var profile: NogProfile?
        var estimate: Int?
        var repeatOverride: Int?
        var delayOverride: Int?

        for token in text.split(whereSeparator: \.isWhitespace) {
            let word = String(token)
            let lower = word.lowercased()
            switch lower {
            case "!off", "!idea", "!no":
                noReminder = true
                continue
            case "!once", "!norepeat", "!no-repeat":
                once = true
                continue
            case "!log", "!logarithmic", "!ease":
                curveOverride = .logarithmic
                continue
            case "!alarm", "!ring":
                alarm = true
                continue
            case _ where NogProfile.token(lower) != nil:
                profile = NogProfile.token(lower)
                continue
            case "@now":
                delayOverride = 0
                continue
            default:
                break
            }
            if lower.hasPrefix("!"), let m = minutes(lower.dropFirst()), m > 0 {
                repeatOverride = m
                continue
            }
            if lower.hasPrefix("@"), let m = minutes(lower.dropFirst()) {
                delayOverride = m
                continue
            }
            if lower.hasPrefix("~"), let m = minutes(lower.dropFirst()), m > 0 {
                estimate = m
                continue
            }
            if word.hasPrefix("#"), word.count > 1 {
                tags.append(String(word.dropFirst()))
                continue
            }
            words.append(word)
        }

        let natural = NaturalDateParser.parse(words.joined(separator: " "), now: now, calendar: calendar)
        let title = natural.title
        if noReminder {
            return CaptureResult(title: title, reminder: nil, tags: tags, estimateMinutes: estimate)
        }
        let effective = profile.map {
            CaptureDefaults(firstDelayMinutes: $0.firstDelayMinutes, repeatMinutes: $0.repeatMinutes,
                            curve: $0.curve, escalateAfter: $0.escalateAfter, silent: $0.silent)
        } ?? defaults
        let start: Date
        if let delayOverride {
            start = now.addingTimeInterval(TimeInterval(delayOverride * 60))
        } else if let naturalStart = natural.start {
            start = naturalStart
        } else {
            start = now.addingTimeInterval(TimeInterval(effective.firstDelayMinutes * 60))
        }
        let repeatMinutes = once ? nil : (repeatOverride ?? natural.repeatMinutes ?? effective.repeatMinutes)
        let reminder = Reminder(start: start, repeatMinutes: repeatMinutes,
                                curve: curveOverride ?? effective.curve, alarm: alarm, silent: effective.silent,
                                escalateAfter: effective.escalateAfter)
        return CaptureResult(title: title, reminder: reminder, tags: tags, estimateMinutes: estimate)
    }

    /// "8m" → 8, "2h" → 120, "1d" → 1440, "15" → 15. Anything else → nil.
    static func minutes(_ s: Substring) -> Int? {
        guard let unit = s.last else { return nil }
        let multiplier: Int
        var digits = s
        switch unit {
        case "m": multiplier = 1; digits = s.dropLast()
        case "h": multiplier = 60; digits = s.dropLast()
        case "d": multiplier = 1440; digits = s.dropLast()
        default:
            guard unit.isASCII, unit.isNumber else { return nil }
            multiplier = 1
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int(digits), n <= 100_000 else { return nil }
        return n * multiplier
    }
}
