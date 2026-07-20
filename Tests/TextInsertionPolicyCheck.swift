import Foundation

@main
enum TextInsertionPolicyCheck {
    static func main() {
        precondition(TextInsertionPolicy.allowsInsertion(accessibilitySubrole: nil))
        precondition(TextInsertionPolicy.allowsInsertion(accessibilitySubrole: "AXTextField"))
        precondition(!TextInsertionPolicy.allowsInsertion(
            accessibilitySubrole: "AXSecureTextField"
        ))
    }
}
