import Foundation

/// Notes are stored as plain text with a little Markdown in it, so they read fine anywhere
/// they're shown as text (Reminders, the nog's file in iCloud Drive, Siri) and look tidy on
/// the nog's page. Only what notes need is understood, one line at a time:
///
///     # Heading (## and ### are smaller)
///     - bullet  (* and + too; indent two spaces to nest)
///     1. numbered   A. lettered   (or 1) and a))
///     - [ ] to do   - [x] done
///     > quote
///     ---  (a line across)
///     ```  (lines between two of these are shown exactly as typed)
///     **bold**  _italic_  ~~struck~~  `code`  [text](https://…)  [[Another nog]]
///
/// Anything else is shown as it was typed, line breaks included.
enum NotesBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(indent: Int, text: String)
    /// `marker` is what was typed, like "1." or "A)".
    case ordered(indent: Int, marker: String, text: String)
    case task(indent: Int, done: Bool, text: String)
    case quote(text: String)
    case code(text: String)
    case rule
    case paragraph(text: String)
    /// One or more empty lines, shown as a small gap.
    case blank
}

/// A block and the line of the notes it came from (counting from 0), so a checkbox
/// tapped on the page can flip the right line.
struct NotesLine: Equatable {
    let index: Int
    let block: NotesBlock
}

enum NotesMarkdown {
    /// The notes, line by line. Runs of empty lines become one gap; none at either end.
    static func blocks(_ text: String) -> [NotesLine] {
        var out: [NotesLine] = []
        var inCode = false
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode {
                out.append(NotesLine(index: i, block: .code(text: raw)))
                continue
            }
            if trimmed.isEmpty {
                if let last = out.last, last.block != .blank {
                    out.append(NotesLine(index: i, block: .blank))
                }
                continue
            }
            out.append(NotesLine(index: i, block: block(for: raw)))
        }
        while out.last?.block == .blank { out.removeLast() }
        return out
    }

    /// One non-empty line.
    static func block(for line: String) -> NotesBlock {
        let (indent, rest) = splitIndent(line)
        if let m = rest.wholeMatch(of: #/(#{1,3})\s+(.+)/#) {
            return .heading(level: m.1.count, text: String(m.2))
        }
        let compact = rest.filter { !$0.isWhitespace }
        if compact.count >= 3, let first = compact.first, "-*_".contains(first), compact.allSatisfy({ $0 == first }) {
            return .rule
        }
        if let m = rest.wholeMatch(of: #/[-*+•]\s+\[([ xX])\](?:\s+(.*))?/#) {
            return .task(indent: indent, done: m.1 != " ", text: String(m.2 ?? ""))
        }
        if let m = rest.wholeMatch(of: #/[-*+•]\s+(.*)/#) {
            return .bullet(indent: indent, text: String(m.1))
        }
        if let m = rest.wholeMatch(of: #/(\d{1,3}|[A-Za-z])([.)])\s+(.+)/#) {
            return .ordered(indent: indent, marker: String(m.1) + String(m.2), text: String(m.3))
        }
        if let m = rest.wholeMatch(of: #/>\s?(.*)/#) {
            return .quote(text: String(m.1))
        }
        return .paragraph(text: rest)
    }

    /// Nesting depth from leading spaces (two per level, a tab counts as four), and the rest.
    static func splitIndent(_ line: String) -> (Int, String) {
        var spaces = 0
        var rest = Substring(line)
        while let c = rest.first, c == " " || c == "\t" {
            spaces += c == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        return (min(spaces / 2, 4), String(rest))
    }

    // MARK: Inline

    /// The scheme used for `[[Another nog]]` links on the page.
    static let linkScheme = "nog-link"

    /// Bold, italic, struck, code and links within one line. `[[Title]]` becomes a link to
    /// that nog, and bare web addresses become links too.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        var result = (try? AttributedString(markdown: linkingTitles(text), options: options)) ?? AttributedString(text)
        linkWebAddresses(in: &result)
        return result
    }

    /// The title a `nog-link:` URL points to.
    static func title(from url: URL) -> String? {
        guard url.scheme == linkScheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "title" })?.value
    }

    /// `[[Title]]` → `[Title](nog-link://open?title=Title)`, and `[[Title|shown]]` shows "shown".
    /// The same rules as `LinkParser`, so what's a link here is listed under Links too.
    static func linkingTitles(_ text: String) -> String {
        var out = ""
        var rest = text[...]
        while let open = rest.range(of: "[[") {
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "]]") else { break }
            let inner = String(after[..<close.lowerBound])
            var name = inner, shown = inner
            if let pipe = inner.firstIndex(of: "|") {
                name = String(inner[..<pipe])
                shown = String(inner[inner.index(after: pipe)...])
            }
            name = name.trimmingCharacters(in: .whitespaces)
            shown = shown.trimmingCharacters(in: .whitespaces)
            out += rest[..<open.lowerBound]
            if !name.isEmpty, !name.contains("[["), let link = url(for: name) {
                out += "[\(escaped(shown.isEmpty ? name : shown))](\(link.absoluteString))"
            } else {
                out += rest[open.lowerBound..<close.upperBound]
            }
            rest = after[close.upperBound...]
        }
        return out + rest
    }

    private static func url(for title: String) -> URL? {
        var c = URLComponents()
        c.scheme = linkScheme
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "title", value: title)]
        // Parentheses would end the Markdown link early.
        c.percentEncodedQuery = c.percentEncodedQuery?
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
        return c.url
    }

    private static func escaped(_ text: String) -> String {
        var out = ""
        for c in text {
            if "\\[]*_~`".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    private static func linkWebAddresses(in text: inout AttributedString) {
        let plain = String(text.characters)
        guard plain.contains("."),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let url = match.url, let r = Range(match.range, in: plain) else { continue }
            let chars = text.characters
            let lower = chars.index(chars.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: r.lowerBound))
            let upper = chars.index(lower, offsetBy: plain.distance(from: r.lowerBound, to: r.upperBound))
            if text[lower..<upper].runs.allSatisfy({ $0.link == nil }) {
                text[lower..<upper].link = url
            }
        }
    }

    /// The notes as plain words, without the Markdown marks: for VoiceOver.
    static func plain(_ text: String) -> String {
        String(inline(text).characters)
    }
}

