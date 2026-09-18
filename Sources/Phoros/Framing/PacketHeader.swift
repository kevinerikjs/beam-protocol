import Foundation

/// What a packet carries. One byte on the wire, at offset 4 of the header.
///
/// Raw values are permanent. A retired type is never reused, and a new type is
/// added at the next free value with a capability flag in the handshake so
/// that older peers are never sent packets they cannot recognise.
public enum PacketType: UInt8, CaseIterable, Sendable {
    /// A fragment of an encoded video frame that is not a keyframe.
    /// Payload: `VideoFragmentHeader` followed by codec bitstream bytes.
    case video = 0x01

    /// One chunk of audio. Payload: `AudioChunkHeader` followed by samples or
    /// one compressed access unit. The codec is in the header flags.
    case audio = 0x02

    /// A JSON `ControlMessage` or `PairingMessage`. Sent over the reliable
    /// channel only.
    case control = 0x03

    /// Keep-alive. Empty payload.
    case heartbeat = 0x04

    /// Codec parameter sets the decoder needs before the first frame: SPS and
    /// PPS for H.264, VPS, SPS and PPS for HEVC. The codec is in the header
    /// flags. Sent once per session and again whenever the encoder restarts.
    case parameterSets = 0x05

    /// A fragment of a keyframe (IDR). Same payload layout as `.video`.
    /// Separate so a receiver can restart decoding here after loss.
    case videoKeyframe = 0x06

    /// A game controller state report from the client. Payload:
    /// `ControllerReport`. Sent at up to 60 Hz while a controller is attached.
    case input = 0x07
}

/// The ten bytes at the start of every packet.
///
/// ```
/// offset  size  field
///      0     4  magic, 0x4245414D ("BEAM"), big-endian
///      4     1  PacketType raw value
///      5     1  flags, meaning depends on the packet type
///      6     4  payload length in bytes, big-endian
/// ```
///
/// The magic lets a receiver on the reliable channel tell a binary packet from
/// a bare JSON message, since no JSON document starts with "BEAM". The flags
/// byte was reserved for years and written as zero by every shipped sender,
/// which is what made it safe to later carry the codec id there for `.audio`
/// and `.parameterSets` packets: an old sender still writes zero, and zero
/// still means the original codec.
public struct PacketHeader: Equatable, Sendable {
    /// `"BEAM"` as a big-endian 32-bit integer.
    public static let magic: UInt32 = 0x4245_414D

    /// Serialized size in bytes.
    public static let size = 10

    public var type: PacketType
    public var flags: UInt8
    public var payloadLength: UInt32

    public init(type: PacketType, flags: UInt8 = 0, payloadLength: UInt32) {
        self.type = type
        self.flags = flags
        self.payloadLength = payloadLength
    }

    /// A header describing `payload`, ready to be sent ahead of it.
    public init(type: PacketType, flags: UInt8 = 0, payload: Data) {
        self.init(type: type, flags: flags, payloadLength: UInt32(payload.count))
    }

    /// The ten header bytes.
    public func serialized() -> Data {
        var out = Data(capacity: PacketHeader.size)
        out.appendBigEndian(PacketHeader.magic)
        out.append(type.rawValue)
        out.append(flags)
        out.appendBigEndian(payloadLength)
        return out
    }

    /// The complete packet: header followed by `payload`.
    ///
    /// The header's `payloadLength` is taken from `payload`, not from `self`.
    public func packet(with payload: Data) -> Data {
        var header = self
        header.payloadLength = UInt32(payload.count)
        var out = Data(capacity: PacketHeader.size + payload.count)
        out.append(header.serialized())
        out.append(payload)
        return out
    }

    /// Reads a header from the first ten bytes of `data`.
    ///
    /// Returns `nil` when there are fewer than ten bytes, the magic does not
    /// match, or the type byte is unassigned. `data` may be a slice; offsets
    /// are taken from its `startIndex`.
    public static func parse(from data: Data) -> PacketHeader? {
        guard data.count >= PacketHeader.size else { return nil }
        let base = data.startIndex
        guard data.readBigEndian(UInt32.self, at: base) == PacketHeader.magic else { return nil }
        guard let type = PacketType(rawValue: data[base + 4]) else { return nil }
        return PacketHeader(
            type: type,
            flags: data[base + 5],
            payloadLength: data.readBigEndian(UInt32.self, at: base + 6)
        )
    }
}

/// Convenience for building a packet in one call.
public enum Packet {
    /// `PacketHeader(type:flags:payload:).packet(with:)` in one step.
    public static func encode(_ type: PacketType, flags: UInt8 = 0, payload: Data = Data()) -> Data {
        PacketHeader(type: type, flags: flags, payload: payload).packet(with: payload)
    }
}
