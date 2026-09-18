import Foundation

/// A named resolution and frame rate that both peers understand.
///
/// Presets travel by name in `ControlMessage.qualityRequest` and
/// `.qualityChanged`. The name defines the output size and rate; bitrate,
/// display strings and the auto-adaptation ladder are the host's and client's
/// own policy and deliberately not part of the contract.
///
/// `.auto` asks the host to pick and adapt. What it adapts between is up to
/// the host; the client learns the current choice from `.qualityChanged`.
public enum QualityPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case p360_30 = "360p30"
    case p480_30 = "480p30"
    case p720_30 = "720p30"
    case p720_60 = "720p60"
    case p1080_30 = "1080p30"
    case p1080_60 = "1080p60"

    public var id: String { rawValue }

    /// Output width in pixels. `.auto` reports the largest size it may use.
    public var width: Int {
        switch self {
        case .p360_30: return 640
        case .p480_30: return 854
        case .p720_30, .p720_60: return 1280
        case .p1080_30, .p1080_60, .auto: return 1920
        }
    }

    /// Output height in pixels. `.auto` reports the largest size it may use.
    public var height: Int {
        switch self {
        case .p360_30: return 360
        case .p480_30: return 480
        case .p720_30, .p720_60: return 720
        case .p1080_30, .p1080_60, .auto: return 1080
        }
    }

    /// Frames per second.
    public var frameRate: Double {
        switch self {
        case .p720_60, .p1080_60: return 60
        case .auto, .p360_30, .p480_30, .p720_30, .p1080_30: return 30
        }
    }
}
