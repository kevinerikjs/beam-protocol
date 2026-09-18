import AudioToolbox
import CoreMedia
import Foundation

/// Interleaved Float32 samples: the wire form of `AudioCodecID.pcmFloat32`
/// and the input to `AACEncoder`.
public struct PCMChunk: Equatable, Sendable {
    public var samples: Data
    public var sampleRate: Double
    public var channels: Int
    public var presentationTime: CMTime

    public init(samples: Data, sampleRate: Double, channels: Int, presentationTime: CMTime) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channels = channels
        self.presentationTime = presentationTime
    }

    public var frameCount: Int { samples.count / (channels * MemoryLayout<Float32>.size) }

    /// Normalises whatever a capture API hands over (Float32 or Int16,
    /// interleaved or planar) into interleaved Float32. `nil` for formats this
    /// does not handle or an empty buffer.
    public init?(sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return nil }

        let channels = Int(asbd.mChannelsPerFrame)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard channels > 0, frames > 0 else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isInt16 = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 && asbd.mBitsPerChannel == 16
        let isPlanar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard (isFloat && asbd.mBitsPerChannel == 32) || isInt16 else { return nil }

        let bufferCount = isPlanar ? channels : 1
        let listSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size * (bufferCount - 1)
        let list = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: list.assumingMemoryBound(to: AudioBufferList.self), bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block
        )
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))

        var out = Data(count: frames * channels * MemoryLayout<Float32>.size)
        out.withUnsafeMutableBytes { raw in
            let dst = raw.baseAddress!.assumingMemoryBound(to: Float32.self)
            if isPlanar {
                for channel in 0..<min(channels, buffers.count) {
                    guard let src = buffers[channel].mData else { continue }
                    let available = Int(buffers[channel].mDataByteSize) / (isFloat ? 4 : 2)
                    for frame in 0..<min(frames, available) {
                        dst[frame * channels + channel] = isFloat
                            ? src.assumingMemoryBound(to: Float32.self)[frame]
                            : Float32(src.assumingMemoryBound(to: Int16.self)[frame]) / Float32(Int16.max)
                    }
                }
            } else if let src = buffers[0].mData {
                let count = min(frames * channels, Int(buffers[0].mDataByteSize) / (isFloat ? 4 : 2))
                if isFloat {
                    raw.baseAddress!.copyMemory(from: src, byteCount: count * 4)
                } else {
                    let ints = src.assumingMemoryBound(to: Int16.self)
                    for index in 0..<count { dst[index] = Float32(ints[index]) / Float32(Int16.max) }
                }
            }
        }

        self.init(samples: out, sampleRate: asbd.mSampleRate, channels: channels, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
