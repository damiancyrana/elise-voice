import Foundation

@main
enum TranscriptFormatterCheck {
    static func main() {
        let normalized = TranscriptFormatter.join([
            "  To jest pierwszy fragment. ",
            "  To jest drugi\nfragment.  "
        ])

        guard normalized == "To jest pierwszy fragment. To jest drugi fragment." else {
            fatalError("Niepoprawne łączenie fragmentów: \(normalized)")
        }

        guard TranscriptFormatter.join(["  \n  "]).isEmpty else {
            fatalError("Cisza powinna dać pusty tekst")
        }
        guard !TranscriptFormatter.isMeaningful(""),
              !TranscriptFormatter.isMeaningful("P"),
              !TranscriptFormatter.isMeaningful("..."),
              TranscriptFormatter.isMeaningful("OK"),
              TranscriptFormatter.isMeaningful("Za") else {
            fatalError("Niepoprawna filtracja szczątkowej transkrypcji")
        }
    }
}
