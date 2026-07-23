import Accelerate
@preconcurrency import AVFoundation
import Foundation
import OSLog
import WhisperKit

public enum AudioCaptureError: LocalizedError {
    case microphoneUnavailable
    case recordingAlreadyActive
    case recordingNotActive
    case recordingTooShort

    public var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            "Brak dostępu do mikrofonu"
        case .recordingAlreadyActive:
            "Nagrywanie jest już aktywne"
        case .recordingNotActive:
            "Nagrywanie nie jest aktywne"
        case .recordingTooShort:
            "Nagranie było zbyt krótkie"
        }
    }
}

public struct RecordingMetrics: Sendable {
    public let duration: TimeInterval
    public let silenceDuration: TimeInterval
    public let level: Float
}

public struct CapturedDictation: Sendable {
    public let samples: [Float]
    public let containsSpeech: Bool
}

public final class AudioCaptureService: @unchecked Sendable {
    public static let sampleRate = 16_000

    private let logger = Logger(subsystem: "com.elisevoice.app", category: "audio")
    private let store = AudioBufferStore(sampleRate: sampleRate)
    private let processingQueue = DispatchQueue(
        label: "com.elisevoice.audio-processing",
        qos: .userInitiated
    )
    private let generationLock = NSLock()

    private var streamGeneration: UInt64 = 0
    private var audioEngine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?

    public var configurationChangeHandler: (@Sendable () -> Void)?

    public init() {}

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    public func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }

    @MainActor
    public func startMonitoring() throws {
        let signpostID = PerformanceDiagnostics.signposter.makeSignpostID()
        let signpostState = PerformanceDiagnostics.signposter.beginInterval(
            "Start microphone",
            id: signpostID
        )
        defer {
            PerformanceDiagnostics.signposter.endInterval(
                "Start microphone",
                signpostState
            )
        }
        if audioEngine?.isRunning == true { return }
        stopMonitoring()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.microphoneUnavailable
        }
        guard let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.microphoneUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: desiredFormat) else {
            throw AudioCaptureError.microphoneUnavailable
        }
        let frameCount = AVAudioFrameCount(max(inputFormat.sampleRate * 0.08, 512))
        // CoreAudio may round a requested tap size up to its hardware quantum
        // (for example 3840 → 4096 at 48 kHz). Keep enough fixed capacity for
        // that rounding and for larger Bluetooth device quanta.
        let pooledFrameCapacity = max(frameCount.nextPowerOfTwo, 8_192)
        guard let inputBufferPool = RealtimeAudioBufferPool(
            format: inputFormat,
            frameCapacity: pooledFrameCapacity,
            count: 6
        ) else {
            throw AudioCaptureError.microphoneUnavailable
        }

        generationLock.lock()
        streamGeneration &+= 1
        let generation = streamGeneration
        generationLock.unlock()
        store.markStreamStarted()

        let store = self.store
        let processingQueue = self.processingQueue
        let service = self

        let tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            // AVAudioEngine owns `buffer`, so it cannot escape this callback.
            // Copy it into a fixed, preallocated pool and perform conversion,
            // allocation and model work on the serial processing queue.
            guard let capturedBuffer = inputBufferPool.acquireCopy(of: buffer) else {
                store.markDroppedBuffer()
                return
            }

            processingQueue.async {
                defer { inputBufferPool.release(capturedBuffer) }
                guard service.isCurrentGeneration(generation) else { return }
                do {
                    let converted = try AudioProcessor.resampleBuffer(
                        capturedBuffer,
                        with: converter
                    )
                    store.append(converted)
                } catch {
                    store.markDroppedBuffer()
                }
            }
        }
        inputNode.installTap(
            onBus: 0,
            bufferSize: frameCount,
            format: inputFormat,
            block: tapHandler
        )

        do {
            engine.prepare()
            try engine.start()
            audioEngine = engine
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                self?.logger.notice("Audio hardware configuration changed")
                self?.configurationChangeHandler?()
            }
            logger.info(
                "Microphone stream started: \(inputFormat.sampleRate, format: .fixed(precision: 0)) Hz, \(inputFormat.channelCount) channel(s)"
            )
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }
    }

    @MainActor
    public func stopMonitoring() {
        generationLock.lock()
        streamGeneration &+= 1
        generationLock.unlock()

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let audioEngine else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()
        self.audioEngine = nil
        logger.info("Microphone stream stopped")
    }

    @MainActor
    public var isMonitoring: Bool {
        audioEngine?.isRunning == true
    }

    public func isStreamHealthy(maximumStall: TimeInterval = 3) -> Bool {
        store.isStreamHealthy(maximumStall: maximumStall)
    }

    public func beginDictation() throws {
        try store.beginRecording()
    }

    public func finishDictation(trimmingTrailingSilence: Bool = false) throws -> CapturedDictation {
        let capture = try store.finishRecording(
            trimmingTrailingSilence: trimmingTrailingSilence
        )
        guard capture.samples.count >= Self.sampleRate / 4 else {
            throw AudioCaptureError.recordingTooShort
        }
        return capture
    }

    public func cancelDictation() {
        store.cancelRecording()
    }

    public func recordingMetrics() -> RecordingMetrics {
        store.recordingMetrics()
    }

    public func droppedBufferCount() -> UInt64 {
        store.droppedBufferCount()
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return streamGeneration == generation
    }
}

