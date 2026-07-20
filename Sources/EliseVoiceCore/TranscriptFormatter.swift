import Foundation

public enum TranscriptFormatter {
    static func join(_ chunks: [String]) -> String {
        chunks
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    public static func isMeaningful(_ text: String) -> Bool {
        text.count(where: \Character.isLetter) >= 2
    }
}
