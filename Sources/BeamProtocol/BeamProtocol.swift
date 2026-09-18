// Protocol.swift
// Beam Network Protocol - shared contract between macOS host and iOS client
// IMPORTANT: Any changes here must be mirrored in beam-ios/Beam/Streaming/Protocol.swift

import Foundation
import CoreMedia

// MARK: - Stream Quality Presets

public enum StreamQualityPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto     = "auto"
    case p360_30  = "360p30"
    case p480_30  = "480p30"
    case p720_30  = "720p30"
    case p720_60  = "720p60"
    case p1080_30 = "1080p30"
    case p1080_60 = "1080p60"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto:     return "Auto"
        case .p360_30:  return "360p · 30 fps"
        case .p480_30:  return "480p · 30 fps"
        case .p720_30:  return "720p · 30 fps"
        case .p720_60:  return "720p · 60 fps"
        case .p1080_30: return "1080p · 30 fps"
        case .p1080_60: return "1080p · 60 fps"
        }
    }

    public var width: Int {
        switch self {
        case .auto:                   return 1920
        case .p360_30:                return 640
        case .p480_30:                return 854
        case .p720_30, .p720_60:      return 1280
        case .p1080_30, .p1080_60:    return 1920
        }
    }

    public var height: Int {
        switch self {
        case .auto:                   return 1080
        case .p360_30:                return 360
        case .p480_30:                return 480
        case .p720_30, .p720_60:      return 720
        case .p1080_30, .p1080_60:    return 1080
        }
    }

    public var fps: Double {
        switch self {
        case .auto, .p360_30, .p480_30, .p720_30, .p1080_30: return 30
        case .p720_60, .p1080_60:                             return 60
        }
    }

    public var bitrateMbps: Double {
        switch self {
        case .auto:    return 6
        case .p360_30: return 1.5
        case .p480_30: return 2.5
        case .p720_30: return 4
        case .p720_60: return 6
        case .p1080_30: return 6
        case .p1080_60: return 10
        }
    }

    /// Non-auto presets ordered lowest → highest (for auto-adaptation tiering).
    public static let autoTiers: [StreamQualityPreset] = [.p360_30, .p480_30, .p720_30, .p1080_30]
}

// MARK: - Packet Types

public enum BeamPacketType: UInt8 {
    case video      = 0x01  // H.264 video fragment
    case audio      = 0x02  // AAC audio chunk
    case control    = 0x03  // Control message (TCP, JSON-encoded)
    case heartbeat  = 0x04  // Keep-alive ping/pong (UDP)
    case spsPps     = 0x05  // H.264 SPS/PPS parameter sets (sent before first frame)
    case videoIDR   = 0x06  // H.264 IDR (keyframe) fragment
    case input      = 0x07  // Controller state report (iOS → macOS)
}

// MARK: - Packet Header
//
// Layout (10 bytes):
//   [0..3]  magic       = 0x4245414D ("BEAM")
//   [4]     type        = BeamPacketType raw value
//   [5]     flags       = reserved, set to 0
//   [6..9]  length      = payload byte count (big-endian UInt32)
//
// Total header = 10 bytes, followed by `length` bytes of payload.

public struct BeamPacketHeader {
    public static let magic: UInt32 = 0x4245414D  // "BEAM"
    public static let size: Int = 10

    public let type: BeamPacketType
    public let flags: UInt8
    public let payloadLength: UInt32

    public init(type: BeamPacketType, flags: UInt8, payloadLength: UInt32) {
        self.type = type
        self.flags = flags
        self.payloadLength = payloadLength
    }

    public func serialized() -> Data {
        var magic = BeamPacketHeader.magic.bigEndian
        var length = payloadLength.bigEndian
        var out = Data(capacity: BeamPacketHeader.size)
        withUnsafeBytes(of: &magic) { out.append(contentsOf: $0) }
        out.append(type.rawValue)
        out.append(flags)
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        return out
    }

    public static func parse(from data: Data) -> BeamPacketHeader? {
        guard data.count >= BeamPacketHeader.size else { return nil }
        let magic = data[0..<4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard magic == BeamPacketHeader.magic else { return nil }
        guard let type = BeamPacketType(rawValue: data[4]) else { return nil }
        let flags = data[5]
        let length = data[6..<10].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        return BeamPacketHeader(type: type, flags: flags, payloadLength: length)
    }
}

// MARK: - Video Payload
//
// For video and videoIDR packets, payload layout:
//   [0..3]   frameNumber      UInt32 big-endian  (monotonically increasing)
//   [4..5]   fragmentIndex    UInt16 big-endian  (0-based)
//   [6..7]   totalFragments   UInt16 big-endian
//   [8..15]  presentationTS   Int64  big-endian  (microseconds, CMTime-derived)
//   [16...]  nalData          raw H.264 Annex B NAL unit bytes

public struct BeamVideoPayloadHeader {
    public static let size: Int = 16

