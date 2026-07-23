import Foundation

public enum MicrophoneLifecyclePolicy {
    public static func recoveryDelay(afterFailureCount count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        return min(pow(2, Double(count - 1)) * 2, 30)
    }
}
