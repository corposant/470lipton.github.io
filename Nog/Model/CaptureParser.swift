import Foundation

struct CaptureDefaults: Equatable {
    var firstDelayMinutes: Int
    var repeatMinutes: Int?
}

struct CaptureResult: Equatable {
    var title: String
    var reminder: Reminder?
    var tags: [String]
}

/// Turns a quick-capture line into an item. Everything gets the default nog
/// unless you say otherwise with a few optional tokens anywhere in the text:
///
///   `!8m` `!2h` `!1d`   repeat every 8 minutes / 2 hours / 1 day
///   `!once`             remind once, don't repeat
///   `!off` / `!idea`    no reminder at all
///   `@30m` `@2h` `@1d`  start nogging in 30 minutes / 2 hours / 1 day
///   `@now`              start now
///   `#tag`              add a tag
enum CaptureParser {
    static func parse(_ text: String, defaults: CaptureDefaults, now: Date) -> CaptureResult {
        var words: [String] = []
        var tags: [String] = []
        var noReminder = false
        var once = false
        var repeatOverride: Int?
        var delayOverride: Int?

        for token in text.split(whereSeparator: \.isWhitespace) {
            let word = String(token)
            let lower = word.lowercased()
            switch lower {
            case "!off", "!idea", "!no":
                noReminder = true
                continue
            case "!once":
                once = true
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
            if word.hasPrefix("#"), word.count > 1 {
                tags.append(String(word.dropFirst()))
                continue
            }
            words.append(word)
        }

        let title = words.joined(separator: " ")
        if noReminder {
            return CaptureResult(title: title, reminder: nil, tags: tags)
        }
        let delay = delayOverride ?? defaults.firstDelayMinutes
        let repeatMinutes = once ? nil : (repeatOverride ?? defaults.repeatMinutes)
        let reminder = Reminder(start: now.addingTimeInterval(TimeInterval(delay * 60)),
                                repeatMinutes: repeatMinutes)
        return CaptureResult(title: title, reminder: reminder, tags: tags)
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
