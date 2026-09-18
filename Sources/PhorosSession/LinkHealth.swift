import Foundation

/// Measures round-trip time with `ping` and `pong`, and never gets stuck.
///
/// An earlier version recorded the send time and cleared it on the reply. One
/// lost reply left the send time set forever, so no probe was ever sent again
/// and the link-quality indicator stayed on "connecting". This probe abandons a
/// reply that is late by `staleAfter` and starts a fresh one.
///
/// ```swift
/// if probe.shouldSend(now: now) { send(.ping) }
/// …
/// case .pong: if let rtt = probe.receivedPong(now: now) { record(rtt) }
/// ```
public struct RoundTripProbe: Equatable, Sendable {
    /// A probe older than this is abandoned.
    public var staleAfter: TimeInterval

    private var sentAt: Date?

    /// The most recent measured round trip.
    public private(set) var lastRoundTrip: TimeInterval?

    public init(staleAfter: TimeInterval = 10) {
        self.staleAfter = staleAfter
    }

    /// `true` when a ping should go out now. Records the send time.
    public mutating func shouldSend(now: Date = Date()) -> Bool {
        if let sentAt, now.timeIntervalSince(sentAt) <= staleAfter { return false }
        sentAt = now
        return true
    }

    /// Records a pong. Returns the round trip, or `nil` if no probe was
    /// outstanding.
    public mutating func receivedPong(now: Date = Date()) -> TimeInterval? {
        guard let sentAt else { return nil }
        self.sentAt = nil
        let rtt = now.timeIntervalSince(sentAt)
        lastRoundTrip = rtt
        return rtt
    }

    public mutating func reset() {
        sentAt = nil
        lastRoundTrip = nil
    }
}

/// Decides when a silent peer is gone.
///
/// Heartbeats share the connection with media, so on a congested link a reply
/// queues behind video and arrives late from a peer that is alive and
/// streaming. A short timeout killed healthy sessions every minute on such
/// links. The default is long enough to ride that out and still catch a dead
/// peer well before a person gives up.
public struct HeartbeatMonitor: Equatable, Sendable {
    public var timeout: TimeInterval
    public private(set) var lastHeard: Date

    public init(timeout: TimeInterval = 30, now: Date = Date()) {
        self.timeout = timeout
        lastHeard = now
    }

    /// Any inbound traffic counts as the peer being alive.
    public mutating func heard(now: Date = Date()) {
        lastHeard = now
    }

    public func isTimedOut(now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastHeard) > timeout
    }
}

/// Tracks a client-requested video hold and what the host must do on release.
///
/// Everything encoded during a hold is dropped, including the keyframe that
/// opened the session, and the encoder believes its parameter sets were
/// already sent. Resuming without repairing that leaves the client's decoder
/// with no reference frame and no format description: a black stream for the
/// rest of the session with nothing in the log. Every release must resend the
/// parameter sets and force a keyframe.
public struct VideoHold: Equatable, Sendable {
    public enum ResumeAction: Equatable, Sendable {
        /// Send the current parameter sets again, with their codec flag.
        case resendParameterSets
        /// Ask the encoder for a keyframe on its next frame.
        case requestKeyframe
    }

    public private(set) var isHeld = false

    public init() {}

    /// The client asked to pause video. Drop queued video too; it is stale by
    /// the time video resumes.
    public mutating func pause() {
        isHeld = true
    }

    /// The client asked to resume. Perform every returned action, in order.
    public mutating func resume() -> [ResumeAction] {
        isHeld = false
        return [.resendParameterSets, .requestKeyframe]
    }
}
