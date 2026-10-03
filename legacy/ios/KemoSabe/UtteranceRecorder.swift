import Foundation
import AVFoundation

/// Keeps the audio of one utterance, in memory, only while on-device Whisper is on this device or OpenAI
/// transcription is opted into, so it can be read again or sent when the utterance ends (iPhone: the recognizer hears the end; Mac: the person
/// taps the mic again). At most 60 seconds. Nothing is written to disk.
final class UtteranceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var frames: AVAudioFrameCount = 0
    private var enabled = false
    func reset(enabled: Bool) { lock.lock(); buffers = []; frames = 0; self.enabled = enabled; lock.unlock() }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, frames < AVAudioFrameCount(buffer.format.sampleRate * 60), let copy = Self.copy(buffer) else { return }
        buffers.append(copy); frames += buffer.frameLength
    }
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, target.count) {
            guard let from = source[index].mData, let to = target[index].mData else { return nil }
            let bytes = min(source[index].mDataByteSize, target[index].mDataByteSize)
            memcpy(to, from, Int(bytes)); target[index].mDataByteSize = bytes
        }
        return copy
    }
    /// The utterance's buffers, then cleared. For on-device Whisper; nothing is written to disk.
    func takeBuffers() -> [AVAudioPCMBuffer] {
        lock.lock(); defer { lock.unlock() }
        let taken = buffers; buffers = []; frames = 0
        return taken
    }
}
