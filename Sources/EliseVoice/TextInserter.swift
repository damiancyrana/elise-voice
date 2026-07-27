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
    fileprivate let frontmostApplicationPID: pid_t
    fileprivate let focusedElement: AXUIElement?
    fileprivate let focusedWindow: AXUIElement?
}

@MainActor
enum TextInserter {
    private static let logger = Logger(
        subsystem: "com.elisevoice.app",
        category: "insertion"
    )
    /// Accessibility queries are synchronous IPC into the target application and
    /// default to a six second timeout each. A frontmost app that is busy or
    /// wedged would otherwise stall the main thread for that long, freezing the
    /// panel, the menu bar and the shortcut.
    private static let messagingTimeout: Float = 0.5
    /// Walking a deep element tree multiplies that cost, so the search also runs
    /// against a wall clock and gives up in favour of the clipboard fallback.
    private static let treeSearchBudget: TimeInterval = 0.3
    private static let maximumInspectedElements = 4_096
    private static var didConfigureGlobalTimeout = false

    static var isAuthorized: Bool {
        AXIsProcessTrusted()
    }

    /// Setting the timeout on the system-wide element applies it process-wide.
    private static func systemWideElement() -> AXUIElement {
        let element = AXUIElementCreateSystemWide()
        if !didConfigureGlobalTimeout {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            didConfigureGlobalTimeout = true
        }
        return element
    }

    private static func applicationElement(for processIdentifier: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func requestAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func captureTarget() throws -> TextInsertionTarget {
        guard AXIsProcessTrusted() else {
            throw TextInserterError.accessibilityPermissionMissing
        }
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            throw TextInserterError.noFocusedTextField
        }
        let frontmostPID = frontmostApplication.processIdentifier

        if let element = focusedElement(for: frontmostPID) {
            guard !isSecureTextField(element) else {
                throw TextInserterError.secureTextField
            }
            return TextInsertionTarget(
                frontmostApplicationPID: frontmostPID,
                focusedElement: element,
                focusedWindow: nil
            )
        }

        guard TextInsertionPolicy.allowsBrowserWindowFallback(
            bundleIdentifier: frontmostApplication.bundleIdentifier
        ), let window = focusedWindow(for: frontmostPID) else {
            throw TextInserterError.noFocusedTextField
        }

        return TextInsertionTarget(
            frontmostApplicationPID: frontmostPID,
            focusedElement: nil,
            focusedWindow: window
        )
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
        if let element = target.focusedElement, isSecureTextField(element) {
            throw TextInserterError.secureTextField
        }
        guard targetIsStillFocused(target) else {
            try copyPermanentlyToClipboard(text)
            throw TextInserterError.targetChanged
        }

        if let element = target.focusedElement {
            let previousValue = stringAttribute(
                kAXValueAttribute as CFString,
                of: element
            )
            let previousSelection = stringAttribute(
                kAXSelectedTextAttribute as CFString,
                of: element
            ) ?? ""
            var isSettable: DarwinBoolean = false
            let settableStatus = AXUIElementIsAttributeSettable(
                element,
                kAXSelectedTextAttribute as CFString,
                &isSettable
            )
            if settableStatus == .success, isSettable.boolValue {
                let status = AXUIElementSetAttributeValue(
                    element,
                    kAXSelectedTextAttribute as CFString,
                    text as CFTypeRef
                )
                if status == .success {
                    try? await Task.sleep(for: .milliseconds(25))
                    let insertionWasApplied = previousValue == nil || stringAttribute(
                        kAXValueAttribute as CFString,
                        of: element
                    ).map { newValue in
                        TextInsertionPolicy.directInsertionWasApplied(
                            previousValue: previousValue ?? "",
                            previousSelection: previousSelection,
                            newValue: newValue,
                            insertedText: text
                        )
                    } == true
                    if insertionWasApplied {
                        logger.info("Transcript inserted through Accessibility API")
                        return
                    }
                    logger.notice("Accessibility API reported success without changing text; using clipboard fallback")
                }
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
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
            == target.frontmostApplicationPID else {
            return false
        }

        if let element = target.focusedElement {
            guard let current = focusedElement(for: target.frontmostApplicationPID) else {
                return false
            }
            return TextInsertionPolicy.targetIsStillFocused(
                frontmostApplicationPID: target.frontmostApplicationPID,
                targetApplicationPID: target.frontmostApplicationPID,
                isFocusedElementEqual: CFEqual(current, element)
            )
        }

        guard let window = target.focusedWindow,
              let current = focusedWindow(for: target.frontmostApplicationPID) else {
            return false
        }
        return TextInsertionPolicy.targetIsStillFocused(
            frontmostApplicationPID: target.frontmostApplicationPID,
            targetApplicationPID: target.frontmostApplicationPID,
            isFocusedElementEqual: CFEqual(current, window)
        )
    }

    private static func focusedElement(for processIdentifier: pid_t) -> AXUIElement? {
        if let element = elementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            of: systemWideElement()
        ) {
            return element
        }

        if let element = elementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            of: applicationElement(for: processIdentifier)
        ) {
            return element
        }
        guard let window = focusedWindow(for: processIdentifier) else {
            return nil
        }
        return focusedDescendant(of: window)
    }

    private static func focusedWindow(for processIdentifier: pid_t) -> AXUIElement? {
        elementAttribute(
            kAXFocusedWindowAttribute as CFString,
            of: applicationElement(for: processIdentifier)
        )
    }

    private static func elementAttribute(
        _ attribute: CFString,
        of element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func focusedDescendant(of root: AXUIElement) -> AXUIElement? {
        let deadline = ProcessInfo.processInfo.systemUptime + treeSearchBudget
        var elements = childElements(of: root)
        var inspectedElementCount = 0

        while let element = elements.popLast(),
              inspectedElementCount < maximumInspectedElements {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                logger.notice("Accessibility tree search exceeded its time budget")
                return nil
            }
            inspectedElementCount += 1
            if booleanAttribute(kAXFocusedAttribute as CFString, of: element) {
                return element
            }
            elements.append(contentsOf: childElements(of: element))
        }
        return nil
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private static func booleanAttribute(
        _ attribute: CFString,
        of element: AXUIElement
    ) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return false
        }
        return value as? Bool ?? false
    }

    private static func stringAttribute(
        _ attribute: CFString,
        of element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
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
