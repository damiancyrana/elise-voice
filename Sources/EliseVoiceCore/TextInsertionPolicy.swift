public enum TextInsertionPolicy {
    public static let secureTextFieldSubrole = "AXSecureTextField"

    public static func allowsInsertion(accessibilitySubrole: String?) -> Bool {
        accessibilitySubrole != secureTextFieldSubrole
    }
}
