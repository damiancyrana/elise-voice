import Foundation

/// Backoff for re-registering the global shortcut. Re-registration unregisters
/// first, so a failure leaves the app without its only trigger; retrying keeps
/// ⌥Space from staying dead until the app is restarted.
public enum HotKeyRecoveryPolicy {
    public static let maximumRetryDelay: TimeInterval = 30

    public static func retryDelay(afterFailureCount count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        return min(pow(2, Double(count - 1)) * 2, maximumRetryDelay)
    }
}
