import AXKit
import ApplicationServices
import Foundation

/// Slack's conversation, read through AXKit: one climb from the focused
/// element, one walk of its window, then pure functions over the records.
///
/// It replaced the old walk on raw AX calls after both published
/// the same keys on every view compared (#358). The label rules are in
/// `SlackLabels.swift`.
enum SlackReader {

    /// What one read saw, as plain records, so the rest runs offline.
    struct Screen {
        /// The window and everything under it, in tree order, the window first.
        var window: [Record]
        /// The window, then each element down to the focused one.
        var path: [Record]
        /// The focused element's title, description or placeholder. A reply
        /// box in the Threads view names its thread there.
        var focusedName: String?
        /// Set when the walk ran out of budget or time, so `window` lacks its tail.
        var cutShort = false
    }

    /// Limits relative to the element each one starts from.
    static let paneDepth = 26
    static let lookDepth = 8
    static let rowDepth = 8
    static let composerDepth = 10
    static let nodeLimit = 4000

    /// The budget counts every element, and `nodeLimit` only the labelled
    /// ones: a Slack window had 725 elements on 10-09. No value is cut.
    static let options = ReadOptions(budget: 20_000, depth: 64, seconds: 2, valueLimit: .max)

    static func read(from focused: Element, stop: (@Sendable () -> Bool)? = nil)
        -> Result<Context.Capture, Context.Declined> {
        var options = options
        options.stop = stop
        return interpret(screen(from: focused, options: options).screen)
    }

