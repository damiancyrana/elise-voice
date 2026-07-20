import Foundation

@main
enum WakeWordTranscriptMatcherCheck {
    static func main() {
        for accepted in [
            "Elise", "E lease", "E-lies", "ILIS", "Iliz", "Elize!", "ELAJS"
        ] {
            precondition(WakeWordTranscriptMatcher.matches(accepted), accepted)
        }

        for rejected in [
            "", "Dziękuję", "Lis", "Elisa", "Eliza", "Alice",
            "Elise napisz wiadomość", "To jest zwykłe zdanie"
        ] {
            precondition(!WakeWordTranscriptMatcher.matches(rejected), rejected)
        }
    }
}
