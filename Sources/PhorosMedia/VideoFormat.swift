import CoreMedia
import Foundation
import Phoros

/// Builds and reads the `CMVideoFormatDescription` that ties a Phoros video
/// stream to a decoder.
public enum VideoFormat {
    /// Number of parameter set NAL units each codec sends: SPS and PPS for
    /// H.264; VPS, SPS and PPS for HEVC.
    public static func parameterSetCount(for codec: VideoCodecID) -> Int {
        codec == .hevc ? 3 : 2
    }

    /// A format description from the Annex B parameter sets carried in a
    /// `.parameterSets` packet. `nil` if the payload does not hold enough NAL
    /// units for `codec` or CoreMedia rejects them.
    public static func makeDescription(parameterSets annexB: Data, codec: VideoCodecID) -> CMVideoFormatDescription? {
        let units = AnnexB.nalUnits(in: annexB)
        let required = parameterSetCount(for: codec)
        guard units.count >= required else { return nil }
        let sets = Array(units.prefix(required))

        var description: CMVideoFormatDescription?
        withStablePointers(sets) { pointers, sizes in
            switch codec {
            case .hevc:
                _ = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointers.baseAddress!,
                    parameterSetSizes: sizes.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            case .h264:
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointers.baseAddress!,
                    parameterSetSizes: sizes.baseAddress!,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        return description
    }

    /// The parameter sets of an encoder's format description as one Annex B
    /// blob, ready to be the payload of a `.parameterSets` packet.
    public static func parameterSets(from description: CMFormatDescription, codec: VideoCodecID) -> Data? {
        var count = 0
        let probe: OSStatus
        switch codec {
        case .hevc:
            probe = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        case .h264:
            probe = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        guard probe == noErr, count >= parameterSetCount(for: codec) else { return nil }

        var units: [Data] = []
        for index in 0..<count {
            var size = 0
            var pointer: UnsafePointer<UInt8>?
            let status: OSStatus
            switch codec {
            case .hevc:
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            case .h264:
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            guard status == noErr, let pointer else { return nil }
            units.append(Data(bytes: pointer, count: size))
        }
        return AnnexB.join(units)
    }

    /// Wraps one Annex B frame in a `CMSampleBuffer` for
    /// `AVSampleBufferDisplayLayer` or `VTDecompressionSession`.
    ///
    /// The buffer is stamped with `presentationTime`, which should be on the
    /// receiver's own clock: the sender's timestamps are on its clock and
    /// scheduling against them displays nothing. Pass the current host time
    /// to display immediately.
    public static func makeSampleBuffer(
        annexB frame: Data,
        formatDescription: CMVideoFormatDescription,
        presentationTime: CMTime,
        duration: CMTime = CMTime(value: 1, timescale: 30)
    ) -> CMSampleBuffer? {
        let avcc = AnnexB.toLengthPrefixed(frame)
        guard !avcc.isEmpty else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: 0, blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copied = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var size = avcc.count
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }

    /// Binds every buffer's bytes to a stable pointer for the duration of `body`.
    private static func withStablePointers(
        _ buffers: [Data],
        _ body: (UnsafeBufferPointer<UnsafePointer<UInt8>>, UnsafeBufferPointer<Int>) -> Void
    ) {
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        func bind(_ index: Int) {
            if index == buffers.count {
                pointers.withUnsafeBufferPointer { p in sizes.withUnsafeBufferPointer { s in body(p, s) } }
                return
            }
            buffers[index].withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                pointers.append(base)
                sizes.append(buffers[index].count)
                bind(index + 1)
            }
        }
        bind(0)
    }
}

public extension CMTime {
    /// This time in the wire unit: microseconds.
    var phorosMicroseconds: Int64 {
        guard timescale != 0, isNumeric else { return 0 }
        return Int64((Double(value) / Double(timescale) * 1_000_000).rounded())
    }

    /// A wire timestamp as a `CMTime`.
    init(phorosMicroseconds: Int64) {
        self.init(value: CMTimeValue(phorosMicroseconds), timescale: 1_000_000)
    }
}
