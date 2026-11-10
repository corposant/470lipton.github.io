import CoreLocation
import Foundation
import Observation

/// Your saved places (Settings › Places): Home, Work, the gym…
///
/// Kept in UserDefaults so capture parsing can read the names from anywhere, and copied
/// to `_places.json` next to your items so they're backed up with them (and restored
/// from there on a new phone).
@MainActor @Observable
final class PlaceBook {
    static let shared = PlaceBook()

    nonisolated static let defaultsKey = "savedPlaces"
    nonisolated static let sidecarName = "_places.json"
    /// iOS watches at most 20 regions per app; leave room.
    nonisolated static let maxWatched = 15

    private(set) var places: [SavedPlace] = PlaceBook.stored

    nonisolated static var stored: [SavedPlace] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([SavedPlace].self, from: data)) ?? []
    }

    /// Names only, for the capture parser.
    nonisolated static var savedNames: [String] { stored.map(\.name) }

    /// A saved place by name, any casing.
    nonisolated static func place(named name: String) -> SavedPlace? {
        stored.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A new phone (or a reinstall) picks the places back up from iCloud.
    func restoreIfEmpty(from store: ItemStore) {
        guard places.isEmpty, let data = store.readSidecar(Self.sidecarName),
              let saved = try? JSONDecoder().decode([SavedPlace].self, from: data), !saved.isEmpty else { return }
        places = saved
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    func save(_ place: SavedPlace) {
        if let i = places.firstIndex(where: { $0.id == place.id }) {
            places[i] = place
        } else {
            places.removeAll { $0.name.caseInsensitiveCompare(place.name) == .orderedSame }
            places.append(place)
        }
        persist()
    }

    func delete(_ id: UUID) {
        places.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(places) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        ItemStore.shared.writeSidecar(Self.sidecarName, data: data)
        ItemStore.shared.scheduleSync()
    }
}

/// Asks for location (While Using only: iOS itself watches for arrivals, Nog never tracks you)
/// and reads where you are once, for "Save where I am now".
@MainActor
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAccess()

    private let manager = CLLocationManager()
    private var authContinuation: CheckedContinuation<Bool, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }
    var isAllowed: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }

    /// Asks once; true when allowed.
    func requestAccess() async -> Bool {
        if isAllowed { return true }
        guard status == .notDetermined else { return false }
        return await withCheckedContinuation { continuation in
            authContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Where you are right now, or nil if it isn't allowed or can't be found.
    func currentLocation() async -> CLLocation? {
        guard await requestAccess() else { return nil }
        return await withCheckedContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined, let c = self.authContinuation else { return }
            self.authContinuation = nil
            c.resume(returning: status == .authorizedWhenInUse || status == .authorizedAlways)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in
            self.locationContinuation?.resume(returning: last)
            self.locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.locationContinuation?.resume(returning: nil)
            self.locationContinuation = nil
        }
    }
}