/// Edits the formatting buttons make. Everything works in character offsets into the notes,
/// and returns the new notes with where the selection should be afterwards.
enum NotesFormat {
    enum LineStyle: CaseIterable {
        case bullet, numbered, lettered, checklist, heading
    }

    enum InlineStyle {
        case bold, italic, strikethrough

        var mark: String {
            switch self {
            case .bold: "**"
            case .italic: "_"
            case .strikethrough: "~~"
            }
        }
    }

    typealias Result = (text: String, selection: Range<Int>)

    /// Any list or heading mark at the start of a line (after its indent).
    private static let anyMark = #/(?:[-*+•]\s+\[[ xX]\]\s?|[-*+•]\s+|(?:\d{1,3}|[A-Za-z])[.)]\s+|#{1,3}\s+|>\s?)/#

    /// Turns the lines the selection touches into `style`, or back to plain lines when
    /// they all already are. Numbers and letters count on from a list just above.
    static func toggle(_ style: LineStyle, in text: String, selection: Range<Int>) -> Result {
        var lines = text.components(separatedBy: "\n")
        let (first, last) = lineSpan(lines, selection)
        let touched = Array(first...last)
        let nonBlank = touched.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        let targets = nonBlank.isEmpty ? [first] : nonBlank
        let removing = !nonBlank.isEmpty && nonBlank.allSatisfy { has(style, lines[$0]) }

        var counter = removing ? 0 : startCount(for: style, above: first, in: lines)
        let caretFromEnd = (lineStart(lines, first) + lines[first].count) - selection.upperBound
        for i in targets {
            let (indent, body) = splitMark(lines[i])
            if removing {
                lines[i] = indent + body
            } else {
                counter += 1
                lines[i] = indent + mark(for: style, number: counter) + body
            }
        }
        let newText = lines.joined(separator: "\n")
        if selection.isEmpty && first == last {
            // Keep the caret where it was in the line, counted from the end.
            let end = lineStart(lines, first) + lines[first].count
            let caret = max(lineStart(lines, first), end - max(0, caretFromEnd))
            return (newText, caret..<caret)
        }
        let start = lineStart(lines, first)
        return (newText, start..<(lineStart(lines, last) + lines[last].count))
    }

