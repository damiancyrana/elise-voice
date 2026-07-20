@main
enum MicrophoneLifecyclePolicyCheck {
    static func main() {
        precondition(MicrophoneLifecyclePolicy.recoveryDelay(afterFailureCount: 0) == 0)
        precondition(MicrophoneLifecyclePolicy.recoveryDelay(afterFailureCount: 1) == 2)
        precondition(MicrophoneLifecyclePolicy.recoveryDelay(afterFailureCount: 4) == 16)
        precondition(MicrophoneLifecyclePolicy.recoveryDelay(afterFailureCount: 10) == 30)
        precondition(MicrophoneLifecyclePolicy.voiceWakeIdleTimeout == 1_800)
        precondition(MicrophoneLifecyclePolicy.voiceWakeIdlePollInterval == 30)
        precondition(!MicrophoneLifecyclePolicy.shouldDisarmVoiceWakeSession(
            secondsSinceEliseInteraction: 1_900,
            secondsSinceSystemInput: 10
        ))
        precondition(!MicrophoneLifecyclePolicy.shouldDisarmVoiceWakeSession(
            secondsSinceEliseInteraction: 10,
            secondsSinceSystemInput: 1_900
        ))
        precondition(MicrophoneLifecyclePolicy.shouldDisarmVoiceWakeSession(
            secondsSinceEliseInteraction: 1_800,
            secondsSinceSystemInput: 1_800
        ))
        precondition(MicrophoneLifecyclePolicy.desiredActivity(
            systemAllowsAudio: true,
            appIsReady: true,
            appIsRecording: false,
            voiceWakeEnabled: true,
            voiceWakeSessionArmed: true
        ) == .wakeWord)
        precondition(MicrophoneLifecyclePolicy.desiredActivity(
            systemAllowsAudio: true,
            appIsReady: true,
            appIsRecording: false,
            voiceWakeEnabled: true,
            voiceWakeSessionArmed: false
        ) == .inactive)
        precondition(MicrophoneLifecyclePolicy.desiredActivity(
            systemAllowsAudio: true,
            appIsReady: true,
            appIsRecording: false,
            voiceWakeEnabled: false,
            voiceWakeSessionArmed: true
        ) == .inactive)
        precondition(MicrophoneLifecyclePolicy.desiredActivity(
            systemAllowsAudio: true,
            appIsReady: false,
            appIsRecording: true,
            voiceWakeEnabled: false,
            voiceWakeSessionArmed: false
        ) == .dictation)
        precondition(MicrophoneLifecyclePolicy.desiredActivity(
            systemAllowsAudio: false,
            appIsReady: false,
            appIsRecording: true,
            voiceWakeEnabled: true,
            voiceWakeSessionArmed: true
        ) == .inactive)

        // Soak the deterministic policy through repeated state transitions.
        for index in 0..<1_000 {
            let expected: MicrophoneActivity = index.isMultiple(of: 2)
                ? .wakeWord
                : .inactive
            precondition(MicrophoneLifecyclePolicy.desiredActivity(
                systemAllowsAudio: true,
                appIsReady: true,
                appIsRecording: false,
                voiceWakeEnabled: true,
                voiceWakeSessionArmed: index.isMultiple(of: 2)
            ) == expected)
        }
    }
}
