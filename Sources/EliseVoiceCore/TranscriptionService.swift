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

        let location = try ModelStorage.prepareForTranscriptionModel(named: Self.modelName)
        // Pointing WhisperKit at the local folder keeps the launch entirely
        // offline. Without it every launch asks Hugging Face about each model
        // file, which fails outright when the app starts before the network is
        // up — for example right after waking or booting the machine.
        let config = WhisperKitConfig(
            model: Self.modelName,
            downloadBase: location.downloadBase,
            modelFolder: location.localModelFolder?.path,
            computeOptions: ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: !location.canStartOffline
        )
        whisperKit = try await WhisperKit(config)
        try ModelStorage.markTranscriptionModelReady(named: Self.modelName)
        logger.info(
            "Transcription model ready in \(ProcessInfo.processInfo.systemUptime - startedAt, format: .fixed(precision: 2)) seconds, offline start: \(location.canStartOffline, privacy: .public)"
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