    public let frameNumber: UInt32
    public let fragmentIndex: UInt16
    public let totalFragments: UInt16
    public let presentationTimestamp: Int64  // microseconds

    public init(frameNumber: UInt32, fragmentIndex: UInt16, totalFragments: UInt16, presentationTimestamp: Int64) {
        self.frameNumber = frameNumber
        self.fragmentIndex = fragmentIndex
        self.totalFragments = totalFragments
        self.presentationTimestamp = presentationTimestamp
    }

    public func serialized() -> Data {
        var out = Data(capacity: BeamVideoPayloadHeader.size)
        var fn = frameNumber.bigEndian
        var fi = fragmentIndex.bigEndian
        var tf = totalFragments.bigEndian
        var ts = presentationTimestamp.bigEndian
        withUnsafeBytes(of: &fn) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &fi) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &tf) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &ts) { out.append(contentsOf: $0) }
        return out
    }

    public static func parse(from data: Data) -> BeamVideoPayloadHeader? {
        guard data.count >= BeamVideoPayloadHeader.size else { return nil }
        let fn  = data[0..<4].withUnsafeBytes  { $0.loadUnaligned(as: UInt32.self).bigEndian }
        let fi  = data[4..<6].withUnsafeBytes  { $0.loadUnaligned(as: UInt16.self).bigEndian }
        let tf  = data[6..<8].withUnsafeBytes  { $0.loadUnaligned(as: UInt16.self).bigEndian }
        let ts  = data[8..<16].withUnsafeBytes { $0.loadUnaligned(as: Int64.self).bigEndian }
        return BeamVideoPayloadHeader(
            frameNumber: fn,
            fragmentIndex: fi,
            totalFragments: tf,
            presentationTimestamp: ts
        )
    }
}

// MARK: - Audio Payload
//
// For audio packets, payload layout:
//   [0..3]   sequenceNumber   UInt32 big-endian
//   [4..11]  presentationTS   Int64  big-endian (microseconds)
//   [12...]  audioData        codec-dependent; the codec is signalled by the low nibble of
//                             BeamPacketHeader.flags (see BeamAudioCodec below):
//                               0x0 → Float32 interleaved PCM samples (legacy)
//                               0x1 → exactly one raw AAC-LC access unit (no ADTS)

public struct BeamAudioPayloadHeader {
    public static let size: Int = 12

    public let sequenceNumber: UInt32
    public let presentationTimestamp: Int64  // microseconds

    public init(sequenceNumber: UInt32, presentationTimestamp: Int64) {
        self.sequenceNumber = sequenceNumber
        self.presentationTimestamp = presentationTimestamp
    }

    public func serialized() -> Data {
        var out = Data(capacity: BeamAudioPayloadHeader.size)
        var sn = sequenceNumber.bigEndian
        var ts = presentationTimestamp.bigEndian
        withUnsafeBytes(of: &sn) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &ts) { out.append(contentsOf: $0) }
        return out
    }

    public static func parse(from data: Data) -> BeamAudioPayloadHeader? {
        guard data.count >= BeamAudioPayloadHeader.size else { return nil }
        let sn = data[0..<4].withUnsafeBytes  { $0.loadUnaligned(as: UInt32.self).bigEndian }
        let ts = data[4..<12].withUnsafeBytes { $0.loadUnaligned(as: Int64.self).bigEndian }
        return BeamAudioPayloadHeader(sequenceNumber: sn, presentationTimestamp: ts)
    }
}

// MARK: - Audio Codec (BeamPacketHeader.flags for packet type .audio)
//
// The audio payload header is a FIXED 12 bytes and must never grow: both peers parse it by
// absolute byte range and iOS does dropFirst(BeamAudioPayloadHeader.size). The codec is
// therefore signalled in the already-reserved flags byte of BeamPacketHeader, and the
// CAPABILITY is negotiated out of band via BeamPairingMessage.supportedAudioCodecs.
//
// flags layout for type == .audio:
//   bits 0-3  codec id (mask 0x0F)   0 = Float32 interleaved PCM (legacy), 1 = AAC-LC
//   bits 4-7  reserved, must be 0, must be masked off before comparison
//
// SAFETY: every Beacon ever shipped writes flags = 0 and every Beam ever shipped ignores the
// flags byte entirely. A host that sends AAC to such a client makes it play compressed bytes
// as Float32 samples — full-scale white noise into headphones. Codec id 0 is therefore
// permanently PCM, and a non-zero id may ONLY be sent to a client that advertised support in
// the authRequest of the current connection.
public enum BeamAudioCodec: UInt8 {
    /// Float32 interleaved PCM, native endianness, no sub-header. The legacy wire format.
    case pcmFloat32 = 0x00
    /// One raw AAC-LC access unit (1024 frames) per packet. No ADTS, no LATM, no length
    /// prefix — the packet's payloadLength is the access unit's explicit byte size.
    case aacLC      = 0x01

