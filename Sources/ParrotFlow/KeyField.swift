import AppKit

/// A secure text field that answers ⌘V.
///
/// ParrotFlow is an accessory app — `LSUIElement` in Info.plist, and
/// `setActivationPolicy(.accessory)` in `main.swift` — and it builds no main
/// menu at all. A text field's ⌘V is not handled by the field: it is a key
/// equivalent on the Edit ▸ Paste menu item, which this app does not have. So
/// the keystroke arrives and nothing happens, which is what the key dialog did
/// on its first outing.
///
/// One field knowing five shortcuts, rather than the app growing a menu bar.
/// A menu exists to be seen, and an accessory app that sprouts File and Edit
/// the moment a dialog opens is the stranger change.
final class KeyField: NSSecureTextField {

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command,
              let pressed = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }

        // Sent to nil, so the field editor — the responder that actually holds
        // the text — is what receives it. Cut and copy are listed for the
        // shortcuts people try; a secure field refuses them itself, which is
        // the right answer and not this type's business to make.
        let action: Selector
        switch pressed {
        case "v": action = #selector(NSText.paste(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        case "z": action = Selector(("undo:"))
        default: return super.performKeyEquivalent(with: event)
        }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}
