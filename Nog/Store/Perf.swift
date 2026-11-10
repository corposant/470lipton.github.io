import os

/// Signposts for Instruments (Points of Interest): disk reloads, syncs and widget publishes
/// show up as intervals, so before/after timings can be compared on a real device.
enum Perf {
    static let signposter = OSSignposter(subsystem: "io.nogapp.nog", category: .pointsOfInterest)
}
