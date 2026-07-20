import EliseVoiceCore
import AVFoundation
import Darwin
import Foundation

@main
enum EliseVoiceASRCheck {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else {
            FileHandle.standardError.write(Data(
                "Użycie: EliseVoiceASRCheck <audio> | --verify-wake <audio...> | --verify-personal-wake MODEL DATA_DIR\n".utf8
            ))
            Darwin.exit(2)
        }

        if CommandLine.arguments[1] == "--verify-personal-wake" {
            guard CommandLine.arguments.count == 4 else { Darwin.exit(2) }
            try await verifyPersonalWakeWord(
                modelPath: CommandLine.arguments[2],
                dataPath: CommandLine.arguments[3]
            )
            return
        }

        let configuredWorkers = ProcessInfo.processInfo.environment["ELISE_ASR_WORKERS"]
            .flatMap(Int.init) ?? 3
        let service = TranscriptionService(concurrentWorkerCount: configuredWorkers)
        try await service.prepare()

        if CommandLine.arguments[1] == "--verify-wake" {
            guard CommandLine.arguments.count >= 3 else { Darwin.exit(2) }
            for path in CommandLine.arguments.dropFirst(2) {
                let accepted = try await service.verifyWakeWord(
                    fileAt: URL(fileURLWithPath: path)
                )
                FileHandle.standardOutput.write(
                    Data("\(accepted ? "accepted" : "rejected")\t\(URL(fileURLWithPath: path).lastPathComponent)\n".utf8)
                )
            }
            return
        }

        if CommandLine.arguments[1] == "--inspect-wake" {
            guard CommandLine.arguments.count >= 3 else { Darwin.exit(2) }
            for path in CommandLine.arguments.dropFirst(2) {
                let transcript = try await service.wakeWordTranscript(
                    fileAt: URL(fileURLWithPath: path)
                )
                FileHandle.standardOutput.write(
                    Data("\(transcript)\t\(URL(fileURLWithPath: path).lastPathComponent)\n".utf8)
                )
            }
            return
        }

        let text = try await service.transcribe(
            fileAt: URL(fileURLWithPath: CommandLine.arguments[1])
        )
        FileHandle.standardOutput.write(Data(text.utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func verifyPersonalWakeWord(
        modelPath: String,
        dataPath: String
    ) async throws {
        let verifier = PersonalWakeWordVerifier()
        guard try await verifier.prepare(
            modelAt: URL(fileURLWithPath: modelPath)
        ) else {
            Darwin.exit(1)
        }

        let root = URL(fileURLWithPath: dataPath, isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.path < $1.path }
        var correct = 0
        for file in files {
            let expected = file.deletingLastPathComponent().lastPathComponent == "elise"
            let samples = try readMonoSamples(from: file)
            // Exercise the production normalizer with realistic rolling-buffer
            // context instead of passing an already aligned clip directly.
            let context = [Float](repeating: 0, count: 9_600)
                + samples
                + [Float](repeating: 0, count: 6_720)
            let accepted = try await verifier.verify(samples: context)
            if accepted == expected { correct += 1 }
            print(
                "\(accepted ? "wake" : "background")\t\(expected ? "elise" : "background")\t\(file.lastPathComponent)"
            )
        }
        print("Personal verifier: \(correct)/\(files.count)")
        guard !files.isEmpty, correct == files.count else { Darwin.exit(1) }
    }

    private static func readMonoSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount == 1,
              abs(format.sampleRate - Double(AudioCaptureService.sampleRate)) < 1 else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?.pointee else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
