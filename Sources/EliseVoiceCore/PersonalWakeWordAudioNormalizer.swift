import Foundation

public enum PersonalWakeWordAudioPolicy {
    public static let sampleRate = 16_000
    public static let windowDuration: TimeInterval = 1
    public static let leadingSilenceDuration: TimeInterval = 0.12
    public static let minimumSpeechDuration: TimeInterval = 0.05
    public static let maximumInternalSilenceDuration: TimeInterval = 0.22
    public static let absoluteActivityFloorDecibels: Float = -46
    public static let activityMarginAboveNoiseFloorDecibels: Float = 9
    public static let maximumActivityThresholdDecibels: Float = -27
    public static let acceptanceConfidence = 0.45
}

/// Recreates the one-second framing used by the personal calibration tool.
/// Only the latest speech island is retained, so an older sound in the rolling
/// buffer cannot shift the keyword away from the model's training position.
public enum PersonalWakeWordAudioNormalizer {
    public static func alignedWindow(
        from samples: [Float],
        sampleRate: Int = PersonalWakeWordAudioPolicy.sampleRate
    ) -> [Float]? {
        guard sampleRate > 0, !samples.isEmpty else { return nil }

        let frameLength = max(sampleRate / 100, 1) // 10 ms
        var frameLevels: [Float] = []
        frameLevels.reserveCapacity((samples.count + frameLength - 1) / frameLength)

        var offset = 0
        while offset < samples.count {
            let end = min(offset + frameLength, samples.count)
            var squareSum: Float = 0
            for sample in samples[offset..<end] {
                squareSum += sample * sample
            }
            let rms = sqrt(max(squareSum / Float(end - offset), 0.000_000_000_1))
            frameLevels.append(20 * log10(rms))
            offset = end
        }
        guard !frameLevels.isEmpty else { return nil }

        let sortedLevels = frameLevels.sorted()
        let noiseFloor = sortedLevels[min(sortedLevels.count / 5, sortedLevels.count - 1)]
        let activityThreshold = min(
            max(
                noiseFloor + PersonalWakeWordAudioPolicy.activityMarginAboveNoiseFloorDecibels,
                PersonalWakeWordAudioPolicy.absoluteActivityFloorDecibels
            ),
            PersonalWakeWordAudioPolicy.maximumActivityThresholdDecibels
        )
        let active = frameLevels.map { $0 > activityThreshold }
        guard let lastActiveFrame = active.lastIndex(of: true) else { return nil }

        let maximumGapFrames = max(
            Int(
                PersonalWakeWordAudioPolicy.maximumInternalSilenceDuration
                    * Double(sampleRate) / Double(frameLength)
            ),
            1
        )
        var firstActiveFrame = lastActiveFrame
        var silentFrames = 0
        if lastActiveFrame > 0 {
            for index in stride(from: lastActiveFrame - 1, through: 0, by: -1) {
                if active[index] {
                    firstActiveFrame = index
                    silentFrames = 0
                } else {
                    silentFrames += 1
                    if silentFrames > maximumGapFrames { break }
                }
            }
        }

        let speechStart = firstActiveFrame * frameLength
        let speechEnd = min((lastActiveFrame + 1) * frameLength, samples.count)
        let minimumSpeechSamples = Int(
            PersonalWakeWordAudioPolicy.minimumSpeechDuration * Double(sampleRate)
        )
        guard speechEnd - speechStart >= minimumSpeechSamples else { return nil }

        let outputCount = Int(
            PersonalWakeWordAudioPolicy.windowDuration * Double(sampleRate)
        )
        let leadingSilenceCount = Int(
            PersonalWakeWordAudioPolicy.leadingSilenceDuration * Double(sampleRate)
        )
        var output = [Float](repeating: 0, count: outputCount)
        let copiedCount = min(
            speechEnd - speechStart,
            max(output.count - leadingSilenceCount, 0)
        )
        guard copiedCount > 0 else { return nil }
        output.withUnsafeMutableBufferPointer { destination in
            samples.withUnsafeBufferPointer { source in
                destination.baseAddress!.advanced(by: leadingSilenceCount).update(
                    from: source.baseAddress!.advanced(by: speechStart),
                    count: copiedCount
                )
            }
        }
        return output
    }
}