    static func screen(from focused: Element, options: ReadOptions = options) -> (screen: Screen, walk: ReadResult?) {
        let started = Date()
        let chain = Read.climb(from: focused, options: options)
        let name = [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"].lazy
            .compactMap { focused.string($0) }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let top = chain.lastIndex(where: { $0.record.role == kAXWindowRole }) else {
            return (Screen(window: [], path: [], focusedName: name), nil)
        }
        var rest = options
        rest.seconds = max(0, options.seconds - Date().timeIntervalSince(started))
        let walk = Read.walk(from: chain[top].element, options: rest)
        let cut = walk.stopped == .budget || walk.stopped == .deadline
        let screen = Screen(window: walk.records, path: chain[top...].map(\.record), focusedName: name, cutShort: cut)
        return (screen, walk)
    }

    // MARK: - Pure, over records

    static func interpret(_ screen: Screen) -> Result<Context.Capture, Context.Declined> {
        // The tail of a walk holds the newest messages. Without it the
        // conversation would read as complete and be wrong.
        guard !screen.cutShort else { return .failure(.cutShort) }
        let records = screen.window
        guard !records.isEmpty else { return Context.treeCapture(nil, roster: []) }
        let title = records[0].title
        let conversation = RecordTree.locate(screen.path, in: records).flatMap { focused in
            pane(around: focused, in: records).map {
                assemble(nodes(under: [$0], in: records), title: title)
            } ?? threadRun(around: focused, named: screen.focusedName, in: records)
        }
        return Context.treeCapture(conversation, roster: roster(in: records))
    }

    /// The nearest ancestor that holds the list naming the conversation and
    /// a message under it.
    ///
    /// Climbed from the focused composer rather than picked out of the window:
    /// one Slack window can show two conversations, each with a composer.
    /// Both halves are needed. Slack keeps a second list beside the messages,
    /// "Recent history in <channel>", which names the conversation and holds
    /// none of it.
    static func pane(around focused: Int, in records: [Record]) -> Int? {
        var current = records[focused].parent
        for _ in 0..<paneDepth {
            guard let up = current, records[up].role != kAXWindowRole else { return nil }
            if holdsMessageList(up, in: records) { return up }
            current = records[up].parent
        }
        return nil
    }

    static func holdsMessageList(_ index: Int, in records: [Record]) -> Bool {
        var named = false, messages = false
        for inner in RecordTree.below(index, in: records, depth: lookDepth) {
            guard let label = label(of: records[inner]) else { continue }
            if records[inner].role == "AXList", place(in: label) != nil { named = true }
            if records[inner].role != kAXTextAreaRole, speaker(in: label) != nil { messages = true }
            if named && messages { return true }
        }
        return false
    }

    /// A thread in the Threads view: the list items after the previous reply
    /// box, down to the focused one. That view stacks threads in one flat
    /// list, "Threads, 4 new replies", and no element holds one thread. Read
    /// with axkit on 2026-10-01.
    static func threadRun(around focused: Int, named name: String?,
                          in records: [Record]) -> Assembled? {
        guard let place = name.flatMap(threadPlace(in:)) else { return nil }
        var item = focused
        for _ in 0..<paneDepth {
            guard let up = records[item].parent, records[up].role != kAXWindowRole else { return nil }
            if records[up].role == "AXList" {
                let items = RecordTree.below(up, in: records, depth: 2).filter { records[$0].parent == up }
                guard let at = items.firstIndex(of: item) else { return nil }
                let start = items[..<at].lastIndex { box in
                    RecordTree.below(box, in: records, depth: composerDepth).contains { records[$0].role == kAXTextAreaRole }
                }.map { $0 + 1 } ?? 0
                let found = assemble(nodes(under: Array(items[start..<at]), in: records), title: nil)
                return Assembled(
                    place: place, people: found.people, text: found.text, code: found.code)
            }
            item = up
        }
        return nil
    }

    /// The labelled elements under each root, under one limit. The last root
    /// is read first, so a long thread loses its oldest messages.
    static func nodes(under roots: [Int], in records: [Record]) -> [Node] {
        var parts: [[Node]] = []
        var left = nodeLimit
        for root in roots.reversed() where left > 0 {
            let found = nodes(under: root, in: records, limit: left)
            left -= found.count
            parts.append(found)
        }
        return parts.reversed().flatMap { $0 }
    }

    /// Whether a record is in a message, in code, or in the composer follows
    /// from its parent. A composer's children are the draft, which `input`
    /// publishes. Buttons are dropped, except the member list.
    private static func nodes(under root: Int, in records: [Record], limit: Int) -> [Node] {
        struct Flags { var message = false, code = false, composer = false }
        var flags: [Int: Flags] = [:]
        var found: [Node] = []
        for index in RecordTree.below(root, in: records, depth: paneDepth) {
            guard found.count < limit else { break }
            let record = records[index]
            let above = index == root ? Flags() : record.parent.flatMap { flags[$0] } ?? Flags()
            let text = label(of: record)
            let composer = above.composer || record.role == kAXTextAreaRole
            let here = Flags(
                message: !composer && (above.message || text.flatMap(speaker(in:)) != nil),
                code: above.code || record.subrole == "AXCodeStyleGroup",
                composer: composer)
            flags[index] = here
            if let text, record.role != kAXButtonRole || text.hasPrefix(memberPrefix) {
                found.append(Node(
                    role: record.role, label: text, frame: record.frame.map(cgRect),
                    inMessage: here.message, code: here.code))
            }
        }
        return found
    }

    /// Every channel and person the sidebar lists: the first outline in the
    /// window is taken to be the sidebar.
    static func roster(in records: [Record]) -> [String] {
        guard let outline = RecordTree.below(0, in: records, depth: paneDepth)
            .first(where: { records[$0].role == kAXOutlineRole }) else { return [] }
        var names: [String] = []
        for index in RecordTree.below(outline, in: records, depth: rowDepth) where records[index].role == kAXRowRole {
            guard names.count < maxRoster else { break }
            guard let label = label(of: records[index]) else { continue }
            for name in rosterNames(in: label)
            where names.count < maxRoster && !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// Value first, then title, then description: the value is what a message
    /// says, the description what a screen reader would announce about it.
    static func label(of record: Record) -> String? {
        record.value ?? record.title ?? record.description
    }

    private static func cgRect(_ rect: Rect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
    }
}
