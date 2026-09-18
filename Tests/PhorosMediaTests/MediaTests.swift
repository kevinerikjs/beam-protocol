import AVFoundation
import CoreMedia
import XCTest
import Phoros
import PhorosMedia

final class AnnexBTests: XCTestCase {
    let start = AnnexB.startCode

    func testSplitsAndJoins() {
        let units = [Data([0x67, 1, 2]), Data([0x68, 3]), Data([0x65, 4, 5, 6])]
        let annexB = AnnexB.join(units)
        XCTAssertEqual(annexB, start + units[0] + start + units[1] + start + units[2])
        XCTAssertEqual(AnnexB.nalUnits(in: annexB), units)
    }

    func testConvertsBothWays() {
        let units = [Data([0x67, 1, 2]), Data([0x65, 4, 5, 6])]
        let annexB = AnnexB.join(units)
        let avcc = AnnexB.toLengthPrefixed(annexB)
        XCTAssertEqual(avcc, Data([0, 0, 0, 3]) + units[0] + Data([0, 0, 0, 4]) + units[1])
        XCTAssertEqual(AnnexB.fromLengthPrefixed(avcc), annexB)
    }

    func testIgnoresGarbageBeforeTheFirstStartCodeAndEmptyUnits() {
        let annexB = Data([9, 9]) + start + Data([1]) + start + start + Data([2])
        XCTAssertEqual(AnnexB.nalUnits(in: annexB), [Data([1]), Data([2])])
        XCTAssertEqual(AnnexB.nalUnits(in: Data()), [])
        XCTAssertEqual(AnnexB.toLengthPrefixed(Data([1, 2, 3])), Data())
    }

    func testTruncatedLengthPrefixStopsCleanly() {
        XCTAssertEqual(AnnexB.fromLengthPrefixed(Data([0, 0, 0, 9, 1, 2])), Data())
        XCTAssertEqual(AnnexB.fromLengthPrefixed(Data([0, 0, 0, 1, 7, 0, 0, 0, 9, 1])), start + Data([7]))
    }

    func testWorksOnSlices() {
        let annexB = Data([0xFF]) + AnnexB.join([Data([1, 2])])
        XCTAssertEqual(AnnexB.nalUnits(in: annexB[1...]), [Data([1, 2])])
    }
}

final class VideoFormatTests: XCTestCase {
    // A real 640x360 H.264 High profile SPS and PPS.
    let sps = Data([0x67, 0x64, 0x00, 0x1E, 0xAC, 0xD9, 0x40, 0xA0, 0x2F, 0xF9, 0x70, 0x11, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00, 0x03, 0x00, 0x3C, 0x0F, 0x16, 0x2D, 0x96])
    let pps = Data([0x68, 0xEB, 0xE3, 0xCB, 0x22, 0xC0])

    func testBuildsAnH264DescriptionFromWireParameterSets() throws {
        let description = try XCTUnwrap(VideoFormat.makeDescription(parameterSets: AnnexB.join([sps, pps]), codec: .h264))
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        XCTAssertEqual(dimensions.width, 640)
        XCTAssertEqual(dimensions.height, 360)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_H264)
    }

    func testParameterSetsRoundTripThroughADescription() throws {
        let wire = AnnexB.join([sps, pps])
        let description = try XCTUnwrap(VideoFormat.makeDescription(parameterSets: wire, codec: .h264))
        XCTAssertEqual(VideoFormat.parameterSets(from: description, codec: .h264), wire)
    }

    func testRejectsTooFewParameterSets() {
        XCTAssertNil(VideoFormat.makeDescription(parameterSets: AnnexB.join([sps]), codec: .h264))
        XCTAssertNil(VideoFormat.makeDescription(parameterSets: AnnexB.join([sps, pps]), codec: .hevc))
        XCTAssertNil(VideoFormat.makeDescription(parameterSets: Data(), codec: .h264))
    }

    func testBuildsASampleBuffer() throws {
        let description = try XCTUnwrap(VideoFormat.makeDescription(parameterSets: AnnexB.join([sps, pps]), codec: .h264))
        let frame = AnnexB.join([Data([0x65, 0x88, 0x84, 0x00])])
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let buffer = try XCTUnwrap(VideoFormat.makeSampleBuffer(annexB: frame, formatDescription: description, presentationTime: now))
        XCTAssertEqual(CMSampleBufferGetNumSamples(buffer), 1)
        XCTAssertEqual(CMSampleBufferGetTotalSampleSize(buffer), 8)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(buffer), now)
        XCTAssertNil(VideoFormat.makeSampleBuffer(annexB: Data(), formatDescription: description, presentationTime: now))
    }

    func testMicrosecondConversion() {
        XCTAssertEqual(CMTime(value: 3, timescale: 2).phorosMicroseconds, 1_500_000)
        XCTAssertEqual(CMTime(phorosMicroseconds: 1_500_000).seconds, 1.5)
        XCTAssertEqual(CMTime.invalid.phorosMicroseconds, 0)
    }
}

