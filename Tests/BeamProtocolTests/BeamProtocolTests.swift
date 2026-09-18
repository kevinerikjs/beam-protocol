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

    func testNewPairingFieldsDoNotBreakAnOlderMessage() throws {
        let data = Data("""
        {
          "type": "auth_success",
          "deviceName": "Mac",
          "deviceID": null,
          "code": null,
          "sharedSecret": null,
          "error": null
        }
        """.utf8)

        let message = try JSONDecoder().decode(BeamPairingMessage.self, from: data)

        XCTAssertEqual(message.type, .authSuccess)
        XCTAssertNil(message.supportedAudioCodecs)
        XCTAssertNil(message.supportsWindowSelection)
    }

    func testNewPairingMessageKeepsOptionalFieldsOnTheWire() throws {
        let original = BeamPairingMessage(
            type: .authRequest,
            deviceName: "iPhone",
            deviceID: "device-id",
            code: nil,
            sharedSecret: "secret",
            error: nil,
            supportedAudioCodecs: ["aac_lc", "pcm_f32le"],
            supportedVideoCodecs: ["hevc", "h264"],
            wantsAudio: false
        )

        let decoded = try JSONDecoder().decode(
            BeamPairingMessage.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.supportedAudioCodecs, ["aac_lc", "pcm_f32le"])
        XCTAssertEqual(decoded.supportedVideoCodecs, ["hevc", "h264"])
        XCTAssertEqual(decoded.wantsAudio, false)
    }
}
