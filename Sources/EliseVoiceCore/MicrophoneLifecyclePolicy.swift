import Foundation

public enum MicrophoneActivity: Equatable, Sendable {
    case inactive
    case wakeWord
    case dictation
}

public enum MicrophoneLifecyclePolicy {
    public static let voiceWakeIdleTimeout: TimeInterval = 30 * 60
    public static let voiceWakeIdlePollInterval: TimeInterval = 30

    public static func shouldDisarmVoiceWakeSession(
        secondsSinceEliseInteraction: TimeInterval,
        secondsSinceSystemInput: TimeInterval
    ) -> Bool {
        min(secondsSinceEliseInteraction, secondsSinceSystemInput)
            >= voiceWakeIdleTimeout
    }

    public static func recoveryDelay(afterFailureCount count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        return min(pow(2, Double(count - 1)) * 2, 30)
    }

    public static func desiredActivity(
        systemAllowsAudio: Bool,
        appIsReady: Bool,
        appIsRecording: Bool,
        voiceWakeEnabled: Bool,
        voiceWakeSessionArmed: Bool
    ) -> MicrophoneActivity {
        guard systemAllowsAudio else { return .inactive }
        if appIsRecording { return .dictation }
        if appIsReady, voiceWakeEnabled, voiceWakeSessionArmed { return .wakeWord }
        return .inactive
    }
}