    /// Mask applied to BeamPacketHeader.flags before interpreting an audio packet.
    public static let flagsMask: UInt8 = 0x0F

    /// UserDefaults key, identical on both platforms, that forces the legacy PCM path.
    /// Escape hatch for a bad release; the macOS half self-updates via Sparkle.
    public static let forcePCMDefaultsKey = "BeamForcePCMAudio"

    /// Maximum size of a single AAC-LC access unit we will emit or accept, in bytes.
    public static let maxAccessUnitBytes = 1536

    /// AAC-LC access unit length in frames.
    public static let aacFramesPerPacket = 1024

    /// Total AAC-LC priming delay in frames (encoder priming + decoder lookahead, counted
    /// once). Used as the fallback when kAudioConverterPrimeInfo reports nothing.
    public static let aacPrimingFrames = 2112

    /// Value written into BeamPacketHeader.flags for an audio packet in this codec.
    public var packetFlags: UInt8 { rawValue }

    /// Decodes an audio packet's flags byte. Returns nil for an unassigned codec id, which
    /// the receiver MUST treat as "drop this packet" — never as a reason to fall through to
    /// the PCM path.
    public init?(packetFlags: UInt8) {
        self.init(rawValue: packetFlags & BeamAudioCodec.flagsMask)
    }

    /// Stable string used in BeamPairingMessage.supportedAudioCodecs / .selectedAudioCodec.
    /// Strings, not an enum, so an unknown future codec can never fail decoding of the whole
    /// pairing message (which would break authentication itself).
    public var wireName: String {
        switch self {
        case .pcmFloat32: return "pcm_f32le"
        case .aacLC:      return "aac_lc"
        }
    }

    init?(wireName: String) {
        switch wireName {
        case "pcm_f32le": self = .pcmFloat32
        case "aac_lc":    self = .aacLC
        default:          return nil
        }
    }

    /// What the iOS client advertises. PCM is always included and always last-resort.
    public static func clientAdvertisedCodecs() -> [String] {
        if UserDefaults.standard.bool(forKey: forcePCMDefaultsKey) {
            return [BeamAudioCodec.pcmFloat32.wireName]
        }
        return [BeamAudioCodec.aacLC.wireName, BeamAudioCodec.pcmFloat32.wireName]
    }

    /// Host-side AAC bitrate for the active video preset. Bound to the preset because it is
    /// the only signal the host has for a constrained link, and the auto-tiering already
    /// drives it down on exactly those links. Halved for mono. Never above 160 kbps, which is
    /// what keeps one access unit inside a single 1400-byte packet (audio is never fragmented).
    public static func aacBitrate(for preset: StreamQualityPreset, channels: Int) -> Int {
        let stereoRate: Int
        switch preset {
        case .p360_30:                                          stereoRate = 64_000
        case .p480_30:                                          stereoRate = 96_000
        case .p720_30, .p720_60, .p1080_30, .p1080_60, .auto:   stereoRate = 128_000
        }
        return channels <= 1 ? stereoRate / 2 : min(stereoRate, 160_000)
    }
}

// MARK: - Video Codec (BeamPacketHeader.flags for packet type .spsPps)
//
// The video codec is negotiated exactly like the audio codec (BeamAudioCodec), one layer up.
// The CAPABILITY is negotiated out of band via BeamPairingMessage.supportedVideoCodecs, and the
// authoritative per-stream signal is the low nibble of BeamPacketHeader.flags on the .spsPps
// packet — because the parameter sets are what tell the receiver whether to build an H.264 or
// an HEVC format description (H.264 carries SPS+PPS; HEVC carries VPS+SPS+PPS). Frame packets
// (.video/.videoIDR) need no codec flag: they decode against the format description already
// built from the parameter sets.
//
// SAFETY, mirrored from BeamAudioCodec: every Beacon ever shipped sends .spsPps with flags = 0
// and every Beam ever shipped ignored the flags byte, so codec id 0 is permanently H.264. HEVC
// (id 1) may ONLY be sent to a client that advertised it in supportedVideoCodecs on the current
// connection. A single shared encoder feeds every session, so the host uses HEVC only when
// EVERY connected client supports it, and falls the whole stream back to H.264 otherwise.
public enum BeamVideoCodec: UInt8 {
    /// H.264 High profile. The legacy wire format and the permanent default.
    case h264 = 0x00
    /// HEVC (H.265) Main profile. ~40-50% less bitrate at equal quality, hardware-encoded on
    /// the Mac and hardware-decoded on the iPhone. Used only when both peers advertise it.
    case hevc = 0x01

