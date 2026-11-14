import XCTest
import SwiftUI
import UIKit
@testable import Nog

final class NotesSelectionTests: XCTestCase {
    func testEmptyAndClampedSelections() {
        XCTAssertEqual(NotesSelection.utf16(0..<0, in: ""), NSRange(location: 0, length: 0))
        XCTAssertEqual(NotesSelection.clamped(40..<80, in: "short"), 5..<5)
        XCTAssertEqual(NotesSelection.clamped(-3..<2, in: "short"), 0..<2)
    }

    func testStaleCharacterOffsetsClampBeforeUTF16Conversion() {
        // A selection saved before notes are shortened must never be converted
        // as a String.Index belonging to that previous text (attached crash).
        let previous = "Notes 👩🏽‍💻 with more text"
        let stale = previous.count..<previous.count
        for current in ["", "a", "😀", "e\u{301}"] {
            let converted = NotesSelection.utf16(stale, in: current)
            XCTAssertEqual(converted, NSRange(location: current.utf16.count, length: 0))
            XCTAssertEqual(NotesSelection.characters(converted, in: current), current.count..<current.count)
        }
    }

    func testUnicodeRoundTrips() {
        let text = "A👩🏽‍💻e\u{301}🇨🇦Z"
        for lower in 0...text.count {
            for upper in lower...text.count {
                let range = lower..<upper
                XCTAssertEqual(NotesSelection.characters(NotesSelection.utf16(range, in: text), in: text), range)
            }
        }
    }

    func testInvalidUTF16RangesAreRejected() {
        XCTAssertNil(NotesSelection.characters(NSRange(location: NSNotFound, length: 0), in: "a"))
        XCTAssertNil(NotesSelection.characters(NSRange(location: 2, length: 0), in: "a"))
        XCTAssertNil(NotesSelection.characters(NSRange(location: 0, length: Int.max), in: "a"))
        XCTAssertNil(NotesSelection.characters(NSRange(location: 1, length: 0), in: "😀"))
    }
}

@MainActor
final class NotesEditorRegressionTests: XCTestCase {
    func testFocusingEmptyNotesDoesNotNeedAStringIndex() {
        var text = ""
        var selection: Range<Int>?
        var focused = false
        let editor = NotesTextView(text: Binding(get: { text }, set: { text = $0 }),
                                   selection: Binding(get: { selection }, set: { selection = $0 }),
                                   isFocused: false, dimmed: false, focusChanged: { focused = $0 })
        let view = UITextView()
        view.text = ""
        view.selectedRange = NSRange(location: 0, length: 0)
        editor.makeCoordinator().textViewDidBeginEditing(view)
        XCTAssertTrue(focused)
        XCTAssertEqual(selection, 0..<0)
    }

    func testBeginningEditingReplacesStaleSelectionWithCurrentTextSelection() {
        var text = ""
        var selection: Range<Int>? = 80..<80
        var focused = false
        let editor = NotesTextView(text: Binding(get: { text }, set: { text = $0 }),
                                   selection: Binding(get: { selection }, set: { selection = $0 }),
                                   isFocused: false, dimmed: false, focusChanged: { focused = $0 })
        let view = UITextView()
        view.text = text
        view.selectedRange = NSRange(location: 0, length: 0)
        editor.makeCoordinator().textViewDidBeginEditing(view)
        XCTAssertTrue(focused)
        XCTAssertEqual(selection, 0..<0)
        XCTAssertEqual(text, "")
    }

    func testReturnContinuesListAndUpdatesSelectionTogether() {
        var text = "- one"
        var selection: Range<Int>? = 5..<5
        let editor = NotesTextView(text: Binding(get: { text }, set: { text = $0 }),
                                   selection: Binding(get: { selection }, set: { selection = $0 }),
                                   isFocused: true, dimmed: false, focusChanged: { _ in })
        let view = UITextView()
        view.text = text
        view.selectedRange = NSRange(location: 5, length: 0)
        let handledByUIKit = editor.makeCoordinator().textView(view, shouldChangeTextIn: view.selectedRange,
                                                              replacementText: "\n")
        XCTAssertFalse(handledByUIKit)
        XCTAssertEqual(text, "- one\n- ")
        XCTAssertEqual(view.text, text)
        XCTAssertEqual(selection, text.count..<text.count)
    }

    func testReturnOnEmptyBulletRemovesMarkerSafely() {
        var text = "- "
        var selection: Range<Int>? = 2..<2
        let editor = NotesTextView(text: Binding(get: { text }, set: { text = $0 }),
                                   selection: Binding(get: { selection }, set: { selection = $0 }),
                                   isFocused: true, dimmed: false, focusChanged: { _ in })
        let view = UITextView()
        view.text = text
        view.selectedRange = NSRange(location: 2, length: 0)
        XCTAssertFalse(editor.makeCoordinator().textView(view, shouldChangeTextIn: view.selectedRange,
                                                         replacementText: "\n"))
        XCTAssertEqual(text, "")
        XCTAssertEqual(selection, 0..<0)
    }
}
