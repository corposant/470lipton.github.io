import XCTest
@testable import Nog

final class NotesMarkdownTests: XCTestCase {
    func testBlocks() {
        let notes = """
        # Plan
        - teach it through experience
          - nested
        A. Acknowledge symptom is here
        2) second
        - [ ] buy milk
        - [x] call mom


        > breathe
        ---
        just words
        """
        let blocks = NotesMarkdown.blocks(notes).map(\.block)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Plan"),
            .bullet(indent: 0, text: "teach it through experience"),
            .bullet(indent: 1, text: "nested"),
            .ordered(indent: 0, marker: "A.", text: "Acknowledge symptom is here"),
            .ordered(indent: 0, marker: "2)", text: "second"),
            .task(indent: 0, done: false, text: "buy milk"),
            .task(indent: 0, done: true, text: "call mom"),
            .blank,
            .quote(text: "breathe"),
            .rule,
            .paragraph(text: "just words"),
        ])
    }

    func testCodeFenceIsVerbatim() {
        let blocks = NotesMarkdown.blocks("```\n- not a list\n```").map(\.block)
        XCTAssertEqual(blocks, [.code(text: "- not a list")])
    }

    func testLineIndexesSurviveBlanks() {
        let lines = NotesMarkdown.blocks("a\n\n\n- [ ] b")
        XCTAssertEqual(lines.last?.index, 3)
        XCTAssertEqual(NotesFormat.toggleTask(line: 3, in: "a\n\n\n- [ ] b"), "a\n\n\n- [x] b")
    }

    func testTitleLinks() {
        let text = NotesMarkdown.inline("See [[Call mom (later)]] now")
        XCTAssertEqual(String(text.characters), "See Call mom (later) now")
        let link = text.runs.compactMap(\.link).first
        XCTAssertEqual(link.flatMap(NotesMarkdown.title(from:)), "Call mom (later)")
    }

    func testBoldIsRead() {
        XCTAssertEqual(NotesMarkdown.plain("**Fight!** I am _with_ you"), "Fight! I am with you")
    }

    func testToggleBulletOnCaretLine() {
        let r = NotesFormat.toggle(.bullet, in: "one\ntwo", selection: 7..<7)
        XCTAssertEqual(r.text, "one\n- two")
        XCTAssertEqual(r.selection, 9..<9)
        let back = NotesFormat.toggle(.bullet, in: r.text, selection: r.selection)
        XCTAssertEqual(back.text, "one\ntwo")
    }

    func testLetteredCountsOnFromAbove() {
        let r = NotesFormat.toggle(.lettered, in: "A. first\nsecond\nthird", selection: 9..<21)
        XCTAssertEqual(r.text, "A. first\nB. second\nC. third")
    }

    func testBulletsBecomeNumbers() {
        let r = NotesFormat.toggle(.numbered, in: "- a\n- b", selection: 0..<7)
        XCTAssertEqual(r.text, "1. a\n2. b")
    }

    func testWrapAndUnwrap() {
        let r = NotesFormat.wrap(.bold, in: "I am with you", selection: 5..<9)
        XCTAssertEqual(r.text, "I am **with** you")
        XCTAssertEqual(r.selection, 7..<11)
        XCTAssertEqual(NotesFormat.wrap(.bold, in: r.text, selection: r.selection).text, "I am with you")
        XCTAssertEqual(NotesFormat.wrap(.italic, in: "ab", selection: 2..<2).text, "ab__")
    }

    func testIndent() {
        XCTAssertEqual(NotesFormat.indent(false, in: "- a", selection: 3..<3).text, "  - a")
        XCTAssertEqual(NotesFormat.indent(true, in: "  - a", selection: 5..<5).text, "- a")
    }

    func testReturnContinuesLists() {
        XCTAssertEqual(NotesFormat.continueList(old: "- a", new: "- a\n")?.text, "- a\n- ")
        XCTAssertEqual(NotesFormat.continueList(old: "A. a", new: "A. a\n")?.text, "A. a\nB. ")
        XCTAssertEqual(NotesFormat.continueList(old: "9) a", new: "9) a\n")?.text, "9) a\n10) ")
        XCTAssertEqual(NotesFormat.continueList(old: "  - [x] a", new: "  - [x] a\n")?.text, "  - [x] a\n  - [ ] ")
        XCTAssertNil(NotesFormat.continueList(old: "plain", new: "plain\n"))
        XCTAssertNil(NotesFormat.continueList(old: "# Head", new: "# Head\n"))
    }

    func testReturnOnEmptyItemEndsList() {
        let r = NotesFormat.continueList(old: "- a\n- ", new: "- a\n- \n")
        XCTAssertEqual(r?.text, "- a\n")
        XCTAssertEqual(r?.selection, 4..<4)
    }

    func testReturnInTheMiddleUsesTheCaret() {
        // Return at the end of "- a", with a blank line and more below.
        let r = NotesFormat.continueList(old: "- a\n\nb", new: "- a\n\n\nb", caret: 3)
        XCTAssertEqual(r?.text, "- a\n- \n\nb")
    }
}
