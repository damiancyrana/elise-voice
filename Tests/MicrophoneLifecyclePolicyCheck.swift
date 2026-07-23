@main
enum MicrophoneLifecyclePolicyCheck {
    static func main() {
        precondition(MicrophoneLifecyclePolicy.recoveryDelay(afterFailureCount: 0) == 0)
        precondition(MicrophoneLifecyclePolicy.recoveryDelay(afterFailureCount: 1) == 2)
        precondition(MicrophoneLifecyclePolicy.recoveryDelay(afterFailureCount: 4) == 16)
        precondition(MicrophoneLifecyclePolicy.recoveryDelay(afterFailureCount: 10) == 30)
    }
}