    /// Mask applied to BeamPacketHeader.flags before interpreting a .spsPps packet's codec.
    public static let flagsMask: UInt8 = 0x0F

    /// Value written into BeamPacketHeader.flags for a .spsPps packet in this codec.
    public var packetFlags: UInt8 { rawValue }

    /// Decodes a .spsPps packet's flags byte. An unassigned codec id falls back to H.264
    /// rather than dropping: a legacy host sends flags = 0 (H.264), and any future-unknown id
    /// is safest interpreted as the permanent default than as a decode we can't perform.
    public init(packetFlags: UInt8) {
        self = BeamVideoCodec(rawValue: packetFlags & BeamVideoCodec.flagsMask) ?? .h264
    }

    /// Stable string used in BeamPairingMessage.supportedVideoCodecs / .selectedVideoCodec.
    /// Strings, not an enum, so an unknown future codec can never fail decoding of the whole
    /// pairing message (which would break authentication itself).
    public var wireName: String {
        switch self {
        case .h264: return "h264"
        case .hevc: return "hevc"
        }
    }

    init?(wireName: String) {
        switch wireName {
        case "h264": self = .h264
        case "hevc": self = .hevc
        default:     return nil
        }
    }
}

// MARK: - Controller Input (packet type .input)
//
// Beacon does not decode controller reports. Replaying them into a virtual gamepad
// needs the com.apple.developer.hid.virtual.device entitlement, which is approval-gated
// and not yet granted for this team. StreamSession recognises .input packets and drops
// them, so the iOS side can ship its half without flooding this log with decode errors.
// The report layout lives in the iOS Protocol.swift and returns here with the grant.

// MARK: - Control Messages (JSON over TCP)

public enum BeamControlMessageType: String, Codable {
    case mediaKey           = "media_key"
    case ping               = "ping"
    case pong               = "pong"
    case streamRequest      = "stream_request"
    case streamStop         = "stream_stop"
    case qualityFeedback    = "quality_feedback"
    case qualityRequest     = "quality_request"   // iOS → macOS: change to this preset
    case qualityChanged     = "quality_changed"   // macOS → iOS: current preset is now this
    case viewportLockRequest = "viewport_lock_request" // iOS → macOS: lock capture to viewport rect
    case audioFormatChanged = "audio_format_changed" // macOS → iOS: active audio sample rate/channels
    case videoPause         = "video_pause"    // iOS → macOS: hold video, keep audio flowing
    case videoResume        = "video_resume"   // iOS → macOS: resume video
    case audioEnableRequest = "audio_enable_request" // iOS → macOS: start/stop sending audio to this client (BEAM-34)
    case windowListRequest  = "window_list_request"  // iOS → macOS: send me the Mac's capturable windows (BEAM-35)
    case windowList         = "window_list"          // macOS → iOS: reply to the above
    case windowSelectRequest = "window_select_request" // iOS → macOS: lock capture to this window (0 = full display)
    case captureModeChanged = "capture_mode_changed" // macOS → iOS: what the host is capturing now
}

public struct BeamControlMessage: Codable {
    public let type: BeamControlMessageType
    public let payload: BeamControlPayload?

    public init(type: BeamControlMessageType, payload: BeamControlPayload?) {
        self.type = type
        self.payload = payload
    }
}

