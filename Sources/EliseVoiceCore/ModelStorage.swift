import Foundation
import OSLog

public enum ModelStorageError: LocalizedError {
    case insufficientDiskSpace(requiredGigabytes: Int)

    public var errorDescription: String? {
        switch self {
        case let .insufficientDiskSpace(requiredGigabytes):
            "Za mało miejsca na model — potrzeba co najmniej \(requiredGigabytes) GB"
        }
    }
}

/// Where the transcription model lives and whether it can be loaded without
/// contacting Hugging Face.
public struct TranscriptionModelLocation: Sendable {
    /// Root directory handed to WhisperKit as its download base.
    public let downloadBase: URL
    /// Set only when the model and its tokenizer are already complete on disk.
    /// WhisperKit then loads straight from this folder instead of querying the
    /// Hub for every model file on each launch.
    public let localModelFolder: URL?

    public var canStartOffline: Bool { localModelFolder != nil }
}

public enum ModelStorage {
    private static let logger = Logger(subsystem: "com.elisevoice.app", category: "model")
    private static let minimumFreeSpace: Int64 = 1_500_000_000
    /// Tokenizer repository WhisperKit resolves for the Large v3 variant. It is
    /// stored next to the model and must be present for an offline start.
    private static let tokenizerRepository = "openai/whisper-large-v3"

    public static func directory() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appendingPathComponent("EliseVoice", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    public static func prepareForTranscriptionModel(
        named modelName: String
    ) throws -> TranscriptionModelLocation {
        let root = try directory()
        let model = transcriptionModelDirectory(root: root, modelName: modelName)
        // Validation walks the whole model directory, so it runs once per launch
        // and the result is reused for both the quarantine and the space check.
        var modelIsComplete = isValidTranscriptionModel(at: model)

        if FileManager.default.fileExists(atPath: model.path), !modelIsComplete {
            let quarantine = root
                .appendingPathComponent("Quarantine", isDirectory: true)
                .appendingPathComponent("\(model.lastPathComponent)-incomplete-\(Int(Date().timeIntervalSince1970))")
            try FileManager.default.createDirectory(
                at: quarantine.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: model, to: quarantine)
            logger.notice("Moved incomplete transcription model to quarantine")
            modelIsComplete = false
        }
        if !modelIsComplete {
            try requireDownloadSpace(at: root)
        }

        // Loading offline also needs the tokenizer; without it WhisperKit would
        // fall back to the Hub and fail whenever the network is unavailable.
        let startsOffline = modelIsComplete && hasLocalTokenizer(root: root)
        return TranscriptionModelLocation(
            downloadBase: root,
            localModelFolder: startsOffline ? model : nil
        )
    }

    public static func markTranscriptionModelReady(named modelName: String) throws {
        let root = try directory()
        let model = transcriptionModelDirectory(root: root, modelName: modelName)
        guard isValidTranscriptionModel(at: model) else { return }
        let marker: [String: Any] = [
            "model": modelName,
            "validatedAt": ISO8601DateFormatter().string(from: Date()),
            "schemaVersion": 1
        ]
        let data = try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys])
        let markerURL = root.appendingPathComponent("model-ready.json")
        let temporaryURL = root.appendingPathComponent("model-ready.json.tmp")
        try data.write(to: temporaryURL, options: .atomic)
        if FileManager.default.fileExists(atPath: markerURL.path) {
            _ = try FileManager.default.replaceItemAt(
                markerURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: markerURL)
        }
    }

    public static func removeLegacyWakeWordModels() throws {
        let root = try directory()
        let candidates = [
            root.appendingPathComponent("models/openai/whisper-tiny", isDirectory: true),
            root.appendingPathComponent(
                "models/argmaxinc/whisperkit-coreml/openai_whisper-tiny",
                isDirectory: true
            ),
            root.appendingPathComponent(
                "models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/openai_whisper-tiny",
                isDirectory: true
            )
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            try FileManager.default.removeItem(at: candidate)
            logger.notice("Removed legacy Whisper Tiny wake model")
        }
    }

    private static func hasLocalTokenizer(root: URL) -> Bool {
        let tokenizer = root
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(tokenizerRepository, isDirectory: true)
            .appendingPathComponent("tokenizer.json")
        return FileManager.default.fileExists(atPath: tokenizer.path)
    }

    private static func transcriptionModelDirectory(root: URL, modelName: String) -> URL {
        root.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml/openai_whisper-\(modelName)",
            isDirectory: true
        )
    }

    private static func isValidTranscriptionModel(at directory: URL) -> Bool {
        let required = [
            "config.json",
            "AudioEncoder.mlmodelc/coremldata.bin",
            "MelSpectrogram.mlmodelc/coremldata.bin",
            "TextDecoder.mlmodelc/coremldata.bin"
        ]
        guard required.allSatisfy({ component in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(component).path
            )
        }) else { return false }

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            totalSize += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return totalSize > 450_000_000
    }

    private static func requireDownloadSpace(at directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        guard available >= minimumFreeSpace else {
            throw ModelStorageError.insufficientDiskSpace(requiredGigabytes: 2)
        }
    }
}
