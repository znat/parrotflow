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

    /// `NSPasteboard.changeCount` as this app last left it.
    ///
    /// The count only ever goes up, so this matches only while the thing on the
    /// clipboard is still the thing this app put there. That is what makes it
    /// safe to read as "nobody else has been here since" — which is the whole
    /// of `clipboardIsOurs` below.
    ///
    /// Not set by `putBack`: what that restores is the user's own clipboard
    /// from before the paste, and it is not this app's to overwrite.
    ///
    /// -1 until this app writes something, because "never" has to match nothing.
    /// Starting it at the count as it stands would claim whatever the user had
    /// copied before this app ran as ours to write over.
    private(set) static var ownChange = -1

    /// True while the clipboard is this app's to write over: untouched since
    /// `change`, or still holding what this app itself put there.
    ///
    /// The second half is what makes a refused in-place edit able to fall back
    /// to the clipboard at all. The edit ladder pastes — that is the branch that
    /// carries every Electron app — and a paste borrows the clipboard, so by the
    /// time the fallback runs the count has moved and this app is the one that
    /// moved it. Measured in Slack, twice on 2026-08-20: the rewrite was
    /// dropped and the message blamed the user's clipboard.
    ///
    /// It is still a real check. The count only goes up, so `ownChange` matches
    /// only while this app's write is the last one there was.
    static func clipboardIsOurs(unchangedFrom change: Int) -> Bool {
        let now = NSPasteboard.general.changeCount
        return now == change || now == ownChange
    }

    @discardableResult
    static func insert(
        _ text: String,
        mode: Config.Transcription.InsertMode = .paste,
        paste: AppProfile.Paste = .plain
    ) -> Outcome {
        guard !text.isEmpty else { return .pasted }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.writeObjects([item(for: text, paste: paste)])
        let ours = pasteboard.changeCount
        ownChange = ours

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
            putBack(saved, to: pasteboard, ifStillAt: ours)
        }

        return .pasted
    }

    /// Plain text, unless the app in front is known to take more.
    ///
    /// Two ways out before anything is rendered: an app nobody has measured,
    /// and a transcript with no formatting in it. Both write `text` itself
    /// rather than a rendering of it, so a dictation that carries no markup
    /// arrives byte for byte as it left. Stripping markers that were never
    /// there can still move whitespace.
    private static func item(for text: String, paste: AppProfile.Paste) -> NSPasteboardItem {
        guard paste != .plain else { return verbatim(text) }
        let markup = Markup.parse(text)
        guard !markup.isPlain else { return verbatim(text) }
        Log.write("paste: \(paste.rawValue) alongside plain text")
        return markup.item(paste.flavours)
    }

    private static func verbatim(_ text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        return item
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

    struct Item {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    static func snapshot(of pasteboard: NSPasteboard) -> [Item] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        // Only the first item — restoring a full multi-item pasteboard is rarely
        // what anyone needs, and this keeps the copy cheap.
        guard let first = items.first else { return [] }
        return first.types.compactMap { type in
            first.data(forType: type).map { Item(type: type, data: $0) }
        }
    }

    /// Puts back what `insert` borrowed — but only while the paste is still the
    /// newest thing on the clipboard.
    ///
    /// The 0.4s wait is long on the scale of what happens in it. An in-place
    /// edit runs on the main actor from end to end, so this cannot even start
    /// until that returns, and by then a refused edit has fallen through to the
    /// clipboard and left the rewrite there. Putting the pre-paste contents
    /// over that would throw the rewrite away.
    ///
    /// Anything newer also means there is nothing of ours left to take back:
    /// the payload this was meant to clear is already gone, so the restore has
    /// no work to do and only damage to cause.
    static func putBack(_ items: [Item], to pasteboard: NSPasteboard, ifStillAt ours: Int) {
        guard pasteboard.changeCount == ours else {
            Log.write("clipboard: written since the paste; the old contents stay put")
            return
        }
        restore(items, to: pasteboard)
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
