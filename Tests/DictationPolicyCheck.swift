import Foundation

@main
enum DictationPolicyCheck {
    static func main() {
        guard !DictationPolicy.shouldStop(afterSilence: 19.999) else {
            fatalError("Dyktowanie zakończyło się przed upływem 20 sekund ciszy")
        }
        guard DictationPolicy.shouldStop(afterSilence: 20) else {
            fatalError("Dyktowanie nie zakończyło się po 20 sekundach ciszy")
        }
        guard !DictationPolicy.reachedMaximumDuration(299.999),
              DictationPolicy.reachedMaximumDuration(300) else {
            fatalError("Niepoprawna granica pięciominutowego limitu nagrania")
        }
        guard DictationPolicy.transcriptionTimeout(forAudioDuration: 5) == 30,
              DictationPolicy.transcriptionTimeout(forAudioDuration: 60) == 54,
              DictationPolicy.transcriptionTimeout(forAudioDuration: 300) == 210 else {
            fatalError("Niepoprawny limit czasu transkrypcji")
        }

        let sampleRate = 16_000
        let minimumSpeechSamples = Int(
            DictationPolicy.minimumSpeechDuration * Double(sampleRate)
        )
        guard !DictationPolicy.containsIntentionalSpeech(
            consecutiveSpeechSampleCount: minimumSpeechSamples - 1,
            sampleRate: sampleRate
        ) else {
            fatalError("Zbyt krótki szum został uznany za mowę")
        }
        guard DictationPolicy.containsIntentionalSpeech(
            consecutiveSpeechSampleCount: minimumSpeechSamples,
            sampleRate: sampleRate
        ) else {
            fatalError("Prawidłowy fragment mowy został odrzucony")
        }
        guard !DictationPolicy.containsIntentionalSpeech(
            consecutiveSpeechSampleCount: minimumSpeechSamples,
            sampleRate: 0
        ) else {
            fatalError("Nieprawidłowa częstotliwość próbkowania została zaakceptowana")
        }
    }
}
