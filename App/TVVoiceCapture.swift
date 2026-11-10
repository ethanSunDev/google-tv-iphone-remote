import AVFoundation
import Foundation

@MainActor
final class TVVoiceCapture {
    private let engine = AVAudioEngine()
    private var tapping = false
    private var sessionActive = false

    static func requestPermission() async -> Bool {
        if #available(iOS 17, *) { return await AVAudioApplication.requestRecordPermission() }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    func start(receive: @escaping @Sendable (Data) -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        sessionActive = true
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8_000,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else { throw CaptureError.format }
        let ratio = target.sampleRate / source.sampleRate
        input.installTap(onBus: 0, bufferSize: 2_048, format: source) { buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let result = converter.convert(to: output, error: &error) { _, status in
                guard !supplied else {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard result != .error, output.frameLength > 0, let samples = output.int16ChannelData?.pointee else { return }
            receive(Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size))
        }
        tapping = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if tapping {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            tapping = false
        }
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }

    private enum CaptureError: Error { case format }
}