public enum BeamControlPayload: Codable {
    case mediaKey(BeamMediaKeyPayload)
    case qualityFeedback(BeamQualityFeedbackPayload)
    case qualityRequest(BeamQualityPayload)
    case qualityChanged(BeamQualityPayload)
    case viewportLock(BeamViewportLockPayload)
    case audioFormat(BeamAudioFormatPayload)
    case audioEnable(BeamAudioEnablePayload)
    case windowList(BeamWindowListPayload)
    case windowSelect(BeamWindowSelectPayload)
    case captureMode(BeamCaptureModePayload)
    case empty

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(BeamMediaKeyPayload.self)        { self = .mediaKey(v); return }
        if let v = try? container.decode(BeamQualityPayload.self)         { self = .qualityRequest(v); return }
        if let v = try? container.decode(BeamQualityFeedbackPayload.self) { self = .qualityFeedback(v); return }
        if let v = try? container.decode(BeamViewportLockPayload.self)    { self = .viewportLock(v); return }
        if let v = try? container.decode(BeamAudioFormatPayload.self)     { self = .audioFormat(v); return }
        if let v = try? container.decode(BeamAudioEnablePayload.self)     { self = .audioEnable(v); return }
        if let v = try? container.decode(BeamWindowListPayload.self)      { self = .windowList(v); return }
        if let v = try? container.decode(BeamCaptureModePayload.self)     { self = .captureMode(v); return }
        if let v = try? container.decode(BeamWindowSelectPayload.self)    { self = .windowSelect(v); return }
        self = .empty
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .mediaKey(let v):        try container.encode(v)
        case .qualityFeedback(let v): try container.encode(v)
        case .qualityRequest(let v):  try container.encode(v)
        case .qualityChanged(let v):  try container.encode(v)
        case .viewportLock(let v):    try container.encode(v)
        case .audioFormat(let v):     try container.encode(v)
        case .audioEnable(let v):     try container.encode(v)
        case .windowList(let v):      try container.encode(v)
        case .windowSelect(let v):    try container.encode(v)
        case .captureMode(let v):     try container.encode(v)
        case .empty:                  try container.encodeNil()
        }
    }
}

public struct BeamMediaKeyPayload: Codable {
    public enum Key: String, Codable, Sendable {
        case playPause      = "play_pause"
        case next           = "next"
        case previous       = "previous"
        case seekBackward   = "seek_backward"
        case seekForward    = "seek_forward"
    }
    public let key: Key
    /// BEAM-39. Id of the pressed button from the host's advertised `phoneControls`. A host
    /// that advertised a layout acts on this and ignores `key`; older hosts never see it.
    /// Keep in sync with the other Protocol.swift.
    public var controlID: String? = nil
    /// BEAM-39. Text the phone user entered for a `promptsForText` button. The host types it.
    public var text: String? = nil
    /// BEAM-40. One key from the phone keyboard in live mode: a character, "\n" for Return
    /// or "\u{8}" for Backspace. The host types it immediately, no Return appended.
    public var keystroke: String? = nil
    /// BEAM-40. Carbon modifier mask armed on the phone for this keystroke (cmdKey etc.).
    /// The host posts the key as a chord when it can map the character to a key code.
    public var keystrokeModifiers: UInt32? = nil
    /// BEAM-40. A tap on the stream while a click button is toggled on.
    public var click: BeamClickPayload? = nil

    public init(key: Key, controlID: String? = nil, text: String? = nil, keystroke: String? = nil, keystrokeModifiers: UInt32? = nil, click: BeamClickPayload? = nil) {
        self.key = key
        self.controlID = controlID
        self.text = text
        self.keystroke = keystroke
        self.keystrokeModifiers = keystrokeModifiers
        self.click = click
    }
}

/// BEAM-40. Where the phone user tapped, normalised to the encoded frame the phone is
/// showing (0...1, origin top-left). The host maps that through the viewport lock and the
/// captured window or display to a point on screen and clicks there.
public struct BeamClickPayload: Codable, Equatable {
    public let x: Double
    public let y: Double
    /// "left" or "right".
    public let button: String

    public init(x: Double, y: Double, button: String) {
        self.x = x
        self.y = y
        self.button = button
    }
}

/// Unified quality payload — used for qualityFeedback (quality field), qualityRequest, and qualityChanged (preset field).
public struct BeamQualityFeedbackPayload: Codable {
    public let quality: Double  // 0.0–1.0

    public init(quality: Double) { self.quality = quality }
}

/// Unified payload for qualityRequest / qualityChanged messages (both carry a preset).
public struct BeamQualityPayload: Codable {
    public let preset: StreamQualityPreset

    public init(preset: StreamQualityPreset) { self.preset = preset }
}

