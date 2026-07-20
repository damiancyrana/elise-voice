import Foundation

/// Strict second-stage match used only after the compact Core ML classifier
/// proposes a candidate. Matching the complete short transcript avoids
/// activating on ordinary sentences that merely contain a similar syllable.
public enum WakeWordTranscriptMatcher {
    private static let acceptedForms: Set<String> = [
        "elis", "elise", "elize", "elyse",
        "ilis", "iliz",
        "elease", "elies", "elajs"
    ]

    public static func matches(_ transcript: String) -> Bool {
        let folded = transcript.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let normalized = folded.unicodeScalars
            .filter(CharacterSet.letters.contains)
            .map(String.init)
            .joined()
        return acceptedForms.contains(normalized)
    }
}
