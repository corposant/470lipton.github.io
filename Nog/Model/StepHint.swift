import Foundation

/// The two-minute start works best with a physical first step ("open the laptop"), not a
/// fuzzy one ("deal with taxes"). Spots titles that start with a vague verb, to nudge gently.
/// Only a hint: it never blocks or rewrites anything.
enum StepHint {
    /// Openings that name a feeling about a task rather than something to do with your hands.
    static let vagueOpenings = [
        "deal with", "sort out", "work on", "figure out", "think about", "look into",
        "handle", "tackle", "get on top of", "get around to", "start on", "focus on",
        "plan", "organize", "organise", "finish", "do something about",
    ]

    /// The vague opening this title starts with, if any ("Deal with").
    static func leadingVerb(_ title: String) -> String? {
        let lower = title.lowercased().trimmingCharacters(in: .whitespaces)
        guard let opening = vagueOpenings
            .filter({ lower == $0 || lower.hasPrefix($0 + " ") })
            .max(by: { $0.count < $1.count })
        else { return nil }
        return String(title.trimmingCharacters(in: .whitespaces).prefix(opening.count))
    }

    static func isVague(_ title: String) -> Bool { leadingVerb(title) != nil }
}
