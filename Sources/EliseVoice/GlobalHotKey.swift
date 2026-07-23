import Carbon.HIToolbox
import Foundation

private let eliseVoiceHotKeySignature: OSType = fourCharacterCode("ELIS")

enum GlobalHotKeyError: Error {
    case installingHandler(OSStatus)
    case registeringShortcut(OSStatus)
}

final class GlobalHotKey: @unchecked Sendable {
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let action: @Sendable () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping @Sendable () -> Void) throws {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )

                guard status == noErr, identifier.signature == eliseVoiceHotKeySignature else {
                    return OSStatus(eventNotHandledErr)
                }

                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                hotKey.action()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerReference
        )

        guard handlerStatus == noErr else {
            throw GlobalHotKeyError.installingHandler(handlerStatus)
        }

        do {
            try register()
        } catch {
            if let eventHandlerReference {
                RemoveEventHandler(eventHandlerReference)
            }
            throw error
        }
    }

    func refreshRegistration() throws {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }
        try register()
    }

    deinit {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
    }

    private func register() throws {
        let identifier = EventHotKeyID(signature: eliseVoiceHotKeySignature, id: 1)
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
        guard registrationStatus == noErr else {
            throw GlobalHotKeyError.registeringShortcut(registrationStatus)
        }
    }
}

private func fourCharacterCode(_ value: StaticString) -> OSType {
    precondition(value.utf8CodeUnitCount == 4)
    return value.withUTF8Buffer { buffer in
        buffer.reduce(0) { ($0 << 8) | OSType($1) }
    }
}
