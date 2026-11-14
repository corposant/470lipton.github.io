import os

/// Nog's log. Anything interpolated into a message (titles, file names, errors) is private
/// by default, so it shows as <private> in logs taken off the device, as Apple recommends
/// for personal data. Only the fixed text is readable there.
enum Log {
    static let nog = Logger(subsystem: "io.nogapp.nog", category: "app")
}
