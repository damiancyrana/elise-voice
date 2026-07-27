import Foundation

/// Backoff for retrying model preparation. A failed preparation used to leave
/// the app stuck until the user pressed the shortcut, which is what happened
/// when the app launched before the network was ready.
public enum ModelPreparationPolicy {
    public static let maximumRetryDelay: TimeInterval = 60

    public static func retryDelay(afterFailureCount count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        return min(pow(2, Double(count - 1)) * 5, maximumRetryDelay)
    }
}
