@preconcurrency import AVFoundation
import CoreML
import Foundation
import OSLog
@preconcurrency import SoundAnalysis

public enum WakeWordDetectorError: LocalizedError {
    case modelMissing
    case modelHasUnexpectedLabels

    public var errorDescription: String? {
        switch self {
        case .modelMissing:
            "Brakuje lokalnego modelu wybudzania ELISE"
        case .modelHasUnexpectedLabels:
            "Model wybudzania ELISE ma nieprawidłowe etykiety"
        }
    }
}

public enum WakeWordAnalysisPolicy {
    /// Personalized A/B testing retained 80% overlap for short ILIS/ELAJS recall. The
    /// acoustic activity gate below prevents this higher overlap from running
    /// continuously through silence.
    public static let overlapFactor = 0.80
    public static let windowDuration: TimeInterval = 1
    public static let preRollDuration: TimeInterval = 0.56
    public static let activityTailDuration: TimeInterval = 1.25
}

public final class WakeWordDetector: NSObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.elisevoice.app", category: "wake")
    private let analysisQueue = DispatchQueue(
        label: "com.elisevoice.wake-analysis",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private let pendingAnalyses = DispatchSemaphore(value: 3)

    private var model: MLModel?
    private var analyzer: SNAudioStreamAnalyzer?
    private var request: SNClassifySoundRequest?
    private var gate = WakeWordDecisionGate()
    private var detectionHandler: (@Sendable () -> Void)?
    private var enabled = false
    private var generation: UInt64 = 0
    private var lastDebugLogTime = -TimeInterval.infinity

    // Accessed exclusively from analysisQueue.
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollFrames: AVAudioFramePosition = 0
    private var analysisActiveUntil: AVAudioFramePosition = 0
    private var nextAnalysisFramePosition: AVAudioFramePosition = 0

    public override init() {
        super.init()
    }

    public func prepare(onDetection: @escaping @Sendable () -> Void) throws {
        let compiledModelURL = Bundle.main.url(
            forResource: "EliseWakeWord",
            withExtension: "mlmodelc"
        )
        let sourceModelURL = Bundle.main.url(
            forResource: "EliseWakeWord",
            withExtension: "mlmodel"
        )
        let modelURL: URL
        if let compiledModelURL {
            modelURL = compiledModelURL
        } else if let sourceModelURL {
            modelURL = try MLModel.compileModel(at: sourceModelURL)
        } else {
            throw WakeWordDetectorError.modelMissing
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let loadedModel = try MLModel(contentsOf: modelURL, configuration: configuration)
        let probeRequest = try SNClassifySoundRequest(mlModel: loadedModel)
        guard
            probeRequest.knownClassifications.contains("elise"),
            probeRequest.knownClassifications.contains("background")
        else {
            throw WakeWordDetectorError.modelHasUnexpectedLabels
        }

        stateLock.lock()
        model = loadedModel
        detectionHandler = onDetection
        stateLock.unlock()
        logger.info("Dedicated ELISE keyword model loaded")
    }

    public func start(format: AVAudioFormat) throws {
        try analysisQueue.sync {
            stateLock.lock()
            guard let model else {
                stateLock.unlock()
                throw WakeWordDetectorError.modelMissing
            }
            generation &+= 1
            let currentGeneration = generation
            gate.reset()
            stateLock.unlock()

            analyzer?.completeAnalysis()
            analyzer?.removeAllRequests()

            let analyzer = SNAudioStreamAnalyzer(format: format)
            let request = try SNClassifySoundRequest(mlModel: model)
            request.windowDuration = CMTime(
                seconds: WakeWordAnalysisPolicy.windowDuration,
                preferredTimescale: 1_000
            )
            request.overlapFactor = WakeWordAnalysisPolicy.overlapFactor
            try analyzer.add(request, withObserver: self)

            preRoll.removeAll(keepingCapacity: true)
            preRollFrames = 0
            analysisActiveUntil = 0
            nextAnalysisFramePosition = 0

            stateLock.lock()
            guard generation == currentGeneration else {
                stateLock.unlock()
                return
            }
            self.analyzer = analyzer
            self.request = request
            stateLock.unlock()
        }
    }

    public func setEnabled(_ enabled: Bool) {
        stateLock.lock()
        self.enabled = enabled
        if !enabled { gate.reset() }
        let currentGeneration = generation
        stateLock.unlock()

        if !enabled {
            analysisQueue.async { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                let isCurrent = self.generation == currentGeneration
                self.stateLock.unlock()
                guard isCurrent else { return }
                self.preRoll.removeAll(keepingCapacity: true)
                self.preRollFrames = 0
                self.analysisActiveUntil = 0
                self.nextAnalysisFramePosition = 0
            }
        }
    }

    public func analyze(
        _ buffer: AVAudioPCMBuffer,
        at framePosition: AVAudioFramePosition,
        hasAcousticActivity: Bool = true
    ) {
        stateLock.lock()
        let shouldAnalyze = enabled && analyzer != nil
        let currentGeneration = generation
        stateLock.unlock()
        guard shouldAnalyze, pendingAnalyses.wait(timeout: .now()) == .success else { return }

        analysisQueue.async { [weak self] in
            guard let self else { return }
            defer { self.pendingAnalyses.signal() }

            self.stateLock.lock()
            let analyzer = self.generation == currentGeneration ? self.analyzer : nil
            let enabled = self.enabled
            self.stateLock.unlock()
            guard enabled, let analyzer else { return }

            let tailFrames = AVAudioFramePosition(
                buffer.format.sampleRate * WakeWordAnalysisPolicy.activityTailDuration
            )
            let maximumPreRollFrames = AVAudioFramePosition(
                buffer.format.sampleRate * WakeWordAnalysisPolicy.preRollDuration
            )
            let wasInactive = framePosition >= self.analysisActiveUntil

            if !hasAcousticActivity, wasInactive {
                self.preRoll.append(buffer)
                self.preRollFrames += AVAudioFramePosition(buffer.frameLength)
                while self.preRollFrames > maximumPreRollFrames,
                      let oldest = self.preRoll.first {
                    self.preRollFrames -= AVAudioFramePosition(oldest.frameLength)
                    self.preRoll.removeFirst()
                }
                return
            }

            if hasAcousticActivity {
                self.analysisActiveUntil = max(
                    self.analysisActiveUntil,
                    framePosition + AVAudioFramePosition(buffer.frameLength) + tailFrames
                )
            }

            if wasInactive {
                for frame in self.preRoll {
                    analyzer.analyze(
                        frame,
                        atAudioFramePosition: self.nextAnalysisFramePosition
                    )
                    self.nextAnalysisFramePosition += AVAudioFramePosition(frame.frameLength)
                }
                self.preRoll.removeAll(keepingCapacity: true)
                self.preRollFrames = 0
            }
            analyzer.analyze(
                buffer,
                atAudioFramePosition: self.nextAnalysisFramePosition
            )
            self.nextAnalysisFramePosition += AVAudioFramePosition(buffer.frameLength)
        }
    }

    public func stop() {
        stateLock.lock()
        enabled = false
        generation &+= 1
        gate.reset()
        stateLock.unlock()

        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.analyzer?.completeAnalysis()
            self.analyzer?.removeAllRequests()
            self.preRoll.removeAll(keepingCapacity: true)
            self.preRollFrames = 0
            self.analysisActiveUntil = 0
            self.nextAnalysisFramePosition = 0
            self.stateLock.lock()
            self.analyzer = nil
            self.request = nil
            self.stateLock.unlock()
        }
    }
}

extension WakeWordDetector: SNResultsObserving {
    public func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let confidence = result.classification(forIdentifier: "elise")?.confidence ?? 0
        let background = result.classification(forIdentifier: "background")?.confidence ?? 0
        let now = ProcessInfo.processInfo.systemUptime

        stateLock.lock()
        let shouldLog = confidence >= WakeWordDecisionGate.supportingThreshold
            || now - lastDebugLogTime >= 1
        if shouldLog { lastDebugLogTime = now }
        let detected = enabled && gate.consume(
            confidence: confidence,
            backgroundConfidence: background,
            at: now
        )
        let handler = detected ? detectionHandler : nil
        stateLock.unlock()

        if shouldLog {
            logger.debug(
                "Keyword window — ELISE: \(confidence, format: .fixed(precision: 3)), background: \(background, format: .fixed(precision: 3))"
            )
        }

        if detected {
            logger.info("ELISE keyword detected, confidence: \(confidence, format: .fixed(precision: 3))")
            handler?()
        }
    }

    public func request(_ request: SNRequest, didFailWithError error: any Error) {
        logger.error("Keyword analysis failed: \(error.localizedDescription, privacy: .public)")
    }

    public func requestDidComplete(_ request: SNRequest) {}
}
