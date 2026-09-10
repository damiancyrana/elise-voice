import Foundation

public enum TextInsertionPolicy {
    public static let secureTextFieldSubrole = "AXSecureTextField"
    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.brave.Browser",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser",
        "org.chromium.Chromium",
        "org.mozilla.firefox"
    ]

    public static func isTerminalApplication(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.apple.Terminal" || bundleIdentifier == "com.googlecode.iterm2"
    }

    public static func allowsInsertion(accessibilitySubrole: String?) -> Bool {
        accessibilitySubrole != secureTextFieldSubrole
    }

    public static func allowsWindowFallback(
        bundleIdentifier: String?,
        supportsManualAccessibility: Bool = false
    ) -> Bool {
        if supportsManualAccessibility { return true }
        guard let bundleIdentifier else { return false }
        return browserBundleIdentifiers.contains(bundleIdentifier)
            || isTerminalApplication(bundleIdentifier: bundleIdentifier)
    }

    public static func allowsAutomaticPaste(role: String?, isEditable: Bool?) -> Bool {
        if isEditable == true { return true }
        // Terminal emulators expose their input and output as a text area,
        // even when their AX value itself is read-only.
        return ["AXTextField", "AXTextArea", "AXComboBox"].contains(role ?? "")
    }

    public static func targetIsStillFocused(
        frontmostApplicationPID: Int32?,
        targetApplicationPID: Int32,
        isFocusedElementEqual: Bool
    ) -> Bool {
        frontmostApplicationPID == targetApplicationPID && isFocusedElementEqual
    }

    /// AX selection offsets use UTF-16, unlike Swift's grapheme count.
    public static func expectedValueAfterInsertion(
        previousValue: String,
        selectionLocation: Int,
        selectionLength: Int,
        insertedText: String
    ) -> String? {
        let value = previousValue as NSString
        guard selectionLocation >= 0, selectionLength >= 0,
              selectionLocation <= value.length,
              selectionLength <= value.length - selectionLocation else { return nil }
        return value.replacingCharacters(
            in: NSRange(location: selectionLocation, length: selectionLength),
            with: insertedText
        )
    }
}
