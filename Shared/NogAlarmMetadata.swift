import AlarmKit
import Foundation

/// Shared by the app and widget so AlarmKit can decode the same metadata type.
/// Explicit isolation is required when a target defaults to MainActor.
nonisolated struct NogAlarmMetadata: AlarmMetadata {
    var itemID: UUID
}
