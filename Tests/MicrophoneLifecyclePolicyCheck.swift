@main
enum MicrophoneLifecyclePolicyCheck {
    static func main() {
        precondition(MicrophoneLifecyclePolicy.recoveryDelay(afterFailureCount: 0) == 0)
        precondition(MicrophoneLifecyclePolicy.recoveryDelay(afterFailureCount: 1) == 2)
        precondition(MicrophoneLifecyclePolicy.recoveryDelay(afterFailureCount: 4) == 16)
        precondition(MicrophoneLifecyclePolicy.recoveryDelay(afterFailureCount: 10) == 30)
        precondition(MicrophoneLifecyclePolicy.desiredActivity(
            systemAllowsAudio: true,
            appIsReady: true,
            appIsRecording: false,
            voiceWakeEnabled: true
        ) == .wakeWord)
        precondition(MicrophoneLifecyclePolicy.desiredActivity(
            systemAllowsAudio: true,
            appIsReady: true,
            appIsRecording: false,
            voiceWakeEnabled: false
        ) == .inactive)
        precondition(MicrophoneLifecyclePolicy.desiredActivity(
            systemAllowsAudio: true,
            appIsReady: false,
            appIsRecording: true,
            voiceWakeEnabled: false
        ) == .dictation)
        precondition(MicrophoneLifecyclePolicy.desiredActivity(
            systemAllowsAudio: false,
            appIsReady: false,
            appIsRecording: true,
            voiceWakeEnabled: true
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
                voiceWakeEnabled: index.isMultiple(of: 2)
            ) == expected)
        }
    }
}
