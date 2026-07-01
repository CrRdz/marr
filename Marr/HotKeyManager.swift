import Carbon
import Foundation
import AppKit

struct MarrHotKeyConfiguration: Equatable {
    static let keyCodeKey = "shortcut.capture.keyCode"
    static let modifiersKey = "shortcut.capture.modifiers"
    static let scopeKey = "shortcut.capture.scope"
    static let scopeBundleIDKey = "shortcut.capture.scopeBundleID"
    static let scopeAppNameKey = "shortcut.capture.scopeAppName"

    var keyCode: UInt32
    var modifiers: UInt32
    var scope: MarrHotKeyScope
    var scopeBundleID: String
    var scopeAppName: String

    static var current: MarrHotKeyConfiguration {
        let defaults = UserDefaults.standard
        let storedKeyCode = defaults.object(forKey: keyCodeKey) as? Int
        let storedModifiers = defaults.object(forKey: modifiersKey) as? Int
        return MarrHotKeyConfiguration(
            keyCode: UInt32(storedKeyCode ?? Int(kVK_ANSI_0)),
            modifiers: UInt32(storedModifiers ?? Int(cmdKey | shiftKey)),
            scope: MarrHotKeyScope(rawValue: defaults.string(forKey: scopeKey) ?? "") ?? .global,
            scopeBundleID: defaults.string(forKey: scopeBundleIDKey) ?? "",
            scopeAppName: defaults.string(forKey: scopeAppNameKey) ?? ""
        )
    }

    var displayString: String {
        HotKeyFormatter.displayString(keyCode: keyCode, modifiers: modifiers)
    }

    var scopeDisplayString: String {
        switch scope {
        case .global: "Global"
        case .frontmostApplication:
            scopeAppName.isEmpty ? "Specific app" : scopeAppName
        case .disabled: "Disabled"
        }
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: Self.keyCodeKey)
        defaults.set(Int(modifiers), forKey: Self.modifiersKey)
        defaults.set(scope.rawValue, forKey: Self.scopeKey)
        defaults.set(scopeBundleID, forKey: Self.scopeBundleIDKey)
        defaults.set(scopeAppName, forKey: Self.scopeAppNameKey)
    }

    func allowsCurrentFrontmostApplication() -> Bool {
        switch scope {
        case .global:
            return true
        case .disabled:
            return false
        case .frontmostApplication:
            guard !scopeBundleID.isEmpty else { return false }
            return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == scopeBundleID
        }
    }
}

struct MarrWindowCaptureHotKeyConfiguration: Equatable {
    static let keyCodeKey = "shortcut.captureWindow.keyCode"
    static let modifiersKey = "shortcut.captureWindow.modifiers"

    var keyCode: UInt32
    var modifiers: UInt32

    static var current: MarrWindowCaptureHotKeyConfiguration {
        let defaults = UserDefaults.standard
        let storedKeyCode = defaults.object(forKey: keyCodeKey) as? Int
        let storedModifiers = defaults.object(forKey: modifiersKey) as? Int
        return MarrWindowCaptureHotKeyConfiguration(
            keyCode: UInt32(storedKeyCode ?? Int(kVK_ANSI_9)),
            modifiers: UInt32(storedModifiers ?? Int(cmdKey | shiftKey))
        )
    }

    var displayString: String {
        HotKeyFormatter.displayString(keyCode: keyCode, modifiers: modifiers)
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: Self.keyCodeKey)
        defaults.set(Int(modifiers), forKey: Self.modifiersKey)
    }
}

enum MarrHotKeyScope: String, CaseIterable, Identifiable {
    case global
    case frontmostApplication
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .global: "Global"
        case .frontmostApplication: "Specific app"
        case .disabled: "Disabled"
        }
    }
}

enum HotKeyFormatter {
    static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        modifierString(modifiers) + keyString(keyCode)
    }

    static func modifierString(_ modifiers: UInt32) -> String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result
    }

    static func keyString(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_Space: "Space"
        case kVK_Return: "Return"
        case kVK_Escape: "Esc"
        case kVK_Tab: "Tab"
        case kVK_Delete: "Delete"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        default: "Key \(keyCode)"
        }
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }
}

final class HotKeyManager {
    enum HotKeyError: LocalizedError {
        case registerFailed(OSStatus)
        case handlerFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .registerFailed(let status):
                return "RegisterEventHotKey failed with status \(status)."
            case .handlerFailed(let status):
                return "InstallEventHandler failed with status \(status)."
            }
        }
    }

    private let keyCode: UInt32
    private let modifiers: UInt32
    private let identifier: UInt32
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?

    private static let signature = HotKeyManager.fourCharCode("OLNS")
    private static var eventHandlerRef: EventHandlerRef?
    private static var actions: [UInt32: () -> Void] = [:]

    init(keyCode: UInt32, modifiers: UInt32, identifier: UInt32 = 1, action: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.identifier = identifier
        self.action = action
    }

    deinit {
        unregister()
    }

    func register() throws {
        unregister()
        try Self.ensureEventHandlerInstalled()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            unregister()
            throw HotKeyError.registerFailed(registerStatus)
        }

        Self.actions[identifier] = action
    }

    func unregister() {
        Self.actions[identifier] = nil

        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private static func ensureEventHandlerInstalled() throws {
        guard eventHandlerRef == nil else {
            return
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else {
                    return OSStatus(eventNotHandledErr)
                }

                var eventHotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &eventHotKeyID
                )

                guard parameterStatus == noErr,
                      eventHotKeyID.signature == HotKeyManager.signature,
                      let action = HotKeyManager.actions[eventHotKeyID.id] else {
                    return OSStatus(eventNotHandledErr)
                }

                action()
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        guard handlerStatus == noErr else {
            throw HotKeyError.handlerFailed(handlerStatus)
        }
    }

    private static func fourCharCode(_ string: String) -> OSType {
        string.utf8.reduce(0) { result, character in
            (result << 8) + OSType(character)
        }
    }
}
