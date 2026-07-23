import EliseVoiceCore
import Darwin
import Foundation

@main
enum EliseVoiceASRCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data(
                "Użycie: EliseVoiceASRCheck <audio>\n".utf8
            ))
            Darwin.exit(2)
        }

        let configuredWorkers = ProcessInfo.processInfo.environment["ELISE_ASR_WORKERS"]
            .flatMap(Int.init) ?? 3
        let service = TranscriptionService(concurrentWorkerCount: configuredWorkers)
        try await service.prepare()
        let text = try await service.transcribe(
            fileAt: URL(fileURLWithPath: CommandLine.arguments[1])
        )
        FileHandle.standardOutput.write(Data(text.utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
