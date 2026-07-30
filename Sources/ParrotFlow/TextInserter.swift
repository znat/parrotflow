import AppKit
import Carbon.HIToolbox

/// Puts transcribed text into whatever app is frontmost.
///
/// Paste-via-clipboard rather than synthesising a keystroke per character:
/// typing a long transcript one `CGEvent` at a time is slow, drops characters
/// in apps that throttle input, and mangles anything non-ASCII. A single ⌘V is
/// atomic from the target app's point of view.
///
/// The cost is that it borrows the pasteboard, so the previous contents are
/// saved and put back afterwards.
enum TextInserter {

    enum Outcome {
        case pasted
        /// Copied deliberately, because the config asked for it.
        case copied
        /// Accessibility isn't granted — text is on the clipboard instead.
        case clipboardOnly

        var isInserted: Bool { self == .pasted }
    }

    @discardableResult
    static func insert(_ text: String, mode: Config.Transcription.InsertMode = .paste) -> Outcome {
        guard !text.isEmpty else { return .pasted }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard mode == .paste else { return .copied }

        guard Permissions.accessibility == .granted else {
            // Leave the text on the clipboard — the user can paste it manually,
            // which is a far better failure mode than losing the dictation.
            return .clipboardOnly
        }

        postCommandV()

        // Restoring immediately races the paste: the target app reads the
        // pasteboard asynchronously after receiving the keystroke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            restore(saved, to: pasteboard)
        }

        return .pasted
    }

    // MARK: - Keystroke

    private static func postCommandV() {
        // .cghidEventTap so the event enters at the same point as real hardware
        // input, which is what apps listening for a paste actually observe.
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Pasteboard preservation

    private struct Item {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [Item] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        // Only the first item — restoring a full multi-item pasteboard is rarely
        // what anyone needs, and this keeps the copy cheap.
        guard let first = items.first else { return [] }
        return first.types.compactMap { type in
            first.data(forType: type).map { Item(type: type, data: $0) }
        }
    }

    private static func restore(_ items: [Item], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let item = NSPasteboardItem()
        for entry in items {
            item.setData(entry.data, forType: entry.type)
        }
        pasteboard.writeObjects([item])
    }
}
