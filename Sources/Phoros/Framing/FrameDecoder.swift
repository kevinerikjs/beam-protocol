import Foundation

/// The four-byte length prefix that delimits frames on the reliable channel.
///
/// TCP is a byte stream with no message boundaries, so every frame is sent as
/// a big-endian `UInt32` byte count followed by that many bytes. A frame is
/// either a packet (`PacketHeader` + payload) or a bare JSON message; see
/// `Frame`.
public enum LengthPrefix {
    /// Size of the prefix in bytes.
    public static let size = 4

    /// `data` preceded by its length.
    public static func frame(_ data: Data) -> Data {
        precondition(data.count <= UInt32.max, "frame exceeds UInt32 length prefix")
        var out = Data(capacity: size + data.count)
        out.appendBigEndian(UInt32(data.count))
        out.append(data)
        return out
    }

    /// Reads the length announced by the first four bytes of `data`, or `nil`
    /// when there are fewer than four. `data` may be a slice.
    public static func length(in data: Data) -> UInt32? {
        guard data.count >= size else { return nil }
        return data.readBigEndian(UInt32.self, at: data.startIndex)
    }
}

extension Data {
    /// `LengthPrefix.frame(self)`.
    public func lengthPrefixed() -> Data {
        LengthPrefix.frame(self)
    }
}

/// A complete packet pulled off the wire: its header and its payload.
public struct DecodedPacket: Equatable, Sendable {
    public var header: PacketHeader
    public var payload: Data

    public init(header: PacketHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }

    public var type: PacketType { header.type }
    public var flags: UInt8 { header.flags }
}

/// One length-prefixed frame from the reliable channel, classified.
///
/// A host sends every frame as a packet. A client sends its JSON handshake and
/// control messages bare, without a packet header, and only wraps binary
/// payloads such as controller reports. Receivers tell the two apart by the
/// magic: no JSON document starts with the bytes `BEAM`.
public enum Frame: Equatable, Sendable {
    /// A frame that starts with a valid `PacketHeader`.
    case packet(DecodedPacket)

    /// A frame that does not. On this protocol that is always a JSON
    /// `PairingMessage` or `ControlMessage`; decode it with `JSONDecoder`.
    case message(Data)
}

/// Why a `FrameDecoder` gave up on a stream.
public enum FrameDecoderError: Error, Equatable, Sendable {
    /// A length prefix announced more bytes than `maximumFrameLength`.
    /// Rejecting it before allocating is the whole point of the limit.
    case frameTooLarge(announced: UInt32, limit: Int)

    /// A frame started with the packet magic but its header was invalid or
    /// its declared payload length did not match the frame length. The stream
    /// is corrupt or hostile; drop the connection.
    case malformedPacket
}

/// Turns the bytes of a reliable channel into `Frame`s.
///
/// Feed it whatever the transport hands you, in whatever chunk sizes, and pull
/// complete frames out. Partial frames wait in the buffer for more bytes.
///
/// ```swift
/// var decoder = FrameDecoder(maximumFrameLength: 4 << 20)
/// decoder.append(bytesFromSocket)
/// while let frame = try decoder.next() {
///     switch frame {
///     case .packet(let packet): handle(packet)
///     case .message(let json): handle(try JSONDecoder().decode(ControlMessage.self, from: json))
///     }
/// }
/// ```
///
/// The decoder is a value type with no locking. Use one per connection, from
/// one queue.
public struct FrameDecoder: Sendable {
    /// Largest frame the decoder will buffer. A peer that announces more is
    /// reported as `frameTooLarge` and nothing is allocated for it.
    public var maximumFrameLength: Int

    private var buffer = Data()
    private var pendingLength: Int?

    /// - Parameter maximumFrameLength: Upper bound for one frame. Pick it from
    ///   what the application actually sends; a screen-streaming session never
    ///   needs more than a few megabytes per frame.
    public init(maximumFrameLength: Int = 8 << 20) {
        self.maximumFrameLength = maximumFrameLength
    }

    /// Bytes waiting to be parsed.
    public var bufferedByteCount: Int { buffer.count }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// The next complete frame, or `nil` when more bytes are needed.
    ///
    /// Throws when the stream cannot be parsed. After a throw the decoder is
    /// unusable; discard it along with the connection.
    public mutating func next() throws -> Frame? {
        if pendingLength == nil {
            guard let announced = LengthPrefix.length(in: buffer) else { return nil }
            guard announced <= maximumFrameLength else {
                throw FrameDecoderError.frameTooLarge(announced: announced, limit: maximumFrameLength)
            }
            buffer.removeFirst(LengthPrefix.size)
            pendingLength = Int(announced)
        }

        guard let length = pendingLength, buffer.count >= length else { return nil }
        let frame = Data(buffer.prefix(length))
        buffer.removeFirst(length)
        pendingLength = nil

        return try FrameDecoder.classify(frame)
    }

    /// Classifies one complete frame. Exposed for transports that already
    /// deliver whole frames, such as `NWConnection` with a length-prefix
    /// framer.
    public static func classify(_ frame: Data) throws -> Frame {
        guard frame.count >= LengthPrefix.size,
              frame.readBigEndian(UInt32.self, at: frame.startIndex) == PacketHeader.magic
        else {
            return .message(frame)
        }
        guard let header = PacketHeader.parse(from: frame),
              Int(header.payloadLength) == frame.count - PacketHeader.size
        else {
            throw FrameDecoderError.malformedPacket
        }
        return .packet(DecodedPacket(header: header, payload: Data(frame.dropFirst(PacketHeader.size))))
    }
}
