import AVFoundation
import Foundation
import Phoros

/// Decodes raw AAC-LC access units from `.audio` packets into Float32 PCM
/// buffers ready for an `AVAudioEngine` player node.
///
/// Output is non-interleaved Float32 at the rate and channel count the host
/// announced in `audioFormatChanged`. Build the decoder only after that
/// message arrives: a decoder built at a guessed rate produces audio at the
/// wrong speed for the first packets and is thrown away when the real rate
/// shows up.
///
/// The decoder performs no priming trim and no timestamp adjustment. The
/// sending `AACEncoder` already shifts each unit's timestamp by the priming
/// delay; compensating again here would push audio permanently early.
///
/// AAC-LC units are independently decodable, so a decoder that starts failing
/// can be discarded and rebuilt; the next unit decodes cleanly.
public final class AACDecoder {
    public let sampleRate: Double
    public let channels: AVAudioChannelCount
    public let outputFormat: AVAudioFormat

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let framesPerUnit: AVAudioFrameCount

    /// `nil` if AVFoundation cannot build a converter for this format.
    public init?(sampleRate: Double, channels: AVAudioChannelCount) {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(AudioCodecID.aacFramesPerAccessUnit), mBytesPerFrame: 0,
            mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0
        )
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output)
        else { return nil }
        self.sampleRate = sampleRate
        self.channels = channels
        inputFormat = input
        outputFormat = output
        self.converter = converter
        framesPerUnit = AVAudioFrameCount(max(1, input.streamDescription.pointee.mFramesPerPacket))
    }

    /// Decodes one access unit. `nil` when the unit is malformed, oversized,
    /// or the decoder produced no frames (normal for the very first unit while
    /// it primes). Callers drop the packet either way.
    public func decode(_ accessUnit: Data) -> AVAudioPCMBuffer? {
        guard !accessUnit.isEmpty, accessUnit.count <= AudioCodecID.maxAccessUnitBytes else { return nil }

        let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: AudioCodecID.maxAccessUnitBytes)
        accessUnit.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(compressed.data, base, accessUnit.count)
        }
        compressed.byteLength = UInt32(accessUnit.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(accessUnit.count))

        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: framesPerUnit) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return compressed
        }
        guard status == .haveData, output.frameLength > 0 else { return nil }
        return output
    }

    public func reset() {
        converter.reset()
    }
}
