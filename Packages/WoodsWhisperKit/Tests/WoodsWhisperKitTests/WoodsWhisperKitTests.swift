import XCTest
@testable import WoodsWhisperKit

final class WoodsWhisperKitTests: XCTestCase {

    func testPresetRendersWithToken() {
        let preset = PromptPreset(name: "X", template: "Do it:\n\n\(PromptPreset.transcriptToken)")
        XCTAssertEqual(preset.render(with: "hello"), "Do it:\n\nhello")
    }

    func testPresetAppendsWhenTokenAbsent() {
        let preset = PromptPreset(name: "X", template: "Do it.")
        XCTAssertEqual(preset.render(with: "hello"), "Do it.\n\nhello")
    }

    func testBuiltInPresetsArePresent() {
        XCTAssertFalse(PromptPreset.builtIns.isEmpty)
        XCTAssertTrue(PromptPreset.builtIns.allSatisfy { $0.isBuiltIn })
    }

    func testRecordingDefaultNameNotEmpty() {
        let r = Recording(audioFileName: "x.m4a", origin: .watch)
        XCTAssertFalse(r.name.isEmpty)
        XCTAssertEqual(r.sampleRate, 16_000)
    }

    func testRecordingTransferRoundTrips() throws {
        let rec = Recording(audioFileName: "x.m4a", origin: .pad)
        let transfer = RecordingTransfer(recording: rec, byteCount: 123, pairingSecret: "s")
        let data = try JSONEncoder.iso.encode(transfer)
        let decoded = try JSONDecoder.iso.decode(RecordingTransfer.self, from: data)
        XCTAssertEqual(decoded.recording.id, rec.id)
        XCTAssertEqual(decoded.byteCount, 123)
        XCTAssertEqual(decoded.pairingSecret, "s")
    }

    func testGemmaDefaultIs4B() {
        XCTAssertEqual(GemmaModel.default, .gemma3_4B)
    }
}
