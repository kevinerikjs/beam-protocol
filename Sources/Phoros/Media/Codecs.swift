import Foundation

/// How the audio in an `.audio` packet is encoded.
///
/// The codec id travels in the low nibble of `PacketHeader.flags` on every
/// audio packet. Id `0` is PCM and always will be: every sender that predates
/// codec negotiation wrote a zero flags byte, and every receiver that predates
/// it ignored the byte and played the payload as Float32 samples. A host may
/// send a non-zero id only to a client that listed that codec in
/// `PairingMessage.supportedAudioCodecs` on the *current* connection. Feeding
/// AAC to a client that expected PCM plays compressed bytes as samples:
/// full-scale white noise into someone's headphones. That incident is why
/// `PeerCapabilities.audioCodecs` treats a missing advertisement as PCM-only.
///
/// A receiver that reads an id it does not know must drop the packet. Falling
/// through to the PCM path is the same white-noise failure.
public enum AudioCodecID: UInt8, CaseIterable, Sendable {
    /// Interleaved Float32 samples, native byte order, no sub-header.
    case pcmFloat32 = 0x00

    /// One raw AAC-LC access unit per packet: 1024 frames, no ADTS, no LATM,
    /// no length prefix. The packet's payload length is the access unit size.
    case aacLC = 0x01

    /// Mask for the codec id within `PacketHeader.flags`. The high nibble is
    /// reserved and must be zero on send and ignored on receive.
    public static let flagsMask: UInt8 = 0x0F

    /// Largest AAC access unit a sender will emit or a receiver will accept.
    /// Chosen so one access unit fits in one conventionally sized media packet.
    public static let maxAccessUnitBytes = 1536

    /// Frames per AAC-LC access unit, fixed by the codec.
    public static let aacFramesPerAccessUnit = 1024

    /// Value to write into `PacketHeader.flags` for an audio packet.
    public var packetFlags: UInt8 { rawValue }

    /// Reads the codec from an audio packet's flags. `nil` for an unassigned
    /// id, which the receiver must treat as "drop this packet".
    public init?(packetFlags: UInt8) {
        self.init(rawValue: packetFlags & AudioCodecID.flagsMask)
    }

    /// Name used in `PairingMessage.supportedAudioCodecs` and
    /// `selectedAudioCodec`. Names, not ids, so that an unknown future codec
    /// in the list cannot fail decoding of the whole handshake message.
    public var wireName: String {
        switch self {
        case .pcmFloat32: return "pcm_f32le"
        case .aacLC: return "aac_lc"
        }
    }

    /// `nil` for a name this version does not know. Unknown names are ignored,
    /// never an error.
    public init?(wireName: String) {
        guard let match = AudioCodecID.allCases.first(where: { $0.wireName == wireName }) else { return nil }
        self = match
    }
}

/// How the video in a session is encoded.
///
/// The codec id travels in the low nibble of `PacketHeader.flags` on the
/// `.parameterSets` packet only. Parameter sets are what a receiver needs to
/// build a format description, and the description is what decides whether
/// the frames that follow are H.264 or HEVC, so tagging the frames themselves
/// would be redundant. Id `0` is H.264 forever, for the same reason `0` is PCM
/// for audio: shipped senders wrote zero and shipped receivers ignored it.
///
/// HEVC may be sent only to a client that listed it in
/// `PairingMessage.supportedVideoCodecs` on the current connection. A host with
/// one shared encoder feeding several clients uses HEVC only when every
/// connected client supports it.
public enum VideoCodecID: UInt8, CaseIterable, Sendable {
    /// H.264, High profile, Annex B. The original wire format.
    case h264 = 0x00

    /// HEVC (H.265), Main profile, Annex B. Roughly 40 to 50 percent less
    /// bitrate at equal quality, hardware-coded on both sides.
    case hevc = 0x01

    /// Mask for the codec id within `PacketHeader.flags`.
    public static let flagsMask: UInt8 = 0x0F

    /// Value to write into `PacketHeader.flags` for a `.parameterSets` packet.
    public var packetFlags: UInt8 { rawValue }

    /// Reads the codec from a `.parameterSets` packet's flags. `nil` for an
    /// unassigned id; the receiver should drop the parameter sets and log,
    /// since it cannot build a format description for a codec it does not know.
    public init?(packetFlags: UInt8) {
        self.init(rawValue: packetFlags & VideoCodecID.flagsMask)
    }

    /// Name used in `PairingMessage.supportedVideoCodecs` and
    /// `selectedVideoCodec`.
    public var wireName: String {
        switch self {
        case .h264: return "h264"
        case .hevc: return "hevc"
        }
    }

    /// `nil` for a name this version does not know. Unknown names are ignored,
    /// never an error.
    public init?(wireName: String) {
        guard let match = VideoCodecID.allCases.first(where: { $0.wireName == wireName }) else { return nil }
        self = match
    }
}