    /// Moves the touched lines in (or out) by one level, two spaces.
    static func indent(_ outward: Bool, in text: String, selection: Range<Int>) -> Result {
        var lines = text.components(separatedBy: "\n")
        let (first, last) = lineSpan(lines, selection)
        var shift = 0, firstShift = 0
        for i in first...last where !lines[i].trimmingCharacters(in: .whitespaces).isEmpty || first == last {
            let before = lines[i].count
            if outward {
                var line = Substring(lines[i])
                var dropped = 0
                while dropped < 2, line.first == " " { line = line.dropFirst(); dropped += 1 }
                lines[i] = String(line)
            } else {
                lines[i] = "  " + lines[i]
            }
            let delta = lines[i].count - before
            if i == first { firstShift = delta }
            shift += delta
        }
        let newText = lines.joined(separator: "\n")
        let lower = max(lineStart(lines, first), selection.lowerBound + firstShift)
        let upper = max(lower, selection.upperBound + shift)
        return (newText, lower..<min(upper, newText.count))
    }

    /// Wraps the selection in bold, italic or strikethrough marks, or takes them off if
    /// it's already wrapped. With nothing selected, puts a pair at the caret, ready to type in.
    static func wrap(_ style: InlineStyle, in text: String, selection: Range<Int>) -> Result {
        var chars = Array(text)
        let mark = Array(style.mark)
        let lo = min(selection.lowerBound, chars.count), hi = min(selection.upperBound, chars.count)
        if lo >= mark.count, hi + mark.count <= chars.count,
           Array(chars[(lo - mark.count)..<lo]) == mark, Array(chars[hi..<(hi + mark.count)]) == mark {
            chars.removeSubrange(hi..<(hi + mark.count))
            chars.removeSubrange((lo - mark.count)..<lo)
            return (String(chars), (lo - mark.count)..<(hi - mark.count))
        }
        chars.insert(contentsOf: mark, at: hi)
        chars.insert(contentsOf: mark, at: lo)
        return (String(chars), (lo + mark.count)..<(hi + mark.count))
    }

    /// After Return at the end of a list line, starts the next item with the next mark
    /// ("- ", "2. ", "B. ", "- [ ] "). Return on an empty item ends the list instead.
    /// `old` and `new` are the notes before and after one keystroke, and `caret` is where the
    /// caret was before it (when known, since a Return beside a blank line is ambiguous
    /// otherwise). nil means leave it be.
    static func continueList(old: String, new: String, caret: Int? = nil) -> Result? {
        guard new.count == old.count + 1 else { return nil }
        let a = Array(old), b = Array(new)
        var i = 0
        if let caret, caret <= a.count, b[caret] == "\n",
           Array(b[..<caret]) == Array(a[..<caret]), Array(b[(caret + 1)...]) == Array(a[caret...]) {
            i = caret
        } else {
            while i < a.count, a[i] == b[i] { i += 1 }
        }
        guard b[i] == "\n", Array(b[(i + 1)...]) == Array(a[i...]) else { return nil }
        // The line the Return finished.
        var start = i
        while start > 0, b[start - 1] != "\n" { start -= 1 }
        let line = String(b[start..<i])
        let (indent, rest) = (String(line.prefix(while: { $0 == " " || $0 == "\t" })),
                              String(line.drop(while: { $0 == " " || $0 == "\t" })))
        guard let m = rest.prefixMatch(of: anyMark), !rest.hasPrefix("#") else { return nil }
        let markText = String(m.0)
        let itemText = rest.dropFirst(markText.count)
        if itemText.trimmingCharacters(in: .whitespaces).isEmpty {
            // An empty item: Return ends the list. Drop the mark and the new line.
            var out = b
            out.removeSubrange(start...i)
            return (String(out), start..<start)
        }
        let next = indent + nextMark(after: markText)
        var out = b
        out.insert(contentsOf: next, at: i + 1)
        let caret = i + 1 + next.count
        return (String(out), caret..<caret)
    }

