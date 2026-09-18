import Foundation

/// The modifier mask carried in `MediaKeyCommand.keystrokeModifiers`.
///
/// The values are Carbon's `cmdKey`, `shiftKey`, `optionKey` and
/// `controlKey`, because the first host posted keystrokes with Carbon and the
/// mask went on the wire as it was. A client on any platform can build the
/// mask from this type without Carbon.
public struct KeyModifiers: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 8)
    public static let shift = KeyModifiers(rawValue: 1 << 9)
    public static let option = KeyModifiers(rawValue: 1 << 11)
    public static let control = KeyModifiers(rawValue: 1 << 12)

    /// The modifier a `ControlButton.modifier` value names, or `nil` for an
    /// unknown name. Known names: `cmd`, `shift`, `alt`, `ctrl`.
    public init?(wireName: String) {
        switch wireName {
        case "cmd": self = .command
        case "shift": self = .shift
        case "alt": self = .option
        case "ctrl": self = .control
        default: return nil
        }
    }
}
