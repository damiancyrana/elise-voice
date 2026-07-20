import AVFoundation
import CoreML
import Foundation
import SoundAnalysis

final class Observer: NSObject, SNResultsObserving {
    var maximumEliseConfidence = 0.0
    var detected = false
    var scores: [Double] = []
    private var gate = OfflineWakeWordGate()
    private let completion = DispatchSemaphore(value: 0)

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let elise = result.classification(forIdentifier: "elise")?.confidence ?? 0
        let background = result.classification(forIdentifier: "background")?.confidence ?? 0
        maximumEliseConfidence = max(maximumEliseConfidence, elise)
        scores.append(elise)
        let time = CMTimeGetSeconds(result.timeRange.start)
        detected = detected || gate.consume(
            confidence: elise,
            backgroundConfidence: background,
            at: time
        )
    }

    func request(_ request: SNRequest, didFailWithError error: any Error) {
        fputs("SoundAnalysis: \(error.localizedDescription)\n", stderr)
        completion.signal()
    }

    func requestDidComplete(_ request: SNRequest) {
        completion.signal()
    }

    func waitForCompletion() {
        _ = completion.wait(timeout: .now() + 10)
    }
}

/// Mirrors WakeWordDecisionGate. The offline check evaluates the same temporal
/// decision as the live app instead of accepting a single maximum score.
private struct OfflineWakeWordGate {
    private var previousConfidence: Double?
    private var previousWindowTime: TimeInterval?
    private var recentStrongEvidence: (confidence: Double, time: TimeInterval)?
    private var lastDetectionTime = -TimeInterval.infinity

    mutating func consume(
        confidence: Double,
        backgroundConfidence: Double,
        at time: TimeInterval
    ) -> Bool {
        guard time - lastDetectionTime >= 2.5 else { return false }
        if let previousWindowTime, time - previousWindowTime > 0.75 {
            previousConfidence = nil
            self.previousWindowTime = nil
        }
        if let evidence = recentStrongEvidence, time - evidence.time > 1.5 {
            recentStrongEvidence = nil
        }
        let adjacent = confidence >= 0.05
            && previousConfidence.map { $0 >= 0.05 && $0 + confidence >= 0.95 } == true
        let spacedStrong = confidence >= 0.70
            && recentStrongEvidence.map {
                time - $0.time <= 1.5 && $0.confidence + confidence >= 1.50
            } == true
        if adjacent || spacedStrong {
            lastDetectionTime = time
            previousConfidence = nil
            previousWindowTime = nil
            recentStrongEvidence = nil
            return true
        }
        previousConfidence = confidence >= 0.05 ? confidence : nil
        previousWindowTime = time
        if confidence >= 0.70 {
            recentStrongEvidence = (confidence, time)
        }
        return false
    }
}

guard CommandLine.arguments.count == 3 else {
    fputs("Użycie: check-wake-word.swift MODEL.mlmodel TEST_DIR\n", stderr)
    exit(64)
}

let sourceModel = URL(fileURLWithPath: CommandLine.arguments[1])
let testDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let compiledModel = try MLModel.compileModel(at: sourceModel)
let configuration = MLModelConfiguration()
configuration.computeUnits = .all
let model = try MLModel(contentsOf: compiledModel, configuration: configuration)
let manager = FileManager.default
let overlap = ProcessInfo.processInfo.environment["ELISE_WAKE_OVERLAP"]
    .flatMap(Double.init) ?? 0.80
guard (0...1).contains(overlap) else {
    fputs("ELISE_WAKE_OVERLAP musi należeć do zakresu 0...1\n", stderr)
    exit(64)
}

