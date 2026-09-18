import Foundation

/// The twelve bytes at the start of every `.audio` payload, followed by the
/// audio for that chunk.
///
/// ```
/// offset  size  field
///      0     4  sequenceNumber, big-endian, increases by one per chunk
///      4     8  presentationTimestamp, big-endian, microseconds
///     12     …  audio, in the codec named by the packet header flags
/// ```
///
/// Audio is never fragmented: one chunk is one packet. For PCM that is a run of
/// interleaved Float32 samples; for AAC it is exactly one access unit. The
/// codec is *not* in this header. It lives in the low nibble of the packet
/// header's flags byte (see `AudioCodecID`), because this header is a fixed
/// twelve bytes that every shipped receiver skips by absolute offset, and
/// growing it would have broken all of them.
///
/// `sequenceNumber` lets a receiver notice a restart: the sender resets to
/// zero when its encoder restarts, and a receiver that sees a large backwards
/// jump should resynchronise rather than treat the chunk as stale.
public struct AudioChunkHeader: Equatable, Sendable {
    /// Serialized size in bytes.
    public static let size = 12

    public var sequenceNumber: UInt32

    /// Microseconds on the sender's media clock, same clock as video.
    public var presentationTimestamp: Int64

    public init(sequenceNumber: UInt32, presentationTimestamp: Int64) {
        self.sequenceNumber = sequenceNumber
        self.presentationTimestamp = presentationTimestamp
    }

    /// The twelve header bytes.
    public func serialized() -> Data {
        var out = Data(capacity: AudioChunkHeader.size)
        out.appendBigEndian(sequenceNumber)
        out.appendBigEndian(presentationTimestamp)
        return out
    }

    /// Reads a header from the first twelve bytes of `data`, or `nil` when
    /// there are fewer. `data` may be a slice.
    public static func parse(from data: Data) -> AudioChunkHeader? {
        guard data.count >= AudioChunkHeader.size else { return nil }
        let base = data.startIndex
        return AudioChunkHeader(
            sequenceNumber: data.readBigEndian(UInt32.self, at: base),
            presentationTimestamp: data.readBigEndian(Int64.self, at: base + 4)
        )
    }
}
