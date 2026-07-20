@preconcurrency import AVFoundation
import CoreML
import Foundation
import OSLog
@preconcurrency import SoundAnalysis

public actor PersonalWakeWordVerifier {
    private let logger = Logger(
        subsystem: "com.elisevoice.app",
        category: "personal-wake"
    )
    private var model: MLModel?

    public init() {}

    /// Returns false when no personalized model has been bundled. The generic
    /// textual verifier remains available in that case.
    public func prepare(modelAt explicitModelURL: URL? = nil) throws -> Bool {
        let compiledURL = Bundle.main.url(
            forResource: "ElisePersonalWakeVerifier",
            withExtension: "mlmodelc"
        )
        let sourceURL = Bundle.main.url(
            forResource: "ElisePersonalWakeVerifier",
            withExtension: "mlmodel"
        )
        let modelURL: URL
        if let explicitModelURL, explicitModelURL.pathExtension == "mlmodelc" {
            modelURL = explicitModelURL
        } else if let explicitModelURL {
            modelURL = try MLModel.compileModel(at: explicitModelURL)
        } else if let compiledURL {
            modelURL = compiledURL
        } else if let sourceURL {
            modelURL = try MLModel.compileModel(at: sourceURL)
        } else {
            model = nil
            return false
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let loadedModel = try MLModel(contentsOf: modelURL, configuration: configuration)
        let probe = try SNClassifySoundRequest(mlModel: loadedModel)
        guard probe.knownClassifications.contains("elise") else {
            throw WakeWordDetectorError.modelHasUnexpectedLabels
        }
        model = loadedModel
        logger.info("Personal acoustic wake verifier loaded")
        return true
    }

    public func verify(samples: [Float]) async throws -> Bool {
        guard let model,
              let alignedSamples = PersonalWakeWordAudioNormalizer.alignedWindow(
                  from: samples
              ) else { return false }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(AudioCaptureService.sampleRate),
            channels: 1,
            interleaved: false
        ) else { return false }

        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(mlModel: model)
        request.windowDuration = CMTime(seconds: 1, preferredTimescale: 1_000)
        request.overlapFactor = 0

        let accepted = try await withCheckedThrowingContinuation { continuation in
            let observer = PersonalVerificationObserver(
                analyzer: analyzer,
                continuation: continuation
            )
            do {
                try analyzer.add(request, withObserver: observer)
                let chunkSize = AVAudioFrameCount(1_280)
                var offset = 0
                var framePosition: AVAudioFramePosition = 0
                while offset < alignedSamples.count {
                    let count = min(Int(chunkSize), alignedSamples.count - offset)
                    guard let buffer = AVAudioPCMBuffer(
                        pcmFormat: format,
                        frameCapacity: AVAudioFrameCount(count)
                    ), let channel = buffer.floatChannelData?.pointee else {
                        observer.finish(.success(false))
                        return
                    }
                    buffer.frameLength = AVAudioFrameCount(count)
                    alignedSamples.withUnsafeBufferPointer { source in
                        channel.update(
                            from: source.baseAddress!.advanced(by: offset),
                            count: count
                        )
                    }
                    analyzer.analyze(buffer, atAudioFramePosition: framePosition)
                    offset += count
                    framePosition += AVAudioFramePosition(count)
                }
                analyzer.completeAnalysis()

                Task {
                    try? await Task.sleep(for: .seconds(2))
                    observer.finish(.success(false))
                }
            } catch {
                observer.finish(.failure(error))
            }
        }
        logger.info("Personal acoustic verification accepted: \(accepted, privacy: .public)")
        return accepted
    }
}

private final class PersonalVerificationObserver: NSObject, SNResultsObserving,
    @unchecked Sendable {
    private let lock = NSLock()
    private var accepted = false
    private var didFinish = false
    private var continuation: CheckedContinuation<Bool, any Error>?
    // SoundAnalysis may finish asynchronously after verify() has fed all data.
    // Retain the analyzer until the callback completes.
    private var analyzer: SNAudioStreamAnalyzer?

    init(
        analyzer: SNAudioStreamAnalyzer,
        continuation: CheckedContinuation<Bool, any Error>
    ) {
        self.analyzer = analyzer
        self.continuation = continuation
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let confidence = result.classification(forIdentifier: "elise")?.confidence ?? 0
        lock.lock()
        if confidence >= PersonalWakeWordAudioPolicy.acceptanceConfidence {
            accepted = true
        }
        lock.unlock()
    }

    func request(_ request: SNRequest, didFailWithError error: any Error) {
        finish(.failure(error))
    }

    func requestDidComplete(_ request: SNRequest) {
        lock.lock()
        let result = accepted
        lock.unlock()
        finish(.success(result))
    }

    func finish(_ result: Result<Bool, any Error>) {
        lock.lock()
        guard !didFinish, let continuation else {
            lock.unlock()
            return
        }
        didFinish = true
        self.continuation = nil
        analyzer = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
