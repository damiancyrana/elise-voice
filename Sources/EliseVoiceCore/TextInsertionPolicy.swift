public enum TextInsertionPolicy {
    public static let secureTextFieldSubrole = "AXSecureTextField"

    public static func allowsInsertion(accessibilitySubrole: String?) -> Bool {
        accessibilitySubrole != secureTextFieldSubrole
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
