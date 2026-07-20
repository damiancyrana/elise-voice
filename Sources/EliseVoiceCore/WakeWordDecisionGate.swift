import Foundation

/// Pure decision logic kept separate from SoundAnalysis so thresholds and
/// cooldown behavior can be covered by deterministic tests.
public struct WakeWordDecisionGate: Sendable {
    public static let supportingThreshold = 0.05
    public static let combinedThreshold = 0.95
    public static let strongEvidenceThreshold = 0.70
    public static let strongCombinedThreshold = 1.50
    public static let adjacentWindow: TimeInterval = 0.75
    public static let confirmationWindow: TimeInterval = 1.5
    public static let cooldown: TimeInterval = 2.5

    private var previousConfidence: Double?
    private var previousWindowTime: TimeInterval?
    private var recentStrongEvidence: (confidence: Double, time: TimeInterval)?
    private var lastDetectionTime = -TimeInterval.infinity

    public init() {}

    public mutating func consume(
        confidence: Double,
        backgroundConfidence: Double,
        at time: TimeInterval
    ) -> Bool {
        guard time - lastDetectionTime >= Self.cooldown else { return false }
        if let previousWindowTime, time - previousWindowTime > Self.adjacentWindow {
            previousConfidence = nil
            self.previousWindowTime = nil
        }
        if let evidence = recentStrongEvidence,
           time - evidence.time > Self.confirmationWindow {
            recentStrongEvidence = nil
        }

        let adjacentConfirmation = confidence >= Self.supportingThreshold
            && previousConfidence.map {
                $0 >= Self.supportingThreshold && $0 + confidence >= Self.combinedThreshold
            } == true
        let spacedStrongConfirmation = confidence >= Self.strongEvidenceThreshold
            && recentStrongEvidence.map {
                time - $0.time <= Self.confirmationWindow
                    && $0.confidence + confidence >= Self.strongCombinedThreshold
            } == true

        if adjacentConfirmation || spacedStrongConfirmation {
            // A single extremely confident window is not sufficient. Requiring
            // corroboration rejects isolated keyboard/room transients that the
            // compact classifier can occasionally score near 1.0. The wider
            // strong-evidence path tolerates a weak transition between the two
            // syllables of ELISE.
            lastDetectionTime = time
            previousConfidence = nil
            previousWindowTime = nil
            recentStrongEvidence = nil
            return true
        }

        previousConfidence = confidence >= Self.supportingThreshold ? confidence : nil
        previousWindowTime = time
        if confidence >= Self.strongEvidenceThreshold {
            recentStrongEvidence = (confidence, time)
        }
        return false
    }

    public mutating func reset() {
        previousConfidence = nil
        previousWindowTime = nil
        recentStrongEvidence = nil
    }
}
