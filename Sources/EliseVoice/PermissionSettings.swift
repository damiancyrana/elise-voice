import AppKit
import Foundation

@MainActor
enum PermissionSettings {
    static func openMicrophone() {
        openPrivacyPane(anchor: "Privacy_Microphone")
    }

    static func openAccessibility() {
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }

    private static func openPrivacyPane(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
