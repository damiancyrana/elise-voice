import Foundation

@main
enum TextInsertionPolicyCheck {
    static func main() {
        precondition(TextInsertionPolicy.allowsInsertion(accessibilitySubrole: nil))
        precondition(!TextInsertionPolicy.allowsInsertion(accessibilitySubrole: "AXSecureTextField"))
        for identifier in ["com.google.Chrome", "com.apple.Terminal", "com.googlecode.iterm2"] {
            precondition(TextInsertionPolicy.allowsWindowFallback(bundleIdentifier: identifier))
        }
        // Any app implementing Electron's protocol is supported, including new forks.
        for identifier in [nil, "com.microsoft.VSCode", "com.google.antigravity-ide", "com.example.NewEditor"] {
            precondition(TextInsertionPolicy.allowsWindowFallback(
                bundleIdentifier: identifier, supportsManualAccessibility: true
            ))
        }
        for identifier in [nil, "com.example.Editor", "com.google.Chrome.untrusted"] {
            precondition(!TextInsertionPolicy.allowsWindowFallback(bundleIdentifier: identifier))
        }
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            precondition(TextInsertionPolicy.allowsAutomaticPaste(role: role, isEditable: nil))
        }
        precondition(TextInsertionPolicy.allowsAutomaticPaste(role: "AXGroup", isEditable: true))
        for role in [nil, "AXButton", "AXCheckBox", "AXStaticText", "AXGroup"] {
            precondition(!TextInsertionPolicy.allowsAutomaticPaste(role: role, isEditable: nil))
        }
        precondition(TextInsertionPolicy.targetIsStillFocused(
            frontmostApplicationPID: 100, targetApplicationPID: 100, isFocusedElementEqual: true
        ))
        precondition(!TextInsertionPolicy.targetIsStillFocused(
            frontmostApplicationPID: 100, targetApplicationPID: 100, isFocusedElementEqual: false
        ))
        precondition(!TextInsertionPolicy.targetIsStillFocused(
            frontmostApplicationPID: 101, targetApplicationPID: 100, isFocusedElementEqual: true
        ))

        func expected(_ value: String, _ location: Int, _ length: Int, _ text: String) -> String? {
            TextInsertionPolicy.expectedValueAfterInsertion(
                previousValue: value, selectionLocation: location,
                selectionLength: length, insertedText: text
            )
        }
        precondition(expected("Ala ma kota", 4, 2, "lubi") == "Ala lubi kota")
        precondition(expected("Ala ma kota", 4, 2, "lubi") != "Ola lubi kota")
        precondition(expected("tekst", 0, 5, "tekst") == "tekst")
        precondition(expected("A😀B", 1, 2, "żółć") == "AżółćB")
        precondition(expected("e\u{301}!", 2, 0, "👩‍💻") == "e\u{301}👩‍💻!")
        precondition(expected("a\nb", 2, 0, "\n") == "a\n\nb")
        precondition(expected("", 0, 0, "Zażółć") == "Zażółć")
        for (location, length) in [(-1, 0), (0, -1), (4, 0), (2, 2), (0, Int.max)] {
            precondition(expected("abc", location, length, "x") == nil)
        }
        print("Text insertion policy checks passed")
    }
}
