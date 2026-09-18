import Foundation
import Phoros

/// One complete encoded video frame, reassembled from its fragments.
public struct AssembledFrame: Equatable, Sendable {
    public var frameNumber: UInt32
    public var presentationTimestamp: Int64
    public var isKeyframe: Bool
    /// Annex B bitstream, exactly as the sender encoded it.
    public var bitstream: Data

    public init(frameNumber: UInt32, presentationTimestamp: Int64, isKeyframe: Bool, bitstream: Data) {
        self.frameNumber = frameNumber
        self.presentationTimestamp = presentationTimestamp
        self.isKeyframe = isKeyframe
        self.bitstream = bitstream
    }
}

/// Reassembles `.video` and `.videoKeyframe` payloads into whole frames.
///
/// Feed every video payload in. Get a frame back when its last fragment
/// arrives. Frames the sender abandoned (a newer frame number appears before
/// they complete) are discarded once they fall `staleDepth` frames behind.
///
/// ```swift
/// var assembler = FrameAssembler()
/// if let frame = assembler.receive(packet.payload, isKeyframe: packet.type == .videoKeyframe) {
///     decode(frame)
/// }
/// ```
///
/// Value type, no locking. Use one per stream, from one queue.
public struct FrameAssembler: Sendable {
    /// Incomplete frames this many frame numbers behind the newest are dropped.
    public var staleDepth: UInt32

    private struct Pending {
        var fragmentCount: UInt16
        var presentationTimestamp: Int64
        var isKeyframe: Bool
        var fragments: [UInt16: Data] = [:]
    }

    private var pending: [UInt32: Pending] = [:]

    public init(staleDepth: UInt32 = 10) {
        self.staleDepth = staleDepth
    }

    /// Frames currently waiting for fragments.
    public var pendingFrameCount: Int { pending.count }

    /// Forget everything, for example when the sender restarts its encoder.
    public mutating func reset() {
        pending.removeAll()
    }

    /// Accepts one video payload. Returns the frame when this payload completes
    /// it, otherwise `nil`. Malformed payloads return `nil` and are ignored.
    public mutating func receive(_ payload: Data, isKeyframe: Bool) -> AssembledFrame? {
        guard let header = VideoFragmentHeader.parse(from: payload), header.fragmentCount > 0 else { return nil }
        let bitstream = Data(payload.dropFirst(VideoFragmentHeader.size))

        defer { dropStale(newest: header.frameNumber) }

        if header.fragmentCount == 1 {
            pending.removeValue(forKey: header.frameNumber)
            return AssembledFrame(
                frameNumber: header.frameNumber,
                presentationTimestamp: header.presentationTimestamp,
                isKeyframe: isKeyframe,
                bitstream: bitstream
            )
        }

        guard header.fragmentIndex < header.fragmentCount else { return nil }

        var frame = pending[header.frameNumber] ?? Pending(
            fragmentCount: header.fragmentCount,
            presentationTimestamp: header.presentationTimestamp,
            isKeyframe: isKeyframe
        )
        frame.fragments[header.fragmentIndex] = bitstream

        guard frame.fragments.count == Int(frame.fragmentCount) else {
            pending[header.frameNumber] = frame
            return nil
        }

        pending.removeValue(forKey: header.frameNumber)
        var assembled = Data()
        for index in 0..<frame.fragmentCount {
            assembled.append(frame.fragments[index]!)
        }
        return AssembledFrame(
            frameNumber: header.frameNumber,
            presentationTimestamp: frame.presentationTimestamp,
            isKeyframe: frame.isKeyframe,
            bitstream: assembled
        )
    }

    private mutating func dropStale(newest: UInt32) {
        guard !pending.isEmpty else { return }
        let threshold = newest > staleDepth ? newest - staleDepth : 0
        pending = pending.filter { $0.key >= threshold }
    }
}
