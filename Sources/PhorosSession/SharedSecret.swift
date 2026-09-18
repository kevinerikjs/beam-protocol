import Foundation

/// The 32 random bytes a host issues at pairing and a client presents on
/// every later connection. On the wire it is lowercase hex.
public struct SharedSecret: Equatable, Sendable {
    public static let byteCount = 32

    public let bytes: Data

    /// `nil` unless `bytes` is exactly 32 bytes.
    public init?(bytes: Data) {
        guard bytes.count == SharedSecret.byteCount else { return nil }
        self.bytes = bytes
    }

    /// `nil` unless `hex` is 64 hex digits.
    public init?(hex: String) {
        guard let data = Data(hexEncoded: hex) else { return nil }
        self.init(bytes: data)
    }

    /// A fresh secret from the system's cryptographic random source.
    public static func generate() -> SharedSecret {
        var generator = SystemRandomNumberGenerator()
        var data = Data(count: byteCount)
        for index in 0..<byteCount {
            data[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return SharedSecret(bytes: data)!
    }

    /// The wire form.
    public var hex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Compares without leaking where the first mismatch is.
    public func matches(_ other: SharedSecret) -> Bool {
        var difference: UInt8 = 0
        for (a, b) in zip(bytes, other.bytes) { difference |= a ^ b }
        return difference == 0
    }
}

public extension Data {
    /// Decodes an even-length hex string. `nil` on any non-hex character.
    init?(hexEncoded hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

/// The six-digit code a host shows and a person types on the client.
public enum PairingCode {
    /// Six decimal digits, zero-padded, from the system's random source.
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0..<1_000_000, using: &generator))
    }
}
