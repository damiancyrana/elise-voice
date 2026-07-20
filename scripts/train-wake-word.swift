import CreateML
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Użycie: train-wake-word.swift DATA_DIR OUTPUT.mlmodel\n", stderr)
    exit(64)
}

let dataDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let trainingSource = MLSoundClassifier.DataSource.labeledDirectories(
    at: dataDirectory.appendingPathComponent("Train", isDirectory: true)
)
let validationSource = MLSoundClassifier.DataSource.labeledDirectories(
    at: dataDirectory.appendingPathComponent("Validation", isDirectory: true)
)

let parameters = MLSoundClassifier.ModelParameters(
    validation: .dataSource(validationSource),
    maxIterations: 75,
    overlapFactor: 0.5,
    algorithm: .transferLearning(
        featureExtractor: .audioFeaturePrint(type: .sound, revision: 1),
        classifier: .logisticRegressor
    ),
    featureExtractionTimeWindowSize: 1.0
)

print("Trening dedykowanego klasyfikatora ELISE…")
let classifier = try MLSoundClassifier(
    trainingData: trainingSource,
    parameters: parameters
)
let testingSource = MLSoundClassifier.DataSource.labeledDirectories(
    at: dataDirectory.appendingPathComponent("Test", isDirectory: true)
)
let testMetrics = classifier.evaluation(on: testingSource)

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try? FileManager.default.removeItem(at: outputURL)
try classifier.write(
    to: outputURL,
    metadata: MLModelMetadata(
        author: "Elise Voice",
        shortDescription: "Lokalny detektor wymowy ILIS, ILIZ i ELAJS.",
        license: "Private use",
        version: "1.1",
        additional: [
            "wakeWord": "ELISE",
            "positivePronunciations": "ILIS, ILIZ, ELAJS",
            "trainingData": "multi-voice-with-hard-negatives-and-over-air-calibration"
        ]
    )
)

print("Training: \(classifier.trainingMetrics)")
print("Validation: \(classifier.validationMetrics)")
print("Test: \(testMetrics)")
print(outputURL.path)
