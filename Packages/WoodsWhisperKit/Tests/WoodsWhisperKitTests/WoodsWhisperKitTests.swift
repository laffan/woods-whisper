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

    // MARK: Pairing / subnet math

    func testIPv4RoundTrips() {
        XCTAssertEqual(NetworkInterface.ipv4ToUInt32("192.168.1.1"), 0xC0A8_0101)
        XCTAssertEqual(NetworkInterface.ipv4ToUInt32("0.0.0.0"), 0)
        XCTAssertEqual(NetworkInterface.ipv4ToUInt32("255.255.255.255"), 0xFFFF_FFFF)
        XCTAssertNil(NetworkInterface.ipv4ToUInt32("nope"))
        XCTAssertNil(NetworkInterface.ipv4ToUInt32("1.2.3"))
        XCTAssertEqual(NetworkInterface.uint32ToIPv4(0xC0A8_0101), "192.168.1.1")
    }

    func testHostsInSubnetForSlash24() {
        let hosts = NetworkInterface.hostsInSubnet(ip: "192.168.1.50", mask: "255.255.255.0")
        XCTAssertEqual(hosts.count, 254)                 // .1 … .254, excludes network + broadcast
        XCTAssertEqual(hosts.first, "192.168.1.1")
        XCTAssertEqual(hosts.last, "192.168.1.254")
        XCTAssertFalse(hosts.contains("192.168.1.0"))    // network address
        XCTAssertFalse(hosts.contains("192.168.1.255"))  // broadcast address
    }

    func testHostsInSubnetForHotspotSlash28() {
        // iOS Personal Hotspot uses 172.20.10.0/28 with the host at .1.
        let hosts = NetworkInterface.hostsInSubnet(ip: "172.20.10.2", mask: "255.255.255.240")
        XCTAssertEqual(hosts.count, 14)
        XCTAssertEqual(hosts.first, "172.20.10.1")
        XCTAssertEqual(hosts.last, "172.20.10.14")
    }

    func testHostsInSubnetIsCapped() {
        // A /16 would be 65k hosts; the cap keeps the scan bounded.
        let hosts = NetworkInterface.hostsInSubnet(ip: "10.0.0.5", mask: "255.255.0.0", cap: 256)
        XCTAssertEqual(hosts.count, 256)
    }
}
