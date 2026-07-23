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

    public static func allowsInsertion(accessibilitySubrole: String?) -> Bool {
        accessibilitySubrole != secureTextFieldSubrole
    }

    public static func allowsBrowserWindowFallback(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return browserBundleIdentifiers.contains(bundleIdentifier)
    }

    public static func targetIsStillFocused(
        frontmostApplicationPID: Int32?,
        targetApplicationPID: Int32,
        isFocusedElementEqual: Bool
    ) -> Bool {
        frontmostApplicationPID == targetApplicationPID && isFocusedElementEqual
    }

    public static func directInsertionWasApplied(
        previousValue: String,
        previousSelection: String,
        newValue: String,
        insertedText: String
    ) -> Bool {
        let expectedCount = previousValue.count
            - previousSelection.count
            + insertedText.count
        return newValue.count == expectedCount
            && (newValue != previousValue || previousSelection == insertedText)
    }
}
