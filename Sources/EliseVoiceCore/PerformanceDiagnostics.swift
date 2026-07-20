import OSLog

/// Privacy-safe points of interest for Instruments. Messages contain timing,
/// sample counts and lifecycle events only—never audio or transcript content.
public enum PerformanceDiagnostics {
    public static let signposter = OSSignposter(
        subsystem: "com.elisevoice.app",
        category: .pointsOfInterest
    )
}
