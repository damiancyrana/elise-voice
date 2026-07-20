import Foundation
import OSLog
import WhisperKit

public actor TranscriptionService {
    public static let modelName = "large-v3-v20240930_626MB"

    private var whisperKit: WhisperKit?
    private let logger = Logger(subsystem: "com.elisevoice.app", category: "transcription")
    private let concurrentWorkerCount: Int

    public init(concurrentWorkerCount: Int = 3) {
        self.concurrentWorkerCount = min(max(concurrentWorkerCount, 1), 4)
    }

    public func prepare() async throws {
        guard whisperKit == nil else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime

        let modelDirectory = try ModelStorage.prepareForTranscriptionModel(named: Self.modelName)
        let config = WhisperKitConfig(
            model: Self.modelName,
            downloadBase: modelDirectory,
            computeOptions: ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        whisperKit = try await WhisperKit(config)
        try ModelStorage.markTranscriptionModelReady(named: Self.modelName)
        logger.info(
            "Transcription model ready in \(ProcessInfo.processInfo.systemUptime - startedAt, format: .fixed(precision: 2)) seconds"
        )
    }

    public func releaseModelForMemoryPressure() {
        whisperKit = nil
        logger.notice("Transcription model released after critical memory pressure")
    }

    public func transcribe(fileAt url: URL) async throws -> String {
        guard let whisperKit else {
            throw TranscriptionError.modelNotReady
        }

        let results = try await whisperKit.transcribe(
            audioPath: url.path,
            decodeOptions: decodingOptions
        )

        return TranscriptFormatter.join(results.map { $0.text })
    }

    public func transcribe(samples: [Float]) async throws -> String {
        guard let whisperKit else {
            throw TranscriptionError.modelNotReady
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let signpostID = PerformanceDiagnostics.signposter.makeSignpostID()
        let signpostState = PerformanceDiagnostics.signposter.beginInterval(
            "Transcription",
            id: signpostID,
            "samples=\(samples.count, privacy: .public) workers=\(self.concurrentWorkerCount, privacy: .public)"
        )
        defer {
            PerformanceDiagnostics.signposter.endInterval(
                "Transcription",
                signpostState
            )
        }
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: decodingOptions
        )
        logger.info(
            "Transcription completed in \(ProcessInfo.processInfo.systemUptime - startedAt, format: .fixed(precision: 2)) seconds for \(samples.count) samples"
        )
        return TranscriptFormatter.join(results.map { $0.text })
    }

    /// Confirms a candidate proposed by the tiny keyword classifier. This is
    /// intentionally invoked only for candidates, never continuously.
    public func verifyWakeWord(samples: [Float]) async throws -> Bool {
        guard let whisperKit else {
            throw TranscriptionError.modelNotReady
        }
        guard !samples.isEmpty else { return false }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let signpostID = PerformanceDiagnostics.signposter.makeSignpostID()
        let signpostState = PerformanceDiagnostics.signposter.beginInterval(
            "Verify wake word",
            id: signpostID,
            "samples=\(samples.count, privacy: .public)"
        )
        defer {
            PerformanceDiagnostics.signposter.endInterval(
                "Verify wake word",
                signpostState
            )
        }

        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: wakeWordDecodingOptions
        )
        let accepted = WakeWordTranscriptMatcher.matches(
            TranscriptFormatter.join(results.map { $0.text })
        )
        logger.info(
            "Wake-word verification completed in \(ProcessInfo.processInfo.systemUptime - startedAt, format: .fixed(precision: 2)) seconds; accepted: \(accepted, privacy: .public)"
        )
        return accepted
    }

    public func verifyWakeWord(fileAt url: URL) async throws -> Bool {
        WakeWordTranscriptMatcher.matches(
            try await wakeWordTranscript(fileAt: url)
        )
    }

    /// Developer-only calibration helper. The app itself never logs or
    /// persists this text.
    public func wakeWordTranscript(fileAt url: URL) async throws -> String {
        guard let whisperKit else {
            throw TranscriptionError.modelNotReady
        }
        let results = try await whisperKit.transcribe(
            audioPath: url.path,
            decodeOptions: wakeWordDecodingOptions
        )
        return TranscriptFormatter.join(results.map { $0.text })
    }

    private var decodingOptions: DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "pl",
            temperature: 0,
            temperatureFallbackCount: 5,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            suppressBlank: true,
            concurrentWorkerCount: concurrentWorkerCount,
            chunkingStrategy: .vad
        )
    }

    private var wakeWordDecodingOptions: DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0,
            temperatureFallbackCount: 1,
            sampleLength: 24,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            suppressBlank: true,
            concurrentWorkerCount: 1,
            chunkingStrategy: ChunkingStrategy.none
        )
    }
}

public enum TranscriptionError: LocalizedError {
    case modelNotReady
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .modelNotReady:
            "Model rozpoznawania mowy nie jest gotowy"
        case .cancelled:
            "Poprzednia transkrypcja została anulowana"
        }
    }
}
