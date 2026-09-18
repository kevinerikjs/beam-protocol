import AudioToolbox
import CoreMedia
import Foundation
import Phoros

/// One AAC-LC access unit ready to be the body of an `.audio` packet with
/// `AudioCodecID.aacLC` flags, and the timestamp to put in its
/// `AudioChunkHeader`.
public struct AACAccessUnit: Equatable, Sendable {
    public var bytes: Data
    /// Priming-compensated. Put it on the wire as is; the decoder must not
    /// compensate again.
    public var presentationTime: CMTime
}

public enum AACEncoderError: Error, Equatable, Sendable {
    case converterCreationFailed(OSStatus)
    case encodeFailed(OSStatus)
}

/// Encodes interleaved Float32 PCM to raw AAC-LC access units sized for the
/// wire, with timestamps that stay in sync with video.
///
/// AAC-LC adds a constant delay of about 2112 frames (encoder priming plus
/// decoder look-ahead). Uncompensated, that is a permanent negative
/// audio/video offset that pushes a receiver toward its hard-resync
/// threshold. This encoder runs a sample-accurate output clock and stamps
/// each access unit `primingFrames` earlier than its nominal position, which
/// cancels the delay exactly. The receiver does no trimming and no
/// compensation; doing so would double-correct.
///
/// Constant bitrate is used so the access-unit size is predictable and the
/// "one access unit fits one packet" rule can hold. Units that still exceed
/// `AudioCodecID.maxAccessUnitBytes` are skipped, but the clock still
/// advances so later timestamps stay truthful.
///
/// Feed chunks from one queue. The encoder rebuilds itself when the source
/// format changes and re-anchors its clock when input timestamps jump by more
/// than `driftTolerance`, which happens when capture stalls.
public final class AACEncoder {
    /// Wire-name of what this produces, for `PairingMessage.selectedAudioCodec`.
    public static let codec = AudioCodecID.aacLC

    /// Default priming delay when the converter does not report one.
    public static let defaultPrimingFrames: Int64 = 2112

    /// Input clock jump that triggers a re-anchor instead of a drift.
    public var driftTolerance: TimeInterval = 0.25

    public private(set) var sampleRate: Double = 0
    public private(set) var channels = 0
    public private(set) var primingFrames = AACEncoder.defaultPrimingFrames
    public private(set) var framesPerAccessUnit = Int64(AudioCodecID.aacFramesPerAccessUnit)
    public private(set) var appliedBitrate = 0

    private var converter: AudioConverterRef?
    private var requestedBitrate = 128_000
    private var bytesPerFrame = 0
    private var pending = Data()
    private var anchor: Int64 = 0
    private var needsAnchor = true
    private var producedUnits: Int64 = 0
    private var fedFrames: Int64 = 0
    private var inputScratch: UnsafeMutableRawPointer?
    private var inputScratchCapacity = 0
    private var outputScratch: UnsafeMutableRawPointer?
    private var outputScratchCapacity = 0
    private let maxUnitsPerCall = 8

    public init(bitrate: Int = 128_000) {
        requestedBitrate = bitrate
    }

    deinit { teardown() }

    /// Change the target bitrate mid-stream. Applied live, no re-anchor, no
    /// change on the wire. Snapped to a rate the encoder supports, never above
    /// 160 kbps so one unit keeps fitting one packet.
    public func setBitrate(_ bitsPerSecond: Int) {
        requestedBitrate = bitsPerSecond
        if let converter { applyBitrate(to: converter) }
    }

    /// Forget buffered input and the clock anchor. The next chunk re-anchors.
    public func reset() {
        teardown()
    }

    /// Encodes a chunk. Returns zero or more access units; the converter
    /// buffers across chunks, so a chunk may yield none.
    public func encode(_ chunk: PCMChunk) throws -> [AACAccessUnit] {
        let channels = max(1, chunk.channels)
        guard chunk.sampleRate > 0, !chunk.samples.isEmpty else { return [] }

        if converter == nil || chunk.sampleRate != sampleRate || channels != self.channels {
            teardown()
            try setUp(sampleRate: chunk.sampleRate, channels: channels)
        }
        guard let converter else { return [] }

        let inputMicroseconds = chunk.presentationTime.phorosMicroseconds
        if needsAnchor {
            reanchor(at: inputMicroseconds)
        } else {
            let predicted = anchor + microseconds(forFrames: fedFrames)
            if abs(inputMicroseconds - predicted) > Int64(driftTolerance * 1_000_000) {
                AudioConverterReset(converter)
                pending.removeAll(keepingCapacity: true)
                reanchor(at: inputMicroseconds)
            }
        }

        let frames = chunk.samples.count / bytesPerFrame
        guard frames > 0 else { return [] }
        pending.append(chunk.samples.prefix(frames * bytesPerFrame))
        fedFrames += Int64(frames)

        return try drain(converter)
    }

    // MARK: Converter

