import Foundation

@main
enum PersonalWakeWordAudioNormalizerCheck {
    static func main() {
        let sampleRate = 16_000
        let phrase = (0..<6_400).map { index in
            Float(sin(Double(index) * 0.11)) * 0.12
        }
        let olderSound = [Float](repeating: 0.08, count: 800)
        let rolling = olderSound
            + [Float](repeating: 0, count: 12_000)
            + phrase
            + [Float](repeating: 0, count: 7_200)

        guard let aligned = PersonalWakeWordAudioNormalizer.alignedWindow(
            from: rolling,
            sampleRate: sampleRate
        ) else {
            preconditionFailure("Expected an aligned personal wake window")
        }
        precondition(aligned.count == sampleRate)
        precondition(aligned.prefix(1_920).allSatisfy { $0 == 0 })
        precondition(aligned[1_920...].contains { abs($0) > 0.05 })
        precondition(
            PersonalWakeWordAudioNormalizer.alignedWindow(
                from: [Float](repeating: 0, count: sampleRate),
                sampleRate: sampleRate
            ) == nil
        )
    }
}