final class AACTests: XCTestCase {
    private func sine(frames: Int, sampleRate: Double, channels: Int, at time: Double) -> PCMChunk {
        var data = Data(count: frames * channels * 4)
        data.withUnsafeMutableBytes { raw in
            let dst = raw.baseAddress!.assumingMemoryBound(to: Float32.self)
            for frame in 0..<frames {
                let seconds: Double = time + Double(frame) / sampleRate
                let phase: Double = 2.0 * Double.pi * 440.0 * seconds
                let sample = Float32(sin(phase)) * 0.5
                for channel in 0..<channels { dst[frame * channels + channel] = sample }
            }
        }
        return PCMChunk(samples: data, sampleRate: sampleRate, channels: channels, presentationTime: CMTime(seconds: time, preferredTimescale: 1_000_000))
    }

    func testEncoderProducesWireSizedUnitsWithPrimingCompensatedTimestamps() throws {
        let encoder = AACEncoder(bitrate: 128_000)
        var units: [AACAccessUnit] = []
        var time = 10.0
        for _ in 0..<40 {
            units += try encoder.encode(sine(frames: 1024, sampleRate: 48_000, channels: 2, at: time))
            time += 1024 / 48_000
        }
        XCTAssertGreaterThan(units.count, 20)
        XCTAssertTrue(units.allSatisfy { !$0.bytes.isEmpty && $0.bytes.count <= AudioCodecID.maxAccessUnitBytes })
        XCTAssertEqual(encoder.sampleRate, 48_000)
        XCTAssertEqual(encoder.framesPerAccessUnit, 1024)
        XCTAssertGreaterThan(encoder.primingFrames, 0)
        XCTAssertLessThanOrEqual(encoder.appliedBitrate, 160_000)

        // The first unit is stamped `primingFrames` before the anchor.
        let expectedFirst = 10_000_000 - Int64((Double(encoder.primingFrames) * 1_000_000 / 48_000).rounded())
        XCTAssertEqual(units[0].presentationTime.phorosMicroseconds, expectedFirst)
        // Consecutive units are exactly one access unit apart.
        let step = units[1].presentationTime.phorosMicroseconds - units[0].presentationTime.phorosMicroseconds
        XCTAssertEqual(step, Int64((1024.0 * 1_000_000 / 48_000).rounded()))
    }

    func testEncoderRoundTripsThroughTheDecoder() throws {
        let encoder = AACEncoder()
        let decoder = try XCTUnwrap(AACDecoder(sampleRate: 44_100, channels: 1))
        var decodedFrames: AVAudioFrameCount = 0
        var time = 0.0
        for _ in 0..<30 {
            for unit in try encoder.encode(sine(frames: 1024, sampleRate: 44_100, channels: 1, at: time)) {
                if let pcm = decoder.decode(unit.bytes) {
                    XCTAssertEqual(pcm.format.sampleRate, 44_100)
                    XCTAssertEqual(pcm.format.channelCount, 1)
                    decodedFrames += pcm.frameLength
                }
            }
            time += 1024 / 44_100
        }
        XCTAssertGreaterThan(decodedFrames, 10 * 1024)
    }

    func testDecoderRejectsMalformedAndOversizedUnits() throws {
        let decoder = try XCTUnwrap(AACDecoder(sampleRate: 48_000, channels: 2))
        XCTAssertNil(decoder.decode(Data()))
        XCTAssertNil(decoder.decode(Data(count: AudioCodecID.maxAccessUnitBytes + 1)))
    }

    func testEncoderRebuildsOnFormatChange() throws {
        let encoder = AACEncoder()
        _ = try encoder.encode(sine(frames: 1024, sampleRate: 48_000, channels: 2, at: 0))
        XCTAssertEqual(encoder.channels, 2)
        _ = try encoder.encode(sine(frames: 1024, sampleRate: 44_100, channels: 1, at: 0))
        XCTAssertEqual(encoder.sampleRate, 44_100)
        XCTAssertEqual(encoder.channels, 1)
    }

    func testPCMChunkFromASampleBuffer() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let ints = buffer.int16ChannelData![0]
        for index in 0..<8 { ints[index] = Int16(index) * 1000 }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(value: 48_000, timescale: 48_000), decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: format.formatDescription, sampleCount: 4, sampleTimingEntryCount: 1,
                             sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        CMSampleBufferSetDataBufferFromAudioBufferList(try XCTUnwrap(sampleBuffer), blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: buffer.audioBufferList)

        let chunk = try XCTUnwrap(PCMChunk(sampleBuffer: try XCTUnwrap(sampleBuffer)))
        XCTAssertEqual(chunk.channels, 2)
        XCTAssertEqual(chunk.sampleRate, 48_000)
        XCTAssertEqual(chunk.frameCount, 4)
        XCTAssertEqual(chunk.presentationTime.seconds, 1)
        let floats = chunk.samples.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        XCTAssertEqual(floats[0], 0)
        XCTAssertEqual(floats[3], Float32(3000) / Float32(Int16.max), accuracy: 0.0001)
    }
}
