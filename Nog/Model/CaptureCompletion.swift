import Foundation

/// Autocomplete for `!` tokens while typing a capture: type `!un` and the tray
/// offers `!unhinged`; tap it (or press Tab on a keyboard) to finish the word.
enum CaptureCompletion {
    /// The `!` words worth offering, most useful first.
    static let tokens: [String] = NogProfile.tokenProfiles.map { "!" + $0.rawValue }
        + ["!alarm", "!once", "!log", "!off"]

    /// Completions for the word being typed (the last one, with no trailing space).
    static func suggestions(for text: String) -> [String] {
        guard let last = text.last, !last.isWhitespace,
              let word = text.split(whereSeparator: \.isWhitespace).last else { return [] }
        let typed = word.lowercased()
        guard typed.hasPrefix("!") else { return [] }
        return tokens.filter { $0.hasPrefix(typed) && $0 != typed }
    }

    /// `text` with its last word replaced by `token`, plus a space to keep typing.
    static func complete(_ text: String, with token: String) -> String {
        guard let range = text.range(of: #"\S+$"#, options: .regularExpression) else {
            return text + token + " "
        }
        return text.replacingCharacters(in: range, with: token + " ")
    }
}