/// Viewport lock payload used by iOS to request host-side capture cropping.
/// Values are normalized to 0...1 in the currently streamed full-display coordinate space.
public struct BeamViewportLockPayload: Codable {
    public let locked: Bool
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(locked: Bool, x: Double, y: Double, width: Double, height: Double) {
        self.locked = locked
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Audio format payload sent by host when active stream audio format changes.
public struct BeamAudioFormatPayload: Codable {
    public let sampleRate: Double
    public let channels: Int

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// iOS → macOS (BEAM-34). Whether this client wants audio packets at all. When false the host
/// stops encoding and sending audio for this session — it is not a mute, the bytes never leave
/// the Mac. A host that predates this message logs a decode failure and keeps streaming audio,
/// which the client then mutes locally. Same intent, less bandwidth saved.
public struct BeamAudioEnablePayload: Codable {
    public let enabled: Bool

    public init(enabled: Bool) { self.enabled = enabled }
}

/// One capturable window on the Mac (BEAM-35). `id` is the CGWindowID, which is only stable
/// for the life of that window — the client must refresh the list rather than remember ids.
/// No thumbnails: titles and app names are enough to pick from and keep the message tiny.
public struct BeamWindowInfo: Codable, Identifiable, Equatable {
    public let id: UInt32
    public let title: String
    public let app: String

    public init(id: UInt32, title: String, app: String) {
        self.id = id
        self.title = title
        self.app = app
    }
}

/// macOS → iOS (BEAM-35). Only ever sent inside an authenticated session — window titles are
/// as private as the picture itself and must never cross the pairing channel.
public struct BeamWindowListPayload: Codable {
    public let windows: [BeamWindowInfo]

    public init(windows: [BeamWindowInfo]) { self.windows = windows }
}

/// iOS → macOS (BEAM-35). `windowID` 0 means "clear the window lock, capture the full display".
/// Required (not optional) on purpose: an all-optional payload would decode from ANY object and
/// hijack every other message in the shape-based payload decoder.
public struct BeamWindowSelectPayload: Codable {
    public let windowID: UInt32

    public init(windowID: UInt32) { self.windowID = windowID }
}

/// macOS → iOS (BEAM-35). Broadcast to every client whenever the host switches between full
/// display and a window, from either end, and sent once right after authSuccess so a fresh
/// client starts in sync with the Mac's menu bar.
public struct BeamCaptureModePayload: Codable {
    public let windowMode: Bool
    public let windowID: UInt32?
    public let title: String?
    public let app: String?

    public init(windowMode: Bool, windowID: UInt32? = nil, title: String? = nil, app: String? = nil) {
        self.windowMode = windowMode
        self.windowID = windowID
        self.title = title
        self.app = app
    }
}

// MARK: - Pairing Messages (JSON over TCP)

public enum BeamPairingMessageType: String, Codable {
    case hello          = "hello"       // iOS → macOS: I want to pair, here's my identity
    case challenge      = "challenge"   // macOS → iOS: here's the code to display
    case codeVerify     = "code_verify" // iOS → macOS: user entered this code
    case pairSuccess    = "pair_success"// macOS → iOS: here's the shared secret
    case pairFailed     = "pair_failed" // macOS → iOS: code wrong
    case authRequest    = "auth_request"// iOS → macOS: reconnect with stored secret
    case authSuccess    = "auth_success"// macOS → iOS: authenticated, stream starting
    case authFailed     = "auth_failed" // macOS → iOS: bad secret
    case unpaired       = "unpaired"    // macOS → iOS: device was unpaired by the host
}

public struct BeamPairingMessage: Codable {
    public let type: BeamPairingMessageType
    public let deviceName: String?
    public let deviceID: String?      // UUID, stable per device
    public let code: String?          // 6-digit pairing code
    public let sharedSecret: String?  // hex-encoded 32-byte random secret
    public let error: String?

    /// macOS → iOS. Addresses this host can be reached at from outside the local network —
    /// its Tailscale IPv4 and MagicDNS name (BEAM-19). Sent on `pairSuccess` and on every
    /// `authSuccess` so the phone's stored copy refreshes itself over the LAN and can't go
    /// stale when the tailnet address changes.
    ///
    /// Optional, like every other field here, so old and new peers interoperate in both
    /// directions with no version negotiation. Keep in sync with beam-ios Protocol.swift.
    public var tailscaleHosts: [String]? = nil

    /// macOS → iOS. Always true from this version on. Its ABSENCE is the signal that matters:
    /// a host that omits it predates remote access entirely (BEAM-19), which is a different
    /// problem from a host that supports it but has no Tailscale installed. Without this the
    /// phone cannot tell those apart — both just produce an empty `tailscaleHosts` — and would
    /// tell the user to install Tailscale on a Mac that needs a Beacon update instead.
    public var supportsRemoteAccess: Bool? = nil

    /// macOS → iOS. True only on hosts that correctly restart video when the client releases a
    /// warmup hold (BEAM-21).
    ///
    /// A host that accepts `video_pause` but predates that fix strands the client's decoder for
    /// the whole session: every frame encoded during the hold is dropped, the IDR that opened
    /// the session with it, and the encoder — already past `parameterSetsSent` — never states
    /// its parameter sets again. The stream stays black with no error anywhere.
    ///
    /// So the absence of this flag means "do not hold video on this host", which is NOT the same
    /// as "this host doesn't understand video_pause". Warmup is an optimisation; a black stream
    /// is not a tradeoff worth making for it.
    public var supportsVideoHold: Bool? = nil

    /// iOS → macOS. The client's native hardware sample rate, sent at auth (BEAM-29).
    ///
    /// Previously the host chose a rate and the client reacted to audioFormatChanged, which
    /// left a window at every session start where the client had to GUESS: it built its engine
    /// at a default, then tore the whole chain down when the real rate arrived. Guessing wrong
    /// played audio at the wrong speed for those first moments.
    ///
    /// The client is the party that actually knows this value, so it states it up front and the
    /// host encodes to match. Optional like every other field here, so an older host simply
    /// ignores it and the existing audioFormatChanged path still applies.
    public var preferredAudioSampleRate: Double? = nil


    /// iOS → macOS. Wire names of the audio codecs this client can decode, most-preferred
    /// first (e.g. ["aac_lc", "pcm_f32le"]). Sent on `hello` and on EVERY `authRequest`.
    ///
    /// `nil` is the load-bearing case: a client that omits this field predates audio codec
    /// negotiation and can decode ONLY Float32 interleaved PCM. The host MUST then send every
    /// audio packet with codec id 0 for the whole session. Feeding such a client AAC bytes
    /// produces full-scale white noise in someone's ears, so absence is never optimistic.
    /// An EMPTY array means the same thing as ["pcm_f32le"] — never "anything goes".
    ///
    /// Typed as [String] rather than [BeamAudioCodec] on purpose: an unknown enum case would
    /// fail decoding of the ENTIRE pairing message, which would break authentication itself.
    /// Unknown strings must be silently ignored.
    public var supportedAudioCodecs: [String]? = nil

    /// macOS → iOS. Wire name of the codec the host has chosen for this session, echoed on
    /// `authSuccess`. Diagnostic/telemetry only — the authority for how to decode any given
    /// packet is always that packet's BeamPacketHeader.flags, because the host may fall back
    /// to PCM mid-session if its encoder fails. `nil` = host predates negotiation = PCM.
    public var selectedAudioCodec: String? = nil

    /// iOS → macOS. Wire names of the video codecs this client can decode, most-preferred
    /// first (e.g. ["hevc", "h264"]). Sent on `hello` and on EVERY `authRequest`.
    ///
    /// `nil` (or absence of "hevc") is the load-bearing case: a client that omits this field
    /// predates video codec negotiation and can decode ONLY H.264. The host MUST then encode
    /// H.264 for the whole session — feeding such a client an HEVC stream would leave it unable
    /// to build a format description and the picture would never appear. Absence is never
    /// treated optimistically. An EMPTY array means the same thing as ["h264"].
    ///
    /// Typed as [String] rather than [BeamVideoCodec] on purpose: an unknown enum case would
    /// fail decoding of the ENTIRE pairing message, which would break authentication itself.
    /// Unknown strings must be silently ignored. Keep in sync with beam-ios Protocol.swift.
    public var supportedVideoCodecs: [String]? = nil

    /// macOS → iOS. Wire name of the codec the host negotiated for this client, echoed on
    /// `authSuccess`. Diagnostic/telemetry only — the authority for how to decode video is
    /// always the .spsPps packet's BeamPacketHeader.flags, because the shared encoder may run
    /// H.264 for everyone if any other connected client can't do HEVC, or fall back to H.264
    /// if the HEVC encoder can't be created. `nil` = host predates negotiation = H.264.
    public var selectedVideoCodec: String? = nil

    /// iOS → macOS (BEAM-34). False means "do not send me audio for this session". Sent on
    /// `authRequest` so the host never encodes a single audio packet for a client that has
    /// audio switched off. Absence means true — an older client always wants audio.
    /// Keep in sync with the other Protocol.swift.
    public var wantsAudio: Bool? = nil

    /// macOS → iOS (BEAM-34). True on hosts that honour `wantsAudio` and `audio_enable_request`.
    /// Absence means the host will stream audio regardless, so the client must mute locally
    /// instead and can tell the user a Beacon update would save bandwidth.
    public var supportsAudioToggle: Bool? = nil

    /// macOS → iOS (BEAM-35). True on hosts that answer `window_list_request` and honour
    /// `window_select_request`. Absence hides the window picker on the phone entirely.
    public var supportsWindowSelection: Bool? = nil

    /// macOS → iOS (BEAM-39). What the phone's media buttons are configured to do on the Mac,
    /// so the phone can show the icon Kevin picked in Beacon Settings. Keyed by the same
    /// wire names as BeamMediaKeyPayload.Key. Absence = host predates the feature = default
    /// glyphs. Unknown or unavailable symbols fall back to the default glyph on the phone.
    /// Keep in sync with the other Protocol.swift.
    public var phoneControls: [BeamPhoneControl]? = nil

    public init(
        type: BeamPairingMessageType,
        deviceName: String?,
        deviceID: String?,
        code: String?,
        sharedSecret: String?,
        error: String?,
        tailscaleHosts: [String]? = nil,
        supportsRemoteAccess: Bool? = nil,
        supportsVideoHold: Bool? = nil,
        preferredAudioSampleRate: Double? = nil,
        supportedAudioCodecs: [String]? = nil,
        selectedAudioCodec: String? = nil,
        supportedVideoCodecs: [String]? = nil,
        selectedVideoCodec: String? = nil,
        wantsAudio: Bool? = nil,
        supportsAudioToggle: Bool? = nil,
        supportsWindowSelection: Bool? = nil,
        phoneControls: [BeamPhoneControl]? = nil
    ) {
        self.type = type
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.code = code
        self.sharedSecret = sharedSecret
        self.error = error
        self.tailscaleHosts = tailscaleHosts
        self.supportsRemoteAccess = supportsRemoteAccess
        self.supportsVideoHold = supportsVideoHold
        self.preferredAudioSampleRate = preferredAudioSampleRate
        self.supportedAudioCodecs = supportedAudioCodecs
        self.selectedAudioCodec = selectedAudioCodec
        self.supportedVideoCodecs = supportedVideoCodecs
        self.selectedVideoCodec = selectedVideoCodec
        self.wantsAudio = wantsAudio
        self.supportsAudioToggle = supportsAudioToggle
        self.supportsWindowSelection = supportsWindowSelection
        self.phoneControls = phoneControls
    }
}

/// BEAM-39. One button of the host's active phone-control layout, in left-to-right order.
/// Up to 7 per layout. The phone renders exactly this list; a tap sends the button's `id`
/// back in BeamMediaKeyPayload.controlID.
public struct BeamPhoneControl: Codable, Equatable {
    /// Stable button id within the layout (UUID string). Not semantic.
    public let id: String
    /// SF Symbol name chosen on the Mac.
    public let symbol: String
    /// Short accessibility label / tooltip, e.g. "Back 10s" or "Next tab".
    public let label: String
    /// True for the one emphasised (larger) button, normally play/pause in the middle.
    public var prominent: Bool? = nil
    /// True when the button asks the phone user for text first (a "keyboard" button). The
    /// phone shows an input box and sends the entered text in BeamMediaKeyPayload.text; the
    /// host types it as key presses (typically followed by Return). nil/false = plain tap.
    public var promptsForText: Bool? = nil
    /// Placeholder / title for that input box, e.g. "Prompt Claude".
    public var textPrompt: String? = nil
    /// BEAM-40. How the phone treats the button. nil/"tap" = send a press. "text" = same as
    /// promptsForText. "keyboard" = toggle: raise the phone keyboard and send every key as a
    /// `keystroke`. "click" = toggle: taps on the stream become `click`s on the Mac. Older
    /// phones ignore this and treat every button as a plain tap.
    public var mode: String? = nil
    /// BEAM-40. For mode "modifier": which key this button arms for the next live keystroke.
    /// "cmd", "ctrl", "alt" or "shift".
    public var modifier: String? = nil

    public init(
        id: String,
        symbol: String,
        label: String,
        prominent: Bool? = nil,
        promptsForText: Bool? = nil,
        textPrompt: String? = nil,
        mode: String? = nil,
        modifier: String? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.label = label
        self.prominent = prominent
        self.promptsForText = promptsForText
        self.textPrompt = textPrompt
        self.mode = mode
        self.modifier = modifier
    }
}

// MARK: - Helpers

extension CMTime {
    /// Convert to microseconds for wire protocol
    public var microseconds: Int64 {
        guard timescale != 0 else { return 0 }
        return Int64(Double(value) / Double(timescale) * 1_000_000)
    }
}

public extension Data {
    /// Encode as a length-prefixed TCP message: [UInt32 big-endian length][data]
    func lengthPrefixed() -> Data {
        var out = Data(capacity: 4 + count)
        var len = UInt32(count).bigEndian
        Swift.withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(self)
        return out
    }
}
