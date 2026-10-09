import AXKit
import AppKit
import ApplicationServices

/// Any app no other reader takes: one climb from the focused element, one walk
/// of its window, then pure functions over the records.
///
/// It publishes `text`, `place` and `code`. `people` and `roster` stay empty:
/// `ContextSpelling` offers every entry there as a name, and a generic sidebar
/// would offer "Inbox".
enum GenericReader {

    /// What one read saw, as plain records, so the rest runs offline.
    struct Screen {
        /// The window and everything under it, in tree order, the window first.
        var records: [Record]
        /// The window, then each element down to the focused one.
        var path: [Record]
        var app: String
        /// The window's AXDocument: a file URL in a document app.
        var document: String?
        /// Whether the URL host may name the place: browsers only. Electron
        /// apps load local or app-internal pages.
        var browser = false
        var stopped: ReadResult.Stop?
    }

    /// The pane is the nearest of this many ancestors that holds enough text.
    static let paneClimb = 12
    static let paneChars = 200
    static let placeLimit = 80
    static let scrubLimit = 256

    static let options = ReadOptions(budget: 4000, depth: 40, seconds: 2, callTimeout: 0.1)

    static func read(from focused: Element, app: Pipeline.App) -> Result<Context.Capture, Context.Declined> {
        let (screen, walk) = screen(from: focused, app: app)
        return interpret(screen).map { capture in
            var capture = capture
            capture.walked?.records = walk?.records.count ?? 0
            capture.walked?.stopped = walk?.stopped?.rawValue
            return capture
        }
    }

    static func screen(from focused: Element, app: Pipeline.App,
                       options: ReadOptions = options) -> (screen: Screen, walk: ReadResult?) {
        let started = Date()
        // Teams' tree goes deeper than 40, so the climb takes more than the walk.
        var climb = options
        climb.depth = 64
        let chain = Read.climb(from: focused, options: climb)
        var screen = Screen(records: [], path: [], app: app.name,
                            browser: browserBundleIDs.contains(app.bundleID.lowercased()))
        guard let top = chain.lastIndex(where: { $0.record.role == kAXWindowRole }) else { return (screen, nil) }
        var rest = options
        rest.seconds = max(0, options.seconds - Date().timeIntervalSince(started))
        let walk = Read.walk(from: chain[top].element, options: rest)
        screen.records = walk.records
        screen.path = chain[top...].map(\.record)
        screen.document = Read.document(of: chain[top].element, options: options)
        screen.stopped = walk.stopped
        return (screen, walk)
    }

    // MARK: - Pure, over records

    static func interpret(_ screen: Screen) -> Result<Context.Capture, Context.Declined> {
        let records = screen.records
        guard !records.isEmpty else { return .failure(.blank) }
        // The window itself when nothing in it has the focus: `--tree-read` of an app behind.
        let focused = RecordTree.locate(screen.path, in: records).flatMap { $0 == 0 ? nil : $0 }
        let kept = readable(records, focused: focused)
        let (pane, branch) = pane(around: focused, in: records, kept: kept)
        let lines = self.lines(under: pane, in: records, kept: kept)
        let code = self.code(in: lines, records: records)
        let place = self.place(screen)
        let text = lines.map(\.text).joined(separator: "\n")
        guard !text.isEmpty || !place.isEmpty else { return .failure(.blank) }
        let (tail, truncated) = Context.tail(of: text, limit: Context.maxChars)
        var capture = Context.Capture(text: tail, truncated: truncated, place: place, code: code)
        capture.walked = Context.Walked(branch: branch)
        return .success(capture)
    }

    /// Roles whose whole subtree is the app talking about itself.
    static let furniture: Set<String> = [
        kAXToolbarRole, kAXMenuRole, kAXMenuBarRole, kAXMenuItemRole, kAXMenuBarItemRole,
        kAXScrollBarRole, kAXSplitterRole,
        // Controls: their label is an instruction, not something written.
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole,
        kAXDisclosureTriangleRole, kAXSliderRole, kAXIncrementorRole, kAXImageRole,
    ]

    static let skippedLandmarks: Set<String> = [
        "AXLandmarkNavigation", "AXLandmarkBanner", "AXLandmarkContentInfo",
    ]

    /// Which records may give text: drawn inside the scroll areas above them,
    /// and under no focused element, editable or secure field, furniture or
    /// skipped landmark. The focused field is `input`'s.
    static func readable(_ records: [Record], focused: Int?, skipping landmarks: Set<String> = skippedLandmarks)
        -> [Bool] {
        var kept = [Bool](repeating: false, count: records.count)
        for index in Read.visible(records) { kept[index] = true }
        for (index, record) in records.enumerated() {
            let above = record.parent.map { kept[$0] } ?? true
            let skipped = index == focused || record.isEditable || record.isSecure
                || furniture.contains(record.role) || record.subrole.map(landmarks.contains) == true
            if !above || skipped { kept[index] = false }
        }
        return kept
    }

