import UIKit

/// Settings › Siri & Shortcuts › "Use while iPhone is locked".
///
/// Off (the default): while the iPhone is locked, Siri can't read your nogs aloud, list them,
/// or change or delete them, so someone holding your phone can't either. Adding, starting,
/// finishing and silencing nogs keep working hands-free (and the buttons on notifications and
/// the Live Activity always work).
///
/// This is checked when the intent runs rather than through `authenticationPolicy`, which is a
/// fixed per-intent value and couldn't follow a setting.
@MainActor
enum LockedSiri {
    static let key = "siriWhenLocked"

    static var allowed: Bool { UserDefaults.standard.bool(forKey: key) }

    /// True once the iPhone is locked (a few seconds after locking, when iOS drops the keys
    /// for protected files). Never true on a phone with no passcode, where there's nothing to protect.
    static var isLocked: Bool { !UIApplication.shared.isProtectedDataAvailable }

    /// Whether to hold back nog titles and changes right now.
    static var blocks: Bool { !allowed && isLocked }

    static func check() throws {
        if blocks { throw NogIntentError.locked }
    }
}
