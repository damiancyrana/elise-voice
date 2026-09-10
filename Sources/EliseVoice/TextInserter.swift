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
    case manualPasteRequired
    case insertionUnverified
    case clipboardChanged

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
        case .manualPasteRequired:
            "Tekst jest w schowku — wklej go ręcznie w wybranym polu"
        case .insertionUnverified:
            "Nie potwierdzono wklejenia — tekst jest w schowku"
        case .clipboardChanged:
            "Schowek zmienił się przed wklejeniem — tekst dyktowania zachowano w schowku"
        }
    }
}

struct TextInsertionTarget: @unchecked Sendable {
    fileprivate let frontmostApplicationPID: pid_t
    fileprivate let focusedElement: AXUIElement?
    fileprivate let focusedWindow: AXUIElement?
    fileprivate let allowsAutomaticPaste: Bool
}

@MainActor
enum TextInserter {
    private static let logger = Logger(
        subsystem: "com.elisevoice.app",
        category: "insertion"
    )
    /// Accessibility queries are synchronous IPC into the target application, so
    /// a wedged frontmost app stalls the main thread and freezes the panel, the
    /// menu bar and the shortcut. Measured against a suspended process, the
    /// system default stalls for 1.5 s per query; this bounds it to 0.5 s.
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

    static func captureTarget() async throws -> TextInsertionTarget {
        guard AXIsProcessTrusted() else {
            throw TextInserterError.accessibilityPermissionMissing
        }
        _ = systemWideElement()
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            throw TextInserterError.noFocusedTextField
        }
        let frontmostPID = frontmostApplication.processIdentifier