    private func setUp(sampleRate: Double, channels: Int) throws {
        var source = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 4),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
        )
        var destination = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(AudioCodecID.aacFramesPerAccessUnit), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0
        )
        var created: AudioConverterRef?
        let status = AudioConverterNew(&source, &destination, &created)
        guard status == noErr, let converter = created else {
            throw AACEncoderError.converterCreationFailed(status)
        }

        var mode = kAudioCodecBitRateControlMode_Constant
        AudioConverterSetProperty(converter, kAudioCodecPropertyBitRateControlMode, UInt32(MemoryLayout<UInt32>.size), &mode)

        self.converter = converter
        self.sampleRate = sampleRate
        self.channels = channels
        bytesPerFrame = channels * 4
        appliedBitrate = 0
        applyBitrate(to: converter)

        var output = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioConverterGetProperty(converter, kAudioConverterCurrentOutputStreamDescription, &size, &output) == noErr, output.mFramesPerPacket > 0 {
            framesPerAccessUnit = Int64(output.mFramesPerPacket)
        }
        var prime = AudioConverterPrimeInfo()
        var primeSize = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
        if AudioConverterGetProperty(converter, kAudioConverterPrimeInfo, &primeSize, &prime) == noErr, prime.leadingFrames > 0 {
            primingFrames = Int64(prime.leadingFrames)
        } else {
            primingFrames = AACEncoder.defaultPrimingFrames
        }

        inputScratchCapacity = max(bytesPerFrame * Int(sampleRate) / 4, bytesPerFrame * 4096)
        inputScratch = .allocate(byteCount: inputScratchCapacity, alignment: 16)
        outputScratchCapacity = AudioCodecID.maxAccessUnitBytes * maxUnitsPerCall
        outputScratch = .allocate(byteCount: outputScratchCapacity, alignment: 16)
        pending.removeAll(keepingCapacity: true)
        needsAnchor = true
    }

    private func teardown() {
        if let converter { AudioConverterDispose(converter) }
        converter = nil
        inputScratch?.deallocate(); inputScratch = nil; inputScratchCapacity = 0
        outputScratch?.deallocate(); outputScratch = nil; outputScratchCapacity = 0
        pending.removeAll()
        sampleRate = 0
        channels = 0
        bytesPerFrame = 0
        needsAnchor = true
        appliedBitrate = 0
    }

    private func reanchor(at microseconds: Int64) {
        anchor = microseconds
        producedUnits = 0
        fedFrames = 0
        needsAnchor = false
    }

    private func microseconds(forFrames frames: Int64) -> Int64 {
        Int64((Double(frames) * 1_000_000 / sampleRate).rounded())
    }

    private func applyBitrate(to converter: AudioConverterRef) {
        let target = min(requestedBitrate, 160_000)
        var chosen = target
        var size: UInt32 = 0
        if AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates, &size, nil) == noErr,
           size >= UInt32(MemoryLayout<AudioValueRange>.size) {
            var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
            var ioSize = size
            let ok = ranges.withUnsafeMutableBytes { AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates, &ioSize, $0.baseAddress!) == noErr }
            if ok {
                let candidates = ranges.flatMap { [Int($0.mMinimum), Int($0.mMaximum)] }.filter { $0 > 0 }
                if let best = candidates.filter({ $0 <= target }).max() ?? candidates.min() { chosen = best }
            }
        }
        guard chosen != appliedBitrate else { return }
        var rate = UInt32(chosen)
        if AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate) == noErr {
            appliedBitrate = chosen
        }
    }

    // MARK: Drain

    private func drain(_ converter: AudioConverterRef) throws -> [AACAccessUnit] {
        guard let outputScratch else { return [] }
        var units: [AACAccessUnit] = []
        var descriptions = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: maxUnitsPerCall)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        while true {
            var packetCount = UInt32(maxUnitsPerCall)
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels), mDataByteSize: UInt32(outputScratchCapacity), mData: outputScratch
            ))
            let status = descriptions.withUnsafeMutableBufferPointer {
                AudioConverterFillComplexBuffer(converter, phorosAACInput, selfPointer, &packetCount, &list, $0.baseAddress)
            }
            if status != noErr && status != AACEncoder.starved {
                teardown()
                throw AACEncoderError.encodeFailed(status)
            }
            for index in 0..<Int(packetCount) {
                let description = descriptions[index]
                let byteCount = Int(description.mDataByteSize)
                let frameOffset = producedUnits * framesPerAccessUnit - primingFrames
                producedUnits += 1
                guard byteCount > 0, byteCount <= AudioCodecID.maxAccessUnitBytes else { continue }
                units.append(AACAccessUnit(
                    bytes: Data(bytes: outputScratch.advanced(by: Int(description.mStartOffset)), count: byteCount),
                    presentationTime: CMTime(phorosMicroseconds: anchor + microseconds(forFrames: frameOffset))
                ))
            }
            if status == AACEncoder.starved || packetCount == 0 { return units }
        }
    }

    /// Any non-zero value the converter will surface verbatim, so "out of
    /// input" is distinguishable from a real failure.
    fileprivate static let starved: OSStatus = 1

    fileprivate func provideInput(packets: UnsafeMutablePointer<UInt32>, list: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard let inputScratch, bytesPerFrame > 0 else { packets.pointee = 0; return AACEncoder.starved }
        let wanted = Int(packets.pointee) * bytesPerFrame
        let byteCount = min(wanted, min(pending.count, inputScratchCapacity)) / bytesPerFrame * bytesPerFrame
        guard byteCount > 0 else { packets.pointee = 0; return AACEncoder.starved }
        pending.withUnsafeBytes { inputScratch.copyMemory(from: $0.baseAddress!, byteCount: byteCount) }
        pending.removeFirst(byteCount)
        list.pointee.mNumberBuffers = 1
        list.pointee.mBuffers.mNumberChannels = UInt32(channels)
        list.pointee.mBuffers.mDataByteSize = UInt32(byteCount)
        list.pointee.mBuffers.mData = inputScratch
        packets.pointee = UInt32(byteCount / bytesPerFrame)
        return noErr
    }
}

private let phorosAACInput: AudioConverterComplexInputDataProc = { _, packets, list, descriptions, userData in
    descriptions?.pointee = nil
    guard let userData else { packets.pointee = 0; return AACEncoder.starved }
    return Unmanaged<AACEncoder>.fromOpaque(userData).takeUnretainedValue().provideInput(packets: packets, list: list)
}
