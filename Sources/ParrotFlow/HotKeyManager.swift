import AppKit
import Carbon.HIToolbox

/// Registers one system-wide hotkey, over one of two backends:
///
/// - A character key plus modifiers (⌃⌥Space) goes through Carbon's
///   `RegisterEventHotKey` — no Accessibility permission, and it swallows the
///   keystroke so the combo doesn't leak into the frontmost app.
/// - A bare modifier (Right ⌥) can't be expressed that way, so it falls to
///   `ModifierKeyMonitor`, which polls the global flag state and holds the
///   press back long enough to tell a dictation from a shortcut.
///
/// Both are permission-free. Which one is in play is visible via `binding`.
final class HotKeyManager {

    enum Binding: Equatable {
        case combo(key: String, modifiers: [String])
        case modifier(ModifierKey)

        var isModifierOnly: Bool {
            if case .modifier = self { return true }
            return false
        }

        var displayName: String {
            switch self {
            case .combo(let key, let modifiers):
                return KeyCodes.displayString(key: key, modifiers: modifiers)
            case .modifier(let key):
                return key.displayName
            }
        }
    }

    enum RegistrationError: LocalizedError {
        case unknownKey(String)
        case noModifiers(String)
        case registrationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unknownKey(let name):
                return "Unknown key \"\(name)\" in config.yaml."
            case .noModifiers(let name):
                return "\"\(name)\" needs at least one modifier (command, control, option or shift)."
            case .registrationFailed(let status):
                return "macOS refused to register the hotkey (error \(status)). Another app probably owns it already."
            }
        }
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// A press already delivered turned out to be part of a shortcut — see
    /// `ModifierKeyMonitor`. Never fires on the Carbon path: a combo is
    /// unambiguous by construction.
    var onAbort: (() -> Void)?

    private(set) var binding: Binding?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let modifierMonitor = ModifierKeyMonitor()
    private let signature: OSType = 0x50_46_4C_57  // 'PFLW'

    init() {
        modifierMonitor.onPress = { [weak self] in self?.onPress?() }
        modifierMonitor.onRelease = { [weak self] in self?.onRelease?() }
        modifierMonitor.onAbort = { [weak self] in self?.onAbort?() }
    }

    // MARK: Lifecycle

    @discardableResult
    func register(
        key: String, modifiers: [String], pressDelay: TimeInterval = 0
    ) throws -> Binding {
        unregister()

        // A bare modifier wins over the combo path, and any `modifiers:` list
        // alongside it is meaningless — the key *is* the modifier.
        if let modifierKey = ModifierKey(name: key) {
            modifierMonitor.start(key: modifierKey, pressDelay: pressDelay)
            let binding = Binding.modifier(modifierKey)
            self.binding = binding
            return binding
        }

        guard let keyCode = KeyCodes.code(for: key) else {
            throw RegistrationError.unknownKey(key)
        }
        let carbonMods = KeyCodes.carbonModifiers(modifiers)
        guard carbonMods != 0 else { throw RegistrationError.noModifiers(key) }

        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonMods,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            throw RegistrationError.registrationFailed(status)
        }
        hotKeyRef = ref

        let binding = Binding.combo(key: key, modifiers: modifiers)
        self.binding = binding
        return binding
    }

    func unregister() {
        modifierMonitor.stop()
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        binding = nil
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    // MARK: Carbon plumbing

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                let kind = GetEventKind(event)
                DispatchQueue.main.async {
                    if kind == UInt32(kEventHotKeyPressed) {
                        manager.onPress?()
                    } else if kind == UInt32(kEventHotKeyReleased) {
                        manager.onRelease?()
                    }
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }
}
