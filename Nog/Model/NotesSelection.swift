import Foundation

/// Keep selection as integer character offsets, not String.Index values belonging
/// to a previous version of the notes. UIKit ranges are validated before conversion.
nonisolated enum NotesSelection {
    static func clamped(_ selection: Range<Int>, in text: String) -> Range<Int> {
        let lo = min(max(0, selection.lowerBound), text.count)
        let hi = min(max(lo, selection.upperBound), text.count)
        return lo..<hi
    }

    static func characters(_ range: NSRange, in text: String) -> Range<Int>? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location,
              let indices = Range(range, in: text) else { return nil }
        let lo = text.distance(from: text.startIndex, to: indices.lowerBound)
        let hi = text.distance(from: text.startIndex, to: indices.upperBound)
        return lo..<hi
    }

    static func utf16(_ selection: Range<Int>, in text: String) -> NSRange {
        let range = clamped(selection, in: text)
        let lo = text.index(text.startIndex, offsetBy: range.lowerBound)
        let hi = text.index(text.startIndex, offsetBy: range.upperBound)
        return NSRange(lo..<hi, in: text)
    }
}