        let application = applicationElement(for: frontmostPID)
        let attribute = "AXManualAccessibility" as CFString
        // Discover Electron's protocol rather than maintaining a list of apps.
        let manualAccessibility = optionalBooleanAttribute(attribute, of: application)
        if manualAccessibility == false {
            let status = AXUIElementSetAttributeValue(application, attribute, kCFBooleanTrue)
            if status == .success {
                // Let Electron publish its renderer tree before retaining an element.
                try await Task.sleep(for: .milliseconds(100))
            } else {
                logger.notice("Could not enable application Accessibility: \(status.rawValue)")
            }
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID else {
            throw TextInserterError.noFocusedTextField
        }

        let window = focusedWindow(for: frontmostPID)
        if let element = focusedElement(for: frontmostPID) {
            guard !isSecureTextField(element) else {
                throw TextInserterError.secureTextField
            }
            let role = stringAttribute(kAXRoleAttribute as CFString, of: element)
            let allowsAutomaticPaste = TextInsertionPolicy.allowsAutomaticPaste(
                role: role,
                isEditable: optionalBooleanAttribute("AXIsEditable" as CFString, of: element)
            ) && optionalBooleanAttribute(kAXEnabledAttribute as CFString, of: element) != false
            logger.info("Captured input: role=\(role ?? "unknown", privacy: .public), automatic paste=\(allowsAutomaticPaste)")
            return TextInsertionTarget(
                frontmostApplicationPID: frontmostPID,
                focusedElement: element,
                focusedWindow: window,
                allowsAutomaticPaste: allowsAutomaticPaste
            )
        }

        // Unknown applications can still transcribe to the clipboard. Never
        // guess a destination or reject the recording merely because AX is absent.
        return TextInsertionTarget(
            frontmostApplicationPID: frontmostPID,
            focusedElement: nil,
            focusedWindow: window,
            allowsAutomaticPaste: window != nil && TextInsertionPolicy.allowsWindowFallback(
                bundleIdentifier: frontmostApplication.bundleIdentifier,
                supportsManualAccessibility: manualAccessibility != nil
            )
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
        guard target.allowsAutomaticPaste else {
            try copyPermanentlyToClipboard(text)
            throw TextInserterError.manualPasteRequired
        }
        guard targetIsStillFocused(target) else {
            try copyPermanentlyToClipboard(text)
            throw TextInserterError.targetChanged
        }

        // A native paste goes through the editor's input/undo pipeline. AX writes
        // can mutate an accessibility value without updating a web editor's model.
        try await pasteThroughClipboard(text, target: target)
    }

    private static func pasteThroughClipboard(
        _ text: String,
        target: TextInsertionTarget
    ) async throws {
        let isTerminal = TextInsertionPolicy.isTerminalApplication(
            bundleIdentifier: NSRunningApplication(processIdentifier: target.frontmostApplicationPID)?.bundleIdentifier
        )
        let expectedValue = isTerminal ? nil : target.focusedElement.flatMap {
            Self.expectedValue(afterInserting: text, into: $0)
        }
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
        guard pasteboard.changeCount == insertedTextChangeCount else {
            try copyPermanentlyToClipboard(text)
            throw TextInserterError.clipboardChanged
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

        // Sending an event is not an acknowledgement from the receiving app.
        // Restore the old clipboard only after observing the exact expected edit.
        // Otherwise retain the transcript, including for slow/opaque editors.
        if let element = target.focusedElement, let expectedValue {
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(100))
                guard targetIsStillFocused(target) else {
                    logger.notice("Focus changed after paste dispatch; transcript retained in clipboard")
                    return
                }
                if stringAttribute(kAXValueAttribute as CFString, of: element) == expectedValue {
                    logger.info("Transcript insertion verified")
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        if pasteboard.changeCount == insertedTextChangeCount {
                            snapshot.restore(to: pasteboard)
                        }
                    }
                    return
                }
            }
            throw TextInserterError.insertionUnverified
        }
        logger.info("Paste shortcut dispatched; transcript retained because the target cannot confirm insertion")
    }

    private static func expectedValue(afterInserting text: String, into element: AXUIElement) -> String? {
        // Multiple selections cannot be verified as a single replacement.
        var selections: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangesAttribute as CFString, &selections
        ) == .success, let ranges = selections as? [Any], ranges.count > 1 {
            return nil
        }
        guard let value = stringAttribute(kAXValueAttribute as CFString, of: element) else { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeValue
        ) == .success, let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(rangeValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return TextInsertionPolicy.expectedValueAfterInsertion(
            previousValue: value,
            selectionLocation: range.location,
            selectionLength: range.length,
            insertedText: text
        )
    }

    private static func targetIsStillFocused(_ target: TextInsertionTarget) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
            == target.frontmostApplicationPID else {
            return false
        }

        if let window = target.focusedWindow {
            guard let currentWindow = focusedWindow(for: target.frontmostApplicationPID),
                  CFEqual(currentWindow, window) else { return false }
        }

        if let element = target.focusedElement {
            guard let current = focusedElement(for: target.frontmostApplicationPID) else {
                return false
            }
            guard !isSecureTextField(current),
                  optionalBooleanAttribute(kAXEnabledAttribute as CFString, of: current) != false else {
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
        // A lazily exposed field may become available during transcription.
        if let currentElement = focusedElement(for: target.frontmostApplicationPID),
           isSecureTextField(currentElement) {
            return false
        }
        return TextInsertionPolicy.targetIsStillFocused(
            frontmostApplicationPID: target.frontmostApplicationPID,
            targetApplicationPID: target.frontmostApplicationPID,
            isFocusedElementEqual: CFEqual(current, window)
        )
    }

    private static func focusedElement(for processIdentifier: pid_t) -> AXUIElement? {
        // Prefer the application's own focus. A system-wide query can return a
        // stale element from another app; renderer PIDs alone cannot identify it.
        let applicationFocus = elementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            of: applicationElement(for: processIdentifier)
        )
        if let element = applicationFocus, isTextInput(element) || isSecureTextField(element) {
            return element
        }
        guard let window = focusedWindow(for: processIdentifier) else { return applicationFocus }
        if let element = elementAttribute(
            kAXFocusedUIElementAttribute as CFString, of: systemWideElement()
        ), let elementWindow = elementAttribute(kAXWindowAttribute as CFString, of: element),
           CFEqual(elementWindow, window) {
            if isTextInput(element) || isSecureTextField(element) { return element }
        }
        // WebKit may report its container while a nested HTML input owns focus.
        return focusedDescendant(of: applicationFocus ?? window) ?? applicationFocus
    }

    private static func isTextInput(_ element: AXUIElement) -> Bool {
        TextInsertionPolicy.allowsAutomaticPaste(
            role: stringAttribute(kAXRoleAttribute as CFString, of: element),
            isEditable: optionalBooleanAttribute("AXIsEditable" as CFString, of: element)
        )
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
        var focusedContainer: AXUIElement?

        while let element = elements.popLast(),
              inspectedElementCount < maximumInspectedElements {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                logger.notice("Accessibility tree search exceeded its time budget")
                return nil
            }
            inspectedElementCount += 1
            if booleanAttribute(kAXFocusedAttribute as CFString, of: element) {
                if isTextInput(element) || isSecureTextField(element) { return element }
                if focusedContainer == nil { focusedContainer = element }
            }
            elements.append(contentsOf: childElements(of: element))
        }
        return focusedContainer
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

    private static func booleanAttribute(_ attribute: CFString, of element: AXUIElement) -> Bool {
        optionalBooleanAttribute(attribute, of: element) == true
    }

    private static func optionalBooleanAttribute(
        _ attribute: CFString,
        of element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? Bool
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
