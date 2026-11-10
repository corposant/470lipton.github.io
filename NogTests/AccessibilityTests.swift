import SwiftUI
import UIKit
import XCTest
@testable import Nog

/// Text colours must stay readable: WCAG AA asks for 4.5:1 for normal-size text.
final class ContrastTests: XCTestCase {
    private func luminance(_ color: Color, _ scheme: ColorScheme) -> Double {
        var env = EnvironmentValues()
        env.colorScheme = scheme
        let c = color.resolve(in: env) // linear sRGB components
        return 0.2126 * Double(c.red) + 0.7152 * Double(c.green) + 0.0722 * Double(c.blue)
    }

    private func ratio(_ a: Color, _ b: Color, _ scheme: ColorScheme) -> Double {
        let (x, y) = (luminance(a, scheme), luminance(b, scheme))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testTextColoursOnTheBase() {
        let text: [(String, Color)] = [
            ("muted", Theme.muted), ("pink", Theme.pink), ("violet", Theme.violet),
            ("blue", Theme.blue), ("teal", Theme.teal), ("panelLabel", Theme.panelLabel), ("lcd", Theme.lcd),
            ("done", StatusDial.tint(.done)), ("alarm", NogKind.alarm.tint),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for background in [Theme.base, Theme.baseTop] {
                for (name, color) in text {
                    let r = ratio(color, background, scheme)
                    XCTAssertGreaterThanOrEqual(r, 4.5, "\(name) in \(scheme) mode is \(r):1")
                }
            }
        }
    }

    func testTagColoursOnTheBase() {
        for pair in TagPalette.colors {
            let tint = Color(light: pair.light, dark: pair.dark)
            for scheme in [ColorScheme.light, .dark] {
                let r = ratio(tint, Theme.base, scheme)
                XCTAssertGreaterThanOrEqual(r, 4.5, "tag \(String(pair.light, radix: 16)) in \(scheme) mode is \(r):1")
            }
        }
    }
}

/// Each tab's title matches its tab bar label, in title case, and each tab has its own colour.
final class TabThemeTests: XCTestCase {
    private let tabs: [AppTab] = [.capture, .agenda, .nogs, .map]

    func testTitles() {
        XCTAssertEqual(tabs.map(\.title), ["New Nog", "Agenda", "List", "Map"])
        for tab in tabs {
            XCTAssertNotEqual(tab.title, tab.title.uppercased(), "\(tab.title) shouldn't be all caps")
        }
    }

    func testAccentsDiffer() {
        var env = EnvironmentValues()
        for scheme in [ColorScheme.light, .dark] {
            env.colorScheme = scheme
            let resolved = tabs.map { tab -> [Float] in
                let c = tab.accent.resolve(in: env)
                return [c.red, c.green, c.blue]
            }
            XCTAssertEqual(Set(resolved.map { $0.map { Int($0 * 255) } }).count, tabs.count)
        }
    }

    func testTitleFontsScaleWithTextSize() {
        let normal = UITraitCollection(preferredContentSizeCategory: .large)
        let big = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge)
        XCTAssertGreaterThan(NogTitleFont.large(big).pointSize, NogTitleFont.large(normal).pointSize)
        XCTAssertGreaterThan(NogTitleFont.inline(big).pointSize, NogTitleFont.inline(normal).pointSize)
        XCTAssertLessThanOrEqual(NogTitleFont.large(big).pointSize, 52)
    }
}

final class TextSizeTests: XCTestCase {
    func testDefaultSizeIsUnchanged() {
        XCTAssertEqual(NogScale.value(13, for: .large, maxScale: 3), 13, accuracy: 0.5)
        XCTAssertEqual(NogScale.value(44, for: .large, maxScale: 1.6), 44, accuracy: 0.5)
    }

    func testGrowsWithTextSize() {
        XCTAssertGreaterThan(NogScale.value(13, for: .xxxLarge, maxScale: 3), 13)
        XCTAssertGreaterThan(NogScale.value(13, for: .accessibility3, maxScale: 3),
                             NogScale.value(13, for: .xxxLarge, maxScale: 3))
    }

    func testBigReadoutsAreCapped() {
        XCTAssertLessThanOrEqual(NogScale.value(44, for: .accessibility5, maxScale: 1.6), 44 * 1.6 + 0.01)
    }

    func testNearestTextStyle() {
        XCTAssertEqual(Font.TextStyle.nearest(to: 11), .caption2)
        XCTAssertEqual(Font.TextStyle.nearest(to: 13), .footnote)
        XCTAssertEqual(Font.TextStyle.nearest(to: 17), .body)
        XCTAssertEqual(Font.TextStyle.nearest(to: 28), .title)
        XCTAssertEqual(Font.TextStyle.nearest(to: 44), .largeTitle)
    }
}

final class CalmTests: XCTestCase {
    private let defaults = UserDefaults.standard

    override func tearDown() {
        defaults.removeObject(forKey: Calm.lowStimulationKey)
        defaults.removeObject(forKey: Calm.hapticsKey)
    }

    func testHapticsOnByDefault() {
        defaults.removeObject(forKey: Calm.lowStimulationKey)
        defaults.removeObject(forKey: Calm.hapticsKey)
        XCTAssertTrue(Calm.hapticsOn)
        XCTAssertFalse(Calm.lowStimulation)
    }

    func testHapticsSwitchTurnsThemOff() {
        defaults.set(false, forKey: Calm.hapticsKey)
        XCTAssertFalse(Calm.hapticsOn)
    }

    func testLowStimulationSilencesHapticsAndMotion() {
        defaults.set(true, forKey: Calm.hapticsKey)
        defaults.set(true, forKey: Calm.lowStimulationKey)
        XCTAssertFalse(Calm.hapticsOn)
        MainActor.assumeIsolated {
            XCTAssertTrue(Calm.reducesMotion)
            XCTAssertNil(Calm.animation(.snappy))
        }
    }
}
