import AVFoundation
import EliseVoiceCore
import Foundation

@MainActor
enum ReadyCuePlayer {
    private static let sampleRate = 48_000
    private static let cueDuration = 0.125
    private static var player: AVAudioPlayer?
    private static let cueData = waveData()

    static func prepare() {
        guard player == nil, let preparedPlayer = try? AVAudioPlayer(data: cueData) else {
            return
        }
        preparedPlayer.volume = 0.4
        preparedPlayer.prepareToPlay()
        player = preparedPlayer
    }

    static func play() async {
        let signpostID = PerformanceDiagnostics.signposter.makeSignpostID()
        let signpostState = PerformanceDiagnostics.signposter.beginInterval(
            "Ready cue",
            id: signpostID
        )
        defer {
            PerformanceDiagnostics.signposter.endInterval("Ready cue", signpostState)
        }
        do {
            let player: AVAudioPlayer
            if let preparedPlayer = self.player {
                player = preparedPlayer
            } else {
                player = try AVAudioPlayer(data: cueData)
                self.player = player
            }
            player.volume = 0.4
            player.prepareToPlay()
            player.currentTime = 0
            player.play()

            try? await Task.sleep(for: .milliseconds(145))
            player.stop()
        } catch {
            // The cue is helpful feedback, but must never block dictation.
        }
    }

    private static func waveData() -> Data {
        let sampleCount = Int(Double(sampleRate) * cueDuration)
        var samples = [Int16]()
        samples.reserveCapacity(sampleCount)

        for index in 0..<sampleCount {
            let time = Double(index) / Double(sampleRate)
            let progress = time / cueDuration
            let attack = min(time / 0.005, 1)
            let release = min((cueDuration - time) / 0.018, 1)
            let decay = exp(-4.6 * progress)
            let envelope = max(min(attack, release), 0) * decay

            // A quiet, fixed perfect-fifth glass chord. Fixed pitches feel
            // calmer and more deliberate than the previous rising chirp.
            let fundamental = sin(2 * Double.pi * 523.25 * time)
            let fifthBloom = min(max((time - 0.012) / 0.018, 0), 1)
            let fifth = sin(2 * Double.pi * 783.99 * time + 0.18) * 0.42 * fifthBloom
            let glass = sin(2 * Double.pi * 1_567.98 * time + 0.4) * 0.07
            let value = (fundamental + fifth + glass) * envelope * 0.17
            samples.append(Int16(max(min(value, 1), -1) * Double(Int16.max)))
        }

        var data = Data()
        let audioByteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(36) + audioByteCount)
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * 2))
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(audioByteCount)
        for sample in samples {
            data.appendLittleEndian(UInt16(bitPattern: sample))
        }
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
