import XCTest
import BeamProtocol

final class BeamProtocolTests: XCTestCase {
    func testPacketHeaderUsesThePublishedWireLayout() {
        let header = BeamPacketHeader(type: .videoIDR, flags: 1, payloadLength: 258)

        XCTAssertEqual(
            header.serialized(),
            Data([0x42, 0x45, 0x41, 0x4D, 0x06, 0x01, 0x00, 0x00, 0x01, 0x02])
        )
    }

    func testPacketHeaderRoundTrips() {
        let original = BeamPacketHeader(type: .audio, flags: 1, payloadLength: 65_535)

        XCTAssertEqual(BeamPacketHeader.parse(from: original.serialized())?.type, .audio)
        XCTAssertEqual(BeamPacketHeader.parse(from: original.serialized())?.payloadLength, 65_535)
        XCTAssertEqual(BeamPacketHeader.parse(from: original.serialized())?.flags, 1)
    }

    func testUnknownCodecIDsAreNotMisreadAsPCM() {
        XCTAssertNil(BeamAudioCodec(packetFlags: 0x0F))
        XCTAssertEqual(BeamVideoCodec(packetFlags: 0x0F), .h264)
    }
}
