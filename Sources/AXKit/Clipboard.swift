import AppKit

/// The general pasteboard, saved and put back around a paste, so a paste
/// done for someone does not lose what they had copied.
public enum Clipboard {
    public struct Saved {
        let items: [[NSPasteboard.PasteboardType: Data]]

        /// The first item's plain text, if it has some.
        public var string: String? {
            items.first?[.string].flatMap { String(data: $0, encoding: .utf8) }
        }

        /// Every type the items carry: rich text, images, file URLs.
        public var types: [String] { items.flatMap { $0.keys.map(\.rawValue) } }
    }

    public static func save(_ board: NSPasteboard = .general) -> Saved {
        let items = board.pasteboardItems ?? []
        return Saved(items: items.map { item in
            var kept: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { kept[type] = item.data(forType: type) }
            return kept
        })
    }

    public static func restore(_ saved: Saved, to board: NSPasteboard = .general) {
        board.clearContents()
        let items = saved.items.map { kept -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in kept { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }

    public static func put(text: String, on board: NSPasteboard = .general) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    public static func put(files: [URL], on board: NSPasteboard = .general) {
        board.clearContents()
        board.writeObjects(files as [NSURL])
    }
}
