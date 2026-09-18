import XCTest
@testable import Phoros

final class FramingTests: XCTestCase {
    // MARK: Packet header

    func testHeaderBytesArePinned() {
        let header = PacketHeader(type: .videoKeyframe, flags: 0x01, payloadLength: 258)
        XCTAssertEqual(
            header.serialized(),
            Data([0x42, 0x45, 0x41, 0x4D, 0x06, 0x01, 0x00, 0x00, 0x01, 0x02])
        )
    }

    func testPacketTypeRawValuesArePinned() {
        let pinned: [PacketType: UInt8] = [
            .video: 0x01, .audio: 0x02, .control: 0x03, .heartbeat: 0x04,
            .parameterSets: 0x05, .videoKeyframe: 0x06, .input: 0x07,
        ]
        XCTAssertEqual(Set(PacketType.allCases), Set(pinned.keys))
        for (type, raw) in pinned { XCTAssertEqual(type.rawValue, raw, "\(type)") }
    }

    func testHeaderRoundTrips() {
        let original = PacketHeader(type: .audio, flags: 0x0F, payloadLength: UInt32.max)
        XCTAssertEqual(PacketHeader.parse(from: original.serialized()), original)
    }

    func testHeaderParsesFromASlice() {
        var stream = Data([0xAA, 0xBB, 0xCC])
        stream.append(PacketHeader(type: .control, payloadLength: 7).serialized())
        stream.append(Data(repeating: 0, count: 7))
        let slice = stream[3...]
        XCTAssertEqual(slice.startIndex, 3)
        XCTAssertEqual(PacketHeader.parse(from: slice)?.type, .control)
        XCTAssertEqual(PacketHeader.parse(from: slice)?.payloadLength, 7)
    }

    func testHeaderRejectsBadMagicShortDataAndUnknownType() {
        XCTAssertNil(PacketHeader.parse(from: Data("{\"type\":\"ping\"}".utf8)))
        XCTAssertNil(PacketHeader.parse(from: Data([0x42, 0x45, 0x41, 0x4D, 0x01])))
        var unknownType = PacketHeader(type: .video, payloadLength: 0).serialized()
        unknownType[4] = 0x7F
        XCTAssertNil(PacketHeader.parse(from: unknownType))
    }

    func testPacketEncodeTakesLengthFromPayload() {
        let payload = Data([1, 2, 3])
        let packet = Packet.encode(.heartbeat, payload: payload)
        XCTAssertEqual(packet.count, PacketHeader.size + 3)
        XCTAssertEqual(PacketHeader.parse(from: packet)?.payloadLength, 3)
        XCTAssertEqual(packet.suffix(3), payload)

        let stale = PacketHeader(type: .video, payloadLength: 999)
        XCTAssertEqual(PacketHeader.parse(from: stale.packet(with: payload))?.payloadLength, 3)
    }

    // MARK: Length prefix

    func testLengthPrefixBytesArePinned() {
        XCTAssertEqual(Data([9, 8]).lengthPrefixed(), Data([0, 0, 0, 2, 9, 8]))
        XCTAssertEqual(LengthPrefix.length(in: Data([0, 1, 0, 0, 0xFF])), 65_536)
        XCTAssertNil(LengthPrefix.length(in: Data([0, 1, 0])))
    }

    // MARK: Frame decoder

    func testDecoderReassemblesFramesFromArbitraryChunks() throws {
        let json = Data(#"{"type":"ping"}"#.utf8)
        let packet = Packet.encode(.audio, flags: 1, payload: Data([7, 7, 7]))
        let stream = json.lengthPrefixed() + packet.lengthPrefixed() + json.lengthPrefixed()

        for chunkSize in [1, 3, 5, 16, stream.count] {
            var decoder = FrameDecoder()
            var frames: [Frame] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                decoder.append(stream[offset..<end])
                while let frame = try decoder.next() { frames.append(frame) }
                offset = end
            }
            XCTAssertEqual(frames, [
                .message(json),
                .packet(DecodedPacket(header: PacketHeader(type: .audio, flags: 1, payloadLength: 3), payload: Data([7, 7, 7]))),
                .message(json),
            ], "chunk size \(chunkSize)")
            XCTAssertEqual(decoder.bufferedByteCount, 0)
        }
    }

    func testDecoderRejectsOversizedFrameBeforeBuffering() {
        var decoder = FrameDecoder(maximumFrameLength: 16)
        decoder.append(Data([0x00, 0x10, 0x00, 0x00]))  // announces 1 MiB
        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? FrameDecoderError, .frameTooLarge(announced: 1 << 20, limit: 16))
        }
    }

    func testDecoderRejectsPacketWhoseLengthDisagreesWithFrame() {
        var lying = PacketHeader(type: .video, payloadLength: 100).serialized()
        lying.append(Data([1, 2]))
        XCTAssertThrowsError(try FrameDecoder.classify(lying)) { error in
            XCTAssertEqual(error as? FrameDecoderError, .malformedPacket)
        }
    }

    func testClassifyTreatsAnythingWithoutMagicAsMessage() throws {
        XCTAssertEqual(try FrameDecoder.classify(Data()), .message(Data()))
        XCTAssertEqual(try FrameDecoder.classify(Data("BEA".utf8)), .message(Data("BEA".utf8)))
    }
}
