import Foundation

/// Which queue a frame goes on. Order matters because everything shares one
/// connection: a write queued behind a 100 KB keyframe waits for all of it.
public enum SendLane: Equatable, Sendable {
    /// Small and latency-critical. Sent before anything else and never dropped.
    case control
    /// Sent before video, so audio never inherits a keyframe's delay.
    case audio
    /// Bulk. Sent last and dropped first.
    case video
}

/// Tunables for `SendScheduler`. The defaults are what the reference host
/// ships with.
public struct SendPolicy: Equatable, Sendable {
    /// Total bytes handed to the transport and not yet written, above which
    /// non-keyframe video is dropped instead of queued. About one second at
    /// 1.5 Mbps and a quarter second at 6 Mbps.
    public var maximumQueuedBytes: Int

    /// Audio bytes in flight above which audio chunks are dropped. Checked
    /// against audio bytes only: video's own gate parks the shared total near
    /// `maximumQueuedBytes`, so a shared check would drop audio forever.
    public var maximumQueuedAudioBytes: Int

    /// Audio is never dropped for longer than this, whatever the counters say.
    /// Admitting one chunk onto a saturated link cannot cause a latency runaway,
    /// and it makes "audio dead for the rest of the session" impossible.
    public var maximumAudioSilence: TimeInterval

    /// Writes handed to the transport at once. One made the send path
    /// stop-and-wait and collapsed throughput on a LAN; eight keeps the
    /// pipeline full while audio still goes first.
    public var maximumConcurrentWrites: Int

    public init(
        maximumQueuedBytes: Int = 192 * 1024,
        maximumQueuedAudioBytes: Int = 64 * 1024,
        maximumAudioSilence: TimeInterval = 1.0,
        maximumConcurrentWrites: Int = 8
    ) {
        self.maximumQueuedBytes = maximumQueuedBytes
        self.maximumQueuedAudioBytes = maximumQueuedAudioBytes
        self.maximumAudioSilence = maximumAudioSilence
        self.maximumConcurrentWrites = maximumConcurrentWrites
    }

    /// Defaults for a client that decodes only PCM: audio is 2.8 Mbps instead
    /// of 128 kbps, so its ceiling must be higher or it sheds constantly.
    public static let pcmAudio = SendPolicy(maximumQueuedAudioBytes: 288 * 1024)
}

/// Decides what to send, in what order, and what to drop, for one connection
/// that carries control, audio and video together.
///
/// The transport is a byte stream that never drops, so once the encoder
/// outpaces the link every frame queues and latency grows without bound. This
/// scheduler keeps latency bounded by refusing video when the backlog is high,
/// keeps audio ahead of video, and never lets an accounting slip silence a
/// stream: counters re-anchor to zero whenever nothing is in flight.
///
/// Usage, from one queue:
///
/// ```swift
/// // Producer side
/// if scheduler.admitVideo(isKeyframe: key, now: now) {
///     scheduler.enqueue(frame, lane: .video)
/// }
/// // Drain
/// while let write = scheduler.dequeue() {
///     connection.send(write.data) { scheduler.completed(write) ; drain() }
/// }
/// ```
///
/// Value type, no locking. Wrap it in whatever synchronisation the transport
/// callbacks need.
public struct SendScheduler: Sendable {
    /// A buffer the scheduler handed out. Pass it back to `completed`.
    public struct Write: Equatable, Sendable {
        public let data: Data
        public let lane: SendLane

        public init(data: Data, lane: SendLane) {
            self.data = data
            self.lane = lane
        }
    }

    public var policy: SendPolicy

    private var control: [Data] = []
    private var audio: [Data] = []
    private var video: [Data] = []

    private var bytesInFlight = 0
    private var audioBytesInFlight = 0
    private var writesInFlight = 0
    private var lastAudioAdmitted = Date.distantPast

    public private(set) var droppedVideoFrames = 0
    public private(set) var droppedAudioChunks = 0

    public init(policy: SendPolicy = SendPolicy()) {
        self.policy = policy
    }

    /// Bytes handed to the transport and not yet confirmed written.
    public var backlog: (total: Int, audio: Int) { (bytesInFlight, audioBytesInFlight) }

    /// Frames queued and not yet handed to the transport.
    public var queuedCount: Int { control.count + audio.count + video.count }

    // MARK: Admission

    /// Whether a video frame should be sent now. Keyframes are always admitted:
    /// dropping one strands the decoder until the next, which is a worse
    /// artefact than a skipped delta frame.
    public mutating func admitVideo(isKeyframe: Bool) -> Bool {
        if isKeyframe || bytesInFlight <= policy.maximumQueuedBytes { return true }
        droppedVideoFrames += 1
        return false
    }

    /// Whether an audio chunk should be sent now.
    public mutating func admitAudio(now: Date = Date()) -> Bool {
        if audioBytesInFlight > policy.maximumQueuedAudioBytes,
           now.timeIntervalSince(lastAudioAdmitted) <= policy.maximumAudioSilence {
            droppedAudioChunks += 1
            return false
        }
        lastAudioAdmitted = now
        return true
    }

    // MARK: Queue

    public mutating func enqueue(_ data: Data, lane: SendLane) {
        switch lane {
        case .control: control.append(data)
        case .audio: audio.append(data)
        case .video: video.append(data)
        }
    }

    /// The next buffer to write, or `nil` when the queue is empty or the
    /// concurrent-write window is full. Control first, then audio, then video.
    public mutating func dequeue() -> Write? {
        guard writesInFlight < policy.maximumConcurrentWrites else { return nil }
        let write: Write
        if !control.isEmpty {
            write = Write(data: control.removeFirst(), lane: .control)
        } else if !audio.isEmpty {
            write = Write(data: audio.removeFirst(), lane: .audio)
        } else if !video.isEmpty {
            write = Write(data: video.removeFirst(), lane: .video)
        } else {
            return nil
        }
        writesInFlight += 1
        bytesInFlight += write.data.count
        if write.lane == .audio { audioBytesInFlight += write.data.count }
        return write
    }

    /// The transport finished (or failed) a write handed out by `dequeue`.
    public mutating func completed(_ write: Write) {
        writesInFlight -= 1
        bytesInFlight -= write.data.count
        if write.lane == .audio { audioBytesInFlight -= write.data.count }
        if writesInFlight <= 0 {
            // Nothing outstanding: any drift from a lost completion is erased
            // here, so the counters can never latch above a threshold.
            writesInFlight = 0
            bytesInFlight = 0
            audioBytesInFlight = 0
        }
    }

    /// Discard queued video, for example when the peer pauses video: what is
    /// queued is stale by the time it resumes.
    public mutating func dropQueuedVideo() {
        video.removeAll()
    }
}
