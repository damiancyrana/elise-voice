import AppKit
import ApplicationServices
import EliseVoiceCore
import Foundation
import OSLog

enum TextInserterError: LocalizedError {
    case accessibilityPermissionMissing
    case noFocusedTextField
    case secureTextField
    case targetChanged
    case clipboardWriteFailed
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            "Włącz Elise Voice w Prywatność i ochrona → Dostępność"
        case .noFocusedTextField:
            "Nie znaleziono aktywnego pola tekstowego"
        case .secureTextField:
            "Elise Voice nie wkleja tekstu do pól haseł"
        case .targetChanged:
            "Pole tekstowe zmieniło się — tekst pozostawiono w schowku"
        case .clipboardWriteFailed:
            "Nie udało się skopiować rozpoznanego tekstu"
        case .eventCreationFailed:
            "Nie udało się wkleić rozpoznanego tekstu"
        }
    }
}

struct TextInsertionTarget: @unchecked Sendable {
    fileprivate let processIdentifier: pid_t
    fileprivate let element: AXUIElement
}

@MainActor
enum TextInserter {
    private static let logger = Logger(
        subsystem: "com.elisevoice.app",
        category: "insertion"
    )

    static var isAuthorized: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func captureTarget() throws -> TextInsertionTarget {
        guard AXIsProcessTrusted() else {
            throw TextInserterError.accessibilityPermissionMissing
        }
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let element = focusedElement(),
              processIdentifier(of: element) == frontmostPID else {
            throw TextInserterError.noFocusedTextField
        }
        guard !isSecureTextField(element) else {
            throw TextInserterError.secureTextField
        }
        return TextInsertionTarget(processIdentifier: frontmostPID, element: element)
    }

    static func paste(_ text: String, into target: TextInsertionTarget) async throws {
        let signpostID = PerformanceDiagnostics.signposter.makeSignpostID()
        let signpostState = PerformanceDiagnostics.signposter.beginInterval(
            "Insert transcript",
            id: signpostID
        )
        defer {
            PerformanceDiagnostics.signposter.endInterval(
                "Insert transcript",
                signpostState
            )
        }
        guard AXIsProcessTrusted() else {
            throw TextInserterError.accessibilityPermissionMissing
        }
        guard !isSecureTextField(target.element) else {
            throw TextInserterError.secureTextField
        }
        guard targetIsStillFocused(target) else {
            try copyPermanentlyToClipboard(text)
            throw TextInserterError.targetChanged
        }

        var isSettable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(
            target.element,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        )
        if settableStatus == .success, isSettable.boolValue {
            let status = AXUIElementSetAttributeValue(
                target.element,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            )
            if status == .success {
                logger.info("Transcript inserted through Accessibility API")
                return
            }
        }

        try await pasteThroughClipboard(text, target: target)
        logger.info("Transcript inserted through guarded clipboard fallback")
    }

    private static func pasteThroughClipboard(
        _ text: String,
        target: TextInsertionTarget
    ) async throws {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TextInserterError.clipboardWriteFailed
        }
        let insertedTextChangeCount = pasteboard.changeCount

        try await Task.sleep(for: .milliseconds(80))
        guard targetIsStillFocused(target) else {
            throw TextInserterError.targetChanged
        }
        guard
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
        else {
            throw TextInserterError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // The receiving process reads the pasteboard synchronously with the
        // keyboard event. Return control quickly, but retain the previous
        // contents for a conservative one-second restoration window.
        try await Task.sleep(for: .milliseconds(120))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(880))
            if pasteboard.changeCount == insertedTextChangeCount {
                snapshot.restore(to: pasteboard)
            }
        }
    }

    private static func targetIsStillFocused(_ target: TextInsertionTarget) -> Bool {
        guard
            NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
            let current = focusedElement(),
            processIdentifier(of: current) == target.processIdentifier
        else { return false }
        return CFEqual(current, target.element)
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success else { return nil }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func processIdentifier(of element: AXUIElement) -> pid_t? {
        var identifier: pid_t = 0
        guard AXUIElementGetPid(element, &identifier) == .success else { return nil }
        return identifier
    }

    private static func isSecureTextField(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &value
        ) == .success else { return false }
        return !TextInsertionPolicy.allowsInsertion(
            accessibilitySubrole: value as? String
        )
    }

    static func copyPermanentlyToClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TextInserterError.clipboardWriteFailed
        }
    }
}

private struct PasteboardSnapshot {
    struct Item {
        let values: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    let items: [Item]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { savedItem in
            let item = NSPasteboardItem()
            for value in savedItem.values {
                item.setData(value.data, forType: value.type)
            }
            return item
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}
