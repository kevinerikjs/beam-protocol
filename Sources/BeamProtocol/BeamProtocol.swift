
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

// Ten bytes: magic ("BEAM"), packet type, flags, then a big-endian UInt32 payload length.

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

// Video payloads begin with a 16-byte big-endian fragment header:
// frame number (UInt32), fragment index (UInt16), fragment count (UInt16), timestamp (Int64).

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

// Audio payloads begin with a 12-byte big-endian header: sequence number (UInt32) and
// presentation timestamp in microseconds (Int64). The low flag nibble selects the codec.

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

// Codec ID 0 is permanently PCM. A host must send AAC only after the current client advertises it.
public enum BeamAudioCodec: UInt8 {
    case pcmFloat32 = 0x00
    case aacLC      = 0x01

    public static let flagsMask: UInt8 = 0x0F

    public static let forcePCMDefaultsKey = "BeamForcePCMAudio"

    public static let maxAccessUnitBytes = 1536

    public static let aacFramesPerPacket = 1024

    public static let aacPrimingFrames = 2112

    public var packetFlags: UInt8 { rawValue }

    public init?(packetFlags: UInt8) {
        self.init(rawValue: packetFlags & BeamAudioCodec.flagsMask)
    }

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

    public static func clientAdvertisedCodecs() -> [String] {
        if UserDefaults.standard.bool(forKey: forcePCMDefaultsKey) {
            return [BeamAudioCodec.pcmFloat32.wireName]
        }
        return [BeamAudioCodec.aacLC.wireName, BeamAudioCodec.pcmFloat32.wireName]
    }

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

// H.264 is the legacy default. HEVC requires an explicit current-connection capability advertisement.
public enum BeamVideoCodec: UInt8 {
    case h264 = 0x00
    case hevc = 0x01

    public static let flagsMask: UInt8 = 0x0F

    public var packetFlags: UInt8 { rawValue }

    public init(packetFlags: UInt8) {
        self = BeamVideoCodec(rawValue: packetFlags & BeamVideoCodec.flagsMask) ?? .h264
    }

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
    case audioEnableRequest = "audio_enable_request" // Client requests an audio stream state change.
    case windowListRequest  = "window_list_request"  // Client requests the host's capturable windows.
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
    public var controlID: String? = nil
    public var text: String? = nil
    public var keystroke: String? = nil
    public var keystrokeModifiers: UInt32? = nil
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

public struct BeamClickPayload: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let button: String

    public init(x: Double, y: Double, button: String) {
        self.x = x
        self.y = y
        self.button = button
    }
}

public struct BeamQualityFeedbackPayload: Codable {
    public let quality: Double  // 0.0–1.0

    public init(quality: Double) { self.quality = quality }
}

public struct BeamQualityPayload: Codable {
    public let preset: StreamQualityPreset

    public init(preset: StreamQualityPreset) { self.preset = preset }
}

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

public struct BeamAudioFormatPayload: Codable {
    public let sampleRate: Double
    public let channels: Int

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public struct BeamAudioEnablePayload: Codable {
    public let enabled: Bool

    public init(enabled: Bool) { self.enabled = enabled }
}

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

public struct BeamWindowListPayload: Codable {
    public let windows: [BeamWindowInfo]

    public init(windows: [BeamWindowInfo]) { self.windows = windows }
}

public struct BeamWindowSelectPayload: Codable {
    public let windowID: UInt32

    public init(windowID: UInt32) { self.windowID = windowID }
}

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

    public var tailscaleHosts: [String]? = nil

    public var supportsRemoteAccess: Bool? = nil

    public var supportsVideoHold: Bool? = nil

    public var preferredAudioSampleRate: Double? = nil


    public var supportedAudioCodecs: [String]? = nil

    public var selectedAudioCodec: String? = nil

    public var supportedVideoCodecs: [String]? = nil

    public var selectedVideoCodec: String? = nil

    public var wantsAudio: Bool? = nil

    public var supportsAudioToggle: Bool? = nil

    public var supportsWindowSelection: Bool? = nil

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

public struct BeamPhoneControl: Codable, Equatable, Identifiable {
    public let id: String
    public let symbol: String
    public let label: String
    public var prominent: Bool? = nil
    public var promptsForText: Bool? = nil
    public var textPrompt: String? = nil
    public var mode: String? = nil
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
    public var microseconds: Int64 {
        guard timescale != 0 else { return 0 }
        return Int64(Double(value) / Double(timescale) * 1_000_000)
    }
}

public extension Data {
    func lengthPrefixed() -> Data {
        var out = Data(capacity: 4 + count)
        var len = UInt32(count).bigEndian
        Swift.withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(self)
        return out
    }
}
