import AppKit
import Carbon.HIToolbox

/// Maps the human-readable key/modifier names used in config.yaml onto the
/// virtual key codes and Carbon modifier masks that `RegisterEventHotKey` wants.
enum KeyCodes {
    private static let table: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,

        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,

        "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return,
        "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape,
        "delete": kVK_Delete, "backspace": kVK_Delete,
        "forwarddelete": kVK_ForwardDelete,
        "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "up": kVK_UpArrow, "down": kVK_DownArrow,
        "home": kVK_Home, "end": kVK_End,
        "pageup": kVK_PageUp, "pagedown": kVK_PageDown,

        "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period,
        "slash": kVK_ANSI_Slash, "backslash": kVK_ANSI_Backslash,
        "semicolon": kVK_ANSI_Semicolon, "quote": kVK_ANSI_Quote,
        "leftbracket": kVK_ANSI_LeftBracket, "rightbracket": kVK_ANSI_RightBracket,
        "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "grave": kVK_ANSI_Grave,

        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5,
        "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10,
        "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14,
        "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18,
        "f19": kVK_F19, "f20": kVK_F20,
    ]

    static func code(for name: String) -> UInt32? {
        let key = name.lowercased().replacingOccurrences(of: "_", with: "")
        guard let code = table[key] else { return nil }
        return UInt32(code)
    }

    /// Carbon modifier mask, for `RegisterEventHotKey`.
    static func carbonModifiers(_ names: [String]) -> UInt32 {
        var mask: UInt32 = 0
        for name in names {
            switch name.lowercased() {
            case "command", "cmd", "⌘": mask |= UInt32(cmdKey)
            case "control", "ctrl", "^": mask |= UInt32(controlKey)
            case "option", "opt", "alt", "⌥": mask |= UInt32(optionKey)
            case "shift", "⇧": mask |= UInt32(shiftKey)
            default: break
            }
        }
        return mask
    }

    /// Cocoa modifier flags, used to poll whether the combo is still held down.
    static func cocoaModifiers(_ names: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name.lowercased() {
            case "command", "cmd", "⌘": flags.insert(.command)
            case "control", "ctrl", "^": flags.insert(.control)
            case "option", "opt", "alt", "⌥": flags.insert(.option)
            case "shift", "⇧": flags.insert(.shift)
            default: break
            }
        }
        return flags
    }

    /// "⌃⌥Space" — for menu items and the settings window.
    static func displayString(key: String, modifiers: [String]) -> String {
        var out = ""
        let lowered = modifiers.map { $0.lowercased() }
        if lowered.contains(where: { ["control", "ctrl", "^"].contains($0) }) { out += "⌃" }
        if lowered.contains(where: { ["option", "opt", "alt", "⌥"].contains($0) }) { out += "⌥" }
        if lowered.contains(where: { ["shift", "⇧"].contains($0) }) { out += "⇧" }
        if lowered.contains(where: { ["command", "cmd", "⌘"].contains($0) }) { out += "⌘" }

        let name = key.lowercased()
        let symbols: [String: String] = [
            "space": "Space", "return": "↩", "enter": "↩", "tab": "⇥",
            "escape": "⎋", "esc": "⎋", "delete": "⌫", "backspace": "⌫",
            "left": "←", "right": "→", "up": "↑", "down": "↓",
            "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
            "semicolon": ";", "quote": "'", "minus": "-", "equal": "=",
            "grave": "`", "leftbracket": "[", "rightbracket": "]",
        ]
        out += symbols[name] ?? key.uppercased()
        return out
    }
}
