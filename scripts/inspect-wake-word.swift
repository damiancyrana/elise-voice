import CoreML
import Foundation
import SoundAnalysis

final class Observer: NSObject, SNResultsObserving {
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let confidence = result.classification(forIdentifier: "elise")?.confidence ?? 0
        print(String(format: "%.3f\t%.3f", result.timeRange.start.seconds, confidence))
    }

    func request(_ request: SNRequest, didFailWithError error: any Error) {
        fputs("SoundAnalysis: \(error.localizedDescription)\n", stderr)
    }
}

guard CommandLine.arguments.count == 3 else {
    fputs("Użycie: inspect-wake-word.swift MODEL.mlmodel AUDIO.wav\n", stderr)
    exit(64)
}

let compiled = try MLModel.compileModel(
    at: URL(fileURLWithPath: CommandLine.arguments[1])
)
let model = try MLModel(contentsOf: compiled)
let analyzer = try SNAudioFileAnalyzer(
    url: URL(fileURLWithPath: CommandLine.arguments[2])
)
let request = try SNClassifySoundRequest(mlModel: model)
request.windowDuration = CMTime(seconds: 1, preferredTimescale: 1_000)
request.overlapFactor = 0.75
let observer = Observer()
try analyzer.add(request, withObserver: observer)
analyzer.analyze()
