import AppKit

/// The general pasteboard, saved and put back around a paste, so a paste
/// done for someone does not lose what they had copied.
public enum Clipboard {
    public struct Saved {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    public static func save() -> Saved {
        let items = NSPasteboard.general.pasteboardItems ?? []
        return Saved(items: items.map { item in
            var kept: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { kept[type] = item.data(forType: type) }
            return kept
        })
    }

    public static func restore(_ saved: Saved) {
        let board = NSPasteboard.general
        board.clearContents()
        let items = saved.items.map { kept -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in kept { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }

    public static func put(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public static func put(files: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(files as [NSURL])
    }
}
