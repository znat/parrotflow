import AXKit
import ApplicationServices
import Foundation

/// The new Outlook for Mac, which is native AppKit: the mail in the reading
/// pane, with its subject as the place.
///
/// It never walks the window. The toolbar's search field holds itself as its
/// only child, at every level: 197 levels on 10-09, so a window walk always
/// stops by depth. The message list is walked by no one either: 220 rows on
/// 10-09, most of the 400–1200 ms a window walk took, and its rows hold mail
/// previews. Outlook marks every cell focused, so no flag is trusted.
enum OutlookReader {

    /// What one read saw: the reading pane's parts under one root, so the rest runs offline.
    struct Screen {
        /// A root, then each part read, in order.
        var records: [Record]
        var app: String
        var title: String?
        /// The focused element's identifier, from the climb.
        var focusedIdentifier: String?
        var branch = "window"
        var stopped: ReadResult.Stop?
    }

    static let headerID = "HeaderMainContainer"
    static let subjectFieldID = "subjectTextField"
    static let composeIDs: Set<String> = ["toTextField", subjectFieldID]
    /// Split groups nest three deep around the reading pane (10-09).
    static let splitDepth = 4

    static func read(from focused: Element, app: Pipeline.App, stop: (@Sendable () -> Bool)? = nil)
        -> Result<Context.Capture, Context.Declined> {
        var options = GenericReader.options
        options.stop = stop
        return interpret(screen(from: focused, app: app, options: options))
    }

    static func screen(from focused: Element, app: Pipeline.App, options: ReadOptions) -> Screen {
        let started = Date()
        let chain = Read.climb(from: focused, options: options)
        var screen = Screen(records: [], app: app.name, focusedIdentifier: chain.last?.record.identifier)
        guard let top = chain.lastIndex(where: { $0.record.role == kAXWindowRole }) else { return screen }
        let window = chain[top].element
        screen.title = chain[top].record.title
        let deadline = started.addingTimeInterval(options.seconds)
        let over = { Date() >= deadline || options.stop?() == true }
        let parts = readingParts(of: window, timeout: options.callTimeout, over: over)
        if parts.isEmpty, over() { screen.stopped = .deadline }
        if !parts.isEmpty { screen.branch = "reading pane" }
        // No reading pane found: the title alone, since a window walk meets the list and the search field.
        var records = [Record(role: kAXGroupRole)]
        for part in parts {
            var rest = options
            rest.seconds = max(0, options.seconds - Date().timeIntervalSince(started))
            rest.budget = options.budget - records.count + 1
            let walk = Read.walk(from: part, options: rest)
            let base = records.count
            for var record in walk.records {
                record.depth += 1
                record.parent = record.parent.map { $0 + base } ?? 0
                records.append(record)
            }
            if let stopped = walk.stopped { screen.stopped = stopped }
            if walk.stopped == .budget || walk.stopped == .deadline { break }
        }
        screen.records = records
        return screen
    }

    /// The children of the innermost split group under the window's first
    /// split group, less splitters and the message list. Empty outside the
    /// main window, so another window gives its title only, and empty when
    /// `over` says the read's time is up.
    static func readingParts(of window: Element, timeout: Float, over: () -> Bool) -> [Element] {
        func peek(_ element: Element) -> String {
            guard !over() else { return "" }
            element.setMessagingTimeout(timeout)
            return element.role ?? ""
        }
        window.setMessagingTimeout(timeout)
        let top = window.children
        guard let at = content(among: top.map(peek)) else { return [] }
        var group = top[at]
        for _ in 0..<splitDepth {
            let children = group.children.map { (element: $0, role: peek($0)) }
            if let inner = children.last(where: { $0.role == kAXSplitGroupRole }) {
                group = inner.element
                continue
            }
            let peeks = children.map { child in Peek(role: child.role, childRoles: child.element.children.map(peek)) }
            guard !over() else { return [] }
            return parts(peeks).map { children[$0].element }
        }
        return []
    }

    /// The content area: the window's first split group. The toolbar before
    /// it holds the search field that nests in itself.
    static func content(among roles: [String]) -> Int? {
        roles.firstIndex(of: kAXSplitGroupRole)
    }

    struct Peek {
        var role: String
        var childRoles: [String]
    }

    /// Which children to read. A list holds a table or an outline as a child.
    static func parts(_ children: [Peek]) -> [Int] {
        let lists: Set<String> = [kAXTableRole, kAXOutlineRole]
        return children.indices.filter { index in
            let child = children[index]
            return child.role != kAXSplitterRole && !lists.contains(child.role)
                && !child.childRoles.contains(where: lists.contains)
        }
    }

    // MARK: - Pure, over records

    static func interpret(_ screen: Screen) -> Result<Context.Capture, Context.Declined> {
        let records = screen.records
        let place = self.place(screen)
        var capture = Context.Capture(text: "", truncated: false, place: place)
        let composing = records.contains { $0.identifier.map(composeIDs.contains) == true }
        // A draft is input. Its body showed no children on 10-09, so only the place is read.
        if !composing, let web = records.firstIndex(where: { $0.role == "AXWebArea" }) {
            let kept = GenericReader.readable(records, focused: nil)
            let lines = GenericReader.lines(under: web, in: records, kept: kept)
            let (text, truncated) = Context.tail(of: lines.map(\.text).joined(separator: "\n"), limit: Context.maxChars)
            capture = Context.Capture(text: text, truncated: truncated, place: place,
                                      code: GenericReader.code(in: lines, records: records))
        }
        guard !capture.text.isEmpty || !place.isEmpty else { return .failure(.blank) }
        capture.walked = Context.Walked(records: max(0, records.count - 1), stopped: screen.stopped?.rawValue,
                                        branch: composing ? "compose" : screen.branch)
        return .success(capture)
    }

    /// The subject: the header's first text, else a draft's subject field
    /// unless the caret is in it, else the window title. Scrubbed of
    /// addresses, counts and the app name.
    static func place(_ screen: Screen) -> String {
        let records = screen.records
        let header = records.firstIndex { $0.identifier == headerID }.flatMap { header in
            records.indices.first { records[$0].parent == header && records[$0].role == kAXStaticTextRole }
        }.flatMap { records[$0].value }
        let field = screen.focusedIdentifier == subjectFieldID ? nil
            : records.first { $0.identifier == subjectFieldID }?.value
        for subject in [header, field, screen.title].compactMap({ $0 }) {
            let place = GenericReader.capped(GenericReader.scrub(subject, app: screen.app))
            if !place.isEmpty { return place }
        }
        return ""
    }
}