    // MARK: Helpers

    private static func nextMark(after mark: String) -> String {
        let trimmed = mark.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("]") {
            return String(trimmed.prefix(1)) + " [ ] "
        }
        if let m = trimmed.wholeMatch(of: #/(\d{1,3})([.)])/#), let n = Int(m.1) {
            return "\(n + 1)\(m.2) "
        }
        if let m = trimmed.wholeMatch(of: #/([A-Za-z])([.)])/#),
           let scalar = m.1.unicodeScalars.first, m.1 != "z", m.1 != "Z",
           let next = Unicode.Scalar(scalar.value + 1) {
            return "\(Character(next))\(m.2) "
        }
        return mark.hasSuffix(" ") ? mark : mark + " "
    }

    private static func mark(for style: LineStyle, number: Int) -> String {
        switch style {
        case .bullet: return "- "
        case .numbered: return "\(number). "
        case .lettered: return "\(letter(number)). "
        case .checklist: return "- [ ] "
        case .heading: return "## "
        }
    }

    private static func letter(_ n: Int) -> String {
        let scalar = UnicodeScalar(UInt8(64 + min(max(n, 1), 26)))
        return String(Character(scalar))
    }

    private static func has(_ style: LineStyle, _ line: String) -> Bool {
        switch NotesMarkdown.block(for: line) {
        case .bullet: style == .bullet
        case .task: style == .checklist
        case .heading: style == .heading
        case .ordered(_, let marker, _): marker.first?.isNumber == true ? style == .numbered : style == .lettered
        default: false
        }
    }

    /// Where numbering picks up: the number (or letter) of the same kind of item just above.
    private static func startCount(for style: LineStyle, above first: Int, in lines: [String]) -> Int {
        guard first > 0, style == .numbered || style == .lettered,
              case .ordered(_, let marker, _) = NotesMarkdown.block(for: lines[first - 1]),
              has(style, lines[first - 1]) else { return 0 }
        let label = marker.dropLast()
        if let n = Int(label) { return n }
        guard let c = label.uppercased().unicodeScalars.first else { return 0 }
        return Int(c.value) - 64
    }

    /// The line's indent, and the line after its indent and any list or heading mark.
    private static func splitMark(_ line: String) -> (String, String) {
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let rest = String(line.dropFirst(indent.count))
        if let m = rest.prefixMatch(of: anyMark) {
            return (indent, String(rest.dropFirst(m.0.count)))
        }
        return (indent, rest)
    }

    private static func lineStart(_ lines: [String], _ index: Int) -> Int {
        lines[..<index].reduce(0) { $0 + $1.count + 1 }
    }

    /// The first and last lines a selection touches. A selection that ends right at the
    /// start of a line doesn't count that line.
    private static func lineSpan(_ lines: [String], _ selection: Range<Int>) -> (Int, Int) {
        func line(at offset: Int) -> Int {
            var start = 0
            for (i, l) in lines.enumerated() {
                if offset <= start + l.count { return i }
                start += l.count + 1
            }
            return lines.count - 1
        }
        let first = line(at: selection.lowerBound)
        var last = line(at: selection.upperBound)
        if last > first, selection.upperBound == lineStart(lines, last) { last -= 1 }
        return (first, max(first, last))
    }
}

extension NotesFormat {
    /// Flips `- [ ]` and `- [x]` on one line of the notes.
    static func toggleTask(line index: Int, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(index) else { return text }
        let line = lines[index]
        if let r = line.range(of: "[ ]") {
            lines[index] = line.replacingCharacters(in: r, with: "[x]")
        } else if let r = line.range(of: "[x]") ?? line.range(of: "[X]") {
            lines[index] = line.replacingCharacters(in: r, with: "[ ]")
        }
        return lines.joined(separator: "\n")
    }
}