func score(_ file: URL) throws -> (maximum: Double, detected: Bool, scores: [Double]) {
    let audioFile = try AVAudioFile(forReading: file)
    let format = audioFile.processingFormat
    let analyzer = SNAudioStreamAnalyzer(format: format)
    let request = try SNClassifySoundRequest(mlModel: model)
    request.windowDuration = CMTime(seconds: 1, preferredTimescale: 1_000)
    request.overlapFactor = overlap
    let observer = Observer()
    try analyzer.add(request, withObserver: observer)

    let chunkFrames = AVAudioFrameCount(max(format.sampleRate * 0.08, 1))
    var framePosition: AVAudioFramePosition = 0

    func analyzeSilence(duration: TimeInterval) throws {
        var remaining = AVAudioFramePosition(format.sampleRate * duration)
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(chunkFrames)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            buffer.frameLength = count
            if let channels = buffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    channels[channel].initialize(repeating: 0, count: Int(count))
                }
            }
            analyzer.analyze(buffer, atAudioFramePosition: framePosition)
            framePosition += AVAudioFramePosition(count)
            remaining -= AVAudioFramePosition(count)
        }
    }

    try analyzeSilence(duration: 0.56)
    while audioFile.framePosition < audioFile.length {
        let remaining = audioFile.length - audioFile.framePosition
        let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(chunkFrames)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try audioFile.read(into: buffer, frameCount: count)
        analyzer.analyze(buffer, atAudioFramePosition: framePosition)
        framePosition += AVAudioFramePosition(buffer.frameLength)
    }
    try analyzeSilence(duration: 1.25)
    analyzer.completeAnalysis()
    observer.waitForCompletion()
    return (observer.maximumEliseConfidence, observer.detected, observer.scores)
}

let labels = try manager.contentsOfDirectory(
    at: testDirectory,
    includingPropertiesForKeys: [.isDirectoryKey]
).filter {
    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
}.map(\.lastPathComponent).sorted()

var truePositives = 0
var falseNegatives = 0
var trueNegatives = 0
var falsePositives = 0
var analyzedNegativeDuration: TimeInterval = 0
for label in labels {
    let directory = testDirectory.appendingPathComponent(label, isDirectory: true)
    let files = try manager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "wav" }
    for file in files {
        if label != "elise" {
            let audioFile = try AVAudioFile(forReading: file)
            analyzedNegativeDuration += Double(audioFile.length) / audioFile.processingFormat.sampleRate
                + 0.56 + 1.25
        }
        let result = try score(file)
        let predictedPositive = result.detected
        if label == "elise" {
            predictedPositive ? (truePositives += 1) : (falseNegatives += 1)
        } else {
            predictedPositive ? (falsePositives += 1) : (trueNegatives += 1)
        }
        let scoreDetails = ProcessInfo.processInfo.environment["ELISE_WAKE_VERBOSE"] == "1"
            ? "\t" + result.scores.map { String(format: "%.3f", $0) }.joined(separator: ",")
            : ""
        print("\(label)\t\(String(format: "%.3f", result.maximum))\t\(predictedPositive ? "wake" : "background")\t\(file.lastPathComponent)\(scoreDetails)")
    }
}

let positives = truePositives + falseNegatives
let negatives = trueNegatives + falsePositives
let recall = positives > 0 ? Double(truePositives) / Double(positives) : 0
let falsePositiveRate = negatives > 0 ? Double(falsePositives) / Double(negatives) : 1
print("Recall: \(String(format: "%.1f%%", recall * 100))")
print("False-positive rate: \(String(format: "%.1f%%", falsePositiveRate * 100))")
let falseActivationsPerHour = analyzedNegativeDuration > 0
    ? Double(falsePositives) * 3_600 / analyzedNegativeDuration
    : .infinity
print("Adversarial synthetic activations/hour: \(String(format: "%.2f", falseActivationsPerHour))")
print("Overlap: \(String(format: "%.2f", overlap))")
// This corpus intentionally consists mostly of confusable commands such as
// “Lis”, “Elisa”, “Idź” and “Dziękuję”; its FPR is not an ambient false-wake
// rate. These gates are regression budgets for this adversarial set. Personal
// calibration and long-form ambient soak remain separate release checks.
// Two adjacent windows deliberately trade some synthetic cross-voice recall
// for a much lower error rate on this unusually difficult set. A personalized
// microphone corpus is the supported path to higher per-user recall.
guard recall >= 0.75, falsePositiveRate <= 0.15 else { exit(1) }
