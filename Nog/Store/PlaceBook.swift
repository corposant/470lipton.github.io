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
        return decodeCache.places(for: data)
    }

    /// Every list row and every keystroke in New Nog reads the places; decode once per change.
    private nonisolated static let decodeCache = PlaceDecodeCache()

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
        guard place.latitude.isFinite, place.longitude.isFinite, place.radius.isFinite,
              (-90...90).contains(place.latitude), (-180...180).contains(place.longitude),
              (100...100_000).contains(place.radius) else { return }
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

/// The last decoded copy of the saved places, reused until the stored data changes.
private final class PlaceDecodeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var last: (data: Data, places: [SavedPlace])?

    func places(for data: Data) -> [SavedPlace] {
        lock.lock()
        defer { lock.unlock() }
        if let last, last.data == data { return last.places }
        let places = (try? JSONDecoder().decode([SavedPlace].self, from: data)) ?? []
        last = (data, places)
        return places
    }
}

/// Asks for location (While Using only: iOS itself watches for arrivals, Nog never tracks you)
/// and reads where you are once, for "Save where I am now".
@MainActor
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAccess()

    private let manager = CLLocationManager()
    private var authWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var locationWaiters: [UUID: CheckedContinuation<CLLocation?, Never>] = [:]
    private var authTimeout: Task<Void, Never>?
    private var locationTimeout: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }
    var isAllowed: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }

    /// Concurrent callers share one system request and each completes exactly once.
    func requestAccess() async -> Bool {
        if isAllowed { return true }
        guard status == .notDetermined, !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                guard !Task.isCancelled else { c.resume(returning: false); return }
                let first = authWaiters.isEmpty
                authWaiters[id] = c
                if first {
                    authTimeout?.cancel()
                    manager.requestWhenInUseAuthorization()
                    authTimeout = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(60))
                        guard !Task.isCancelled else { return }
                        self?.finishAuthorization(false)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.authWaiters.removeValue(forKey: id)?.resume(returning: false) }
        }
    }

    func currentLocation() async -> CLLocation? {
        guard await requestAccess(), !Task.isCancelled else { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                guard !Task.isCancelled else { c.resume(returning: nil); return }
                let first = locationWaiters.isEmpty
                locationWaiters[id] = c
                if first {
                    locationTimeout?.cancel()
                    manager.requestLocation()
                    locationTimeout = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(30))
                        guard !Task.isCancelled else { return }
                        self?.finishLocation(nil)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.locationWaiters.removeValue(forKey: id)?.resume(returning: nil) }
        }
    }

    private func finishAuthorization(_ allowed: Bool) {
        authTimeout?.cancel()
        authTimeout = nil
        let waiters = authWaiters
        authWaiters = [:]
        for c in waiters.values { c.resume(returning: allowed) }
    }

    private func finishLocation(_ location: CLLocation?) {
        locationTimeout?.cancel()
        locationTimeout = nil
        let waiters = locationWaiters
        locationWaiters = [:]
        for c in waiters.values { c.resume(returning: location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard status != .notDetermined else { return }
            self?.finishAuthorization(status == .authorizedWhenInUse || status == .authorizedAlways)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor [weak self] in self?.finishLocation(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.finishLocation(nil) }
    }
}