    /// The nearest ancestor of the focus, at most `paneClimb` up and never the
    /// window, holding `paneChars` of readable text. Else the web area around
    /// the focus, else the window.
    static func pane(around focused: Int?, in records: [Record], kept: [Bool]) -> (index: Int, branch: String) {
        guard let focused else { return (0, "window") }
        let above = RecordTree.ancestors(of: focused, in: records)
        for up in above.prefix(paneClimb) where up != 0 {
            let chars = lines(under: up, in: records, kept: kept).reduce(0) { $0 + $1.text.count }
            if chars >= paneChars { return (up, "pane") }
        }
        if let web = above.first(where: { records[$0].role == "AXWebArea" }) { return (web, "web area") }
        return (0, "window")
    }

    struct Line: Equatable {
        var text: String
        var frame: CGRect?
        var index: Int

        /// Unknown boxes answer true, as in `SlackReader.assemble`.
        func holds(_ other: Line) -> Bool {
            guard let mine = frame, let theirs = other.frame else { return true }
            return mine.insetBy(dx: -2, dy: -2).contains(theirs)
        }
    }

    /// What the readable records under `root` say, one line each, in tree
    /// order. A value is always read; a title or description only on a record
    /// with no children. A paragraph drawn as a group and again as its text
    /// keeps one copy: the same words in nested boxes.
    static func lines(under root: Int, in records: [Record], kept: [Bool]) -> [Line] {
        let range = RecordTree.below(root, in: records, depth: .max)
        let parents = Set(range.compactMap { records[$0].parent })
        var found: [Line] = []
        for index in range where kept[index] {
            let record = records[index]
            guard let said = record.value ?? (parents.contains(index) ? nil : record.title ?? record.description)
            else { continue }
            let frame = record.frame.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
            for row in said.components(separatedBy: .newlines) {
                let text = row.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let line = Line(text: text, frame: frame, index: index)
                if let last = found.last, last.text == text, last.holds(line) || line.holds(last) { continue }
                found.append(line)
            }
        }
        return found
    }

    /// Text under an AXCodeStyleGroup, Chromium's mark for code.
    static func code(in lines: [Line], records: [Record]) -> [String] {
        var spans: [String] = []
        for line in lines where spans.count < SlackReader.maxSpans {
            guard line.text.count <= SlackReader.maxSpanChars, !spans.contains(line.text) else { continue }
            let marked = ([line.index] + RecordTree.ancestors(of: line.index, in: records))
                .contains { records[$0].subrole == "AXCodeStyleGroup" }
            if marked { spans.append(line.text) }
        }
        return spans
    }

    // MARK: - Place

    /// The nearest web area's title, with the URL host in a browser. Else the
    /// window's document file name. Else the window title. Scrubbed either way.
    static func place(_ screen: Screen) -> String {
        if let web = screen.path.last(where: { $0.role == "AXWebArea" }) {
            let title = scrub(web.title ?? "", app: screen.app)
            let host = screen.browser ? web.url.flatMap { URL(string: $0)?.host } : nil
            let named = [title, host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " — ")
            if !named.isEmpty { return capped(named) }
        }
        if let document = screen.document, let url = URL(string: document), url.isFileURL {
            let name = scrub(url.lastPathComponent, app: screen.app)
            if !name.isEmpty { return capped(name) }
        }
        return capped(scrub(screen.path.first?.title ?? "", app: screen.app))
    }

    private static let separators = [" — ", " – ", " - ", " | ", " · ", " • "]

    /// A title without what changes while you dictate or names you: marks,
    /// unread counts, email addresses, and the app's own name with anything
    /// after it, such as a browser profile. "Inbox (1,234) — name@mail" gives
    /// "Inbox".
    static func scrub(_ title: String, app: String) -> String {
        // A page sets its own title. The regexes below backtrack, so they never see more than this.
        var text = String(title.prefix(scrubLimit))
        text = text.replacingOccurrences(of: "[^\\s<>()\\[\\]@]+@[^\\s<>()\\[\\]]+", with: "",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: "\\(\\s*\\d[\\d,.]*(?: [\\d,.]+)*\\+?\\s*\\)", with: "",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: "^[\\s!*•●◦·]+", with: "", options: .regularExpression)
        let separator = separators.first { text.contains($0) } ?? " - "
        var parts: [String] = []
        for part in split(text) {
            let clean = part.trimmingCharacters(in: .whitespaces)
            if !app.isEmpty, clean.caseInsensitiveCompare(app) == .orderedSame { break }
            let count = "^\\d[\\d,]* (new|unread)( (items?|messages?|notifications?))?$"
            guard !clean.isEmpty, clean.range(of: count, options: [.regularExpression, .caseInsensitive]) == nil
            else { continue }
            parts.append(clean)
        }
        return parts.joined(separator: separator)
    }

    private static func split(_ text: String) -> [String] {
        var parts = [text]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts
    }

    private static func capped(_ text: String) -> String {
        guard text.count > placeLimit else { return text }
        let cut = String(text.prefix(placeLimit))
        return cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? cut
    }

    /// Browsers by bundle id, lower case.
    static let browserBundleIDs: Set<String> = [
        "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.dev", "com.google.chrome.canary",
        "org.chromium.chromium", "com.apple.safari", "com.apple.safaritechnologypreview",
        "com.microsoft.edgemac", "com.microsoft.edgemac.beta", "com.microsoft.edgemac.dev",
        "company.thebrowser.browser", "com.brave.browser", "org.mozilla.firefox",
        "com.operasoftware.opera", "com.vivaldi.vivaldi",
    ]
}
