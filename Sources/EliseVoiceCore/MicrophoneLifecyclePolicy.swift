import Foundation

public enum MicrophoneActivity: Equatable, Sendable {
    case inactive
    case wakeWord
    case dictation
}

public enum MicrophoneLifecyclePolicy {
    public static func recoveryDelay(afterFailureCount count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        return min(pow(2, Double(count - 1)) * 2, 30)
    }

    public static func desiredActivity(
        systemAllowsAudio: Bool,
        appIsReady: Bool,
        appIsRecording: Bool,
        voiceWakeEnabled: Bool
    ) -> MicrophoneActivity {
        guard systemAllowsAudio else { return .inactive }
        if appIsRecording { return .dictation }
        if appIsReady, voiceWakeEnabled { return .wakeWord }
        return .inactive
    }
}
