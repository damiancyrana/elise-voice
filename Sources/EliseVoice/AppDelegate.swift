import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var voiceWakeMenuItem: NSMenuItem?
    private var coordinator: DictationCoordinator?
    private var hotKey: GlobalHotKey?
    private var recordingWindow: RecordingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        ReadyCuePlayer.prepare()
        let recordingWindow = RecordingWindowController()
        self.recordingWindow = recordingWindow

        let coordinator = DictationCoordinator { [weak self] state in
            self?.render(state)
        } onAudioLevelChange: { [weak recordingWindow] level, silenceRemaining in
            recordingWindow?.updateAudio(level: level, silenceRemaining: silenceRemaining)
        }
        self.coordinator = coordinator
        voiceWakeMenuItem?.state = coordinator.voiceWakeEnabled ? .on : .off

        do {
            hotKey = try GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) {
                Task { @MainActor [weak coordinator] in
                    await coordinator?.toggleDictation()
                }
            }
        } catch {
            render(.failed("Nie można zarejestrować skrótu ⌥Space"))
            return
        }

        Task {
            await coordinator.prepare()
        }

        do {
            try LaunchAtLoginService.enable()
        } catch {
            render(.failed("Nie udało się włączyć startu przy logowaniu"))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.cancel()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        recordingWindow?.showListeningBriefly()
        return true
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Elise Voice")

        let menu = NSMenu()
        let status = NSMenuItem(title: "Uruchamianie…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let voiceWake = NSMenuItem(
            title: "Wybudzanie głosem „ELISE”",
            action: #selector(toggleVoiceWake(_:)),
            keyEquivalent: ""
        )
        voiceWake.target = self
        let defaults = UserDefaults.standard
        voiceWake.state = defaults.object(forKey: DictationCoordinator.voiceWakePreferenceKey) == nil
            || defaults.bool(forKey: DictationCoordinator.voiceWakePreferenceKey)
            ? .on
            : .off
        menu.addItem(voiceWake)
        voiceWakeMenuItem = voiceWake
        menu.addItem(.separator())

        let microphoneSettings = NSMenuItem(
            title: "Ustawienia mikrofonu…",
            action: #selector(openMicrophoneSettings),
            keyEquivalent: ""
        )
        microphoneSettings.target = self
        menu.addItem(microphoneSettings)

        let accessibilitySettings = NSMenuItem(
            title: "Ustawienia dostępności…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        accessibilitySettings.target = self
        menu.addItem(accessibilitySettings)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Zakończ Elise Voice",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        statusMenuItem = status
    }

    @objc private func openMicrophoneSettings() {
        PermissionSettings.openMicrophone()
    }

    @objc private func toggleVoiceWake(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        sender.state = enabled ? .on : .off
        coordinator?.setVoiceWakeEnabled(enabled)
    }

    @objc private func openAccessibilitySettings() {
        PermissionSettings.openAccessibility()
    }

    private func render(_ state: DictationState) {
        recordingWindow?.render(state)
        statusMenuItem?.title = state.description
        statusItem?.button?.contentTintColor = state.tintColor
        statusItem?.button?.image = NSImage(
            systemSymbolName: state.symbolName,
            accessibilityDescription: state.description
        )
    }
}

private extension DictationState {
    var description: String {
        switch self {
        case .preparing:
            "Przygotowywanie modelu…"
        case .ready:
            "Gotowe — naciśnij ⌥Space"
        case let .recording(elapsedSeconds):
            "Nagrywanie \(Self.formattedDuration(elapsedSeconds)) — ⌥Space kończy"
        case .transcribing:
            "Przepisywanie…"
        case let .failed(message):
            message
        }
    }

    var symbolName: String {
        switch self {
        case .preparing, .transcribing:
            "waveform"
        case .ready:
            "mic"
        case .recording:
            "mic.fill"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    var tintColor: NSColor? {
        switch self {
        case .recording:
            .systemRed
        case .failed:
            .systemOrange
        default:
            nil
        }
    }

    static func formattedDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
