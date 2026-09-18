import Foundation

/// The sixteen bytes at the start of every `.video` and `.videoKeyframe`
/// payload, followed by the codec bitstream for that fragment.
///
/// ```
/// offset  size  field
///      0     4  frameNumber, big-endian, increases by one per encoded frame
///      4     2  fragmentIndex, big-endian, zero-based
///      6     2  fragmentCount, big-endian, fragments in this frame
///      8     8  presentationTimestamp, big-endian, microseconds
///     16     …  bitstream bytes (Annex B NAL units for H.264 and HEVC)
/// ```
///
/// A frame may be split across several packets so that one large keyframe does
/// not delay audio behind it. A receiver collects fragments by `frameNumber`
/// and hands the bitstream to the decoder once `fragmentCount` have arrived.
/// Fragments of a frame are sent in order on the reliable channel; a receiver
/// that sees a new `frameNumber` before the previous frame completed can
/// discard the incomplete one.
///
/// The bitstream is not codec-tagged. Frames decode against the format
/// description built from the most recent `.parameterSets` packet, which does
/// carry the codec in its flags.
public struct VideoFragmentHeader: Equatable, Sendable {
    /// Serialized size in bytes.
    public static let size = 16

    public var frameNumber: UInt32
    public var fragmentIndex: UInt16
    public var fragmentCount: UInt16

    /// Microseconds on the sender's media clock. Receivers use it to keep
    /// audio and video aligned, not as wall-clock time.
    public var presentationTimestamp: Int64

    public init(frameNumber: UInt32, fragmentIndex: UInt16, fragmentCount: UInt16, presentationTimestamp: Int64) {
        self.frameNumber = frameNumber
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.presentationTimestamp = presentationTimestamp
    }

    /// The sixteen header bytes.
    public func serialized() -> Data {
        var out = Data(capacity: VideoFragmentHeader.size)
        out.appendBigEndian(frameNumber)
        out.appendBigEndian(fragmentIndex)
        out.appendBigEndian(fragmentCount)
        out.appendBigEndian(presentationTimestamp)
        return out
    }

    /// Reads a header from the first sixteen bytes of `data`, or `nil` when
    /// there are fewer. `data` may be a slice.
    public static func parse(from data: Data) -> VideoFragmentHeader? {
        guard data.count >= VideoFragmentHeader.size else { return nil }
        let base = data.startIndex
        return VideoFragmentHeader(
            frameNumber: data.readBigEndian(UInt32.self, at: base),
            fragmentIndex: data.readBigEndian(UInt16.self, at: base + 4),
            fragmentCount: data.readBigEndian(UInt16.self, at: base + 6),
            presentationTimestamp: data.readBigEndian(Int64.self, at: base + 8)
        )
    }

    /// Splits one encoded frame into payloads ready for `.video` or
    /// `.videoKeyframe` packets, each no larger than `maximumPayloadLength`
    /// including this header.
    public static func fragment(
        _ bitstream: Data,
        frameNumber: UInt32,
        presentationTimestamp: Int64,
        maximumPayloadLength: Int
    ) -> [Data] {
        let chunk = max(1, maximumPayloadLength - size)
        let count = max(1, (bitstream.count + chunk - 1) / chunk)
        precondition(count <= Int(UInt16.max), "frame needs more than 65535 fragments")
        return (0..<count).map { index in
            let start = bitstream.startIndex + index * chunk
            let end = min(start + chunk, bitstream.endIndex)
            var payload = VideoFragmentHeader(
                frameNumber: frameNumber,
                fragmentIndex: UInt16(index),
                fragmentCount: UInt16(count),
                presentationTimestamp: presentationTimestamp
            ).serialized()
            payload.append(bitstream[start..<end])
            return payload
        }
    }
}
