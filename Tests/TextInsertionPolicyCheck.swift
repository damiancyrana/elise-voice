import Foundation

@main
enum TextInsertionPolicyCheck {
    static func main() {
        precondition(TextInsertionPolicy.allowsInsertion(accessibilitySubrole: nil))
        precondition(TextInsertionPolicy.allowsInsertion(accessibilitySubrole: "AXTextField"))
        precondition(!TextInsertionPolicy.allowsInsertion(
            accessibilitySubrole: "AXSecureTextField"
        ))
        precondition(TextInsertionPolicy.allowsBrowserWindowFallback(
            bundleIdentifier: "com.google.Chrome"
        ))
        precondition(!TextInsertionPolicy.allowsBrowserWindowFallback(
            bundleIdentifier: "com.example.Editor"
        ))
        precondition(TextInsertionPolicy.targetIsStillFocused(
            frontmostApplicationPID: 100,
            targetApplicationPID: 100,
            isFocusedElementEqual: true
        ))
        precondition(!TextInsertionPolicy.targetIsStillFocused(
            frontmostApplicationPID: 100,
            targetApplicationPID: 100,
            isFocusedElementEqual: false
        ))
        precondition(!TextInsertionPolicy.targetIsStillFocused(
            frontmostApplicationPID: 101,
            targetApplicationPID: 100,
            isFocusedElementEqual: true
        ))
        precondition(TextInsertionPolicy.directInsertionWasApplied(
            previousValue: "Ala ma kota",
            previousSelection: "ma",
            newValue: "Ala lubi kota",
            insertedText: "lubi"
        ))
        precondition(TextInsertionPolicy.directInsertionWasApplied(
            previousValue: "tekst",
            previousSelection: "tekst",
            newValue: "tekst",
            insertedText: "tekst"
        ))
        precondition(!TextInsertionPolicy.directInsertionWasApplied(
            previousValue: "",
            previousSelection: "",
            newValue: "",
            insertedText: "dyktowanie"
        ))
    }
}