private extension AVAudioFrameCount {
    var nextPowerOfTwo: AVAudioFrameCount {
        guard self > 1 else { return 1 }
        return 1 << (AVAudioFrameCount.bitWidth - (self - 1).leadingZeroBitCount)
    }
}

/// A small fixed pool used by the AVAudioEngine tap. Acquiring the pool lock is
/// nonblocking; under pressure a frame is dropped instead of ever stalling the
/// realtime audio callback.
private final class RealtimeAudioBufferPool: @unchecked Sendable {
    private let lock = NSLock()
    private var available: [AVAudioPCMBuffer] = []
    private let frameCapacity: AVAudioFrameCount

    init?(format: AVAudioFormat, frameCapacity: AVAudioFrameCount, count: Int) {
        guard frameCapacity > 0, count > 0 else { return nil }
        self.frameCapacity = frameCapacity
        available.reserveCapacity(count)
        for _ in 0..<count {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCapacity
            ) else { return nil }
            available.append(buffer)
        }
    }

    func acquireCopy(of source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard source.frameLength <= frameCapacity, lock.try() else { return nil }
        guard let destination = available.popLast() else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else {
            release(destination)
            return nil
        }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            guard
                let sourceData = sourceBuffer.mData,
                let destinationData = destinationBuffers[index].mData,
                sourceBuffer.mDataByteSize <= destinationBuffers[index].mDataByteSize
            else {
                release(destination)
                return nil
            }
            memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
            destinationBuffers[index].mDataByteSize = sourceBuffer.mDataByteSize
        }
        return destination
    }

    func release(_ buffer: AVAudioPCMBuffer) {
        buffer.frameLength = 0
        lock.lock()
        available.append(buffer)
        lock.unlock()
    }
}

private final class AudioBufferStore: @unchecked Sendable {
    private final class RecordingBuffer {
        var samples: [Float]

        init(reserving capacity: Int) {
            samples = []
            samples.reserveCapacity(capacity)
        }
    }

    private struct State {
        var totalSamples: UInt64 = 0
        var smoothedLevel: Float = 0
        var recentDecibels: [Float] = []
        var noiseFloorDecibels: Float = -60
        var recording: RecordingBuffer?
        var lastRecordingSpeechSample = 0
        var currentRecordingSpeechSamples = 0
        var maximumConsecutiveRecordingSpeechSamples = 0
        var recordingSpeechGuardSamplesRemaining = 0
        var lastAudioUptime: TimeInterval = 0
        var droppedBuffers: UInt64 = 0
    }

    private let lock = NSLock()
    private let sampleRate: Int
    private var state = State()

