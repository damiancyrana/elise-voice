import AppKit

@main
enum EliseVoiceApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()

        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()

        withExtendedLifetime(delegate) {}
    }
}
