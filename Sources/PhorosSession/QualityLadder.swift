import Foundation
import Phoros

/// Tunables for `QualityLadder`.
public struct QualityLadderPolicy: Equatable, Sendable {
    /// Feedback below this counts as bad.
    public var stepDownBelow: Double
    /// Feedback above this counts as good.
    public var stepUpAbove: Double
    /// Bad feedback must persist this long before stepping down.
    public var sustainedLow: TimeInterval
    /// Good feedback must persist this long before stepping up. Longer than
    /// `sustainedLow` on purpose: climbing too eagerly oscillates.
    public var sustainedHigh: TimeInterval
    /// Minimum time between two changes in either direction.
    public var minimumInterval: TimeInterval

    public init(
        stepDownBelow: Double = 0.45,
        stepUpAbove: Double = 0.80,
        sustainedLow: TimeInterval = 3,
        sustainedHigh: TimeInterval = 12,
        minimumInterval: TimeInterval = 6
    ) {
        self.stepDownBelow = stepDownBelow
        self.stepUpAbove = stepUpAbove
        self.sustainedLow = sustainedLow
        self.sustainedHigh = sustainedHigh
        self.minimumInterval = minimumInterval
    }
}

/// Chooses a preset from the client's `qualityFeedback`, with hysteresis.
///
/// The host calls `feedback` whenever a `qualityFeedback` arrives and
/// `evaluate` on a timer (the reference host uses two seconds). When
/// `evaluate` returns a preset, reconfigure the encoder and send
/// `qualityChanged`.
///
/// The ladder itself is the host's policy; pass the presets it may move
/// between, lowest first.
public struct QualityLadder: Equatable, Sendable {
    public var policy: QualityLadderPolicy
    public let tiers: [QualityPreset]

    public private(set) var index: Int
    private var latest: Double = 1
    private var lowSince: Date?
    private var highSince: Date?
    private var lastChange = Date.distantPast

    /// - Parameters:
    ///   - tiers: Presets in ascending quality. Must not be empty or contain `.auto`.
    ///   - startingAt: Initial tier; defaults to the top.
    public init(tiers: [QualityPreset], startingAt: QualityPreset? = nil, policy: QualityLadderPolicy = QualityLadderPolicy()) {
        precondition(!tiers.isEmpty && !tiers.contains(.auto), "tiers must be concrete presets")
        self.tiers = tiers
        self.policy = policy
        index = startingAt.flatMap(tiers.firstIndex(of:)) ?? tiers.count - 1
    }

    public var current: QualityPreset { tiers[index] }

    /// Record the client's latest `qualityFeedback` (0 bad, 1 perfect).
    public mutating func feedback(_ quality: Double) {
        latest = quality
    }

    /// Returns the preset to switch to, or `nil` to stay.
    public mutating func evaluate(now: Date = Date()) -> QualityPreset? {
        let mayChange = now.timeIntervalSince(lastChange) >= policy.minimumInterval

        if latest < policy.stepDownBelow {
            highSince = nil
            lowSince = lowSince ?? now
            if mayChange, now.timeIntervalSince(lowSince!) >= policy.sustainedLow, index > 0 {
                return change(to: index - 1, now: now)
            }
        } else if latest > policy.stepUpAbove {
            lowSince = nil
            highSince = highSince ?? now
            if mayChange, now.timeIntervalSince(highSince!) >= policy.sustainedHigh, index < tiers.count - 1 {
                return change(to: index + 1, now: now)
            }
        } else {
            lowSince = nil
            highSince = nil
        }
        return nil
    }

    /// The host or client chose a tier directly. Resets the timers.
    public mutating func set(_ preset: QualityPreset, now: Date = Date()) {
        if let newIndex = tiers.firstIndex(of: preset) {
            _ = change(to: newIndex, now: now)
        }
    }

    private mutating func change(to newIndex: Int, now: Date) -> QualityPreset {
        index = newIndex
        lastChange = now
        lowSince = nil
        highSince = nil
        return tiers[newIndex]
    }
}
