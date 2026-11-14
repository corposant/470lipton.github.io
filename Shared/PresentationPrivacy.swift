import Foundation

/// One title policy for notifications, alarms and live presentations.
nonisolated enum PresentationPrivacy {
    static func title(_ title: String, visible: Bool) -> String {
        visible ? title : "Nog"
    }
}
