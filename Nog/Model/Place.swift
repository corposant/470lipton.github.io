import Foundation

/// "When I get home", "when I leave work": an item that reminds you at a place
/// instead of (or as well as) a time. The place is looked up by name in your saved
/// places when nogs are scheduled, so moving Home moves every item that uses it.
struct PlaceTrigger: Hashable {
    var name: String
    /// Remind when you leave, instead of when you arrive.
    var leaving = false

    /// "when you get home", "when you get to Work", "when you leave the gym"
    var phrase: String {
        if leaving { return "when you leave \(name)" }
        return name.lowercased() == "home" ? "when you get home" : "when you get to \(name)"
    }
}

/// A place you've saved in Settings › Places.
struct SavedPlace: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    /// Metres. iOS reacts reliably from about 100 m.
    var radius: Double = 150
}

/// Finds a place phrase in a capture line and takes it out of the title.
///
///   when I get home · when I get to work · when I arrive at the gym · when I'm at Mum's
///   when I leave work · when leaving the office
enum PlacePhraseParser {
    /// Common places that are understood even before they're saved.
    static let everyday = ["home", "work", "school", "the office", "the gym", "the shop", "the store"]

    /// The place, and the words left over. `known` are saved place names (any casing).
    static func extract(from words: [String], known: [String]) -> (PlaceTrigger, [String])? {
        let lower = words.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;!?()\"")) }
        for when in lower.indices where lower[when] == "when" {
            if let found = extract(from: words, lower: lower, when: when, known: known) { return found }
        }
        return nil
    }

    private static func extract(from words: [String], lower: [String], when: Int,
                                known: [String]) -> (PlaceTrigger, [String])? {
        var i = when + 1
        func at(_ k: Int) -> String? { k < lower.count ? lower[k] : nil }

        var leaving = false
        // Sure it's a place (arrive, reach, leave, or "to"/"at" before it)? Then an unknown
        // word can be one. "When I get paid" isn't a place; "when I get to Sam's" is.
        var surelyPlace = false
        if at(i) == "leaving" {
            leaving = true; surelyPlace = true; i += 1
        } else {
            // "i", "i'm", "im"
            if let w = at(i), ["i", "i'm", "im", "i’m"].contains(w) {
                let contracted = w != "i"
                i += 1
                if contracted {
                    // "when I'm at X", "when I'm back home"
                } else if let verb = at(i), ["get", "arrive", "reach", "am", "leave", "go", "come"].contains(verb) {
                    leaving = verb == "leave"
                    surelyPlace = ["arrive", "reach", "leave"].contains(verb)
                    i += 1
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }
        // Little words before the place: to, at, back, back to, into
        while let w = at(i), ["to", "at", "back", "in", "into"].contains(w) {
            if w != "back" { surelyPlace = true }
            i += 1
        }
        guard i < lower.count else { return nil }

        // A saved or everyday name, longest first; otherwise one word.
        let candidates = (known + everyday).sorted { $0.count > $1.count }
        var name: String?
        var used = 0
        for candidate in candidates {
            let parts = candidate.lowercased().split(separator: " ").map(String.init)
            guard i + parts.count <= lower.count, Array(lower[i..<(i + parts.count)]) == parts else { continue }
            name = known.first { $0.caseInsensitiveCompare(candidate) == .orderedSame }
                ?? candidate.prefix(1).uppercased() + candidate.dropFirst()
            used = parts.count
            break
        }
        if name == nil {
            guard surelyPlace else { return nil }
            var k = i
            if lower[k] == "the", k + 1 < lower.count { k += 1 }
            let word = words[k].trimmingCharacters(in: CharacterSet(charactersIn: ",.;!?()\""))
            guard !word.isEmpty, word.first?.isLetter == true,
                  !["a", "an", "chance", "moment", "minute", "time"].contains(word.lowercased()) else { return nil }
            let full = (k > i ? "the " : "") + word
            name = full.prefix(1).uppercased() + full.dropFirst()
            used = k - i + 1
        }
        guard let name else { return nil }
        var rest = words
        rest.removeSubrange(when..<(i + used))
        return (PlaceTrigger(name: name, leaving: leaving), rest)
    }
}
