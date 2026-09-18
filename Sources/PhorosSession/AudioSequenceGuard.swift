import Foundation

/// Decides whether an audio chunk is new, stale, or the first after a sender
/// restart.
///
/// The transport is ordered, so a chunk with a sequence number behind the last
/// one is not a reordered packet. A small step back is a duplicate and is
/// dropped. A large step back means the sender reset its counter (its encoder
/// restarted) and the receiver must re-anchor rather than drop.
///
/// The second case is the one that matters. An earlier version dropped every
/// backwards chunk, and because the drop path did not advance the counter, one
/// backwards jump muted audio for the rest of the session while video played
/// on. This type cannot latch that way: a restart always re-anchors.
///
/// ```swift
/// switch sequenceGuard.accept(header.sequenceNumber) {
/// case .accept: play(chunk)
/// case .restarted: resync(); play(chunk)
/// case .duplicate: break
/// }
/// ```
public struct AudioSequenceGuard: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Newer than the last accepted chunk. Play it.
        case accept
        /// Behind the last chunk by less than `restartThreshold`. Drop it.
        case duplicate
        /// Behind by `restartThreshold` or more: the sender restarted. The
        /// guard has re-anchored to this chunk. Reset any sync state and play it.
        case restarted
    }

    /// Backwards distance at or beyond which a chunk is a restart, not a duplicate.
    public var restartThreshold: UInt32

    private var last: UInt32?

    public init(restartThreshold: UInt32 = 256) {
        self.restartThreshold = restartThreshold
    }

    /// The last accepted sequence number, or `nil` before the first chunk.
    public var lastAccepted: UInt32? { last }

    /// Forget the last sequence number, for example on reconnect.
    public mutating func reset() {
        last = nil
    }

    public mutating func accept(_ sequence: UInt32) -> Decision {
        guard let previous = last else {
            last = sequence
            return .accept
        }
        let forward = sequence &- previous
        if forward != 0 && forward < UInt32.max / 2 {
            last = sequence
            return .accept
        }
        let backward = previous &- sequence
        if backward >= restartThreshold {
            last = sequence
            return .restarted
        }
        return .duplicate
    }
}
