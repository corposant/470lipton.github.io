import SwiftUI
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
            ("blue", Theme.blue), ("panelLabel", Theme.panelLabel), ("lcd", Theme.lcd),
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
