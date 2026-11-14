import ActivityKit
import Foundation

/// The Live Activity shown while you're doing a nog (▶︎).
/// Compiled into both the app and the NogWidgets extension.
nonisolated struct DoingAttributes: ActivityAttributes {
    var itemID: UUID
    var title: String

    nonisolated struct ContentState: Codable, Hashable {
        /// When this session started.
        var startedAt: Date
        /// When the timebox ends; nil = open-ended (counts up).
        var endsAt: Date?
        /// Time already spent in earlier sessions, in seconds.
        var priorSeconds: TimeInterval
        /// Rings as an alarm when time's up.
        var isUrgent: Bool
        /// Optional for decoding live activities created by earlier app versions.
        var displayTitle: String? = nil
    }
}