    init(sampleRate: Int) {
        self.sampleRate = sampleRate
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard
            buffer.format.commonFormat == .pcmFormatFloat32,
            let channel = buffer.floatChannelData?.pointee
        else { return }
        let sampleCount = Int(buffer.frameLength)
        guard sampleCount > 0 else { return }
        let samples = UnsafeBufferPointer(start: channel, count: sampleCount)

        var meanSquare: Float = 0
        vDSP_measqv(channel, 1, &meanSquare, vDSP_Length(sampleCount))
        let rms = sqrt(max(meanSquare, 0.000_000_1))
        let decibels = 20 * log10(rms)
        let normalizedLevel = min(max((decibels + 55) / 45, 0), 1)

        lock.lock()
        state.lastAudioUptime = ProcessInfo.processInfo.systemUptime

        let isInitialCalibration = state.totalSamples < UInt64(sampleRate * 2)
        let resemblesBackground = decibels < state.noiseFloorDecibels + 8
        if state.recording == nil, isInitialCalibration || resemblesBackground {
            state.recentDecibels.append(decibels)
            if state.recentDecibels.count > 50 {
                state.recentDecibels.removeFirst(state.recentDecibels.count - 50)
            }
            let sortedLevels = state.recentDecibels.sorted()
            state.noiseFloorDecibels = sortedLevels[sortedLevels.count / 5]
        } else if state.recording == nil {
            // A microphone/input-gain change can move the entire room floor
            // above the old threshold. Rise slowly enough to preserve the
            // beginning of speech, but converge on sustained HVAC, traffic or
            // fan noise.
            let bufferDuration = Float(sampleCount) / Float(sampleRate)
            let maximumRise = 1.2 * bufferDuration
            let targetFloor = decibels - 5
            state.noiseFloorDecibels += min(
                max(targetFloor - state.noiseFloorDecibels, 0),
                maximumRise
            )
        }

        let speechThreshold = min(max(state.noiseFloorDecibels + 9, -50), -27)
        let containsSpeech = decibels > speechThreshold
        state.smoothedLevel = (state.smoothedLevel * 0.72) + (normalizedLevel * 0.28)
        state.totalSamples += UInt64(sampleCount)

        if let recording = state.recording {
            let maximumSamples = sampleRate * Int(DictationPolicy.maximumRecordingDuration)
            let available = max(maximumSamples - recording.samples.count, 0)
            let acceptedCount = min(available, sampleCount)
            if acceptedCount > 0 {
                recording.samples.append(contentsOf: samples.prefix(acceptedCount))
                if containsSpeech {
                    state.lastRecordingSpeechSample = recording.samples.count
                }

                let guardSamples = min(
                    state.recordingSpeechGuardSamplesRemaining,
                    acceptedCount
                )
                state.recordingSpeechGuardSamplesRemaining -= guardSamples
                let eligibleSpeechSamples = acceptedCount - guardSamples
                if containsSpeech, eligibleSpeechSamples > 0 {
                    state.currentRecordingSpeechSamples += eligibleSpeechSamples
                    state.maximumConsecutiveRecordingSpeechSamples = max(
                        state.maximumConsecutiveRecordingSpeechSamples,
                        state.currentRecordingSpeechSamples
                    )
                } else if !containsSpeech {
                    state.currentRecordingSpeechSamples = 0
                }
            }
        }
        lock.unlock()
    }

    func markStreamStarted() {
        lock.lock()
        // Recalibrate the ambient floor for the current input route.
        state.totalSamples = 0
        state.smoothedLevel = 0
        state.recentDecibels.removeAll(keepingCapacity: true)
        state.noiseFloorDecibels = -60
        state.lastAudioUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    func markDroppedBuffer() {
        lock.lock()
        state.droppedBuffers &+= 1
        lock.unlock()
    }

    func isStreamHealthy(maximumStall: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - state.lastAudioUptime <= maximumStall
    }

    func beginRecording() throws {
        lock.lock()
        defer { lock.unlock() }
        guard state.recording == nil else {
            throw AudioCaptureError.recordingAlreadyActive
        }
        state.recording = RecordingBuffer(reserving: sampleRate * 90)
        state.lastRecordingSpeechSample = 0
        state.currentRecordingSpeechSamples = 0
        state.maximumConsecutiveRecordingSpeechSamples = 0
        state.recordingSpeechGuardSamplesRemaining = Int(
            DictationPolicy.postCueSpeechGuardDuration * Double(sampleRate)
        )
    }

    func finishRecording(trimmingTrailingSilence: Bool) throws -> CapturedDictation {
        lock.lock()
        defer { lock.unlock() }
        guard let recordingBuffer = state.recording else {
            throw AudioCaptureError.recordingNotActive
        }
        let recording = recordingBuffer.samples

        let finalRecording: [Float]
        if trimmingTrailingSilence {
            let retainedTail = sampleRate / 2
            let endIndex = min(state.lastRecordingSpeechSample + retainedTail, recording.count)
            finalRecording = Array(recording.prefix(endIndex))
        } else {
            finalRecording = recording
        }

        let containsSpeech = DictationPolicy.containsIntentionalSpeech(
            consecutiveSpeechSampleCount: state.maximumConsecutiveRecordingSpeechSamples,
            sampleRate: sampleRate
        )
        state.recording = nil
        state.lastRecordingSpeechSample = 0
        state.currentRecordingSpeechSamples = 0
        state.maximumConsecutiveRecordingSpeechSamples = 0
        state.recordingSpeechGuardSamplesRemaining = 0
        return CapturedDictation(samples: finalRecording, containsSpeech: containsSpeech)
    }

    func cancelRecording() {
        lock.lock()
        state.recording = nil
        state.lastRecordingSpeechSample = 0
        state.currentRecordingSpeechSamples = 0
        state.maximumConsecutiveRecordingSpeechSamples = 0
        state.recordingSpeechGuardSamplesRemaining = 0
        lock.unlock()
    }

    func recordingMetrics() -> RecordingMetrics {
        lock.lock()
        defer { lock.unlock() }
        let recordedCount = state.recording?.samples.count ?? 0
        let silentSamples = max(recordedCount - state.lastRecordingSpeechSample, 0)
        return RecordingMetrics(
            duration: Double(recordedCount) / Double(sampleRate),
            silenceDuration: Double(silentSamples) / Double(sampleRate),
            level: state.smoothedLevel
        )
    }

    func droppedBufferCount() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return state.droppedBuffers
    }

}
