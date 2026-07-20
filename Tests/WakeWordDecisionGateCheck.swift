import Foundation

@main
enum WakeWordDecisionGateCheck {
    static func main() {
        var confirmedGate = WakeWordDecisionGate()
        precondition(!confirmedGate.consume(
            confidence: 0.45,
            backgroundConfidence: 0.55,
            at: 1
        ))
        precondition(confirmedGate.consume(
            confidence: 0.51,
            backgroundConfidence: 0.49,
            at: 1.5
        ))

        var highConfidenceGate = WakeWordDecisionGate()
        precondition(!highConfidenceGate.consume(
            confidence: 1,
            backgroundConfidence: 0,
            at: 10
        ))
        precondition(!highConfidenceGate.consume(
            confidence: 0.01,
            backgroundConfidence: 0.99,
            at: 10.5
        ))
        precondition(!highConfidenceGate.consume(
            confidence: 0.48,
            backgroundConfidence: 0.52,
            at: 11
        ))
        precondition(highConfidenceGate.consume(
            confidence: 0.50,
            backgroundConfidence: 0.50,
            at: 11.25
        ))
        precondition(!highConfidenceGate.consume(
            confidence: 0.99,
            backgroundConfidence: 0.01,
            at: 12
        ))
        highConfidenceGate.reset()
        precondition(!highConfidenceGate.consume(
            confidence: 0.60,
            backgroundConfidence: 0.40,
            at: 14
        ))
        precondition(highConfidenceGate.consume(
            confidence: 0.36,
            backgroundConfidence: 0.64,
            at: 14.25
        ))

        var syllableGapGate = WakeWordDecisionGate()
        precondition(!syllableGapGate.consume(
            confidence: 0.99,
            backgroundConfidence: 0.01,
            at: 20
        ))
        precondition(!syllableGapGate.consume(
            confidence: 0.01,
            backgroundConfidence: 0.99,
            at: 20.5
        ))
        precondition(syllableGapGate.consume(
            confidence: 0.86,
            backgroundConfidence: 0.14,
            at: 21
        ))

        var expiredEvidenceGate = WakeWordDecisionGate()
        precondition(!expiredEvidenceGate.consume(
            confidence: 0.99,
            backgroundConfidence: 0.01,
            at: 30
        ))
        precondition(!expiredEvidenceGate.consume(
            confidence: 0.90,
            backgroundConfidence: 0.10,
            at: 31.6
        ))

        var sequenceGate = WakeWordDecisionGate()
        precondition(!sequenceGate.consume(
            confidence: 0.60,
            backgroundConfidence: 0.40,
            at: 1
        ))
        precondition(!sequenceGate.consume(
            confidence: 0.01,
            backgroundConfidence: 0.99,
            at: 1.5
        ))
        precondition(!sequenceGate.consume(
            confidence: 0.60,
            backgroundConfidence: 0.40,
            at: 2
        ))

        var noiseGate = WakeWordDecisionGate()
        for index in 0..<1_000 {
            precondition(!noiseGate.consume(
                confidence: Double(index % 20) / 100,
                backgroundConfidence: 0.8,
                at: Double(index) * 0.5
            ))
        }
    }
}
