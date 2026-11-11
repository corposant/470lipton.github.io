import XCTest
@testable import Nog

/// Recordings on a nog: how they're listed in the item's file, and their names.
final class VoiceNoteTests: XCTestCase {
    func testRoundTrip() throws {
        var item = Item(title: "Idea from the car")
        item.created = Date(timeIntervalSince1970: 1_800_000_000)
        item.updated = item.created
        item.voiceNotes = [VoiceNote(file: VoiceNote.newFileName(), seconds: 42),
                           VoiceNote(file: VoiceNote.newFileName(), seconds: 605)]
        let text = ItemFile.encode(item)
        XCTAssertTrue(text.contains("voice: [voice-"))
        XCTAssertEqual(try XCTUnwrap(ItemFile.decode(text)), item)
    }

    func testNoVoiceLineWithoutRecordings() {
        XCTAssertFalse(ItemFile.encode(Item(title: "Quiet")).contains("voice:"))
    }

    func testIgnoresNamesOutsideTheFolder() throws {
        let id = UUID().uuidString
        let text = "---\nid: \(id)\ntitle: x\nvoice: [../secret.m4a=3, voice-a/b.m4a=4, notes.txt=5, voice-ok.m4a=7, voice-nolength.m4a]\n---\n"
        let item = try XCTUnwrap(ItemFile.decode(text))
        XCTAssertEqual(item.voiceNotes, [VoiceNote(file: "voice-ok.m4a", seconds: 7),
                                         VoiceNote(file: "voice-nolength.m4a", seconds: 0)])
    }

    func testCaptureTitleSaysItsAVoiceNog() {
        XCTAssertTrue(VoiceNote.captureTitle(.now).hasPrefix("Voice nog "))
    }

    func testClock() {
        XCTAssertEqual(VoiceNote.clock(0), "0:00")
        XCTAssertEqual(VoiceNote.clock(42.4), "0:42")
        XCTAssertEqual(VoiceNote.clock(605), "10:05")
        XCTAssertEqual(VoiceNote.clock(-3), "0:00")
    }
}
