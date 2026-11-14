import AlarmKit
import Foundation

/// Small boundary so reconciliation can be tested without scheduling real alarms.
struct NogAlarmSnapshot {
    let id: UUID
    let state: Alarm.State
}

@MainActor
protocol NogAlarmManaging {
    var authorizationState: AlarmManager.AuthorizationState { get }
    func requestAuthorization() async throws -> AlarmManager.AuthorizationState
    func alarms() throws -> [NogAlarmSnapshot]
    func cancel(id: UUID) throws
    func schedule(id: UUID, configuration: AlarmManager.AlarmConfiguration<NogAlarmMetadata>) async throws
}

@MainActor
final class SystemNogAlarmManager: NogAlarmManaging {
    private let manager = AlarmManager.shared
    var authorizationState: AlarmManager.AuthorizationState { manager.authorizationState }
    func requestAuthorization() async throws -> AlarmManager.AuthorizationState {
        try await manager.requestAuthorization()
    }
    func alarms() throws -> [NogAlarmSnapshot] {
        try manager.alarms.map { NogAlarmSnapshot(id: $0.id, state: $0.state) }
    }
    func cancel(id: UUID) throws { try manager.cancel(id: id) }
    func schedule(id: UUID, configuration: AlarmManager.AlarmConfiguration<NogAlarmMetadata>) async throws {
        _ = try await manager.schedule(id: id, configuration: configuration)
    }
}

/// Device-local ownership journal; never iCloud-synced, because each device has
/// its own AlarmKit store. Dates let us inspect the planned times after relaunch.
nonisolated struct NogAlarmRecord: Codable {
    var itemID: UUID
    var date: Date
}
