import Foundation

public enum DictationPolicy {
    public static let automaticSilenceStop: TimeInterval = 20
    public static let minimumSpeechDuration: TimeInterval = 0.28
    public static let postCueSpeechGuardDuration: TimeInterval = 0.18
    public static let maximumRecordingDuration: TimeInterval = 300
    public static let minimumTranscriptionTimeout: TimeInterval = 30
    public static let maximumTranscriptionTimeout: TimeInterval = 210

    public static func shouldStop(afterSilence duration: TimeInterval) -> Bool {
        duration >= automaticSilenceStop
    }

    public static func reachedMaximumDuration(_ duration: TimeInterval) -> Bool {
        duration >= maximumRecordingDuration
    }

    public static func transcriptionTimeout(forAudioDuration duration: TimeInterval) -> TimeInterval {
        min(
            max(minimumTranscriptionTimeout, duration * 0.65 + 15),
            maximumTranscriptionTimeout
        )
    }

    public static func containsIntentionalSpeech(
        consecutiveSpeechSampleCount: Int,
        sampleRate: Int
    ) -> Bool {
        guard sampleRate > 0 else { return false }
        return consecutiveSpeechSampleCount >= Int(minimumSpeechDuration * Double(sampleRate))
    }
}
