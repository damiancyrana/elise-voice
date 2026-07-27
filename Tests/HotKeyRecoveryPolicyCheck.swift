@main
enum HotKeyRecoveryPolicyCheck {
    static func main() {
        precondition(HotKeyRecoveryPolicy.retryDelay(afterFailureCount: 0) == 0)
        precondition(HotKeyRecoveryPolicy.retryDelay(afterFailureCount: 1) == 2)
        precondition(HotKeyRecoveryPolicy.retryDelay(afterFailureCount: 3) == 8)
        precondition(HotKeyRecoveryPolicy.retryDelay(afterFailureCount: 5) == 30)
        precondition(HotKeyRecoveryPolicy.retryDelay(afterFailureCount: 40) == 30)
    }
}
