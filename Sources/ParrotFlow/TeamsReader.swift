import AXKit
import ApplicationServices

/// Microsoft Teams, the WebView2 app: the chat around the focus. The walk is
/// the generic reader's; this picks the messages out of its records.
///
/// Measured 10-09 on two chats: the message list holds, per message, an
/// AXHeading whose text is a screen-reader summary drawn 0×1, then an
/// AXApplicationGroup with that summary as its title and the visible parts
/// under it. Names are titled AXPopUpButtons. The chat view has no main
/// landmark, so the generic reader took the sidebar or read each message twice.
enum TeamsReader {

    static func read(from focused: Element, app: Pipeline.App, stop: (@Sendable () -> Bool)? = nil)
        -> Result<Context.Capture, Context.Declined> {
        var options = GenericReader.options
        options.stop = stop
        let (screen, walk) = GenericReader.screen(from: focused, app: app, options: options)
        return interpret(screen).map { capture in
            var capture = capture
            capture.walked?.records = walk?.records.count ?? 0
            capture.walked?.stopped = walk?.stopped?.rawValue
            return capture
        }
    }

    // MARK: - Pure, over records

    static func interpret(_ screen: GenericReader.Screen) -> Result<Context.Capture, Context.Declined> {
        let records = screen.records
        guard !records.isEmpty else { return .failure(.blank) }
        let focused = RecordTree.locate(screen.path, in: records).flatMap { $0 == 0 ? nil : $0 }
        guard let list = messageList(around: focused, in: records) else {
            // A chat with no message yet: the caret is in the composer, and the sidebar is not the chat.
            guard let focused, records[focused].isEditable else { return GenericReader.interpret(screen) }
            let place = self.place(before: records.count, in: records, screen: screen)
            guard !place.isEmpty else { return .failure(.blank) }
            var capture = Context.Capture(text: "", truncated: false, place: place)
            capture.walked = Context.Walked(branch: "empty chat", chromium: screen.chromium)
            return .success(capture)
        }
        let visible = Set(Read.visible(records))
        var lines: [String] = [], people: [String] = [], code: [String] = []
        for message in RecordTree.below(list, in: records, depth: 2)
        where records[message].parent == list && records[message].subrole == messageSubrole {
            let said = read(message: message, in: records, visible: visible)
            let line = said.line.isEmpty ? records[message].title ?? "" : said.line
            if !line.isEmpty { lines.append(line) }
            for name in said.names where people.count < SlackReader.maxSpans && !people.contains(name) {
                people.append(name)
            }
            for span in said.code where code.count < SlackReader.maxSpans && !code.contains(span) {
                code.append(span)
            }
        }
        let (text, truncated) = Context.tail(of: lines.joined(separator: "\n"), limit: Context.maxChars)
        var capture = Context.Capture(text: text, truncated: truncated,
                                      place: place(before: list, in: records, screen: screen),
                                      people: people, code: code)
        capture.walked = Context.Walked(branch: "messages", chromium: screen.chromium)
        return .success(capture)
    }

    static let messageSubrole = "AXApplicationGroup"

    /// A record whose children are messages: an AXHeading and an
    /// AXApplicationGroup among them. The nearest to the focus, or with
    /// nothing focused the one holding the most messages.
    static func messageList(around focused: Int?, in records: [Record]) -> Int? {
        var children: [Int: [Int]] = [:]
        for (index, record) in records.enumerated() {
            if let parent = record.parent { children[parent, default: []].append(index) }
        }
        let count = { (index: Int) in children[index, default: []].filter { records[$0].subrole == messageSubrole }.count }
        let lists = children.keys.sorted().filter { index in
            let under = children[index, default: []]
            return under.contains { records[$0].role == kAXHeadingRole } && count(index) > 0
        }
        guard let focused else { return lists.max { count($0) < count($1) } }
        for up in RecordTree.ancestors(of: focused, in: records).prefix(GenericReader.paneClimb) {
            if let list = lists.first(where: { RecordTree.ancestors(of: $0, in: records).contains(up) }) {
                return list
            }
        }
        return nil
    }

    /// One message's visible words in order, with the names Teams marks as
    /// people. Buttons, images and fields are skipped with what is under them.
    static func read(message: Int, in records: [Record], visible: Set<Int>)
        -> (line: String, names: [String], code: [String]) {
        var parts: [String] = [], names: [String] = [], code: [String] = []
        var skipBelow: Int?
        for index in RecordTree.below(message, in: records, depth: .max) where index != message {
            let record = records[index]
            if let depth = skipBelow {
                if record.depth > depth { continue }
                skipBelow = nil
            }
            guard visible.contains(index), !record.isEditable, !record.isSecure else {
                skipBelow = record.depth
                continue
            }
            if record.role == kAXPopUpButtonRole {
                if let name = (record.title ?? record.description)?.trimmingCharacters(in: .whitespaces),
                   !name.isEmpty {
                    parts.append(name)
                    if name.count <= SlackReader.maxSpanChars { names.append(name) }
                }
                skipBelow = record.depth
            } else if GenericReader.furniture.contains(record.role) || record.role == kAXButtonRole {
                skipBelow = record.depth
            } else if record.role == kAXStaticTextRole, let value = record.value {
                parts.append(value)
                let marked = RecordTree.ancestors(of: index, in: records).prefix { $0 != message }
                    .contains { records[$0].subrole == "AXCodeStyleGroup" }
                let span = value.trimmingCharacters(in: .whitespaces)
                if marked, !span.isEmpty, span.count <= SlackReader.maxSpanChars { code.append(span) }
            }
        }
        var line = parts.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ([.,;:!?])", with: "$1", options: .regularExpression)
        line = line.trimmingCharacters(in: .whitespaces)
        return (line, names, code)
    }

    /// The chat's name: the last titled heading before the message list, which
    /// is the chat header. Else the generic place, from the page title.
    static func place(before list: Int, in records: [Record], screen: GenericReader.Screen) -> String {
        let header = records[..<list].lastIndex { $0.role == kAXHeadingRole && $0.title?.isEmpty == false }
        let named = header.map { GenericReader.capped(GenericReader.scrub(records[$0].title ?? "", app: screen.app)) }
        return named.flatMap { $0.isEmpty ? nil : $0 } ?? GenericReader.place(screen)
    }
}
