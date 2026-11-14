import XCTest
@testable import Nog

/// The Live Activity shows on the Lock Screen, Apple Watch and CarPlay, so it must follow
/// "Show titles on Lock Screen" like notifications and widgets do.
@MainActor
final class LockScreenPrivacyTests: XCTestCase {
    private let key = NogSettings.Key.showTitles
    private var saved: Any?

    override func setUp() async throws {
        saved = UserDefaults.standard.object(forKey: key)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(saved, forKey: key)
    }

    func testLiveActivityTitleFollowsTheSetting() {
        var item = Item(title: "Call the clinic about results")
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertEqual(DoingActivities.title(for: item), "Call the clinic about results")
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertEqual(DoingActivities.title(for: item), DoingActivities.hiddenTitle)
        item.title = "Something else"
        XCTAssertEqual(DoingActivities.title(for: item), DoingActivities.hiddenTitle)
    }

    func testSiriWhenLockedIsOffByDefault() {
        let saved = UserDefaults.standard.object(forKey: LockedSiri.key)
        defer { UserDefaults.standard.set(saved, forKey: LockedSiri.key) }
        UserDefaults.standard.removeObject(forKey: LockedSiri.key)
        XCTAssertFalse(LockedSiri.allowed)
    }
}
